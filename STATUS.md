# VisionCraft status

Last updated: 2026-06-03

> Current runtime path: Mac ALVR host (`VisionCraftHost`) + ALVR `server_core` + VisionCraft headset client (`ALVRClient`).
> Source-control model: the vendored ALVR version and VisionCraft ALVR changes live under `visionos-app/`; prepare scripts validate/build artifacts only.
> Older notes about RemoteImmersiveSpace / custom companion relay are historical only.

## Current beta flow

```bash
scripts/vc.sh bootstrap
scripts/vc.sh package-beta
scripts/vc.sh host --rebuild --synthetic
scripts/vc.sh headset
scripts/vc.sh verify   # ALVR-only synthetic stream
scripts/vc.sh test-sender
scripts/vc.sh minecraft # press F7 for Minecraft
scripts/vc.sh verify
```

Current OOTB work focuses on a packaged local beta: self-checking scripts, a guided Mac host UI, VisionCraft-specific headset onboarding, and explicit signing/pairing recovery. AVP install still requires Apple signing/provisioning through Xcode or TestFlight.

## Milestones

| Milestone | Description | Status |
|-----------|-------------|--------|
| **M0** | RemoteImmersiveSpace + Metal stereo on Vision Pro | **Visual + head tracking passed**; 10-minute comfort run deferred |
| **M1** | Java ↔ native bridge (test patterns + pose) | **Automated in CI** via `MockVisionCraftHost`; visual check still needs real host |
| **M2** | AppleVisionProvider, no SteamVR path | **Integrated** in vendored Vivecraft, default plugin |
| **M3** | Stereo main menu on headset | ALVR path wired; hardware validation pending |
| **M4** | In-world head-tracked view | ALVR pose bridge wired; hardware validation pending |
| **M5** | 30-minute survival MVP | Controller input wired; hardware validation pending |
| **M6** | IOSurface / no CPU readback | Stub only (`MetalInterop.mm`) |

## What works in repo today

- Vendored Vivecraft Apple provider
- Bridge v1 loopback protocol + metrics
- **`MockVisionCraftHost`** — headless M1 server (no Mac/AVP)
- **CI integration tests** — stereo frame + pose round-trip on every push
- Mac ALVR host Swift app (ALVR `server_core` + Bridge v1 server + loopback control API)
- Comfort defaults (seated, HMD aim, fake controllers for crosshair)
- OpenVR `create()` skip on Apple Vision path

## Hardware validation checklist

```bash
scripts/vc.sh host --rebuild --synthetic
scripts/vc.sh headset
scripts/vc.sh verify
scripts/vc.sh observe 30
scripts/vc.sh test-sender
scripts/vc.sh verify
```

Synthetic frames prove host -> ALVR -> AVP without Java or Minecraft. Then validate the test-pattern sender with `scripts/vc.sh test-sender`, then Minecraft with `scripts/vc.sh minecraft`, press F7, and run the controller checklist in `docs/runbook.md`.

## 2026-06-03 audit remediation (code)

- Bridge session warmup: Mac host sends `paused` on ALVR connect, then `ready` after tracking + `view_config`; Java `sendFrame` is gated on `ready`.
- Control API: `/status` exposes `bridge_streaming_ready`, `sent_video_config`, `frames_dropped_no_config`; `scripts/vc.sh verify` checks `alvr_frames_sent` and encoder counters.
- Java bridge: UTF-8 line reader, ping/pong watchdog, pose staleness (250 ms), controller pose wiring, frame id reset on `ready`.
- ALVRClient: foveation disabled in capabilities, decode overrun threshold fixed, `renderStarted` cleared on stream stop, stutter path calls `resetEncoding()`.
- Docs: [docs/alvr-render-orientation.md](docs/alvr-render-orientation.md) (no `render_orientation` on HEVC path); [NOTICE](NOTICE); [docs/distribution.md](docs/distribution.md).

## 2026-06-02 hardware hardening findings

