# Legacy VisionCraft Companion Stream Protocol

> Legacy only. The custom Mac relay / native VisionCraft companion transport has been replaced by the VisionCraft headset client (ALVRClient) plus ALVR `server_core`.
>
> This document is retained only as historical design context. Current Bridge v1 Java loopback messages are documented in `bridge/protocol.md`.

This is the **Mac ↔ Apple Vision Pro** transport for the native-companion architecture.
It is distinct from `bridge/protocol.md`, which is the **loopback** IPC between Minecraft
(Java) and a Mac-side process.

```
 Minecraft (Java)            Mac relay (Swift)                 visionOS companion (Swift)
 ───────────────             ─────────────────                 ──────────────────────────
 raw RGBA eye frames ──bridge/protocol.md (loopback TCP)──▶ JavaBridgeServer
                                     │ HEVC-encode (VideoToolbox)
                                     │ stream-protocol.md (LAN TCP)
                                     ├──────────── VIDEO_FRAME ───────────────▶ decode → composite
   pose / hand / recenter  ◀──bridge/protocol.md──┤◀─────── POSE / HAND / RECENTER ───────  ARKit on-device
```

The relay reuses the existing bridge server unchanged: Minecraft still sends raw frames and
consumes `pose`/`hand`/`view_config` exactly as today. The relay just swaps the *frame sink*
(compositor → HEVC encoder) and the *pose/hand source* (Mac WorldTracking → the AVP uplink).

## Transport

