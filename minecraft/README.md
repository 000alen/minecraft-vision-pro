# Minecraft / Vivecraft integration

## Submodule

```bash
git submodule update --init VivecraftMod
```

Pin a specific VivecraftMod commit in `.gitmodules` after validating a Minecraft version.

## Apple provider sources

Copy into VivecraftMod:

```bash
cp -R src/client/java/org/vivecraft/client_vr/provider/apple/ \
  VivecraftMod/common/src/main/java/org/vivecraft/client_vr/provider/apple/
```

Copy bridge Java (or depend on `visioncraft-bridge` JAR):

```bash
mkdir -p VivecraftMod/common/src/main/java/visioncraft/bridge
cp ../../bridge/java/*.java VivecraftMod/common/src/main/java/visioncraft/bridge/
```

## Patches

```bash
cd VivecraftMod
patch -p1 < ../patches/0001-apple-vision-provider.patch
```

Add Gson to Vivecraft dependencies if not already present (bridge JSON).

## Enable in game

1. Start **VisionCraftHost** (immersive + bridge).
2. Launch Minecraft Fabric with patched Vivecraft.
3. VR Settings → **VR Plugin** → **Apple Vision**.
4. Enable VR.

## M2 acceptance

- Minecraft launches without SteamVR
- `AppleVisionProvider` initializes when host is running
- Fake / live pose from bridge updates HMD matrices
