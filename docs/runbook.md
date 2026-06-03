# VisionCraft Runbook

For the hardware-first ALVR triage flow, start with [alvr-hardware-playbook.md](alvr-hardware-playbook.md). For canonical path names, see [repo-structure.md](repo-structure.md). For the shell tooling design, see [tooling-architecture.md](tooling-architecture.md).

The reproducible ALVR path is:

```text
Minecraft or test-pattern sender -> Bridge v1 :19735 -> Mac ALVR host -> ALVR server_core -> ALVRClient on Apple Vision Pro
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
  host        clean + launch VisionCraftHost (`--synthetic` arms host-native test frames)
  headset    open the VisionCraft headset client (ALVRClient) project; alias: alvr-client
  synthetic   enable host-native ALVR test frames on a running host
  minecraft  launch the Minecraft Fabric dev client; alias: mc
  test-sender [n] launch the headless test-pattern sender; alias: sender
  verify      assert ALVR client connected, session ready, frames flowing
  observe [s] capture host/ALVR/device diagnostics into .run/observability
  avp-console [s] launch ALVRClient through devicectl --console and capture output
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
scripts/vc.sh bootstrap
scripts/vc.sh package-beta
```

Pair the headset in Xcode first. On the AVP, open Settings, General, Remote Devices, then pair from Xcode. The tracked ALVRClient project currently uses `com.000alen.VisionCraftALVRClient`; change signing and bundle settings deliberately in Xcode if your team needs different values. Set `VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID` only when command-line tooling cannot read the Xcode build settings or must launch an already-installed app with a different bundle ID.

The beta bundle is written to `.run/beta`. Open `.run/beta/README-FIRST.txt` for the shortest local run instructions.

## Run

1. Start clean with host-native synthetic frames armed:

```bash
scripts/vc.sh clean
scripts/vc.sh host --rebuild --synthetic
```

2. Run the headset client:

```bash
scripts/vc.sh headset
```

Xcode opens `visionos-app/ALVRClient.xcodeproj`. Select the paired Apple Vision Pro, press Run, and allow the app permissions on-device.
The headset UI shows a VisionCraft setup panel. If it stays on "Waiting for VisionCraftHost", run `scripts/vc.sh doctor` on the Mac and check artifacts, signing, firewall/network state, and whether the host is running.

For console-driven runs, use:

```bash
scripts/vc.sh avp-console 120
```

This launches the installed ALVRClient via `devicectl --console` and captures stdout/stderr under `.run/observability/`.

3. Verify ALVR-only streaming:

```bash
scripts/vc.sh verify
scripts/vc.sh observe 30
```

The host-native synthetic pattern bypasses Java/Minecraft. If it is not stable, debug only `VisionCraftHost`/ALVR/ALVRClient.

4. Start a Java/Minecraft frame source only after synthetic is stable:

```bash
scripts/vc.sh test-sender
# or
scripts/vc.sh minecraft
```

For Minecraft, press F7 or the VR toggle after the title screen appears.

5. Verify the full bridge path:

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

## Failure Triage Order

1. `scripts/vc.sh observe 30` during the failure.
2. Check `.run/observability/<timestamp>/live/status.ndjson`: confirm `alvr_client_connected`, `session_state`, `frames_encoded`, and `alvr_frames_sent`.
3. If synthetic frames do not advance, inspect `mac-unified.log`, `alvr/session.json`, `alvr/server-core.log`, and `avp-console.log` if present.
4. If synthetic is stable but `test-sender`/`minecraft` is not, inspect `logs/sender.log` or `logs/minecraft.log` plus bridge process/port snapshots.
5. Do not restart `scripts/vc.sh host` mid-test unless you intentionally want to kill frame sources; `host` runs `clean`.

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

Only one frame source can use the bridge at a time. If `vc.sh minecraft` (`mc`) or `vc.sh test-sender` (`sender`) refuses to start, run `scripts/vc.sh clean`.

`vc.sh preflight` verifies real ALVR artifacts, not just project folders. Missing `ALVRClientCore.xcframework`, `alvr_server_core.h`, or `libalvr_server_core.dylib` causes it to run `scripts/prepare-alvr.sh`.

## Observability

Use `scripts/vc.sh observe 30` during any hardware run. It writes a timestamped bundle under `.run/observability/` with `/status` samples, Mac unified logs for VisionCraft/ALVR, process and port snapshots, sender/Minecraft logs, ALVR session config/logs, and `devicectl` device/app/process listings when the AVP is connected.

Use `scripts/vc.sh avp-console 120` when you want Xcode-style headset stdout/stderr without manually watching Xcode. It launches `ALVRClient` through `xcrun devicectl device process launch --console` and stores console plus CoreDevice output in `.run/observability/`.