- `scripts/vc.sh host` intentionally runs `clean`, so it kills any Java sender or Minecraft frame source. Use `scripts/vc.sh synthetic` on an already-running host when isolating ALVR after a frame source is active.
- Host video config recovery is deliberate: `AlvrServerCoordinator` sends VPS/SPS/PPS through ALVR decoder config and keeps them inline on IDR frames so ALVRClient can recreate VideoToolbox state after a decoder reset.
- ALVRClient now falls back to creating a VideoToolbox decoder from incoming IDR NALs when the decoder config event is missed or arrives out of order.
- Every hardware report should include `.run/observability/<timestamp>/` from `scripts/vc.sh observe 30`; use `scripts/vc.sh avp-console 120` when Xcode console output matters.

## Latest M0 preflight

2026-05-31 local preflight:

- `VisionCraftHost` builds with Xcode 26.3.
- `/health`, `/status`, `/bridge/start`, and `/immersive/open` are reachable through the loopback control API.
- macOS reports `supports_remote_scenes: true`.
- With a real Vision Pro selected, `openImmersiveSpace` reached `immersive_open: true`, `remote_device_identifier_available: true`, and the renderer submitted frames.
- Black-screen root cause: the early debug pass wrote color without valid depth. Compositor Services needs visible pixels to have alpha > 0 and a valid depth value.
- M0 debug pass renders a depth-writing, world-anchored stereo panel using `WorldTrackingProvider`, drawable per-eye view/projection data, layered layout, explicit viewports, and vertex amplification. User confirmed distinct left/right color and head-tracked behavior.
- No separate Vision Pro app install is expected for the RemoteImmersiveSpace path.

### 2026-05-31 evening — Minecraft frame presentation fixes (code-grounded, untested on device)

Three defects from the first Minecraft playtest were root-caused and fixed in code:

1. **"Small square" game view.** The external-frame path reused `composite_vertex`,
   which places geometry on a ±0.35 m panel at 1.5 m via MVP — a tiny floating quad.
   Minecraft already renders each eye with its own projection, so the correct
   presentation is a **1:1 fullscreen blit per eye**. Added `fullscreen_vertex`
   (oversized NDC triangle, constant mid-range depth, amplification to both eye
   viewports) and rewrote `compositeExternalTextures` to draw 3 verts fullscreen
   with no MVP. UV mapping preserves the verified upright orientation.
2. **OOM crash (~119 GB).** The render loop runs on a long-lived background GCD
   block with no run loop, so per-frame autoreleased Metal objects (command
   buffers, drawables, encoders) never drained. Wrapped each loop iteration in
   `autoreleasepool`.
2b. **OOM crash, second cause (~259 GB, observed on the live remote AVP path).**
   Even with the autorelease pool, the render loop had **no frames-in-flight
   bound**: it committed a command buffer and immediately looped. Each committed
   buffer retains its drawable (per-eye color ~65 MB + depth ~32 MB) until its GPU
   completion handler fires. On the **remote** Vision Pro path presentation happens
   over the network, so completion lags submission and command buffers accumulate
   unbounded (`~16.6k submitted × ~16 MB ≈ 259 GB`). Added the canonical Metal
   throttle: a `DispatchSemaphore(value: 3)` waited before `commit()` and signaled
   in the completion handler. A timed wait (0.5 s) degrades to *dropping* frames —
   not leaking them — and lets the loop tear down cleanly if completion stalls
   entirely. Also hardened `JavaBridgeServer`: an unparseable `frame` header now
   drops the connection instead of scanning the binary payload as text (desync).
3. **Flicker / tearing.** `FrameReceiver.upload()` (network thread) called
   `texture.replace()` on the same texture the render thread was sampling on the
   GPU. Made `FrameReceiver` 3-buffered with a lock so the CPU never overwrites
   the most-recently-published pair.

### 2026-05-31 evening — per-eye device-true projection over the bridge (code-grounded, untested on device)

The fixed symmetric FOV / device-frustum mismatch above is now resolved in code.

- **New `view_config` bridge message** (`bridge/protocol.md`): host → Java, carries
  measured IPD plus per-eye frustum tangents `[left, right, up, down]` and the
  recommended render `width`/`height` for each view. Sent on change and on a ~72-frame
  heartbeat so late-connecting Java clients still converge.
