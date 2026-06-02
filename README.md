# VisionCraft

Local-only **Minecraft Java Edition in VR** on **MacBook Pro (Apple Silicon) + Apple Vision Pro**, without Windows, SteamVR, cloud streaming, or extra PC VR hardware.

## Architecture

```text
MacBook Pro (M4)
  → Minecraft Java + Fabric + Vivecraft (fork)
  → AppleVisionProvider (Java)
  → visioncraft bridge (localhost socket)
  → VisionCraftHost (Swift + VideoToolbox + ALVR server_core)
  → ALVRClient on Apple Vision Pro
```

See [docs/architecture.md](docs/architecture.md) for the full system design, milestones, and risk register.

## Repository layout

| Path | Purpose |
|------|---------|
| `docs/` | Architecture, build, latency, transport notes |
| `bridge/` | Versioned JSON protocol + Java JNI/socket bridge |
| `mac-host/` | macOS 26+ ALVR server_core host app |
| `visionos-app/` | Vendored `alvr-visionos` headset client |
| `minecraft/VivecraftMod/` | **Vendored** Vivecraft fork (Apple provider + bridge in-tree) |
| `test/` | Bridge and math unit tests |

## Quick Start (Packaged Beta)

### Prerequisites

- macOS 26+ (Tahoe), visionOS 26+, Xcode 26+
- MacBook Pro M4 + Apple Vision Pro (paired, Developer Mode)
- Homebrew, Xcode command line tools, and a completed Xcode first launch/license
- `xcodegen`, `openjdk@21`, and Rust (`rustup-init`)
- Minecraft Java Edition + Fabric Loader if you want to run outside the dev client
- [VivecraftMod](https://github.com/Vivecraft/VivecraftMod) (vendored under `minecraft/VivecraftMod/`)

### 1. Clone and bootstrap

```bash
git clone https://github.com/000alen/minecraft-vision-pro.git
cd minecraft-vision-pro
brew install xcodegen openjdk@21 rustup-init
rustup-init -y
source "$HOME/.cargo/env"
```

For AVP installation, set a real Apple Developer Team ID and a unique bundle ID before preparing artifacts:

```bash
export VISIONCRAFT_DEVELOPMENT_TEAM=<your team id>
export VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID=com.example.visioncraft.alvrclient
scripts/vc.sh bootstrap
```

`bootstrap` installs nothing automatically; it verifies tools, initializes submodules, generates projects, builds ALVR artifacts when missing, and prints exact next steps.

### 2. Package the beta

```bash
scripts/vc.sh package-beta
```

The package is written to `.run/beta` and includes `VisionCraftHost.app`, the Fabric mod jar, and `README-FIRST.txt`. The headset client still requires Apple signing/provisioning: use `scripts/vc.sh alvr-client` to open the ALVRClient Xcode project and install it on the paired AVP.

### 3. Run

```bash
scripts/vc.sh host --rebuild
scripts/vc.sh alvr-client
scripts/vc.sh sender     # test pattern
# or: scripts/vc.sh mc   # Minecraft dev client, then press F7
scripts/vc.sh verify
```

Expected result: `ALVR client connected`, `bridge session ready`, and frames flowing.

### 4. Troubleshoot

```bash
scripts/vc.sh doctor
scripts/vc.sh status
scripts/vc.sh clean
```

The host app also shows guided readiness cards for setup, headset connection, bridge state, frame source, and diagnostics.

## Implementation Order

1. ALVR client/server_core integration
2. Java fake stereo frame sender
3. `AppleVisionProvider` in Vivecraft
4. Stereo main menu on headset
5. In-world head-tracked view
6. Hand/gamepad-style controller input through ALVR
7. 30-minute survival MVP
8. Transport optimization (reduce readback/copy overhead)

See [STATUS.md](STATUS.md) for milestone progress and hardware validation steps.

## Milestones

| ID | Goal | Status |
|----|------|--------|
| M0 | ALVR client/server_core proof | Host compiles; AVP visual checkpoint pending |
| M1 | Java ↔ native bridge | Synthetic frames + pose validated |
| M2 | Apple provider, no SteamVR | Fabric mod builds with Apple provider default |
| M3 | Stereo menu on Vision Pro | Next playtest target |
| M4 | In-world head tracking | ALVR pose bridge wired; runtime validation pending |
| M5 | Playable survival MVP | Controller input wired; hardware validation pending |
| M6 | Optimization pass | Not started |

## Default Controller Mapping

VisionCraft carries raw ALVRClient inputs through `controller` bridge messages. Defaults:
left thumbstick moves, right thumbstick turns, right trigger attacks, left trigger uses, squeeze/grip drives VR interact/climb grab, right A/B jump/sneak, left X/Y inventory/radial, and menu/system opens the in-game menu.

## License

VivecraftMod is upstream LGPL/GPL as published by Vivecraft. VisionCraft-specific code in this repository is provided for development; confirm licensing before distribution.
