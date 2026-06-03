# VisionCraft — agent instructions

Local-only **Minecraft Java in VR** on MacBook Pro (Apple Silicon) + **Apple Vision Pro**. See [docs/architecture.md](docs/architecture.md) for the full system design.

**Platform pins:** macOS 26+, visionOS 26+, Xcode 26+. Do not assume APIs from older OS versions.

For hardware debugging, start with [docs/alvr-hardware-playbook.md](docs/alvr-hardware-playbook.md). Do not skip the ALVR-only synthetic validation step.

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

## Canonical repo names

Use the names in [docs/repo-structure.md](docs/repo-structure.md): Mac ALVR host (`mac-host/`), VisionCraft headset client / ALVRClient (`visionos-app/`), Vivecraft Apple provider (`minecraft/VivecraftMod/`), Bridge v1 (`bridge/`), bridge Java library (`bridge/java/lib/`), test-pattern sender (`bridge/java/test-pattern-sender/`), and mock host (`bridge/java/mock-host/`). Do not move top-level app/vendor paths during nomenclature cleanup.

## Before editing Apple / Vision Pro code

1. Read the relevant **golden files** below and matching code in-repo.
2. Read [docs/vision-pro-references.md](docs/vision-pro-references.md) when touching headset-side ALVR/visionOS behavior.
3. Use the **vision-pro-research** skill (`.cursor/skills/vision-pro-research/SKILL.md`) for visionOS, hand tracking, compositor, or immersive lifecycle work.
4. Query official Apple documentation via **Context7** (`/websites/developer_apple`) or fetch the doc URL — do not guess API names or lifecycle.
5. State brief **research notes** (doc links + in-repo precedent) before proposing diffs.

## Golden files — Mac ALVR host (`mac-host/`)

| File | Role |
|------|------|
| `Sources/AlvrServerCoordinator.swift` | ALVR server_core lifecycle, event polling, NAL submission, pose/view uplink |
| `Sources/ALVRServerCoreShim.h` / `.c` | Swift-safe wrapper around generated ALVR C ABI |
| `Sources/JavaBridgeServer.swift` | Loopback TCP bridge to Java |
| `Sources/StereoFrameEncoder.swift` | Side-by-side Annex-B HEVC encode |
| `Sources/VisionCraftAppModel.swift` | Bridge/control/ALVR lifecycle wiring |
| `README.md` | XcodeGen, signing, run steps |

## Golden files — VisionCraft headset client / ALVRClient (`visionos-app/`)

| File | Role |
|------|------|
| `ALVRClient.xcodeproj` | Xcode entry for the VisionCraft headset client |
| `ALVR/` | ALVR tree pinned to the client-compatible commit |
| `ALVRClient/Shaders.metal` | Side-by-side sampling contract |
| `build_and_repack.sh` | Builds/repackages `alvr_client_core` |

## Wire contracts

| Doc | Contents |
|-----|----------|
| [bridge/protocol.md](bridge/protocol.md) | Bridge v1 loopback Java bridge: `pose`, `controller`, `hand`, `view_config`, `frame` |

## Build / project layout

- The Mac Xcode project is **generated** from `mac-host/project.yml` — run `scripts/gen-projects.sh` after adding/removing Mac host sources.
- The vendored ALVR version and VisionCraft ALVR source changes are source-controlled under `visionos-app/`; see `visionos-app/VENDORED.md`. `scripts/prepare-alvr.sh` may validate/build artifacts, but must not be the only place project source changes live; exported diffs are review/audit only.
- Vendored Vivecraft Apple provider: `minecraft/VivecraftMod/` — Java-side VR provider, not visionOS.

## Tooling architecture

`scripts/vc.sh` is the user-facing command dispatcher. Shared shell behavior belongs in `scripts/lib/`; see [docs/tooling-architecture.md](docs/tooling-architecture.md).

- Put paths, ports, and bundle IDs in `scripts/lib/vc-env.sh`, with `VISIONCRAFT_*` overrides.
- Put device discovery in `scripts/lib/vc-device.sh`, process/port logic in `scripts/lib/vc-process.sh`, control API calls in `scripts/lib/vc-control.sh`, and evidence capture in `scripts/lib/vc-observe.sh`.
- Do not add large inline helper blocks or duplicate `devicectl`, `lsof`, `curl`, or JSON parsing snippets in command scripts.
- Every hardware-facing command should either produce logs/evidence or point to `scripts/vc.sh observe`.

## Hardware-debug procedure

Every AVP hardware run should be reproducible and observable:

1. Start with `scripts/vc.sh host --synthetic` and `scripts/vc.sh avp-console 120` (or Xcode Run if console launch is not desired).
2. Press Enter in ALVRClient and run `scripts/vc.sh observe 30` while reproducing.
3. Prove the host-native synthetic pattern is stable before introducing `scripts/vc.sh test-sender` (`sender`) or `scripts/vc.sh minecraft` (`mc`).
4. If synthetic is stable but Java/Minecraft is not, debug only the bridge/frame-source layer.
5. Preserve `.run/observability/<timestamp>/` bundles when reporting findings.

## Anti-patterns

- Adding `HandTrackingProvider` or visionOS-only ARKit APIs under `mac-host/`.
- Enabling foveation on uniform-resolution game frames (both apps disable it intentionally).
- Reimplementing ALVR's wire protocol in Swift.
- Removing decoder recovery behavior. The host must call `alvr_set_video_config_nals` and also keep VPS/SPS/PPS inline on IDR access units so the headset can recover after decoder resets/reconnects.
