# Build guide

## Hardware & OS

- MacBook Pro with Apple Silicon (M4 recommended)
- Apple Vision Pro on visionOS 26+, Developer Mode enabled
- macOS 26+ (Tahoe), Xcode 26+

## Version freeze (recommended)

| Component | Version |
|-----------|---------|
| macOS / visionOS / Xcode | 26+ |
| Java | 21+ |
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

**M0 acceptance:** stereoscopic cube, head tracking, 10 minutes without crash.

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

Install the Fabric JAR in Minecraft `mods/` with Fabric API. Default VR plugin is **Apple Vision**. Launch **VisionCraftHost** before enabling VR.

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
