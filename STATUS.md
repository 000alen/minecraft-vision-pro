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

Known refinements to tune **after** confirming the loop is stable on device
(deliberately not changed blind):
- Eye buffers are square (`aspect = 1.0`) but the AVP eye viewports are not, so
  the fullscreen blit stretches slightly. Fix = render Java eyes at the viewport
  aspect (requires host → Java dimensions).
- Game uses a fixed symmetric 100° FOV; AVP frustums are asymmetric. Fix = send
  per-eye projection/tangents over the bridge so frames match the device frustum.

## Known gaps

1. M0 10-minute stability was intentionally deferred to avoid headset wear; debug as needed during playable testing.
2. Pose uses `WorldTrackingProvider` when a remote Vision Pro device identifier is available; otherwise it falls back to simulated pose for bridge preflight.
3. Frame path uses **CPU readback** (slow; M6 IOSurface)
4. OpenVR JAR may still load with LWJGL; Apple path does not call `MCOpenVR`

## Coordinate tuning

If yaw is mirrored on device: `-Dvisioncraft.flipYaw=true` on Minecraft JVM.
