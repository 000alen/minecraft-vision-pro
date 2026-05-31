# VisionCraftHost

macOS 26+ application that:

1. **M0** — Opens `RemoteImmersiveSpace` and renders a stereoscopic Metal scene on Vision Pro.
2. **M1** — Listens on TCP port `19735` for Java stereo frames and pose protocol v1.

## Open in Xcode

```bash
open VisionCraftHost.xcodeproj
```

Create the Xcode project on a Mac if the generated project is missing targets — source files are under `Sources/` and `Shaders/`.

### Manual Xcode setup

1. New **App** → SwiftUI → macOS 26 deployment target.
2. Add **Compositor Services** capability / framework.
3. Add all `Sources/*.swift` and `Shaders/Composite.metal`.
4. Enable **Remote Immersive Space** in Signing & Capabilities (verify exact entitlement name in Xcode 26).

## Run

1. Pair Vision Pro in Xcode → Devices.
2. Run **VisionCraftHost** on Mac.
3. Click **Start bridge**, then **Open immersive**.
4. Run `./gradlew :bridge-test:run` or Minecraft with Apple provider.

## API notes

`CompositorRenderer` uses `LayerRenderer` APIs from Compositor Services. Exact method names may differ slightly in the shipping SDK — adjust `onRenderThread` / `drawable` access after the first compile on Xcode 26.
