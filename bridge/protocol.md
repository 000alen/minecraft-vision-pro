# VisionCraft bridge protocol v1

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

1. `left.byte_length` bytes — RGBA8 row-major, top-left origin
2. `right.byte_length` bytes — same format

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
