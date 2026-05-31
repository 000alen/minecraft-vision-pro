# Minecraft (vendored Vivecraft)

**VivecraftMod is vendored in full** at `VivecraftMod/`. No submodules, no copy step.

## Build

```bash
cd VivecraftMod
./gradlew :fabric:build
```

Output: `VivecraftMod/fabric/build/libs/*.jar` → install in Minecraft `mods/` with Fabric API.

## Apple Vision provider

Already integrated in the vendored tree:

- `common/src/main/java/org/vivecraft/client_vr/provider/apple/`
- `common/src/main/java/visioncraft/bridge/`
- Default `VRSettings.stereoProviderPluginID` = `APPLE_VISION`

## Run

1. Build and run **VisionCraftHost** (`mac-host/`).
2. Open immersive space + bridge on Mac.
3. Launch Minecraft (Fabric) with the built mod.
4. Enable VR (plugin should already be Apple Vision).

## Upstream

See [VENDORED.md](VENDORED.md) for pinned commit and merge instructions.
