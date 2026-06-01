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
{"type":"frame","version":1,"frame_id":12345,"timestamp_ns":123456789,"left":{"width":1512,"height":1680,"format":"rgba8","byte_length":10160640},"right":{"width":1512,"height":1680,"format":"rgba8","byte_length":10160640},"near":0.05,"far":512.0}
```

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
