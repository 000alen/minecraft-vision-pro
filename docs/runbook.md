# VisionCraft runbook

The single, reproducible recipe for bringing the whole pipeline up — and the stale-state checks
that keep it robust. Every Mac-side step is wrapped by **`scripts/vc.sh`** so there is no
improvising. Wear the Apple Vision Pro only after the host is healthy (Phase B).

```
scripts/vc.sh <command>
  doctor      read-only health report (tools, ports, processes, host /status, AVP)
  status      compact live status + a 1.5s frame-flow sample
  clean       stop ALL VisionCraft processes (host, frame source, gradle daemons) + free ports
  preflight   verify toolchain + regenerate Xcode projects if missing
  host        clean + (re)launch VisionCraftHost; block until control API is healthy
  companion   build + install + launch the companion on the paired AVP (best effort)
  mc          launch the Minecraft Fabric dev client (openjdk@21) as the frame source
  sender [n]  launch the headless test-pattern sender (n frames; 0 = continuous)
  verify      assert the live stream is healthy (viewer connected, frames flowing, session ready)
  stop        alias for clean
```

## System map

```
 Minecraft (Java, Vivecraft Apple provider)                Apple Vision Pro
        │  TCP 127.0.0.1:19735  (bridge / Java)                    │
        ▼                                                          │  Bonjour _visioncraft-stream._tcp
 ┌─────────────────────── VisionCraftHost (macOS) ───────────────────────┐
 │  bridge :19735   receives RGBA eye frames + pose/view_config          │
 │  StereoFrameEncoder → HEVC                                            │
 │  relay  :19736   streams to the companion ◄───────────────────────────┘ (TCP 19736)
 │  control:19734   loopback HTTP automation (/health /status /bridge/* /relay/*)
 └───────────────────────────────────────────────────────────────────────┘
```

| Port  | Role | Who connects |
|-------|------|--------------|
| 19734 | Loopback control API (HTTP) | `vc.sh` / `curl` |
| 19735 | Java bridge | Minecraft **or** the test sender (exactly one) |
| 19736 | Stream relay (Bonjour `_visioncraft-stream._tcp`) | the AVP companion |

**Critical ordering invariant:** the host never opens its own immersive space — the **companion
connecting is what flips the bridge session to `ready`**. Minecraft refuses to submit frames
("Session not ready") until the headset is in. So the order is always: **host → companion → game → F7.**

**One frame source at a time.** Minecraft and the `sender` both attach to the bridge as the single
Java client. `vc.sh mc` / `vc.sh sender` refuse to start if one is already connected — run
`vc.sh clean` first.

## Toolchain (one-time)

```bash
brew install xcodegen openjdk@21
scripts/vc.sh preflight     # verifies tools, regenerates *.xcodeproj if missing, prints doctor
```

`preflight` must end with green checks for `xcodebuild`, `xcodegen`, `openjdk@21`, both xcodeprojects,
and a connected AVP. Pair the headset first: on the AVP, **Settings ▸ General ▸ Remote Devices**, then
**Pair** it in Xcode (same Wi-Fi + Bluetooth on).

---

## The recipe

### Phase A — start from a known-clean slate (handles stale processes)

```bash
scripts/vc.sh doctor    # inspect: stale host? leftover gradle daemons? ports held?
scripts/vc.sh clean     # stop host + frame sources + gradle daemons; verify 19734/35/36 are free
```

`clean` is always safe to run and idempotent. It stops Gradle daemons gracefully (`gradlew --stop`
for both wrappers), severs any live bridge client, SIGTERM→SIGKILL the host, then **confirms each
port is actually free** (escalating to kill the port holder if not). If it ever prints
`✗ … STILL held`, something outside this repo owns the port — investigate before continuing.

### Phase B — host (Mac only, no headset yet)

```bash
scripts/vc.sh host          # reuses the existing Debug build; add --rebuild after Swift/Metal edits
```

✅ **Checkpoint B:** the command prints `✓ control API healthy on :19734` and
`relay_running = true`, `diagnostic = Relay listening on :19736` / `Bonjour registered`.
If it dies with "control API never responded", re-run `scripts/vc.sh host --rebuild`.

### Phase C — companion on the AVP (build + run from Xcode)

The companion is built and run **from Xcode** — this is the reliable path:

```bash
scripts/vc.sh companion     # opens the project + prints the steps below
```

