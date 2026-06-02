# VisionCraft — agent instructions

Local-only **Minecraft Java in VR** on MacBook Pro (Apple Silicon) + **Apple Vision Pro**. See [docs/architecture.md](docs/architecture.md) for the full system design.

**Platform pins:** macOS 26+, visionOS 26+, Xcode 26+. Do not assume APIs from older OS versions.

## Current Apple path

Vision Pro rendering now uses ALVR end to end. The Mac host links ALVR's `alvr_server_core`; the headset app is the vendored `alvr-visionos` client under `visionos-app/`.

| Capability | `mac-host/` | `visionos-app/` |
|------------|-------------|----------------|
| Runs on | Mac | Apple Vision Pro |
| Stereo output to headset | VideoToolbox HEVC → `alvr_server_core` | ALVRClient decode/render |
| Head pose to Java | `alvr_get_device_motion` via server_core | ALVRClient tracking |
| Hand / controller input | Raw ALVR buttons/axes + poses bridged to Java `controller` | ALVRClient tracking/input source |
| Video contract | Annex-B HEVC, side-by-side stereo, VPS/SPS/PPS via DecoderConfig | ALVR client shader/decode contract |
| Golden entry | `Sources/AlvrServerCoordinator.swift` | `ALVRClient.xcodeproj` |

The old custom RemoteImmersiveSpace, stream relay, and VisionCraft companion code was retired. Do not reintroduce `StreamRelay*`, `StreamProtocol`, `CompositorRenderer`, or `VisionCraftImmersiveContent` unless explicitly requested.

## Before editing Apple / Vision Pro code

1. Read the relevant **golden files** below and matching code in-repo.
2. Read [docs/vision-pro-references.md](docs/vision-pro-references.md) when touching headset-side ALVR/visionOS behavior.
3. Use the **vision-pro-research** skill (`.cursor/skills/vision-pro-research/SKILL.md`) for visionOS, hand tracking, compositor, or immersive lifecycle work.
4. Query official Apple documentation via **Context7** (`/websites/developer_apple`) or fetch the doc URL — do not guess API names or lifecycle.
5. State brief **research notes** (doc links + in-repo precedent) before proposing diffs.

## Golden files — mac host (`mac-host/`)

| File | Role |
|------|------|
| `Sources/AlvrServerCoordinator.swift` | ALVR server_core lifecycle, event polling, NAL submission, pose/view uplink |
| `Sources/ALVRServerCoreShim.h` / `.c` | Swift-safe wrapper around generated ALVR C ABI |
| `Sources/JavaBridgeServer.swift` | Loopback TCP bridge to Java |
| `Sources/StereoFrameEncoder.swift` | Side-by-side Annex-B HEVC encode |
| `Sources/VisionCraftAppModel.swift` | Bridge/control/ALVR lifecycle wiring |
| `README.md` | XcodeGen, signing, run steps |

## Golden files — Vision Pro ALVR client (`visionos-app/`)

| File | Role |
|------|------|
| `ALVRClient.xcodeproj` | Xcode entry for the vendored ALVR visionOS client |
| `ALVR/` | ALVR tree pinned to the client-compatible commit |
| `ALVRClient/Shaders.metal` | Side-by-side sampling contract |
| `build_and_repack.sh` | Builds/repackages `alvr_client_core` |

## Wire contracts

| Doc | Contents |
|-----|----------|
| [bridge/protocol.md](bridge/protocol.md) | Loopback Java bridge: `pose`, `controller`, `hand`, `view_config`, `frame` |

## Build / project layout

- The Mac Xcode project is **generated** from `mac-host/project.yml` — run `scripts/gen-projects.sh` after adding/removing Mac host sources.
- ALVR artifacts are prepared with `scripts/prepare-alvr.sh`.
- Vendored Vivecraft: `minecraft/VivecraftMod/` — Java-side VR provider, not visionOS.

## Anti-patterns

- Adding `HandTrackingProvider` or visionOS-only ARKit APIs under `mac-host/`.
- Enabling foveation on uniform-resolution game frames (both apps disable it intentionally).
- Reimplementing ALVR's wire protocol in Swift.
- Passing VPS/SPS/PPS in-band to ALVR instead of via `alvr_set_video_config_nals`.
