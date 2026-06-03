# Latency budget

## Target

| Metric | MVP minimum | Target |
|--------|-------------|--------|
| Stereo frame rate | 45 Hz stable | 72+ Hz if compositor allows |
| Motion-to-photon | &lt; 40 ms seated | &lt; 25 ms after M6 |
| Pose age at render | &lt; 16 ms | &lt; 8 ms |

## Pipeline stages

Log every stage with monotonic `timestamp_ns` (e.g. `System.nanoTime` / `mach_absolute_time`).
These are for **intra-process** stage deltas only. Any timestamp compared **across** the
Java↔native boundary (e.g. `pose.timestamp_ns`) must use the Unix-epoch clock — see
`bridge/protocol.md` § Clocks and timestamps.

```text
t_pose_received     — Java got pose from bridge
t_render_begin      — Vivecraft eye pass start
t_render_end        — Both eyes finished
t_readback_done     — RGBA copied from GL
t_frame_sent        — Socket write complete
t_native_received   — Host got frame
t_metal_upload_done — Textures updated
t_present           — Compositor submit
```

## Expected MVP overhead (CPU transport)

| Stage | Order of magnitude |
|-------|-------------------|
| Minecraft render (both eyes) | 8–20 ms @ 1080p scale |
| glGetTexImage × 2 | 4–12 ms |
| Socket copy | 1–4 ms |
| Metal upload + present | 2–6 ms |

CPU readback dominates until IOSurface path (M6).

## Mitigations (by milestone)

- **M1:** Log frame IDs; detect stalls &gt; 33 ms.
- **M3:** Reduce eye buffer resolution (e.g. 50% scale).
- **M5:** Cap Minecraft simulation if present queue &gt; 2 frames.
- **M6:** IOSurface / no readback; pinned memory PBO.

## Diagnostics

- The test-pattern sender (`:bridge-test`) prints rolling avg/max per stage.
- Host: VideoToolbox encode timing + signposts around `AlvrServerCoordinator` NAL submission.
- Java: `AppleFrameSubmitter` logs dropped frames when `frame_id` skips.

## Comfort interaction

High latency worsens sim sickness. MVP defaults: seated, snap turn, no head bob, optional vignette.
