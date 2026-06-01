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

## Known gaps

1. M0 10-minute stability was intentionally deferred to avoid headset wear; debug as needed during playable testing.
2. Pose uses `WorldTrackingProvider` when a remote Vision Pro device identifier is available; otherwise it falls back to simulated pose for bridge preflight.
3. Frame path uses **CPU readback** (slow; M6 IOSurface)
4. OpenVR JAR may still load with LWJGL; Apple path does not call `MCOpenVR`
5. Eye render buffers are fixed at `1512×1680`; not yet resized to the host's
   recommended `view_config` dimensions (sampling-quality only — geometry is correct).
6. No real controller/hand input, haptics, or spatial audio on the Apple path yet.

## Coordinate tuning

If yaw is mirrored on device: `-Dvisioncraft.flipYaw=true` on Minecraft JVM.
