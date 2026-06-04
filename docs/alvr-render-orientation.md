# ALVR render orientation / timewarp spike

**Outcome:** Do **not** wire `render_orientation_xyzw` through the ALVR HEVC path in v1.

## What we checked

| Layer | Finding |
|-------|---------|
| Bridge v1 `frame` JSON | Optional `render_orientation_xyzw` for legacy RemoteImmersive / compositor timewarp |
| Mac ALVR host | Encodes side-by-side Annex-B HEVC via VideoToolbox → `alvr_server_core`; no per-frame orientation side channel |
| ALVR `VideoPacket` / client | Bitstream + timing; visionOS client applies ALVR view matrices and decoder presentation timing |
| ALVRClient `EventHandler` | No consumer for bridge `render_orientation`; reprojection is ALVR’s pose-driven view, not Java RGBA metadata |

## Decision

1. Keep sending `render_orientation_xyzw` from Java only when the renderer already has head
   orientation (harmless on ALVR path).
2. Document in [bridge/protocol.md](../bridge/protocol.md) that ALVR HEVC does not use the field.
3. Revisit only if ALVR exposes a supported per-frame orientation or reprojection hook on visionOS.

## Follow-ups (not in v1)

- If ALVR adds video metadata for late-frame warp, mirror it in `AlvrServerCoordinator` NAL path.
- If returning to a custom compositor client, restore host forwarding from Java → headset shader.
