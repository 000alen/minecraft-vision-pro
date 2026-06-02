# VisionCraft — agent instructions

Local-only **Minecraft Java in VR** on MacBook Pro (Apple Silicon) + **Apple Vision Pro**. See [docs/architecture.md](docs/architecture.md) for the full system design.

**Platform pins:** macOS 26+, visionOS 26+, Xcode 26+. Do not assume APIs from older OS versions.

## Two Apple paths (do not mix them)

Vision Pro work in this repo follows **one of two rendering paths**. Identify which path you are editing before changing Swift, Metal, or bridge code.

| Capability | `mac-host/` (Mac → remote display) | `visionos-app/` (on-device companion) |
|------------|-------------------------------------|----------------------------------------|
| Runs on | Mac | Apple Vision Pro |
| Scene container | `RemoteImmersiveSpace` | `ImmersiveSpace` |
| Stereo output to headset | Mac compositor → remote AVP | Local `CompositorLayer` |
| Head pose to Java | Mac `WorldTrackingProvider` (remote device) | On-device `WorldTrackingProvider` uplink |
| Hand / pinch input | **Not available** (ARKit hand is visionOS-only) | `HandTrackingProvider` + `TrackingUplink` |
| Video path | HEVC **encode** + stream relay | HEVC **decode** + composite |
| Golden entry | `VisionCraftImmersiveContent.swift` | `VisionCraftCompanionApp.swift` |

The companion app exists because **`HandTrackingProvider` cannot run in the macOS RemoteImmersiveSpace host**. See [bridge/protocol.md](bridge/protocol.md) (`hand` platform note).

## Before editing Apple / Vision Pro code

1. Read the relevant **golden files** below and matching code in-repo.
2. Read [docs/vision-pro-references.md](docs/vision-pro-references.md) and [docs/apple-spatial-rendering-notes.md](docs/apple-spatial-rendering-notes.md).
3. Use the **vision-pro-research** skill (`.cursor/skills/vision-pro-research/SKILL.md`) for visionOS, hand tracking, compositor, or immersive lifecycle work.
4. Query official Apple documentation via **Context7** (`/websites/developer_apple`) or fetch the doc URL — do not guess API names or lifecycle.
5. State brief **research notes** (doc links + in-repo precedent) before proposing diffs.

## Golden files — mac host (`mac-host/`)

| File | Role |
|------|------|
| `Sources/VisionCraftImmersiveContent.swift` | `RemoteImmersiveSpace`, remote ARKit session, head-only tracking |
| `Sources/CompositorRenderer.swift` | Metal stereo compositor, render thread, frame pacing |
| `Sources/JavaBridgeServer.swift` | Loopback TCP bridge to Java |
| `Sources/StreamRelayCoordinator.swift` | Relay when companion connects; suppress local pose |
| `Sources/StereoFrameEncoder.swift` | HEVC encode for stream |
| `README.md` | XcodeGen, signing, run steps |

## Golden files — Vision Pro companion (`visionos-app/`)

| File | Role |
|------|------|
| `Sources/VisionCraftCompanionApp.swift` | `ImmersiveSpace`, `CompositorLayer`, `upperLimbVisibility`, foveation config |
| `Sources/AppModel.swift` | ARKit auth, immersive lifecycle, off-main-actor compositor wiring |
| `Sources/CompanionRenderer.swift` | Render loop, pose-tagged drawables, compositor reprojection, `view_config` |
| `Sources/TrackingUplink.swift` | `pose` / `hand` / `recenter` uplink |
| `Sources/HandPinch.swift` | Pinch strength from `HandAnchor` joints |
| `Sources/VideoStreamDecoder.swift` | VideoToolbox HEVC → `MTLTexture` |
| `Sources/StreamClient.swift` | Bonjour + stream protocol client |
| `README.md` | Device pairing, Developer Mode, phased status |

## Wire contracts

| Doc | Contents |
|-----|----------|
| [bridge/protocol.md](bridge/protocol.md) | Loopback Java bridge: `pose`, `hand`, `view_config`, `frame` |
| [bridge/stream-protocol.md](bridge/stream-protocol.md) | Mac ↔ companion LAN stream |

## Build / project layout

- Xcode projects are **generated** from `project.yml` — run `scripts/gen-projects.sh` after adding sources.
- Vendored Vivecraft: `minecraft/VivecraftMod/` — Java-side VR provider, not visionOS.

## Anti-patterns

- Adding `HandTrackingProvider` or visionOS-only ARKit APIs under `mac-host/`.
- Using `RemoteImmersiveSpace` in `visionos-app/`.
- Enabling foveation on uniform-resolution game frames (both apps disable it intentionally).
- `@MainActor` on the Metal render loop — follow existing off-main-actor + `mainAsync` UI pattern in `AppModel`.
- Inventing `LayerRenderer` / compositor method names — verify against Apple docs and compile on Xcode 26.
