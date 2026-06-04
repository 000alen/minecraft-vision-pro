# VisionCraft — Extensive Technical Audit Report

**Repository:** minecraft-vision-pro  
**Audit period:** Rounds 1–7 (read-only code review, no implementation changes in audit sessions)  
**Last verified:** 2026-06-03 (workspace: vendored `visionos-app/` tree without submodule `.git`; `prepare-alvr.sh --check-source` fails accordingly)  
**Platform pins (project):** macOS 26+, visionOS 26+, Xcode 26+

---

## Table of contents

1. [Executive summary](#1-executive-summary)
2. [Scope and methodology](#2-scope-and-methodology)
3. [System architecture](#3-system-architecture)
4. [Critical invariants](#4-critical-invariants)
5. [Findings by severity](#5-findings-by-severity)
6. [Mac ALVR host](#6-mac-alvr-host)
7. [VisionCraft headset client (ALVRClient)](#7-visioncraft-headset-client-alvrclient)
8. [Bridge v1 and Java layer](#8-bridge-v1-and-java-layer)
9. [Vivecraft Apple provider](#9-vivecraft-apple-provider)
10. [ALVR vendored stack (video, IDR, negotiation)](#10-alvr-vendored-stack-video-idr-negotiation)
11. [Tooling, control API, and observability](#11-tooling-control-api-and-observability)
12. [Documentation, CI, and build gates](#12-documentation-ci-and-build-gates)
13. [Security and licensing](#13-security-and-licensing)
14. [Testing inventory and gaps](#14-testing-inventory-and-gaps)
15. [Failure mode matrix](#15-failure-mode-matrix)
16. [Hardware debug playbook](#16-hardware-debug-playbook)
17. [Remediation roadmap](#17-remediation-roadmap)
18. [Appendix: golden files and round map](#18-appendix-golden-files-and-round-map)

---

## 1. Executive summary

VisionCraft streams **Minecraft Java in VR** from a MacBook (Apple Silicon) to **Apple Vision Pro** using a deliberate three-hop design:

1. **Vivecraft Apple provider** (Java) renders stereo RGBA and speaks **Bridge v1** over loopback TCP (`:19735`).
2. **Mac ALVR host** (`VisionCraftHost`) encodes side-by-side **HEVC Annex-B** via VideoToolbox and feeds **ALVR `server_core`**.
3. **ALVRClient** on visionOS decodes, composites (Metal or RealityKit), and uplinks tracking via ALVR control packets.

The architecture is **sound and intentionally narrow**: VisionCraft does not reimplement ALVR’s wire protocol in Swift; it bridges Java I/O to ALVR’s encoder path and uses ALVRClient for decode/render.

**Overall assessment**

| Area | Rating | Notes |
|------|--------|-------|
| Architecture / contracts | Strong | Clear golden files, `bridge/protocol.md`, ALVR end-to-end path |
| Bridge v1 + Java | Good | Thread model sane; integration tests; some protocol asymmetry vs Mac |
| Mac host video | Mixed | Solid VT path; several gates and dead fields confuse debug |
| Headset client | Mixed | Functional path; known leaks, queue bug, lifecycle flag drift |
| Tooling | Good foundation | `vc.sh` + observe bundles; metrics gaps for decode/black screen |
| Build / CI | Weak | `prepare-alvr.sh` blocks vendored monorepo; CI is Java-only |
| Docs / legal | Needs work | STATUS/README drift; LGPL Vivecraft; no root NOTICE |

**Top blockers (P0)**

1. **`scripts/prepare-alvr.sh`** still requires `visionos-app/.git` and `visionos-app/ALVR/.git` — fails on the **vendored-in-root** tree model (commit `39c6384` style) even when all files are present.
2. **Session `ready` before video can encode** — Java may stream while Mac drops frames until `TRACKING_UPDATED`.
3. **Stale `view_config` width/height** vs actual Java encode dimensions — fusion/scale bugs.
4. **`sentVideoConfig` / HEVC parameter sets** — permanent black video if IDR never yields VPS/SPS/PPS.

**Top stability issues (P1)**

- `WorldTracker.sendViewParams` memory leak (every IPD change).
- Client `frameQueueLastTimestamp != timestamp || true` disables dedup.
- `renderStarted` never cleared on disconnect — immersive/render gating drift.
- `render_orientation_xyzw` parsed but not sent on ALVR path.
- Client advertises `foveated_encoding: true` while server default is off (footgun if settings change).

---

## 2. Scope and methodology

### In scope

- `mac-host/` — ALVR server coordinator, Java bridge server, VideoToolbox encoder, control API
- `visionos-app/` — ALVRClient, vendored `ALVR/` (client_core, server_core, session)
- `minecraft/VivecraftMod/` — Apple VR provider and `visioncraft.bridge`
- `bridge/` — protocol docs, mock host, test-pattern sender
- `scripts/` — `vc.sh`, `prepare-alvr.sh`, observability
- `shared/Sources/StereoMath.swift`
- CI workflow, key docs

### Out of scope / retired (do not reintroduce without explicit request)

Per `AGENTS.md`: `StreamRelay*`, `StreamProtocol`, `CompositorRenderer`, `VisionCraftImmersiveContent`, custom RemoteImmersiveSpace relay (`bridge/stream-protocol.md` port 19736).

### Method

Seven audit rounds:

| Round | Focus |
|-------|--------|
| 1 | Repo breadth, architecture, initial P0s |
| 2a | FFI lifecycle, `view_config` timeline, reconnect |
| 2b | Mac video path, every drop point, HEVC |
| 2c | Client decode, queue, render, foveation layers |
| 2d | Bridge threading, mock vs Mac, test gaps |
| 3 | Cross-layer invariants, failure matrix, fix DAG |
| 4a | NAL path, IDR/DecoderConfig, raw buttons |
| 4b | Control API, `vc.sh`, observe limits |
| 4c | Settings negotiation (resolution, fps, foveation) |
| 5 | Debug decision tree |
| 6 | Unused FFI, CI blind spots |
| 7 | Projection/tangents, legal, prepare-alvr, signing |

No hardware run was performed as part of this report; hardware steps are **recommended validation**, not audit results.

---

## 3. System architecture

### Data flow

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ Minecraft (Vivecraft AppleVisionProvider)                                │
│  AppleVisionStereoRenderer.endFrame  [gates on view_config]              │
│  AppleFrameSubmitter → AsyncFrameSender → AppleNativeBridge (TCP client) │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ Bridge v1 :19735 (JSON lines + RGBA8×2)
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Mac VisionCraftHost                                                      │
│  JavaBridgeServer → AlvrServerCoordinator.submitFrame                    │
│  StereoFrameEncoder (HEVC SBS) → vc_alvr_send_video_nal                  │
│  ALVR poll: pose, controller, hand, view_config → forwardUplink          │
│  Control API :19734 (/status, /alvr/start, …)                            │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ ALVR (TCP/video + control)
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ ALVRClient (visionOS)                                                    │
│  EventHandler: decode, frame queue, streaming events                     │
│  WorldTracker: sendViewParams, sendTracking                              │
│  Renderer / RealityKitClientSystem: compositor, SBS shader               │
└─────────────────────────────────────────────────────────────────────────┘
```

### Ports and processes

| Port | Service |
|------|---------|
| 19734 | Mac control API (loopback HTTP) |
| 19735 | Bridge v1 (loopback TCP) |
| ALVR | LAN streaming (mDNS / session; not fixed port in audit) |

### Canonical names

See `docs/repo-structure.md`: Mac ALVR host, VisionCraft headset client / ALVRClient, Vivecraft Apple provider, Bridge v1, bridge Java library, test-pattern sender, mock host.

---

## 4. Critical invariants

Violating these produces “black headset,” “standby forever,” or unfusable stereo.

### I1 — Java withholds stereo until `view_config`

`AppleVisionStereoRenderer.endFrame` returns early if `getViewConfig() == null`. Symmetric fallback projection **cannot fuse** on AVP.

**Unlock:** `views[]` with index `0` and `1`, each with parseable `tangents[4]`. Width/height/IPD are not required for the gate.

### I2 — Mac encodes video only after first tracking sample

`submitFrame` and `submitSyntheticFrameLocked` require `lastTrackingSampleTimestampNs != 0`.

**Paradox:** `session_state` can be `ready` and `view_config` can arrive **before** tracking — Java may send frames that Mac **silently drops**.

### I3 — `view_config` dimensions vs encode dimensions

Mac publishes `width`/`height` from `viewConfigEyeWidth/Height` (set at ALVR `start()`). Java updates `targetEyeWidth/Height` per frame. Tangents come from ALVR FOV; **pixel sizes in JSON can be stale**.

### I4 — ALVR wire `ViewsConfig` is FOV + IPD only

Server rebuilds eye poses; Java bridge JSON does not carry per-eye canted poses from AVP—only tangents derived from FOV angles.

### I5 — First visible AVP frame ≠ first decoded NAL

Client gates: IPD discovery, `framesRendered < refreshRate`, origin anchor, then `alvr_report_compositor_start`. Expect **~1–4 s after immersive open** in typical conditions.

### I6 — `render_orientation_xyzw` not on ALVR video path

Java sends it when pose is valid; Mac parses it into encoder `AccessUnit` but **`send()` does not use it** — timewarp metadata is discarded for ALVR streaming.

---

## 5. Findings by severity

### P0 — Blockers

| ID | Finding | Location / evidence |
|----|---------|---------------------|
| P0-1 | `prepare-alvr.sh --check-source` fails when `visionos-app` is vendored without `.git` | `scripts/prepare-alvr.sh` L82–85; verified 2026-06-03 |
| P0-2 | `submitFrame` gated on tracking; session `ready` earlier | `AlvrServerCoordinator.swift` L168; `VisionCraftAppModel` connect callback |
| P0-3 | Stale `viewConfigEyeWidth/Height` in `view_config` JSON | `publishViewConfig` vs `targetEyeWidth` updates |
| P0-4 | If IDR lacks extractable VPS/SPS/PPS, `sentVideoConfig` never true → no NALs sent | `send()` L346; `splitHEVCParameterSets` |
| P0-5 | Xcode Mac host preBuild runs full `prepare-alvr.sh` | `mac-host/project.yml` — same submodule gate |

### P1 — Correctness / stability

| ID | Finding | Location / evidence |
|----|---------|---------------------|
| P1-1 | `sendViewParams` allocates without `deallocate` | `WorldTracker.swift` ~3045–3049 |
| P1-2 | `|| true` disables frame queue timestamp dedup | `EventHandler.swift` ~573 |
| P1-3 | `renderStarted` never cleared on `stop()` / stream stop | `EventHandler.swift`; `Renderer.init` sets true only |
| P1-4 | `render_orientation` dead on ALVR path | `JavaBridgeServer` → `StereoFrameEncoder` → `send()` |
| P1-5 | `foveated_encoding: true` in client capabilities | `EventHandler.swift` ~194; server default off |
| P1-6 | Java pose has no staleness (unlike hand/controller 250 ms) | `ApplePoseProvider` |
| P1-7 | Bridge reader `(char) b` per byte — not UTF-8 safe | `AppleNativeBridge` readLoop |
| P1-8 | No application `ping` watchdog despite protocol support | Vivecraft provider |
| P1-9 | `tracking_state` always `"valid"` on Mac pose uplink | `publishPose` |
| P1-10 | VT bitrate ~80 Mbps fixed; ALVR `bitrate_bps` ignored | `StereoFrameEncoder.swift` L159–160; `refreshDynamicEncoderParamsLocked` |
| P1-11 | Java `recenter` only bumps counter — no ALVR recenter API | Mac bridge handler |
| P1-12 | Decode overrun guard uses `50*MSEC_PER_SEC` (~50k s) | `EventHandler.swift` ~554 |
| P1-13 | `framesEncoded` increments before `sentVideoConfig` guard | Misleading `pipeline_ready` / metrics |
| P1-14 | `vc_alvr_report_composed` / `report_present` never called from Swift | Shim only |
| P1-15 | Client `exit(0)` on background / watchdog | `EventHandler.swift` |

### P2 — DX / tests / docs

| ID | Finding |
|----|---------|
| P2-1 | CI: Ubuntu only, `./gradlew test` — no prepare-alvr, no Xcode, no Rust |
| P2-2 | `session_state` enum includes `paused`/`lost` but Mac never sets them |
| P2-3 | Mock host static hand/controller — masks staleness tests |
| P2-4 | Mac closes on malformed JSON; Java swallows field errors — asymmetry |
| P2-5 | `StereoMath.tangents(fromProjection:)` unused — dead alternate path |
| P2-6 | `docs/architecture.md` still says “symmetric perspective per eye” |
| P2-7 | `bridge/protocol.md` header implies Compositor-only `view_config` source |
| P2-8 | `STATUS.md` milestone table vs README / current ALVR path confusion |
| P2-9 | `ALVRClient.xcconfig` team `GBH6W69TD8` stale; pbxproj `29JNF9988B` wins |
| P2-10 | `verify` checks `frames_encoded` only, not `alvr_frames_sent` |
| P2-11 | `desiredEyeDims()` uses left eye size for both eyes |
| P2-12 | Bridge controller poses parsed but unused for aim (fake HMD-forward) |
| P2-13 | No root `NOTICE` / consolidated third-party attribution |
| P2-14 | LGPL Vivecraft — distribution checklist not in `docs/` |

### P3 — Minor / informational

| ID | Finding |
|----|---------|
| P3-1 | Synthetic timer capped at 60 Hz while encoder may be 90 Hz |
| P3-2 | `frame_id` monotonic across reconnect (never reset unless provider destroyed) |
| P3-3 | mDNS listener recreated ~every 2s until streaming |
| P3-4 | `PosePublisher.publishViewConfig` dead when ALVR connected |
| P3-5 | No Swift unit tests for Mac host |
| P3-6 | `alvr_restart()` not exposed in Mac shim |
| P3-7 | Stutter counter logs only — no recovery action |

---

## 6. Mac ALVR host

### Golden files

- `Sources/AlvrServerCoordinator.swift` — lifecycle, encode, uplink
- `Sources/JavaBridgeServer.swift` — Bridge v1 TCP server
- `Sources/StereoFrameEncoder.swift` — HEVC SBS
- `Sources/VisionCraftAppModel.swift` — wiring, control API
- `Sources/ALVRServerCoreShim.c` / `.h` — C ABI

### Video path — early returns / drops

**Bridge ingress (`JavaBridgeServer`):**

- Malformed JSON / version / frame metadata → **close connection**
- Eye dimension / `byte_length` mismatch → **silent drop** (buffer consumed, no `onFrame`)
- Invalid `render_orientation_xyzw` → orientation cleared; frame may still proceed

**Coordinator:**

- `!running`, `!clientConnected`, `lastTrackingSampleTimestampNs == 0` → drop frame

**Encoder (`StereoFrameEncoder`):**

- Latest-frame-wins while VT busy (intermediate frames dropped)
- Many VT failure paths return false → drop

**ALVR egress (`send`):**

- `!sentVideoConfig || empty payload` → drop NAL (but `framesEncoded` already incremented)

### HEVC parameter sets

- On keyframe: split VPS/SPS/PPS (NAL types 32/33/34) for `vc_alvr_set_video_config_hevc`
- **Full Annex-B AU still sent** on wire (inline PS on IDR for decoder recovery)
- `split.payload` from split is unused for send path

### Dynamic encoder params

| Field | Read | Applied |
|-------|------|---------|
| `framerate` | Yes | Yes → VT `ExpectedFrameRate` |
| `bitrate_bps` | Yes | **No** (80 Mbps fixed) |

### `view_config` publication

```swift
// AlvrServerCoordinator — tangents from ALVR FOV; dimensions from viewConfigEye*
private static func tangents(from fov: VCAlvrFov) -> SIMD4<Float> {
    SIMD4<Float>(tan(-fov.left), tan(fov.right), tan(fov.up), tan(-fov.down))
}
```

`VC_ALVR_EVENT_VIEWS_CONFIG` does **not** refresh `viewConfigEyeWidth/Height` from event.

### Session lifecycle

| Event | Effects |
|-------|---------|
| `CLIENT_CONNECTED` | `session ready`, tracking=0, `sentVideoConfig=false`, `requestKeyframe()` |
| `TRACKING_UPDATED` | Sets `lastTrackingSampleTimestampNs` — **unblocks encode** |
| `CLIENT_DISCONNECTED` | `session closed`, counters reset |

### Input bridge

- Raw ALVR buttons via `vc_alvr_get_raw_buttons` → Java `controller` JSON
- Haptics: `vc_alvr_send_haptics` from Java `haptic` messages
- Mapped `alvr_get_buttons` not exposed in shim

---

## 7. VisionCraft headset client (ALVRClient)

### Golden files

- `EventHandler.swift` — ALVR thread, decode, mDNS
- `WorldTracker.swift` — tracking, `sendViewParams`
- `Renderer.swift` / `RealityKitClientSystem.swift` — display paths
- `Shaders.metal` — side-by-side sampling (`sourceY = 1.0 - uv.y`)

### State flags

| Flag | Meaning |
|------|---------|
| `alvrInitialized` | `alvr_initialize` done |
| `streamingActive` | Stream believed active |
| `renderStarted` | Immersive renderer up; **never cleared on stop** |

### `handleNals` behavior

- If `!renderStarted`: return **true** (accept NALs, no decode)
- `|| true`: always enter queue branch — **dedup disabled**
- IDR / lag / starvation paths return **false** → request IDR from host

### View params FFI

`alvr_send_view_params` **copies** two structs synchronously in Rust (`client_core/c_api.rs`) — safe to deallocate immediately after call; Swift `sendViewParams` **does not deallocate**.

### Foveation (three layers)

1. **ALVR FFR shader** — gated by `settings.video.foveated_encoding` (server default **off**)
2. **Compositor** `isFoveationEnabled` from hardware capabilities — independent
3. **RealityKit VRR** rasterization rate map — separate from ALVR FFR

Client still advertises `foveated_encoding: true` in capabilities.

### First-frame timeline (estimate)

After immersive open: IPD gate, `refreshRate` frame warmup, origin anchor (up to ~300 frames), `videoFormat`, `alvr_report_compositor_start` — often **1–4 s** to stable stereo.

---

## 8. Bridge v1 and Java layer

### Protocol (`bridge/protocol.md`)

- TCP loopback, newline-delimited JSON
- `frame`: JSON line + left RGBA8 + right RGBA8 (OpenGL bottom-left origin)
- `view_config`: asymmetric tangents + per-eye width/height + `ipd_m`
- `pose`, `controller`, `hand`, `session`, `ping`/`pong`, `haptic`, `recenter`

### Threading

| Thread | Role |
|--------|------|
| Minecraft poll | reconnect, pose, input |
| Render | PBO readback, `AsyncFrameSender` commit |
| `visioncraft-frame-sender` | `sendFrame` (synchronized) |
| `visioncraft-bridge-reader` | `handleLine` |

`AsyncFrameSender`: latest-wins mailbox; send failures do not kill sender thread.

### Parsing gaps

- Partial `view_config` returns null → **keeps previous** config (good)
- Unknown `type` ignored on Java; Mac may close on malformed lines
- No max line length on Java reader (mock caps 64 KiB)

### Mock vs Mac host (summary)

| Behavior | Mock | Mac |
|----------|------|-----|
| Session | Always `ready` | `ready` / `closed` from ALVR |
| view_config | Once at connect | ALVR + 1 Hz heartbeat |
| Hand/controller | Once, static | Live ALVR |
| Frame validation | byte_length strict | Drops dim mismatch silently |

---

## 9. Vivecraft Apple provider

### Defaults

- VR backend: `APPLE_VISION`
- OpenVR skipped via mixins / `VisionCraftRuntime.skipOpenVR()`

### Projection (`AppleProjectionProvider`)

- **With `view_config`:** `projectionFromTangents` — matches protocol `frustum(-left·n, right·n, -down·n, up·n, n, f)`
- **Without:** symmetric `setPerspective` — gated out of streaming until config arrives

### Latency

- PBO double-buffer + async sender ≈ **2+ frames** after render

### Input

- Bridge controller poses parsed but **not used** for aim — fake HMD-forward controllers
- F7 toggles VR

### Launch

- `scripts/vc.sh minecraft` uses Gradle via tooling; direct `./gradlew :fabric:runClient --no-daemon` often more reliable per runbook

---

## 10. ALVR vendored stack (video, IDR, negotiation)

### NAL path (Mac → network)

`vc_alvr_send_video_nal` → `alvr_send_video_nal` → sync channel (depth **2**) → video send thread → sharded TCP with `VideoPacketHeader` + Annex-B payload.

### DecoderConfig vs Mac gate

| Step | Mechanism |
|------|-----------|
| Store | `vc_alvr_set_video_config_hevc` on first IDR with PS |
| Wire to client | `ServerControlPacket::DecoderConfig` on **client `RequestIdr`** only |
| Mac send gate | `sentVideoConfig` before `vc_alvr_send_video_nal` |

### IDR

**Server → Mac:** queue full, stream corrupted flag, client `RequestIdr`, etc. → `VC_ALVR_EVENT_REQUEST_IDR` → `requestKeyframe()`.

**Client → server:** `RequestIdr` → re-send DecoderConfig if stored + host IDR event.

### Settings negotiation (typical VisionCraft)

| Parameter | Client advertises | Server default | Mac actual |
|-----------|-------------------|----------------|------------|
| View hint | 3776×3648 caps | 2144×1072 absolute | game_render ~2144×… |
| FPS | 90–120 list | 90 preferred | 90 + dynamic framerate |
| Foveated encoding | **true** | **disabled** | N/A (external VT) |
| Codec | HEVC + optional AV1 | HEVC | HEVC VT |
| Bitrate | — | 30 Mbps ALVR path | **80 Mbps** VT fixed |

### VisionCraft vendored deltas (sentinel-checked)

- Raw button forwarding to `ServerCoreEvent::RawButtons`
- PSVR2 profile id 30 in OpenVR config
- `foveated_encoding` disabled in session defaults
- ALVRClient Entry/WorldTracker/EventHandler VisionCraft strings
- Personal-team entitlement checks in prepare script

---

## 11. Tooling, control API, and observability

### Control API (`:19734`, loopback)

| Route | Purpose |
|-------|---------|
| `GET /health` | Liveness |
| `GET /ready` | 503 unless `pipeline_ready` |
| `GET /status` | Full JSON snapshot |
| `POST /alvr/start?synthetic=true` | Synthetic pattern |
| `POST /bridge/start` | Bridge listener |

**`pipeline_ready`:** `bridgeRunning && alvrRunning && alvrClientConnected && framesEncoded > 0`

**Not in JSON:** immersive phase, decode health, `frame_source` label, tracking age, `host_pid`.

### `vc.sh` flows

- **`host`:** `clean` → kill existing host → `open` app → wait `/health` → optional synthetic POST
- **`observe`:** `.run/observability/<timestamp>/` with before/after snapshots, status.ndjson, logs
- **`verify`:** connected + session ready + `frames_encoded` increasing (not `alvr_frames_sent`)

### Race: Xcode vs `vc.sh host`

`vc.sh host` always runs **`clean`** first — kills existing `VisionCraftHost`. Running two hosts risks ambiguous control port ownership.

### Recommended observability additions (audit-only)

- `/status`: `frame_source`, `tracking_age_ms`, `video_age_ms`
- `verify`: warn if `frames_encoded` ↑ but `alvr_frames_sent` flat
- `doctor`: fail if multiple host PIDs

---

## 12. Documentation, CI, and build gates

### Drift

| Doc | Issue |
|-----|--------|
| `prepare-alvr.sh` header | Still describes submodules as source of truth |
| `README.md` / `docs/build.md` | Submodule init instructions vs vendored tree |
| `docs/architecture.md` | “Symmetric perspective per eye” — outdated |
| `bridge/protocol.md` | Compositor-only `view_config` provenance in places |
| `STATUS.md` | Long historical RemoteImmersive sections; milestone table vs README |

### CI (`.github/workflows/visioncraft-ci.yml`)

- Ubuntu, JDK 21
- `./gradlew test`
- Bridge JAR build
- **Does not run:** `prepare-alvr.sh`, Xcode, Swift, submodule checks, `bash -n scripts`

### `prepare-alvr.sh`

**`--check-source` path:**

1. Requires `git`, `python3`
2. **Requires `visionos-app/.git` and `ALVR/.git`** ← fails vendored monorepo
3. Python sentinel checks on 17+ files
4. Optional `--check-source-control`: clean submodule trees + SHA pointers

**Verified failure (2026-06-03):**

```text
error: visionos-app is missing; run: git submodule update --init --recursive visionos-app
```

(directory present, no `.git`)

---

## 13. Security and licensing

### Secrets

High-level grep: no committed credentials in VisionCraft-owned paths; CI uses GitHub secrets in upstream Vivecraft workflows only.

### Licensing

| Component | License / note |
|-----------|----------------|
| VivecraftMod | **LGPLv3** (`minecraft/VivecraftMod/LICENSE.md`) |
| ALVR | Vendored upstream license (see `visionos-app/ALVR/LICENSE`) |
| VisionCraft Mac/Swift/Java additions | No root LICENSE/NOTICE consolidating obligations |

**Distribution risk:** Shipping binaries without LGPL compliance artifacts and clear Mojang/modding constraints is **not documented** in `docs/`.

`README.md` mentions licensing briefly; no `docs/security.md` or distribution checklist.

---

## 14. Testing inventory and gaps

### Automated tests (Gradle)

| Suite | Tests |
|-------|-------|
| `BridgeIntegrationTest` | 9 — connect, frame, view_config, hand, controller, haptic, disconnect, reconnect, late host |
| `AsyncFrameSenderTest` | 6 — ordering, latest-wins, pool, failures |
| `BridgeProtocolTest` | 3 |
| `BridgeMathTest` | 4 |
| `BridgeSettingsTest` | 1 |

### Not tested

- ALVR end-to-end (encode/decode)
- `sentVideoConfig` / IDR / empty VPS
- `submitFrame` with session ready but tracking=0
- `render_orientation` round-trip
- Broken pipe during binary frame body
- `view_config` tangents-only (zero width/height)
- `frame_id` across reconnect
- Mac `JavaBridgeServer` silent dimension drop
- UTF-8 / oversized JSON lines on Java reader
- Swift Mac host / ALVRClient

---

## 15. Failure mode matrix

| Symptom | Likely layer | Mechanism |
|---------|--------------|-----------|
| prepare-alvr / Xcode preBuild fails | Tooling | Submodule `.git` check |
| verify: not connected | ALVR / network | Client not streaming / LAN |
| verify passes, black headset | Mac video | `sentVideoConfig` false or tracking gate |
| MC standby / waiting view_config | Java gate | No `view_config` on bridge |
| MC streams, headset black | Mac | tracking=0 or no NAL send |
| Unfusable / double vision | Java projection | Symmetric fallback or bad tangents |
| Wrong scale | Bridge JSON | Stale view_config dimensions |
| Memory climb in immersive | Client | `sendViewParams` leak |
| App exits | Client | `exit(0)` watchdog |
| Synthetic OK, MC bad | Bridge/Java | F7, frame source, mod connect |
| encoded ↑, sent flat | Mac | IDR/PS extract failure |

---

## 16. Hardware debug playbook

### Order of validation (per `AGENTS.md` / runbook)

1. `scripts/prepare-alvr.sh --check-source` (after P0-1 fix)
2. `scripts/vc.sh host --rebuild --synthetic`
3. ALVRClient: connect, **Enter immersive**
4. `scripts/vc.sh verify` and `scripts/vc.sh observe 30`
5. Prove synthetic stable → `scripts/vc.sh test-sender` → `scripts/vc.sh minecraft` (F7)

### Pass criteria

- `alvr_client_connected` true, `session_state` ready
- **`alvr_frames_sent`** increases (not only `frames_encoded`)
- Java log: view_config acquired / streaming fuseable
- AVP stable 5+ minutes, no memory climb
- `.run/observability/<ts>/` preserved for reports

### Key `/status` fields

| Field | Healthy signal |
|-------|----------------|
| `alvr_client_connected` | true |
| `session_state` | ready |
| `frames_encoded` | increasing |
| `alvr_frames_sent` | increasing with encoded |
| `frames_received` | >0 when Minecraft/sender running |
| `alvr_last_tracking_timestamp_ns` | non-zero when streaming video |

---

## 17. Remediation roadmap

### Tier A — Unblock build + AVP stability

1. Fix **`prepare-alvr.sh`** for monorepo (no `.git` requirement when tree present; update docs).
2. **`sendViewParams`** `defer deallocate`.
3. Refresh **`viewConfigEyeWidth/Height`** on `VIEWS_CONFIG` and/or sync from `targetEyeWidth/Height`.
4. Client: **`foveated_encoding: false`**, remove **`|| true`**, fix decode overrun threshold.

### Tier B — Correctness / debuggability

5. Document or delay **`session ready`** until tracking + initial `view_config`.
6. Java pose staleness; optional **ping** watchdog.
7. Apply **bitrate** to VT or document intentional 80 Mbps.
8. Wire or remove **`render_orientation`**.
9. **`renderStarted = false`** on stream stop.
10. Increment **`framesSent`** / `pipeline_ready` only after successful NAL transmit.
11. Extend **`verify`** and **`/status`** per §11.

### Tier C — DX / legal / CI

12. macOS CI job: `prepare-alvr.sh --check-source`.
13. Root **NOTICE** + distribution / LGPL checklist doc.
14. Sync **architecture**, **protocol**, **STATUS** with ALVR path.
15. Align **ALVRClient.xcconfig** team ID with pbxproj.
16. Integration tests from §14 gaps (prioritized subset).

---

## 18. Appendix: golden files and round map

### Golden files (from `AGENTS.md`)

**Mac host:** `AlvrServerCoordinator.swift`, `ALVRServerCoreShim`, `JavaBridgeServer.swift`, `StereoFrameEncoder.swift`, `VisionCraftAppModel.swift`

**Headset:** `ALVRClient.xcodeproj`, `ALVR/`, `Shaders.metal`, `build_and_repack.sh`

**Wire:** `bridge/protocol.md`

### Anti-patterns (do not reintroduce)

- `HandTrackingProvider` on Mac host
- Foveation on uniform game frames (both sides intentionally disable ALVR FFR for game content)
- Reimplementing ALVR wire protocol in Swift
- Removing inline VPS/SPS/PPS on IDR (decoder recovery)
- `StreamRelay*`, custom companion immersive stack

### Round map (audit sessions)

| Round | Deliverable |
|-------|-------------|
| 1 | Breadth, architecture, initial tiers |
| 2a–d | Host, client, bridge, Vivecraft deep dives |
| 3 | Invariants I1–I6, failure matrix, fix DAG |
| 4a–c | Video/IDR, control API, negotiation |
| 5–6 | Debug tree, unused FFI, CI gaps |
| 7 | Projection, legal, prepare-alvr, signing |
| **Report** | This document |

---

*End of audit report. For implementation work, start with Tier A and re-run the hardware playbook in §16.*