- **Host extraction** (`CompositorRenderer.publishViewConfigIfNeeded`): tangents are
  derived from `drawable.computeProjection(viewIndex:)` by unprojecting NDC corners
  through the inverse matrix (robust to the reverse-Z / right-up-back convention),
  because `cp_view_get_tangents` is `API_UNAVAILABLE(macosx)`. IPD is the distance
  between the two eye-view transform origins.
- **Java application**: `AppleNativeBridge.ViewConfig` stores the parsed config (with
  defensive `parseViewConfig` that ignores malformed messages). `AppleProjectionProvider
  .projectionFromTangents` builds an off-axis `Matrix4f.frustum` using **Minecraft's own
  near/far** (render distance unchanged), and `AppleVisionStereoRenderer.getProjectionMatrix`
  uses it when a config is present, else falls back to the prior symmetric projection.
  `AppleVisionProvider.getIPD()` prefers the measured IPD when within 0.04–0.085 m.
- **Buffer aspect** is intentionally left at `1512×1680`. Geometry is now correct
  regardless of buffer aspect (the host blits each eye buffer 1:1 into its device
  viewport), so matching the exact device pixel aspect is only a sampling-quality
  refinement, deferred to avoid resizing render targets blind.
- Verified: view 0 → `eyeIndex 0` → left texture (`Composite.metal`), so host view[0]
  = left eye = Java `eyeType 0` = `view_config` index 0 — consistent end to end.
- Builds green: 12 bridge tests pass (incl. `clientReceivesAsymmetricViewConfig`),
  Swift host `BUILD SUCCEEDED`, Fabric mod `BUILD SUCCESSFUL`.

### 2026-05-31 night — Apple host best-practices + performance audit (code-grounded)

Audited the Swift host against the CompositorServices/Metal/ARKit SDK headers
(`MacOSX.sdk/.../CompositorServices.framework/Headers/{frame,drawable,cp_types}.h`).

- **Frame-loop ordering fixed** (`CompositorRenderer.renderNextFrame`): now follows
  the documented timeline — `startUpdate`/`endUpdate` → `predictTiming` → wait on
  `optimalInputTime` → `startSubmission` → `queryDrawables`. Previously the drawable
  was queried *before* `startSubmission()`; the header says query drawables "when
  you're ready to encode" (the submission phase). `predictTiming()` is still called
  before `queryDrawables()` (required) and all pose work stays in the submission phase.
- **ARKit teardown** (`detach()`): now calls `ARKitSession.stop()` so the world-tracking
  provider doesn't keep running after the immersive space closes.
- **Texture storage mode** (`FrameReceiver`): eye textures are now `.shared` on
  unified-memory Apple Silicon (the AVP host class) so the GPU samples CPU-written
  bytes with no managed-resource sync; falls back to `.managed` on discrete GPUs.
- **Receive hot path** (`JavaBridgeServer`): pass the buffer slices straight to the
  synchronous frame handler instead of allocating two ~10 MB/eye `Data` copies per
  frame before the texture upload.
- **Dead code removed**: unused system-default `device` property, `blit(...)`, and
  `clearPassDescriptor(...)`.
- Confirmed `drawable.computeProjection(viewIndex:)` uses the default `.rightUpBack`
  (+Y up) convention, matching the tangent extraction.
- Swift host still `BUILD SUCCEEDED`.

Biggest remaining performance lever is unchanged and architectural: the CPU
read-back frame path (M6 IOSurface / zero-copy), intentionally deferred.

## Client frame-submit audit (Java)

The Java submit path (`AppleFrameSubmitter` + new `AsyncFrameSender`) was hardened
for performance and reliability while on-device testing is deferred:

- **Off-thread send.** The blocking ~20 MB socket write moved off the render thread
  to a dedicated `AsyncFrameSender` thread. `endFrame()` no longer stalls on network
  backpressure, so a slow host can't induce render-thread frame hitches.
- **Latest-frame-wins.** If a newer frame is committed while one is still queued, the
  stale frame is dropped (recycled), so end-to-end latency stays bounded under load
  instead of building a send backlog — mirrors the host's latest-wins `FrameReceiver`.
