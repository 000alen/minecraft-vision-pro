# Build guide

> **Running the full pipeline?** Use the reproducible recipe in [runbook.md](runbook.md)
> (driven by `scripts/vc.sh`) — it handles stale processes, port conflicts, and the
> host → ALVRClient → game → F7 ordering. This file covers the underlying build details.

## Hardware & OS

- MacBook Pro with Apple Silicon (M4 recommended)
- Apple Vision Pro on visionOS 26+, Developer Mode enabled
- macOS 26+ (Tahoe), Xcode 26+

## Version freeze (recommended)

| Component | Version |
|-----------|---------|
| macOS / visionOS / Xcode | 26+ |
| Java | 21+ for bridge tests; Vivecraft resolves its requested Java toolchain |
| Minecraft | Latest stable supported by vendored Vivecraft tree |
| Loader | Fabric (first) |
| VivecraftMod | Vendored at `minecraft/VivecraftMod/` — see `minecraft/VENDORED.md` |

Update the vendored tree only deliberately after M5; document new upstream SHA in `VENDORED.md`.

## Native Host and ALVR Artifacts

```bash
scripts/vc.sh bootstrap
```

`bootstrap` checks prerequisites, verifies the source-controlled vendored `alvr-visionos` tree, generates projects, builds `alvr_client_core`, builds the macOS `alvr_server_core` dylib/header, and places server artifacts under `mac-host/Vendor/ALVRServerCore/`. The vendored ALVR version and VisionCraft source deltas must already live in the repo; prepare scripts validate/build them rather than owning project source changes.

For a source-only ALVR hygiene check that does not build artifacts:

```bash
scripts/prepare-alvr.sh --check-source
```

`prepare-alvr.sh` accepts a **monorepo vendored** `visionos-app/` tree (no `.git` under `visionos-app` or `ALVR`) when `ALVRClient.xcodeproj` and `ALVR/Cargo.toml` are present. Submodule mode still runs `git submodule update` when `.git` exists.

For offline Mac host iteration only, set `VISIONCRAFT_SKIP_PREPARE_ALVR=1` to skip the Xcode preBuild `prepare-alvr.sh` step (artifacts must already exist under `mac-host/Vendor/ALVRServerCore/`).

`--check-source` validates required VisionCraft source deltas and intentionally allows dirty local vendored development. Before shipping, run the stricter source-control gate:

```bash
scripts/prepare-alvr.sh --check-source-control
```

That mode fails if `visionos-app` or `visionos-app/ALVR` has uncommitted or untracked source changes, or if the parent repositories do not record the checked-out submodule commits.

`scripts/prepare-alvr.sh` does not rewrite tracked ALVRClient signing, bundle IDs, entitlements, or project files. The tracked ALVRClient target currently sets `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `ALVRClient.xcodeproj`; target-level Xcode build settings override values from `ALVRClient.xcconfig` and `Override.xcconfig`. Use Xcode's Signing & Capabilities tab, an explicit project source change, or command-line build settings for local signing changes. `Override.xcconfig` remains useful only for settings that are not overridden by target build settings.

For a local compile-only host build without a command-line signing identity:

```bash
xcodebuild -project mac-host/VisionCraftHost.xcodeproj -scheme VisionCraftHost \
  -configuration Debug -derivedDataPath mac-host/build CODE_SIGNING_ALLOWED=NO build
