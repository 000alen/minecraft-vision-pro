// Coordinate conventions (verify on first Vision Pro device run — M0)
//
// Minecraft: +Y up, yaw about Y, 1 block = 1 meter (MVP)
// Bridge pose: position_m [x,y,z], orientation_xyzw (JOML-compatible)
// Apple compositor: confirm right-handed basis from LayerRenderer device anchor
//
// Debug checklist:
// - Turn head right → world moves left (negative yaw in MC if camera correct)
// - Look up → pitch increases
// - Recenter aligns Vision Pro forward with Minecraft +Z (verify!)

import Foundation

enum VisionCraftCoordinates {
    static let seatedEyeHeightM: Float = 1.65
}