- **Zero per-frame allocation.** Eye pixel buffers come from a fixed 3-slot pool, so the
  hot path eliminates the ~40 MB/frame of `new byte[]` churn (and the GC pauses it caused
  at 72–90 Hz). Pixels are mapped straight out of the PBO into the pooled buffer.
- **Lifecycle.** `AppleVisionProvider.destroy()` closes the submitter (joins the sender
  thread); the renderer's `destroyBuffers()` frees the PBOs on the render thread.
- Covered by `AsyncFrameSenderTest` (in-order delivery, backpressure dropping, buffer
  pooling/resize, commit-after-close safety); full bridge suite green; mod `:common`
  compiles.

## Async PBO readback + device-true render resolution

Two follow-ups landed (still no on-device test; both are code-grounded and verified by
compile/tests):

- **(a) Device-recommended render size.** `AppleVisionStereoRenderer` now sizes the eye
  buffers to the host's `view_config` recommended dimensions (1:1 sampling on the headset)
  instead of the fixed `1512×1680`. Dims are clamped to `[512, 4096]`. Adoption is a single
  stable reinit: `endFrame()` detects the change once `view_config` arrives, sets
  `resolution` + `reinitFrameBuffers`, and the next frame rebuilds the FB stack at the new
  size. The host's `FrameReceiver` already resets its texture pool on a dimension change,
  so the switch is safe mid-session.
- **(b) Async double-buffered PBO readback.** `AppleFrameSubmitter` replaced the synchronous
  `glGetTexImage`-to-client-memory copy (which stalls the GL pipeline until the GPU
  finishes) with a ping-pong of pixel-pack buffers: each frame issues a non-blocking
  `glGetTexImage` into the current PBO and maps the *previous* PBO (whose DMA already
  completed) read-only, copying it into the pooled send buffer. Net effect: the render
  thread no longer stalls on GPU→CPU transfer, at the cost of one frame of transport
  latency (the host reprojects against its own latest pose regardless). The transferred
  bytes are identical to before, so there's no pixel/orientation change. GL state
  (`GL_TEXTURE_BINDING_2D`, `GL_PIXEL_PACK_BUFFER_BINDING`) is saved/restored each call;
  PBOs are recreated lazily on size change and freed in `destroyBuffers()`.

True cross-process **IOSurface zero-copy** is still future work: it needs a JNI native lib
(none is wired today — `bridge/native/MetalInterop.mm` is an unbuilt stub) plus mach-port
IPC to share the surface across the Minecraft and host processes (a mach port can't cross
the TCP bridge). The PBO path removes the readback stall without that risk.

## Hand / pinch input (wire contract only — host source blocked on macOS)

A `hand` bridge message (chirality, `tracked`, `pinch` 0..1, advisory wrist pose) and its full
**Java consumer** are implemented and tested: `AppleNativeBridge` parses it into `HandState`, and
`AppleVisionProvider.processInputs()` maps **right pinch → primary (attack/mine, GUI click)** and
**left pinch → secondary (use/place)** with engage/release **hysteresis** (0.7/0.4) and edge-
triggered `InputSimulator` mouse press/release. Held buttons are force-released on disconnect and
on `destroy()` so input can never stick.

**Critical platform finding (compiler- and docs-grounded):** ARKit `HandTrackingProvider` is a
local on-device visionOS feature and is **`unavailable` on macOS**. The macOS Spatial Rendering /
RemoteImmersiveSpace host only vends head pose (`WorldTrackingProvider`), so it **cannot emit
`hand`**. The host code was therefore kept head-tracking-only. The `hand` contract is exercised
end-to-end by `MockVisionCraftHost` (→ `BridgeIntegrationTest.clientReceivesHandPinch`) and is the
drop-in integration point for a **future visionOS-native helper** that runs hand tracking on-device
and streams pinch over the bridge. Until such a source exists, hands stay untracked and contribute
no input — the playable path today is **head aim + Mac keyboard/mouse**.

## visionOS companion app — Phase 1 scaffolding (code-grounded, not yet built in Xcode)

The hand/pinch finding above (no on-device hand source on macOS) is being resolved the only way
the Mac-only constraint allows: a **native visionOS companion app** that runs on the Vision Pro,
does its own head + hand tracking, and turns the Mac into a video encoder/relay. This **flips the
architecture** — the AVP becomes the renderer; the Mac HEVC-encodes the eye frames Minecraft
already produces and streams them to the headset.

