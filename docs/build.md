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
| Minecraft | Latest stable supported by pinned Vivecraft release |
| Loader | Fabric (first) |
| VivecraftMod | Pin submodule commit in `.gitmodules` |

Update the Vivecraft submodule only deliberately after M5.

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

## Vivecraft + Apple provider

```bash
git submodule update --init minecraft/VivecraftMod
```

1. Copy `minecraft/src/client/java/org/vivecraft/client_vr/provider/apple/` into  
   `minecraft/VivecraftMod/common/src/main/java/org/vivecraft/client_vr/provider/apple/`.
2. Apply patches:

```bash
cd minecraft/VivecraftMod
patch -p1 < ../patches/0001-apple-vision-provider.patch
```

3. Build Fabric artifact:

```bash
./gradlew :fabric:build
```

4. Install jar in Minecraft `mods/` with Fabric API.
5. In Vivecraft VR settings, set **VR Plugin** to **Apple Vision**.
6. Launch **VisionCraftHost** before Minecraft.

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
