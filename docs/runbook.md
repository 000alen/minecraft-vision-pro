# VisionCraft Runbook

The reproducible ALVR path is:

```text
Minecraft / bridge-test -> Java bridge :19735 -> VisionCraftHost -> ALVR server_core -> ALVRClient on Apple Vision Pro
```

`scripts/vc.sh` wraps the Mac-side steps and stale-process checks.

```bash
scripts/vc.sh <command>
  bootstrap   first-run beta setup checks + artifact preparation
  doctor      read-only health report
  status      compact live status + frame-flow sample
  clean       stop host/frame sources/gradle daemons and free ports
  preflight   verify toolchain + generate projects if missing
  package-beta build a local beta bundle under .run/beta
  host        clean + launch VisionCraftHost
  alvr-client open the vendored ALVRClient project and print AVP run steps
  mc          launch the Minecraft Fabric dev client
  sender [n]  launch the headless test-pattern sender
  verify      assert ALVR client connected, session ready, frames flowing
  stop        alias for clean
```

## Ports

| Port | Role | Who connects |
|---|---|---|
| 19734 | Loopback control API | `vc.sh` / `curl` |
| 19735 | Java bridge | Minecraft or the test sender |

ALVR owns headset discovery and streaming on its own LAN ports.

## Setup

```bash
brew install xcodegen openjdk@21 rustup-init
rustup-init -y
source "$HOME/.cargo/env"
export VISIONCRAFT_DEVELOPMENT_TEAM=<your Apple team id>
export VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID=com.example.visioncraft.alvrclient
scripts/vc.sh bootstrap
scripts/vc.sh package-beta
```

Pair the headset in Xcode first. On the AVP, open Settings, General, Remote Devices, then pair from Xcode. If `VISIONCRAFT_DEVELOPMENT_TEAM` is unset, the generated headset project leaves signing blank and Xcode will ask you to select a team before installing on-device.

The beta bundle is written to `.run/beta`. Open `.run/beta/README-FIRST.txt` for the shortest local run instructions.

## Run

1. Start clean:

```bash
scripts/vc.sh clean
scripts/vc.sh host --rebuild
```

2. Run the headset client:

```bash
scripts/vc.sh alvr-client
```

Xcode opens `visionos-app/ALVRClient.xcodeproj`. Select the paired Apple Vision Pro, press Run, and allow the app permissions on-device.
The headset UI shows a VisionCraft setup panel. If it stays on "Waiting for VisionCraftHost", run `scripts/vc.sh doctor` on the Mac and check artifacts, signing, firewall/network state, and whether the host is running.

3. Start a frame source:

```bash
scripts/vc.sh sender
# or
scripts/vc.sh mc
```

For Minecraft, press F7 or the VR toggle after the title screen appears.

4. Verify:

```bash
scripts/vc.sh verify
```

Expected result:

```text
✓ ALVR client connected
✓ bridge session ready
✓ frames flowing (N -> M)
==> STREAM LIVE
```

## Controller Validation

Once video and head pose are stable on hardware, validate inputs in this order:

1. In `scripts/vc.sh status`, confirm ALVR is connected and the Java bridge is ready.
2. In Minecraft, move the left thumbstick: forward/back/strafe should move the player.
3. Move the right thumbstick horizontally: it should drive Vivecraft free-rotate/turn.
4. Right trigger should attack/mine; left trigger should use/place.
5. Squeeze/grip should drive VR interact and climb-grab bindings where those features are enabled.
6. Right A/B should map to jump/sneak; left X/Y should map to inventory/radial menu.
7. Menu/system click should open the in-game menu without fighting visionOS system gestures.
8. Kill or quit ALVRClient while holding an input; all actions should release within one frame or one stale-input timeout.

## Robustness Checks

`vc.sh clean` stops Gradle daemons, severs bridge clients, terminates the host, and verifies loopback ports are free. `vc.sh doctor` reports toolchain availability, AVP presence, port holders, host PID, frame source PID, and `/status`.

Only one frame source can use the bridge at a time. If `vc.sh mc` or `vc.sh sender` refuses to start, run `scripts/vc.sh clean`.

`vc.sh preflight` verifies real ALVR artifacts, not just project folders. Missing `ALVRClientCore.xcframework`, `alvr_server_core.h`, or `libalvr_server_core.dylib` causes it to run `scripts/prepare-alvr.sh`.