- **TCP**, LAN. Default port **19736** (one above the loopback bridge's 19735).
- The **Mac is the server** (it owns the video). The **AVP app is the client**.
- Discovery: the Mac advertises Bonjour service **`_visioncraft-stream._tcp`**; the AVP browses
  and connects. A manual host/IP entry is the fallback when Bonjour is unavailable.
- Single connection, **both directions multiplexed**. Video dominates the downlink; pose/hand
  are small and frequent on the uplink.

> Security: this link leaves the box (unlike the loopback bridge), so it is gated by a
> per-session **pairing token** in `HELLO` (see below). Treat any peer that fails the token
> check as hostile and drop it. A future v2 may wrap the socket in TLS via `NWProtocolTLS`.

## Framing

Every message is a length-prefixed envelope. All integers are **big-endian** (network order).

```
┌────────────┬────────┬──────────────────────────┐
│ length u32 │ type u8│ payload (length-1 bytes)  │
└────────────┴────────┴──────────────────────────┘
```

- `length` counts `type` + `payload` (i.e. total envelope bytes minus the 4 length bytes).
- `type` selects the payload shape below.
- Max `length` is **64 MiB**; a larger value is a protocol error → drop the connection.

### Message types

| type   | name           | dir       | payload |
|--------|----------------|-----------|---------|
| `0x01` | `HELLO`        | both      | JSON (UTF-8) |
| `0x02` | `PING`         | both      | JSON line (`bridge/protocol.md` `ping`) |
| `0x03` | `PONG`         | both      | JSON line (`bridge/protocol.md` `pong`) |
| `0x10` | `VIDEO_CONFIG` | Mac → AVP | JSON (UTF-8) |
| `0x11` | `VIDEO_FRAME`  | Mac → AVP | `u32 metaLen` + meta JSON + HEVC access unit |
| `0x20` | `UPLINK`       | AVP → Mac | one newline-terminated JSON line, verbatim from `bridge/protocol.md` |
| `0x21` | `REQUEST_IDR`  | AVP → Mac | empty (host emits a keyframe on the next encode) |
| `0x22` | `DOWNLINK`     | Mac → AVP | one newline-terminated JSON line (e.g. Java-initiated `recenter`) |
| `0x30` | `BYE`          | both      | JSON (UTF-8), optional `reason` |

The single most important reuse decision: **`UPLINK` payloads are the exact newline-JSON lines
defined in `bridge/protocol.md`** (`pose`, `hand`, `recenter`). The relay forwards them into the
loopback bridge broadcast without reformatting, so Minecraft's existing consumers are untouched.

## Handshake

1. AVP connects, sends `HELLO`:
   ```json
   {"type":"hello","version":1,"role":"viewer","token":"<pairing-token>","device":"Apple Vision Pro","capabilities":{"hevc_decode":true,"mvhevc_decode":true}}
   ```
2. Mac validates `token`. On mismatch → `BYE` + close. On success, Mac replies `HELLO`:
   ```json
   {"type":"hello","version":1,"role":"host","capabilities":{"hevc_encode":true,"mvhevc_encode":false}}
   ```
3. Mac sends `VIDEO_CONFIG` (below). The AVP builds its decoder from it.
4. Mac begins sending `VIDEO_FRAME`. The AVP begins sending `UPLINK` (pose at 90 Hz, hand at the
   pose rate, `recenter` on demand).

Either side rejects an unknown major `version`.

## `VIDEO_CONFIG`

Describes the encoded video the AVP will receive. Sent at start and whenever the geometry
changes (e.g. Minecraft window resize → eye-buffer resize).

```json
{"type":"video_config","version":1,"codec":"hevc","packing":"side_by_side","eye_width":1888,"eye_height":1824,"frame_width":3776,"frame_height":1824,"fps":90,"color":"bt709","full_range":true}
```

- `codec` — `hevc` for v1. `mvhevc` reserved for the multiview upgrade (one bitstream, two
  layers, native to visionOS spatial video).
- `packing` — how the two eyes are laid out in the single encoded frame:
  - `side_by_side` — `[ left | right ]`, each `eye_width × eye_height`; `frame_width = 2·eye_width`.
  - `top_bottom` — `[ left / right ]`; `frame_height = 2·eye_height`. (Reserved.)
  - For `mvhevc`, `packing` is `multiview` and the two eyes are separate layers.
- `eye_width`/`eye_height` — per-eye source resolution (typically the device-recommended
  viewport from the loopback `view_config`).
- `fps` — encoder target; the compositor still reprojects to the live head pose regardless.
- `color`/`full_range` — colorimetry for the decoder's `CMFormatDescription`.

## `VIDEO_FRAME`

Envelope type is `0x11`; the payload is:

```
[u32 metaLen BE][meta JSON (metaLen bytes)][HEVC access unit bytes...]
```

Meta JSON:

```json
{"frame_id":12345,"pts_ns":123456789,"keyframe":true,"packing":"side_by_side","byte_length":40231}
```

- The HEVC bytes are an **Annex-B** elementary stream (4-byte `00 00 00 01` start codes).
- **Keyframes (IDR) carry their parameter sets inline** (`VPS`,`SPS`,`PPS` NAL units precede the
  IDR slice). The AVP rebuilds its `CMVideoFormatDescription` from the param sets on each
  keyframe, so a viewer that joins mid-stream recovers at the next keyframe.
- The encoder runs **low-latency**: real-time mode, no frame reordering, no B-frames. The relay
  requests a keyframe on connect and every ~2 s as a recovery anchor.
- `byte_length` is the HEVC access-unit length (redundant with the envelope length minus the
  meta; provided for sanity checks/logging).

### Eye origin / orientation

The eyes are encoded **top-left origin** (Metal/VideoToolbox convention). Minecraft's frames are
bottom-left origin (OpenGL); the relay flips at encode time (or the AVP flips `v` in the sample
shader, mirroring the existing host's `external_frame_fragment`). Exactly one flip total — see
`bridge/protocol.md` origin note. For `side_by_side`, the left eye occupies `u ∈ [0, 0.5)` and the
right eye `u ∈ [0.5, 1.0]`.

## Uplink (`UPLINK`)

The payload is one `bridge/protocol.md` line, verbatim:

- **`pose`** — on-device `WorldTrackingProvider` head pose, published at the device frame rate.
- **`hand`** — on-device `HandTrackingProvider` per-hand pinch + advisory wrist pose, at the pose
  rate. **This is the message that the macOS host cannot produce** — the whole reason for the
  companion. Right pinch → primary, left pinch → secondary, with client-side hysteresis.
- **`recenter`** — when the user performs the recenter gesture on-device.

Because these are the same lines the loopback bridge already defines and Minecraft already
parses, the relay is a pure pass-through for the uplink.

## Reprojection & latency

The companion submits each decoded frame to a `CompositorLayer` drawable. When the frame meta
includes `render_orientation_xyzw`, the composite shader applies a rotational correction from the
render-time head orientation to the live pose (and the drawable is **not** also tagged with the
live `DeviceAnchor`, to avoid stacking that warp on platform reprojection). Frames without
`render_orientation_xyzw` use the live `DeviceAnchor` and platform reprojection only.
Translation (walking) still carries encode → network → decode latency, which is acceptable for
Minecraft's slow locomotion.

## Connection lifecycle

1. Mac advertises Bonjour, listens on 19736.
2. AVP connects → `HELLO` exchange → token check.
3. Mac sends `VIDEO_CONFIG`, then `VIDEO_FRAME` stream.
4. AVP sends `UPLINK` (`pose`/`hand`/`recenter`).
5. On video stall, the AVP holds the last frame (compositor keeps reprojecting it) and may
   send `REQUEST_IDR` (`0x21`); the host also emits periodic keyframes (~2 s).
6. Disconnect: send `BYE` if possible; both sides reset and the AVP returns to a "waiting for
   host" state.

## Error handling

- Envelope `length` > 64 MiB, invalid `length` (< 1), or unknown `type` byte: drop the connection.
- `VIDEO_FRAME` with `metaLen` exceeding the payload: drop the connection (desync).
- Token mismatch in `HELLO`: `BYE` + close.
- Decode failure: drop the frame, wait for the next keyframe; do not tear down the connection.

## v2+ roadmap

- **MV-HEVC** (`codec":"mvhevc"`) — native stereo bitstream; better quality at lower bitrate and
  the canonical visionOS spatial-video format.
- `KEYFRAME_REQUEST` (AVP → Mac) for fast recovery after loss.
- Dynamic bitrate / resolution scaling driven by uplinked RTT.
- TLS via `NWProtocolTLS`, and a QUIC/`NWProtocolWebSocket`-style datagram path for the video to
  shed head-of-line blocking under loss.
- Optional fixed-foveation in the encoder once the companion renders foveation-aware content.