1. Xcode opens `visionos-app/VisionCraftCompanion.xcodeproj`.
2. In the run-destination menu, pick **Alen’s Apple Vision Pro**.
3. Press **▶ (Cmd-R)** — Xcode builds, signs, installs, and launches on the headset.
4. **Put on the AVP**, open **VisionCraft**, and tap **Enter VisionCraft**.

> **Why not headless `xcodebuild`/`devicectl`?** The AVP exposes *two different identifiers*: the
> CoreDevice UDID that `devicectl` uses (e.g. `D196DA96-…`) and the hardware id `xcodebuild
> -destination id=` expects (e.g. `00008142-…`). Xcode's ▶ resolves the right id plus automatic
> signing and provisioning in one step; a CLI flow is fragile against all three. Use Xcode.

✅ **Checkpoint C:** on the Mac,

```bash
scripts/vc.sh status        # relay_viewer = true, session_state = ready
```

If `relay_viewer = false`, the companion did not reach the relay — confirm Mac + AVP are on the same
network and re-tap Enter. (The app should not error opening the immersive space; that bug is fixed via
`UIApplicationSupportsMultipleScenes`.)

### Phase D — frame source

Real game:

```bash
scripts/vc.sh mc            # launches the Fabric dev client with openjdk@21; logs to .run/minecraft.log
# at the Minecraft title screen, press F7 (or the "VR: OFF" toggle) to enable VR
```

…or a deterministic test pattern (no game, no account) to isolate the video path:

```bash
scripts/vc.sh sender        # continuous checkerboards; logs to .run/sender.log
```

✅ **Checkpoint D — the gate before you trust what you see in the headset:**

```bash
scripts/vc.sh verify
#   ✓ companion connected to relay
#   ✓ bridge session ready
#   ✓ frames flowing (N → M)
#   ==> STREAM LIVE
```

Only when `verify` says **STREAM LIVE** is it worth judging the image in the headset.

### Phase E — tear down

```bash
scripts/vc.sh clean         # leaves ports free and no daemons running
```

---

## Stale-process handling (what "robust" means here)

`vc.sh` treats the following as the live source of truth, never assumptions:

- **Ports** — `lsof -nP -iTCP:<port>`; `clean` frees 19734/19735/19736 and *verifies* they are free.
- **Host** — matched by its bundle path, SIGTERM with a 3s grace window, then SIGKILL.
- **Frame source** — detected as *any non-host process with an ESTABLISHED socket on :19735* (so it
  catches an orphaned game/sender JVM even when the Gradle wrapper has exited).
- **Gradle daemons** — stopped via `gradlew --stop` for both the root and `minecraft/VivecraftMod`
  wrappers (they run different Gradle versions: 8.12 and 9.3.0).

If you ever hit `Relay failed: Address already in use`, it means a previous host (or another process)
still holds a port — `scripts/vc.sh clean` is the fix, and `doctor` shows you the culprit PID first.

## Troubleshooting (symptom → check)

| Symptom | Command | What it tells you |
|---|---|---|
| "Is anything stale?" | `vc.sh doctor` | port holders, host PID, frame source, gradle daemons, AVP, `/status` |
| Host won't start, port in use | `vc.sh clean` then `vc.sh host` | frees ports, relaunches; `doctor` names the PID |
| Companion shows nothing | `vc.sh status` | `relay_viewer` must be `true`; else network/Enter issue |
| "Session not ready" in Minecraft | `vc.sh status` | `session_state` must be `ready` → companion must be connected first |
| Black/stuck image | `vc.sh verify` | `frames_encoded` must advance; if not, source is off or VR isn't toggled (F7) |
| Two sources fighting | `vc.sh mc`/`sender` refuse | only one bridge client allowed — `vc.sh clean` |
| Minecraft logs | `tail -f .run/minecraft.log` | game/Gradle output |
| Test-sender logs | `tail -f .run/sender.log` | headless pattern output |

## Notes

- `vc.sh` is bash 3.2-compatible (stock macOS `/bin/bash`) and reads/writes only loopback + local files.
- Background logs and pidfiles live in `.run/` (git-ignored).
- The control API is **loopback-only** by design (it can start/stop services), so these commands must
  run on the same Mac as the host.
- For the deeper build details (Gradle/XcodeGen, why openjdk@21), see [build.md](build.md).
```
