# Apple spatial rendering notes

> Retired design notes: the current path uses ALVRClient + `alvr_server_core`, not the custom
> macOS `RemoteImmersiveSpace` compositor. Keep this file as historical research context only.

## APIs (macOS 26+)

| API | Role |
|-----|------|
| [`RemoteImmersiveSpace`](https://developer.apple.com/documentation/swiftui/remoteimmersivespace) | macOS container for compositor content on a chosen visionOS device |
| [Compositor Services](https://developer.apple.com/documentation/compositorservices) | Metal-controlled immersive drawing environment |

M0 validates both before Minecraft integration.

## M0 sample behavior

`VisionCraftHost` opens a `RemoteImmersiveSpace` and renders:

- Stereoscopic scene (debug cube + axis gizmo)
- Camera from device head pose (Compositor Services tracking)
- Optional diagnostic text overlay (frame time, pose validity)

## Entitlements & signing

- Verify required entitlements in Xcode for Compositor Services on your team.
- Personal Apple ID may suffice for local device testing — **confirm on hardware**, do not assume.
- Developer Mode on Vision Pro required.

## Coordinate space

Apple compositor space is right-handed; meters. M0 draws:

- **+X** red, **+Y** green, **+Z** blue axes at origin
- Compare head yaw direction against expected forward

Document findings in the current ALVR hardware validation notes if this path is revisited.

## Metal interop (M6)

- `CVMetalTextureCacheCreateTextureFromImage` from IOSurface
- Match sRGB vs linear to Minecraft gamma
- Prefer `BGRA8Unorm` if compositor expects it

Spike in `bridge/native/MetalInterop.mm` (Objective-C++).

## Frame rate

Compositor may target 90 Hz on Vision Pro; Minecraft may not keep pace. Host should:

- Present latest complete stereo pair (drop stale frames)
- Expose `displayed_frame_age_ms` in overlay

## Links

- [RemoteImmersiveSpace](https://developer.apple.com/documentation/swiftui/remoteimmersivespace)
- [Compositor Services](https://developer.apple.com/documentation/compositorservices)

For visionOS companion work (hand tracking, on-device immersive, stream decode), see [vision-pro-references.md](vision-pro-references.md).
