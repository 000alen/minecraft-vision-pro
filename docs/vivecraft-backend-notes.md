# Vivecraft backend notes

## Provider selection

`VRState.initializeVR()` chooses provider from `VRSettings.stereoProviderPluginID`:

```java
if (dh.vrSettings.stereoProviderPluginID == VRSettings.VRProvider.OPENVR) {
    dh.vr = new MCOpenVR(...);
} else {
    dh.vr = new NullVR(...);
}
```

VisionCraft adds `APPLE_VISION` → `new AppleVisionProvider(...)`.

## Classes to mirror

| OpenVR / Null | Apple |
|---------------|-------|
| `MCOpenVR` | `AppleVisionProvider` |
| `OpenVRStereoRenderer` | `AppleVisionStereoRenderer` |
| `OpenVRHapticScheduler` | No-op or `AppleHapticScheduler` stub |
| Compositor submit in `endFrame()` | `AppleFrameSubmitter.submit()` |

## `MCVR` responsibilities

- `init()` / `destroy()` / `poll(frameIndex)`
- HMD pose: `hmdPose`, `hmdPoseLeftEye`, `hmdPoseRightEye`
- `createVRRenderer()` → stereo renderer
- Seated mode, recenter, input actions (MVP: minimal / fake controllers)

## `VRRenderer` responsibilities

- `getRenderTextureSizes()` — eye buffer resolution
- `getProjectionMatrix(eye, near, far)`
- `createRenderTexture(w, h)` — GL textures for eyes
- `endFrame()` — submit to runtime (bridge for Apple)

## NullVR as template

`NullVR` + `NullVRStereoRenderer` show a **runtime-free** path:

- Fake controller offsets
- `endFrame()` no-op
- Perspective from settings (`nullvrFOV`, `nullvrEyeAngle`)

Apple provider copies seated/head-only patterns from NullVR but replaces pose source and `endFrame()` submit.

## OpenXR fork (reference only)

[VivecraftMod#446](https://github.com/Vivecraft/VivecraftMod/issues/446) discusses non-OpenVR providers. Use as a map for decoupling, not as the Apple runtime.

## Vendored integration

Apple provider and bridge live directly in `minecraft/VivecraftMod/` (no separate patches to apply). See `minecraft/VENDORED.md`.

## SteamVR avoidance

With `APPLE_VISION` selected, `MCOpenVR` must not load. Do not initialize LWJGL OpenVR bindings on this path.

## Apple Vision Mac boot

**Symptom:** During the red Mojang splash, the Mac window shows a gray or black block in one corner (often bottom-left). It looks like the empty view on the headset. The window may close and reopen once.

**Cause:** `rememberVr` used to set `VRState.VR_ENABLED` on the first resource reload while the splash was still visible. That ran full VR init, toggled `VR_RUNNING` (which resizes the GLFW window), and blitted empty eye framebuffers to the desktop mirror before the title screen.

**Fix:** `AppleVisionStartup` defers remembered VR until `TitleScreen` and keeps `VR_RUNNING` off while the loading overlay or pre-title boot UI is active. Start `scripts/vc.sh host` before Minecraft so bridge connect succeeds when VR turns on at the title screen.

**OOTB:** `scripts/vc.sh minecraft` after `scripts/vc.sh host` + ALVRClient connected. No action needed on the splash; use F7 on the title screen only if VR is off.

## GUI / crosshair (M4/M5)

- Aim device: HMD (`VRSettings.AimDevice.HMD`)
- Seated crosshair ray from head forward
- Recenter hotkey → bridge `recenter` → host ack via `recenter_counter`
