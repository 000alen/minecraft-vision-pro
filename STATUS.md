# VisionCraft status

Last updated: 2026-05-31

## Milestones

| Milestone | Description | Status |
|-----------|-------------|--------|
| **M0** | RemoteImmersiveSpace + Metal stereo on Vision Pro | Code complete — **requires Mac + AVP hardware validation** |
| **M1** | Java ↔ native bridge (test patterns + pose) | Code complete — run `./gradlew :bridge-test:run` with host |
| **M2** | AppleVisionProvider, no SteamVR path | **Integrated** in vendored Vivecraft, default plugin |
| **M3** | Stereo main menu on headset | Blocked on M0 + M1 on device |
| **M4** | In-world head-tracked view | Provider + HMD aim wired — needs device QA |
| **M5** | 30-minute survival MVP | Not validated |
| **M6** | IOSurface / no CPU readback | Stub only (`MetalInterop.mm`) |

## What works in repo today

- Vendored VivecraftMod with Apple Vision backend
- TCP bridge protocol v1 + metrics
- VisionCraftHost Swift app (compositor + bridge server)
- Comfort defaults (seated, HMD aim, fake controllers for crosshair)
- CI: Gradle bridge unit tests

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

## Known gaps

1. Compositor Services API may need Xcode 26 compile fixes on device
2. Pose is **simulated** in host until device anchor is wired
3. Frame path uses **CPU readback** (slow; M6 IOSurface)
4. OpenVR JAR may still load with LWJGL; Apple path does not call `MCOpenVR`

## Coordinate tuning

If yaw is mirrored on device: `-Dvisioncraft.flipYaw=true` on Minecraft JVM.
