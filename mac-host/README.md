# VisionCraftHost

macOS 26+ application that:

1. **M0** — Opens `RemoteImmersiveSpace` and renders a stereoscopic Metal scene on Vision Pro.
2. **M1** — Listens on TCP port `19735` for Java stereo frames and pose protocol v1.

## Project generation (XcodeGen)

The `.xcodeproj` is a **generated build artifact** (git-ignored). The source of truth is
[`project.yml`](project.yml). After a fresh clone — or whenever you add/remove/rename files —
regenerate it:

```bash
brew install xcodegen          # one-time
../scripts/gen-projects.sh     # regenerates both mac-host and visionos-app projects
open VisionCraftHost.xcodeproj
```

Sources live under `Sources/` and `Shaders/`; bundle id, deployment target (macOS 26.0), and
hardened-runtime settings are all declared in `project.yml`. Set your **Development Team** in
Signing & Capabilities before deploying.

## CLI build

```bash
xcodebuild -project VisionCraftHost.xcodeproj -scheme VisionCraftHost -destination 'platform=macOS' build
```

## Run

1. Pair Vision Pro in Xcode → Devices.
2. Run **VisionCraftHost** on Mac.
3. Click **Start bridge**, then **Open immersive**.
4. Run `./gradlew :bridge-test:run` or Minecraft with Apple provider.

## API notes

`CompositorRenderer` uses `LayerRenderer` APIs from Compositor Services. Exact method names may differ slightly in the shipping SDK — adjust `onRenderThread` / `drawable` access after the first compile on Xcode 26.
