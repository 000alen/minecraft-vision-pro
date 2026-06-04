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

## Frame capture / instrumentation

Off-by-default, bounded PNG capture at each Mac-side pipeline stage, so the exact frames can be
inspected and diffed. Three independent flows:

### 1. Host capture (control-API, with running host + frame source)

Arms a one-shot capture of the next N frames into `.run/captures/<timestamp>/`:

```bash
scripts/vc.sh capture 4          # or: curl -X POST 'http://127.0.0.1:19734/debug/capture?frames=4'
```

Bundle layout:

- `recv/frame_NNNNNNNN_{left,right}.png` — raw per-eye RGBA8 received from Java (flipped upright).
- `sbs/frame_NNNNNNNN.png` — the side-by-side BGRA buffer handed to HEVC encode.
- `decoded/frame_NNNNNNNN.png` — the host's own HEVC self-decode (validates the bitstream; the
  endpoint forces an IDR so the decode starts clean).
- `header.json` — device `view_config` (ipd + per-eye `[left,right,up,down]` tangents), dims, fps.
- `manifest.ndjson` — one line per captured frame (frame_id, dims, target timestamp, keyframe).

### 2. Vivecraft pristine per-eye render (Minecraft side)

Dumps the game's per-eye color buffers before any host processing, off the render thread:

```bash
cd minecraft/VivecraftMod
./gradlew :fabric:runClient -Dvisioncraft.dumpFrames=4 -Dvisioncraft.dumpDir=/abs/out/vivecraft
```

Writes `frame_NNNNNNNN_{left,right}.png` (upright). Default dir: `.run/captures/vivecraft`
(relative to `minecraft/VivecraftMod`).

### 3. Offline / deterministic (no headset, no macOS host)

Drive the mock host with the deterministic test-pattern sender and dump received frames:

```bash
./gradlew :bridge-mock-host:run --args="19735 --dump-dir /abs/out/mock --dump-frames 4"   # terminal 1
scripts/vc.sh sender 8                                                                     # terminal 2 (or :bridge-test:run)
```

The sender emits distinct L/R checkers (top-down origin), so the mock PNGs come out upright and
verify bridge framing + per-eye packing without any Apple hardware.

### 4. Host capture self-test (no GUI, no ALVR, no headset)

Exercises the REAL host capture code — `StereoFrameEncoder` (SBS pack + HEVC encode) and
`FrameCapture` (recv/sbs/decoded PNG writers + HEVC self-decode roundtrip) — fully headless. The
two sources depend only on system frameworks, so the script compiles them with `swiftc` and runs
a synthetic stereo pair through the exact production path:

```bash
mac-host/Tests/run-capture-selftest.sh /tmp/vc-selftest 512 512 3
```

Produces `/tmp/vc-selftest/.run/captures/<ts>/{recv,sbs,decoded}/*.png`. Use it to validate SBS
packing (left half = left eye), RGBA->BGRA, the bottom-left-origin flip, and the HEVC
encode/decode roundtrip without an Apple Vision Pro.

### Replaying real device geometry headless

The mock host's `view_config` defaults to representative AVP-like tangents. To run headless
captures with the EXACT device geometry, capture it once from a live session (the bundle's
`header.json` records `ipd_m` + per-eye `[left,right,up,down]` tangents), then replay it via env:

```bash
VISIONCRAFT_VIEW_IPD_M=0.063 \
VISIONCRAFT_VIEW_TANGENTS_LEFT=1.39,1.07,1.06,1.06 \
VISIONCRAFT_VIEW_TANGENTS_RIGHT=1.07,1.39,1.06,1.06 \
VISIONCRAFT_VIEW_EYE_WIDTH=1888 VISIONCRAFT_VIEW_EYE_HEIGHT=1824 \
./gradlew :bridge-mock-host:run --args="19735"
```

Then drive Minecraft against it (`-Dvisioncraft.dumpFrames=N`) to dump real game eyes rendered
with the real device frustum — no headset needed after the one-time capture.
