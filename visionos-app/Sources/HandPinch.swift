import ARKit
import simd

/// Computes a normalized pinch strength (0…1) from a hand anchor's index-tip ↔ thumb-tip
/// distance. The client side (Vivecraft `AppleVisionProvider`) applies hysteresis to turn this
/// continuous value into a discrete press, so this only needs to be smooth and monotonic.
enum HandPinch {
    /// Index-tip↔thumb-tip distances (meters). Below `closed` reads as fully pinched (1.0),
    /// above `open` as released (0.0), linearly interpolated between. Tuned for adult hands;
    /// the consumer's hysteresis thresholds (engage 0.7 / release 0.4) sit comfortably inside.
    private static let closedDistance: Float = 0.015
    private static let openDistance: Float = 0.045

    /// Returns pinch strength in 0…1, or `nil` if the relevant joints are not tracked.
    static func strength(for anchor: HandAnchor) -> Float? {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let indexTip = skeleton.joint(.indexFingerTip)
        let thumbTip = skeleton.joint(.thumbTip)
        guard indexTip.isTracked, thumbTip.isTracked else { return nil }

        // Joint transforms are relative to the anchor; the distance between two joints is
        // invariant under the shared anchor transform, so we can compare them directly.
        let a = indexTip.anchorFromJointTransform.columns.3
        let b = thumbTip.anchorFromJointTransform.columns.3
        let distance = simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))

        let t = (openDistance - distance) / (openDistance - closedDistance)
        return simd_clamp(t, 0, 1)
    }
}
