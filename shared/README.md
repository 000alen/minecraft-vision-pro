# shared/

Single source of truth for code that the macOS host (`VisionCraftHost`) and the visionOS
companion (`VisionCraftCompanion`) **must** keep identical. They are two separate apps with no
common binary framework, so these files are compiled into *both* targets via XcodeGen
(`sources: ../shared/...` in each `project.yml`). One copy on disk ⇒ the two ends can never drift.

| File | Shared contract |
| --- | --- |
| `Sources/StreamProtocol.swift` | `bridge/stream-protocol.md` envelope framing, the `VIDEO_FRAME` payload codec (producer + consumer), and the discovery constants (TCP port + Bonjour service type). Sender and receiver must agree byte-for-byte. |
| `Sources/StereoMath.swift` | Frustum-tangent extraction, the `view_config` JSON serializer, the debug MVP, and `%.6g` JSON float formatting. The host and companion must compute the same stereo geometry or frames won't fuse. |
| `Shaders/Composite.metal` | The debug stereo pattern + fullscreen-blit vertex shared by both, plus each presentation path's fragment (`companion_external_fragment` for the network/YUV path, `external_frame_fragment` for the Mac-local RGBA path). Unused entry points are dead-stripped per target. |

## Why a shared folder and not a Swift package

Both apps ship the code in their own signed binary regardless of module boundary, so a separate
framework would add build/signing overhead and `public` access churn for no runtime benefit. A
shared source group gives the same single-source-of-truth guarantee with zero ceremony. Revisit if
the shared surface grows enough to warrant its own module + tests.

Regenerate the Xcode projects after adding/removing files here: `scripts/gen-projects.sh`.
