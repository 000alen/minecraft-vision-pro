# shared/

Small shared Swift utilities compiled into the macOS host target.

| File | Shared contract |
| --- | --- |
| `Sources/StereoMath.swift` | Frustum-tangent extraction, `view_config` JSON serialization, and stable JSON float formatting for the Java bridge. |

The custom VisionCraft stream protocol and shared Metal compositor shader were retired when the headset path moved to ALVR.

Regenerate the host Xcode project after adding/removing files here: `scripts/gen-projects.sh`.
