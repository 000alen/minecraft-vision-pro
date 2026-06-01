# Build guide

## Hardware & OS

- MacBook Pro with Apple Silicon (M4 recommended)
- Apple Vision Pro on visionOS 26+, Developer Mode enabled
- macOS 26+ (Tahoe), Xcode 26+

## Version freeze (recommended)

| Component | Version |
|-----------|---------|
| macOS / visionOS / Xcode | 26+ |
| Java | 21+ for bridge tests; Vivecraft resolves its requested Java toolchain |
| Minecraft | Latest stable supported by vendored Vivecraft tree |
| Loader | Fabric (first) |
| VivecraftMod | Vendored at `minecraft/VivecraftMod/` — see `minecraft/VENDORED.md` |

Update the vendored tree only deliberately after M5; document new upstream SHA in `VENDORED.md`.

## Native host (mac-host)

```bash
cd mac-host
open VisionCraftHost.xcodeproj
```

1. Select **My Mac** as run destination.
2. Sign with your Apple ID (personal team is fine for local M0 — confirm Compositor entitlements).
3. Pair Vision Pro via Xcode → Devices.
4. Run; use in-app control to open **Remote Immersive Space**.

**M0 acceptance:** stereoscopic content and head tracking on Vision Pro. The
10-minute wear test is deferred while playable Minecraft is prioritized.

### Automation hooks

For simulator and repeatable hardware smoke tests, the host accepts environment
variables or equivalent launch arguments:

```bash
VISIONCRAFT_BRIDGE_PORT=19735
VISIONCRAFT_AUTO_OPEN_IMMERSIVE=1
VISIONCRAFT_NO_AUTO_START_BRIDGE=1
```

Equivalent launch arguments are `--bridge-port 19735`, `--auto-open-immersive`,
and `--no-auto-start-bridge`.

The host also starts a loopback-only HTTP control API on port `19734` by default
(`VISIONCRAFT_CONTROL_PORT` or `--control-port` overrides it):

```bash
curl http://127.0.0.1:19734/health
curl http://127.0.0.1:19734/status
curl -X POST 'http://127.0.0.1:19734/bridge/start?port=19735'
curl -X POST http://127.0.0.1:19734/bridge/stop
curl -X POST http://127.0.0.1:19734/immersive/open
```

`/immersive/open` schedules SwiftUI's `openImmersiveSpace` from the host window,
which lets scripts drive simulator/device smoke tests without clicking the
button manually. `/status` reports `supports_remote_scenes`,
`remote_device_identifier_available`, and `ar_tracking_state`.

If Apple's picker opens and says **No People Found**, the Mac supports remote
scene presentation but no nearby/shareable Vision Pro target is discoverable.
That is an M0 hardware gate, not a Java bridge failure. Keep the host running,
make the Vision Pro discoverable from the same Apple ID/developer setup, then
retry:

```bash
curl -X POST http://127.0.0.1:19734/immersive/open
```

After selecting the Vision Pro, check the renderer diagnostics:

```bash
curl http://127.0.0.1:19734/status
```

For M0 visual validation, expect `immersive_open: true`,
`remote_device_identifier_available: true`, `renderer_layer_state: "running"`,
`renderer_last_view_count: 2`, `renderer_last_drawable_count: 1`,
`renderer_last_anchor_state: "available"`, `renderer_last_command_buffer_status: "4"`,
and `renderer_last_error` beginning with `none`. The headset should show a
depth-writing, world-anchored stereo panel with distinct left/right colors. If
it is black, verify the debug renderer is writing depth as well as color.
If `ar_tracking_state` stays at `starting`, the remote ARKit session did not
finish starting and the renderer intentionally has not attached yet.

## Bridge tests (any OS with Java 21)

```bash
./gradlew test
./gradlew :bridge-test:run
```

On Mac, start `VisionCraftHost` first so port `19735` is listening.

## Vivecraft (vendored)

```bash
cd minecraft/VivecraftMod
./gradlew :fabric:build
```

The current Fabric artifact is written to
`minecraft/VivecraftMod/build/libs/vivecraft-26.1.2-1.3.10-fabric.jar`.
Install that JAR in the Minecraft Fabric profile's `mods/` directory with the
matching Fabric loader setup. Default VR plugin is **Apple Vision**. Launch
**VisionCraftHost**, start the bridge, and open the immersive space before
enabling VR.

## Development loop

```text
1. Run VisionCraftHost (immersive session ready)
2. Launch Minecraft Fabric profile
3. Enable VR in Vivecraft
4. Watch host logs + bridge-test metrics
```

## Packaging (post-MVP)

Not required for MVP. Future deliverables:

- `VisionCraftHost.app`
- Fabric mod JAR
- Launcher profile JSON + install script
