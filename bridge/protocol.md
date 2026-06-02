# VisionCraft bridge protocol v1

Java implementation (vendored): `minecraft/VivecraftMod/common/src/main/java/visioncraft/bridge/`

Transport: **TCP**, default host `127.0.0.1`, port **19735**.

All JSON messages are **one line** terminated by `\n` (UTF-8).

Binary payloads follow JSON where noted.

## Versioning

Every JSON object includes `"version": 1`. Receivers must reject unknown major versions.

## Java → native

### `frame`

Metadata line, then binary:

```json
{"type":"frame","version":1,"frame_id":12345,"timestamp_ns":123456789,"left":{"width":1512,"height":1680,"format":"rgba8","byte_length":10160640},"right":{"width":1512,"height":1680,"format":"rgba8","byte_length":10160640},"near":0.05,"far":512.0,"render_orientation_xyzw":[0.0,0.0,0.0,1.0]}
```

- `render_orientation_xyzw` *(optional)* — the head orientation (raw ARKit world space, the
  same frame the `pose` message reports) this image was rendered for. The native host forwards
  it through the AVP stream so the on-device compositor can apply rotational async timewarp
  (reproject the late frame to the current head pose). Omit it (or send identity) to disable the
  warp; consumers must treat a missing value as "no reprojection".

Immediately after the newline:

1. `left.byte_length` bytes — RGBA8 row-major, **bottom-left origin** (OpenGL convention)
2. `right.byte_length` bytes — same format

