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

    /// Index-tip↔thumb-tip pinch strength in 0…1, or `nil` if the joints are not tracked. Maps to
    /// the primary/secondary "click" actions on the consumer side.
    static func strength(for anchor: HandAnchor) -> Float? {
        pinch(anchor, .indexFingerTip)
    }

    /// Middle-tip↔thumb-tip pinch strength in 0…1, or `nil` if the joints are not tracked. The
    /// consumer maps this to a movement action (jump / sneak), distinct from the index pinch.
    static func middleStrength(for anchor: HandAnchor) -> Float? {
        pinch(anchor, .middleFingerTip)
    }

    /// Normalized strength of a fingertip→thumb-tip pinch.
    private static func pinch(_ anchor: HandAnchor, _ fingerTip: HandSkeleton.JointName) -> Float? {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let tip = skeleton.joint(fingerTip)
        let thumbTip = skeleton.joint(.thumbTip)
        guard tip.isTracked, thumbTip.isTracked else { return nil }

        // Joint transforms are relative to the anchor; the distance between two joints is
        // invariant under the shared anchor transform, so we can compare them directly.
        let a = tip.anchorFromJointTransform.columns.3
        let b = thumbTip.anchorFromJointTransform.columns.3
        let distance = simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))

        let t = (openDistance - distance) / (openDistance - closedDistance)
        return simd_clamp(t, 0, 1)
    }
}