- **Wire protocol** (`bridge/stream-protocol.md`, new): Mac ↔ AVP over LAN TCP, Bonjour-discovered
  (`_visioncraft-stream._tcp`), length-prefixed binary envelopes. Messages: `HELLO`, `PING`/`PONG`,
  `VIDEO_CONFIG`, `VIDEO_FRAME` (HEVC side-by-side, Annex-B), `UPLINK` (verbatim `bridge/protocol.md`
  pose/hand/recenter JSON), `BYE`. `maxMessageLength` 64 MiB. The **loopback Java bridge is unchanged**.
- **App** (`visionos-app/`, new, ~12 Swift files + shader + Info.plist/entitlements + README):
  - `VisionCraftCompanionApp` + `ContentStageConfiguration`: `ImmersiveSpace` → `CompositorLayer`,
    `.layered`, foveation off, `.full` immersion, upper limbs visible.
  - `AppModel`: plain `@Observable` (not `@MainActor`, to match the off-main `CompositorLayer`
    content closure that hands over a non-`Sendable` `LayerRenderer`); UI state written via an
    explicit main-thread hop. Owns the `ARKitSession` (world + hand), client, uplink, renderer.
  - `CompanionRenderer`: stereo render loop adapted from the macOS host — per-eye viewports +
    vertex amplification, world-anchored device pose, **the same `DispatchSemaphore(value: 3)`
    frames-in-flight throttle** that fixed the host OOM. Two paths: composite the decoded
    side-by-side video, or (Phase 1) draw a loud debug stereo pattern when no video yet.
  - `TrackingUplink` + `HandPinch`: `WorldTrackingProvider` → `pose`, `HandTrackingProvider`
    anchor updates → `hand` (index↔thumb pinch 0..1), emitted as `bridge/protocol.md` lines at
    ~90 Hz. This is the on-device hand source the macOS host structurally cannot provide.
  - `StreamClient` + `StreamProtocol`: Bonjour/manual `NWConnection`, `HELLO` handshake,
    incremental `StreamFramer`, routes `VIDEO_FRAME` to the decoder and sends `UPLINK`.
  - `VideoStreamDecoder` (`VideoSource`): **Phase 1 placeholder** — stores `VIDEO_CONFIG`, accepts
    frames, but `latestFrame` stays nil so the debug scene shows. Phase 2 wires
    VideoToolbox HEVC → `CVPixelBuffer` → `MTLTexture` (`CVMetalTextureCache`).
- **Testable on the headset alone today** (no Mac): entering the immersive space runs ARKit and
  the debug stereo pattern, validating tracking/stage/pinch before the video spine exists.
- **Not yet done**: the Xcode target itself (must be created on the Mac per `visionos-app/README.md`),
  Phase 2 decoder, and the Mac-side encoder + `StreamRelayCoordinator`. Foveated Streaming is
  deliberately excluded (it requires NVIDIA CloudXR, incompatible with Apple Silicon).

## Known gaps

1. M0 10-minute stability was intentionally deferred to avoid headset wear; debug as needed during playable testing.
2. Pose uses `WorldTrackingProvider` when a remote Vision Pro device identifier is available; otherwise it falls back to simulated pose for bridge preflight.
3. Frame path still uses **CPU readback over TCP**, but the synchronous GPU stall, the
   allocation churn, and the render-thread network stall are all resolved (async PBO +
   off-thread pooled sender). The remaining architectural step is true cross-process
   IOSurface zero-copy (needs JNI + mach-port IPC — see section above).
4. OpenVR JAR may still load with LWJGL; Apple path does not call `MCOpenVR`
5. **Pinch input is fully wired on the client but inert in production**: no on-device hand source
   exists because `HandTrackingProvider` is macOS-unavailable (see "Hand / pinch input" above). A
   visionOS-native hand-streaming helper is the next real-input step. No haptics or spatial audio yet.

## Coordinate tuning

If yaw is mirrored on device: `-Dvisioncraft.flipYaw=true` on Minecraft JVM.
