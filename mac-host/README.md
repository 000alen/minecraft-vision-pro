# VisionCraftHost

macOS 26+ application that listens on the Java bridge (`127.0.0.1:19735`) and feeds stereo HEVC frames into ALVR's `alvr_server_core` C ABI. The headset renderer is the vendored `alvr-visionos` client in `../visionos-app`.

## Project Generation

The `.xcodeproj` is generated from [`project.yml`](project.yml):

```bash
brew install xcodegen rustup-init
rustup-init -y
export VISIONCRAFT_DEVELOPMENT_TEAM=<your Apple team id>
../scripts/vc.sh bootstrap
open VisionCraftHost.xcodeproj
```

`vc.sh bootstrap` uses Rust/cargo, installs `cbindgen` if missing, builds the matching ALVR client/server artifacts, and places the server dylib/header under `Vendor/ALVRServerCore/`.

## CLI Build

```bash
xcodebuild -project VisionCraftHost.xcodeproj -scheme VisionCraftHost -destination 'platform=macOS' build
```

For compile-only checks on machines without a local signing identity:

```bash
xcodebuild -project VisionCraftHost.xcodeproj -scheme VisionCraftHost CODE_SIGNING_ALLOWED=NO build
```

## Run

1. Run `scripts/vc.sh package-beta` from the repo root if you want a local beta bundle under `.run/beta`.
2. Run `scripts/vc.sh host` from the repo root, or open `.run/beta/Host/VisionCraftHost.app`.
3. Run the ALVR client from `visionos-app/ALVRClient.xcodeproj` on Apple Vision Pro.
4. Start Minecraft with the Apple provider, or run `scripts/vc.sh test-sender` (`sender`) for the deterministic test pattern.
5. Use `scripts/vc.sh verify` to confirm ALVR is connected and frames are advancing.

The host window includes guided cards for setup artifacts, bridge state, headset connection, frame source, and diagnostics. If it reports missing artifacts, run:

```bash
scripts/vc.sh bootstrap
```
