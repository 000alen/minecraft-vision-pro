# OpenVR isolation (Apple Vision path)

VisionCraft should not initialize SteamVR when `VRProvider.APPLE_VISION` is selected.

## Mechanisms

1. **`VRState`** — Instantiates `AppleVisionProvider`, not `MCOpenVR`.
2. **`OpenVRMixin.create`** — No-ops when `VisionCraftRuntime.skipOpenVR()` is true.
3. **Env / properties** — Force skip even before settings load:
   - `-Dvisioncraft.skipOpenVR=true`
   - `VISIONCRAFT_SKIP_OPENVR=1`

## Residual risk

LWJGL may still load `openvr` if another class references `org.lwjgl.openvr.*` before settings exist. Report any `libopenvr` load in logs on Apple path.

## Verify on Mac

```bash
# Launch Minecraft with Apple Vision; check Console for openvr/SteamVR
log show --predicate 'process == "java"' --last 5m | grep -i openvr
```