```

To run on hardware, use:

```bash
scripts/vc.sh headset
```

This opens `visionos-app/ALVRClient.xcodeproj`. Choose the paired Apple Vision Pro and press Run. Xcode/TestFlight signing is still required for AVP installation.

### Automation hooks

For simulator and repeatable hardware smoke tests, the host accepts environment
variables or equivalent launch arguments:

```bash
VISIONCRAFT_BRIDGE_PORT=19735
VISIONCRAFT_NO_AUTO_START_BRIDGE=1
VISIONCRAFT_NO_AUTO_START_ALVR=1
VISIONCRAFT_CODE_SIGNING_ALLOWED=NO
```

Equivalent launch arguments are `--bridge-port 19735` and `--no-auto-start-bridge`.

The host also starts a loopback-only HTTP control API on port `19734` by default
(`VISIONCRAFT_CONTROL_PORT` or `--control-port` overrides it):

```bash
curl http://127.0.0.1:19734/health
curl http://127.0.0.1:19734/status
curl -X POST 'http://127.0.0.1:19734/bridge/start?port=19735'
curl -X POST http://127.0.0.1:19734/bridge/stop
curl -X POST 'http://127.0.0.1:19734/alvr/start?synthetic=true'
curl -X POST http://127.0.0.1:19734/alvr/stop
```

`/status` reports ALVR server/client connection, target eye size, frame counters, bridge session state, and diagnostics.

After launching ALVRClient, check:

```bash
curl http://127.0.0.1:19734/status
```

For ALVR validation, start with the host-native synthetic source:

```bash
scripts/vc.sh host --rebuild --synthetic
# or, if the host is already running:
scripts/vc.sh synthetic
```

Expect `alvr_running: true`, `alvr_client_connected: true`, `session_state: "ready"`, and `alvr_frames_sent` advancing after ALVRClient enters immersive mode. Only move to `scripts/vc.sh test-sender` (`sender`) or `scripts/vc.sh minecraft` (`mc`) after this ALVR-only path is stable.

## Bridge tests (any OS with Java 21)

```bash
./gradlew test
./gradlew :bridge-test:run
```

The bridge Java modules live under `bridge/java/`, but their Gradle project names
remain `:bridge-lib`, `:bridge-mock-host`, and `:bridge-test` for compatibility.
On Mac, start `VisionCraftHost` first so port `19735` is listening.

## Vivecraft (vendored)

```bash
cd minecraft/VivecraftMod
./gradlew :fabric:build
```

The current Fabric artifact is written to
`minecraft/VivecraftMod/build/libs/vivecraft-26.1.2-1.3.10-fabric.jar`.
Install that JAR in the Minecraft Fabric profile's `mods/` directory with the
matching Fabric loader setup. Default VR plugin is **Apple Vision**. Launch
**VisionCraftHost** and **ALVRClient**, then enable VR.

## Running Minecraft on the headset (dev client — no launcher/account)

The fastest way to run the game with the mod is the **Fabric Loom dev client**, not
the Minecraft Launcher. It spins up Minecraft `26.1.2` with the vendored mod already
on the classpath — no Microsoft account, no `mods/` copy, no installed profile.

> The Gradle wrapper here rejects Java 25 (the game's runtime). Drive it with
> Homebrew **`openjdk@21`**; Loom provisions the game JVM itself.

```bash
# from minecraft/VivecraftMod
env JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home" \
  PATH="$(brew --prefix openjdk@21)/bin:$PATH" \
  ./gradlew :fabric:runClient
```

In-game: at the title screen press **F7** (or click the `VR: OFF` toggle) to enable VR.
The Apple Vision provider then connects to the loopback bridge on `127.0.0.1:19735`.

### ALVR Ordering

ALVRClient connecting is what makes the bridge session `ready`, so Minecraft will refuse to submit frames ("Session not ready") until the headset is in. Order:

```text
1. Run VisionCraftHost            # auto-starts control API :19734, bridge :19735, ALVR server_core
2. Run ALVRClient on AVP          # connects to server_core; bridge session -> ready
3. Validate synthetic frames      # scripts/vc.sh synthetic; no Java/Minecraft involved
4. ./gradlew :fabric:runClient    # launch the game (openjdk@21 as above)
5. Press F7 in-game               # VR ON -> real eye frames flow to the headset
```

Headless frame-source sanity check without the game (continuous test pattern):

```bash
./gradlew :bridge-test:run        # streams checkerboards until Ctrl-C; needs ALVRClient connected
```

Watch the pipeline from the loopback control API:

```bash
curl -s http://127.0.0.1:19734/status   # alvr_client_connected, frames_encoded, session_state
```

## Packaging

Create the local beta bundle with:

```bash
scripts/vc.sh package-beta
```

The bundle is written to `.run/beta` and contains:

- `VisionCraftHost.app`
- Fabric mod JAR
- `README-FIRST.txt`
- headset install notes for the signed ALVRClient Xcode/TestFlight step
