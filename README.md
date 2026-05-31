# VisionCraft

Local-only **Minecraft Java Edition in VR** on **MacBook Pro (Apple Silicon) + Apple Vision Pro**, without Windows, SteamVR, cloud streaming, or extra PC VR hardware.

## Architecture

```text
MacBook Pro (M4)
  → Minecraft Java + Fabric + Vivecraft (fork)
  → AppleVisionProvider (Java)
  → visioncraft bridge (localhost socket)
  → VisionCraftHost (Swift + Metal + RemoteImmersiveSpace)
  → Apple Vision Pro
```

See [docs/architecture.md](docs/architecture.md) for the full system design, milestones, and risk register.

## Repository layout

| Path | Purpose |
|------|---------|
| `docs/` | Architecture, build, latency, transport notes |
| `bridge/` | Versioned JSON protocol + Java JNI/socket bridge |
| `mac-host/` | macOS 26+ host app (M0/M1) |
| `minecraft/VivecraftMod/` | **Vendored** Vivecraft fork (Apple provider + bridge in-tree) |
| `test/` | Bridge and math unit tests |

## Quick start (development)

### Prerequisites

- macOS 26+ (Tahoe), visionOS 26+, Xcode 26+
- MacBook Pro M4 + Apple Vision Pro (paired, Developer Mode)
- Java 21+, Gradle 8+
- Minecraft Java Edition + Fabric Loader
- [VivecraftMod](https://github.com/Vivecraft/VivecraftMod) (vendored under `minecraft/VivecraftMod/`)

### 1. Clone

```bash
git clone https://github.com/000alen/minecraft-vision-pro.git
cd minecraft-vision-pro
```

Everything needed to build is in the repo (vendored Vivecraft, no submodules).

### 2. M0 — Stereo cube on Vision Pro

```bash
open mac-host/VisionCraftHost.xcodeproj
# Run on Mac; start immersive session on Vision Pro
```

Acceptance: stereoscopic cube, head-tracked view, 10 minutes stable. **If M0 fails, stop — the architecture is blocked.**

### 3. M1 — Java ↔ native bridge

```bash
# Terminal A: build and run native host (or use Xcode)
# Terminal B:
./gradlew :bridge-test:run
```

Acceptance: left/right test patterns in correct eyes; pose messages received by Java.

### 4. M2+ — Vivecraft Apple provider

Build the vendored Fabric mod (Apple Vision is the default provider):

```bash
cd minecraft/VivecraftMod
./gradlew :fabric:build
```

Run **VisionCraftHost** before launching Minecraft.

## Implementation order (ASAP)

1. M0 — `RemoteImmersiveSpace` stereo cube  
2. M1 — Java fake stereo frame sender  
3. M2 — `AppleVisionProvider` in Vivecraft  
4. M3 — Stereo main menu on headset  
5. M4 — In-world head-tracked view  
6. M5 — 30-minute survival MVP  
7. M6 — Transport optimization (IOSurface / no CPU readback)

See [STATUS.md](STATUS.md) for milestone progress and hardware validation steps.

## Milestones

| ID | Goal | Status |
|----|------|--------|
| M0 | Apple spatial rendering proof | Scaffolded — verify on device |
| M1 | Java ↔ native bridge | Scaffolded — run bridge-test |
| M2 | Fake Apple provider, no SteamVR | Scaffolded — integrate patches |
| M3 | Stereo menu on Vision Pro | Not started |
| M4 | In-world head tracking | Not started |
| M5 | Playable survival MVP | Not started |
| M6 | Optimization pass | Not started |

## License

VivecraftMod is upstream LGPL/GPL as published by Vivecraft. VisionCraft-specific code in this repository is provided for development; confirm licensing before distribution.