> Origin note: the Java sender produces these bytes with `glGetTexImage`, which returns
> texture row 0 = the **bottom** scanline of the rendered eye (OpenGL's bottom-left origin).
> The native host uploads rows verbatim into a Metal texture (top-left origin) and flips
> vertically at sample time in the fullscreen presentation shader (`fullscreen_vertex` maps
> NDC-top → `v = 1.0`). Do not add a CPU-side flip in Java; it would invert the image.

`buffer_id` in the spec is optional in v1; use `frame_id` for correlation.

### `recenter` (Java → native)

```json
{"type":"recenter","version":1}
```

### `ping`

```json
{"type":"ping","version":1,"timestamp_ns":123}
```

Response:

```json
{"type":"pong","version":1,"timestamp_ns":123}
```

## Native → Java

### `pose`

```json
{"type":"pose","version":1,"timestamp_ns":123456789,"position_m":[0.0,1.65,0.0],"orientation_xyzw":[0.0,0.0,0.0,1.0],"tracking_state":"valid","recenter_counter":4}
```

`tracking_state`: `valid` | `lost` | `unavailable`

### `session`

```json
{"type":"session","version":1,"state":"ready"}
```

`state`: `ready` | `paused` | `lost` | `closed`

### `recenter` (native → Java, ack)

```json
{"type":"recenter","version":1,"recenter_counter":5}
```

### `view_config`

The host's true per-eye view frustum and recommended render dimensions, derived from
Compositor Services (`cp_drawable_compute_projection` / view transforms). The host sends
this once the immersive space is rendering, on change, and as a low-rate heartbeat (~1 Hz)
so a late-connecting Java client still receives it.

```json
{"type":"view_config","version":1,"ipd_m":0.063,"views":[{"index":0,"tangents":[1.21,0.93,1.02,1.02],"width":1888,"height":1824},{"index":1,"tangents":[0.93,1.21,1.02,1.02],"width":1888,"height":1824}]}
```

- `views[].index` — `0` = left eye, `1` = right eye (matches Vivecraft `eyeType`).
- `views[].tangents` — `[left, right, up, down]`, the **positive** tangents of the frustum
  half-angles (same order and sign convention as `cp_view_get_tangents`). The eye frustum
  is asymmetric: the nasal edge tangent is smaller than the temporal edge. Java builds an
  off-axis projection as `frustum(-left·n, right·n, -down·n, up·n, n, f)` using its own
  near/far so the device frustum is matched without clamping Minecraft's render distance.
- `views[].width` / `height` — the device's recommended per-eye viewport in pixels. The host
  blits the *entire* Java eye buffer to the *entire* device viewport, so geometry is correct
  for any Java buffer resolution; these are advisory (used only to match pixel aspect).
- `ipd_m` — measured inter-pupillary distance in meters, from the distance between the two
  view transforms' origins. Java uses this for eye-to-head separation when present (> 0).

Until the first `view_config` arrives, Java falls back to a symmetric FOV and its configured
IPD. Receiving a `view_config` is idempotent — the client stores the latest values.

On Apple Vision Pro, the Vivecraft Apple provider **withholds stereo frames** until the first
`view_config` is received (symmetric fallback frames do not fuse on-device). The companion
uplinks on-device `view_config`; when a companion is connected, the Mac host suppresses its own
remote-display `view_config` so only one source is active.

### `hand`

Per-hand tracking (pinch + advisory wrist pose). A host publishes this on the same
channel/cadence as `pose` (heartbeat at the pose rate) whenever hand tracking is supported
and running. Hands that are not currently tracked are reported with `tracked:false`.

> **Platform note.** ARKit `HandTrackingProvider` is a local, on-device visionOS feature and is
> `unavailable` on macOS. The current **macOS Spatial Rendering / RemoteImmersiveSpace host vends
> head pose only** (via `WorldTrackingProvider`) and therefore does **not** emit `hand`. This
> message is the stable wire contract for hand input: it is emitted today by the mock host
> (`MockVisionCraftHost`, for tests) and is the integration point for a future visionOS-native
> host that runs `HandTrackingProvider` on-device and streams pinch over this bridge. The Java
> client already consumes it (right pinch → primary, left pinch → secondary); when no host emits
> `hand`, both hands stay untracked and contribute no input.

```json
{"type":"hand","version":1,"timestamp_ns":123456789,"hands":[{"chirality":"left","tracked":true,"position_m":[-0.2,1.3,-0.3],"orientation_xyzw":[0.0,0.0,0.0,1.0],"pinch":0.0,"pinch_middle":0.0},{"chirality":"right","tracked":true,"position_m":[0.2,1.3,-0.3],"orientation_xyzw":[0.0,0.0,0.0,1.0],"pinch":0.92,"pinch_middle":0.0}]}
```

- `hands[].chirality` — `left` | `right`. Either or both may be present.
- `hands[].tracked` — `false` when the hand left the field of view; consumers must treat an
  untracked hand as "no input" (e.g. release any held pinch action).
- `hands[].pinch` — index-tip↔thumb-tip pinch strength in `0..1` (`1` = fully pinched).
- `hands[].pinch_middle` *(optional)* — middle-tip↔thumb-tip pinch strength in `0..1`. The seated
  client maps `right` → jump (space) and `left` → sneak (left shift). Defaults to `0` when absent.
  Computed host-side from the joint distance; the client applies its own hysteresis to turn
  this into a discrete press so it never chatters at the threshold.
- `hands[].position_m` — wrist position in the same tracking space as `pose.position_m`
  (meters). **Advisory** today: the seated Apple profile aims with the head, so the client
  consumes only `pinch`. Reserved for a future hand-aimed (non-seated) profile.
- `hands[].orientation_xyzw` — raw ARKit wrist orientation (world space), JOML-compatible.
  **Advisory**, same rationale as `position_m`.

The seated client maps `right` pinch → primary action (attack/mine, GUI click) and `left`
pinch → secondary action (use/place); middle-finger pinch maps `right` → jump and `left` →
sneak. A missing or untracked hand contributes no input.

## Clocks and timestamps

There is no shared monotonic clock across the two processes, so each timestamp field
has an explicit clock base:

- **`pose.timestamp_ns`** — host wall clock, **Unix-epoch nanoseconds**. A Java consumer
  measuring pose staleness must compare against its own epoch clock
  (`System.currentTimeMillis() * 1_000_000`), never `System.nanoTime()`.
- **`ping`/`pong.timestamp_ns`** — opaque echo token chosen by the *originator*. The
  responder copies it back verbatim; only the originator interprets it (for RTT).
- **`frame.timestamp_ns`** — capture time on the Java sender's clock. The native side
  treats it as an opaque correlation id and does not compare it to its own clock.

## Connection lifecycle

1. Java connects (client) → host listens (server).
2. Host sends `session` `ready` when immersive space is active.
3. Java may send frames only while session is `ready`.
4. On disconnect, host sends `closed` if possible.

## Error handling

- Malformed JSON: close connection.
- `byte_length` mismatch: drop frame, log `frame_id`.
- Unknown `type`: ignore if `version` matches and type is optional; else close.

## Future extensions (v2+)

- `format: "iosurface"` with handle FD passing
- Compressed eyes (not planned for MVP)
