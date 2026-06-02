# Frame transport

> Retired design notes: this file describes the pre-ALVR Metal compositor transport. The current
> runtime still accepts raw RGBA frames over `bridge/protocol.md`, then encodes side-by-side HEVC and
> submits it through ALVR `server_core`.

## MVP path (implemented)

```text
OpenGL eye texture
  → glGetTexImage (RGBA8, GL_UNSIGNED_BYTE)
  → byte[] per eye
  → length-prefixed TCP messages
  → VisionCraftHost FrameReceiver
  → MTLTexture upload
  → CompositorLayer present
```

Slow but proves gameplay before GPU interop.

## Message framing

1. One JSON line (UTF-8, newline-terminated) for metadata (`type: frame`).
2. Raw RGBA8 for left eye (`width × height × 4` bytes).
3. Raw RGBA8 for right eye.

See [bridge/protocol.md](../bridge/protocol.md).

## Phase 2 — PBO async readback

```text
glGetTexImage into PBO (non-blocking)
  → map when ready
  → shared memory ring buffer
```

Reduces GPU stall; still one copy.

## Phase 3 — IOSurface (target)

```text
GL texture share group / IOSurface
  → CVMetalTextureCache
  → Compositor layer input
```

Requirements:

- macOS IOSurface + LWJGL/Cocoa interop spike (`bridge/native/MetalInterop.mm`)
- No CPU readback on critical path
- sRGB / color space match (RGBA8 sRGB aware)

## Buffer sizing

Start below native panel resolution:

| Setting | Default |
|---------|---------|
| Eye width | 1512 (75% of 2016) |
| Eye height | 1680 (75% of 2240) |
| Format | RGBA8 UNORM |

Scale via Vivecraft render scale + `AppleVisionConfig`.

## Failure modes

| Symptom | Likely cause |
|---------|----------------|
| Left/right swapped | Eye index bug in submit |
| Mirrored yaw | Coordinate conversion sign |
| Pink textures | Format mismatch (BGRA vs RGBA) |
| Stutter | GC pause or sync readback |

Add axis debug grid in M0 host to validate conventions.
