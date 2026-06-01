# VisionCraft status

Last updated: 2026-05-31

## Milestones

| Milestone | Description | Status |
|-----------|-------------|--------|
| **M0** | RemoteImmersiveSpace + Metal stereo on Vision Pro | **Visual + head tracking passed**; 10-minute comfort run deferred |
| **M1** | Java ↔ native bridge (test patterns + pose) | **Automated in CI** via `MockVisionCraftHost`; visual check still needs real host |
| **M2** | AppleVisionProvider, no SteamVR path | **Integrated** in vendored Vivecraft, default plugin |
| **M3** | Stereo main menu on headset | Blocked on M0 + M1 on device |
| **M4** | In-world head-tracked view | Provider + HMD aim wired — needs device QA |
| **M5** | 30-minute survival MVP | Not validated |
| **M6** | IOSurface / no CPU readback | Stub only (`MetalInterop.mm`) |

## What works in repo today

- Vendored VivecraftMod with Apple Vision backend
- TCP bridge protocol v1 + metrics
- **`MockVisionCraftHost`** — headless M1 server (no Mac/AVP)
- **CI integration tests** — stereo frame + pose round-trip on every push
- VisionCraftHost Swift app (compositor + bridge server + loopback control API)
- Comfort defaults (seated, HMD aim, fake controllers for crosshair)
- OpenVR `create()` skip on Apple Vision path

## Hardware validation checklist (you)

```bash
# Mac
open mac-host/VisionCraftHost.xcodeproj
# Run → Start bridge → Open immersive

# Same Mac terminal
./gradlew :bridge-test:run

# Minecraft
cd minecraft/VivecraftMod && ./gradlew :fabric:build
# Install JAR, launch Fabric, enable VR
```

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
