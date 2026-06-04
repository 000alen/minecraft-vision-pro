# ALVR Hardware Playbook

This playbook is the source of truth for reproducible Apple Vision Pro hardware runs.

## Pipeline

```text
ALVR-only:
Mac ALVR host synthetic frames -> ALVR server_core -> ALVRClient on AVP

Full bridge:
Vivecraft Apple provider or test-pattern sender -> Bridge v1 :19735 -> Mac ALVR host
  -> ALVR server_core -> ALVRClient on AVP
```

Always prove the ALVR-only pipeline before adding Java or Minecraft.

## Golden Run

```bash
scripts/vc.sh clean
scripts/vc.sh host --rebuild --synthetic
scripts/vc.sh headset
scripts/vc.sh verify
scripts/vc.sh observe 30
```

On the AVP, wait for "Enter", press it, and expect the host-native synthetic pattern.

When synthetic is stable:

```bash
scripts/vc.sh test-sender
scripts/vc.sh verify
scripts/vc.sh observe 30
```

When the test-pattern sender is stable:

```bash
scripts/vc.sh minecraft
# Apple Vision: VR auto-enables on the title screen when "Remember VR" is on (not during the Mojang splash).
# Otherwise press F7 on the title screen.
scripts/vc.sh verify
scripts/vc.sh observe 30
```

## Console Capture

Use this when Xcode console output is relevant:

```bash
scripts/vc.sh avp-console 120
```

It launches the installed ALVRClient with `xcrun devicectl device process launch --console` and writes logs under `.run/observability/`.

## Triage Matrix

| Symptom | First check | Likely layer |
|---|---|---|
| AVP says "Waiting for VisionCraftHost" | `scripts/vc.sh status`, `doctor`, `devicectl device info apps` | Host not running, LAN/firewall, signing/bundle mismatch, mDNS |
| AVP shows "Enter" but no stream | `host --synthetic`, `observe 30`, `avp-console 120` | ALVR session, decoder config, renderer lifecycle |
| Synthetic works but `test-sender` fails | `logs/sender.log`, bridge port/process snapshot | Bridge v1/test-pattern sender |
| Synthetic and `test-sender` work but Minecraft fails | `.run/minecraft.log`, F7/VR state, controller state | Vivecraft Apple provider or render submitter |
| Minecraft window opens then closes; log stops mid-startup, no `crash-reports/` | `fabric/runs/client/logs/latest.log`, avoid `vc.sh host` while MC is up, launch from Terminal | Process killed externally (`clean`, agent shell, or duplicate Gradle), not always a JVM crash |
| Gray/black rectangle on Mojang red splash (matches empty AVP view); window may flicker closed/reopened | Wait for title screen; ensure `scripts/vc.sh host` is up first; see [vivecraft-backend-notes.md](vivecraft-backend-notes.md#apple-vision-mac-boot) | Remember-VR used to enable stereo during splash (mirror + window resize); fixed by deferred title-screen VR |
| "Missing video format" | Check IDR/config lines in AVP console and `alvr_frames_sent` | Decoder config timing or IDR recovery |
| Renderer crash on reconnect | AVP console stack, `Renderer.swift`, frame queue state | ALVRClient renderer lifecycle |

## Known Runtime Invariants

- `scripts/vc.sh host` runs `clean`; it intentionally stops frame sources. Use `scripts/vc.sh synthetic` to arm test frames on an already-running host.
- Only one Java frame source may own the bridge at a time.
- ALVRClient connecting starts the bridge session in `paused`; the Mac host promotes to `ready` only after tracking + synced `view_config`. Java must not send frames until `ready` (see `scripts/vc.sh verify` and `bridge_streaming_ready` on `/status`).
- ALVR runtime directory/log setup is process-once; host stop/start cycles reuse the initialized server_core environment.
- The bridge caches the latest headset `view_config`, sends it to late Java clients, and heartbeats it while the session is `ready`.
- The host sends HEVC VPS/SPS/PPS out-of-band through ALVR decoder config and keeps them inline on IDR frames for decoder recovery.
- Foveation stays disabled for uniform side-by-side Minecraft frames.
- `view_config` from the headset drives Java projection; do not replace it with symmetric FOV.
- `HandTrackingProvider` is visionOS-only; mac-host receives ALVR controller/button/pose data, not ARKit hands.

## Evidence Bundle Checklist

Attach or inspect these before changing code from a hardware report:

- `.run/observability/<timestamp>/metadata.txt`
- `.run/observability/<timestamp>/before/status.json`
- `.run/observability/<timestamp>/after/status.json`
- `.run/observability/<timestamp>/live/status.ndjson`
- `.run/observability/<timestamp>/mac-unified.log`
- `.run/observability/<timestamp>/alvr/server-core.log`
- `.run/observability/<timestamp>/avp-console.log` when collected
- `.run/logs/sender.log` or `.run/logs/minecraft.log` when Java/Minecraft is involved

## Stop Rules

- Do not patch around ALVR protocol behavior without reading both the matching client and server-core C ABI.
- Do not debug Minecraft until synthetic ALVR frames are stable.
- Do not debug controller input until video, pose, and `view_config` are stable.
- Do not rely on screenshots of Xcode console when `avp-console` can collect the same output.
