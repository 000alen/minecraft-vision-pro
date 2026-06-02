import Foundation
import simd

// Stereo / projection math used by the macOS host to serialize `view_config` for the Java bridge.
// Pure Foundation + simd so it remains independent of ALVR and Apple compositor APIs.
enum StereoMath {
    /// POSIX locale so JSON always uses `.` decimal separators (never `1,5` on European locales).
    private static let jsonNumberLocale = Locale(identifier: "en_US_POSIX")

    /// Compact, locale-independent float formatting for protocol JSON (≈6 significant digits).
    static func fmt(_ value: Float) -> String {
        String(format: "%.6g", locale: jsonNumberLocale, value)
    }

    /// Extract the positive frustum tangents `[left, right, up, down]` from a projection matrix.
    /// `cp_view_get_tangents` is unavailable on macOS, so we recover them from the projection itself.
    ///
    /// Convention-agnostic: for any perspective projection, all view-space points mapping to a fixed
    /// NDC `(x, y)` lie on one ray through the eye, so unprojecting a single NDC point per edge yields
    /// that edge's direction. Magnitudes make the result robust to the matrix's handedness /
    /// reverse-Z depth encoding.
    static func tangents(fromProjection projection: simd_float4x4) -> SIMD4<Float> {
        let inverse = projection.inverse
        func edgeDirection(_ ndcX: Float, _ ndcY: Float) -> SIMD3<Float> {
            // NDC depth is arbitrary for a perspective frustum; 0.5 is mid-range for both [0,1] and
            // reverse-Z conventions.
            let view = inverse * SIMD4<Float>(ndcX, ndcY, 0.5, 1)
            let w = abs(view.w) > 1e-7 ? view.w : 1
            return SIMD3<Float>(view.x, view.y, view.z) / w
        }
        func tangent(_ lateral: Float, _ forward: Float) -> Float {
            let denom = max(abs(forward), 1e-6)
            // Clamp to a sane FOV so a degenerate matrix can never produce NaN/huge values.
            return min(max(abs(lateral) / denom, 0.05), 10.0)
        }
        // Right/up convention: NDC x = -1 → left edge, +1 → right; y = +1 → top, -1 → bottom.
        let left = edgeDirection(-1, 0)
        let right = edgeDirection(1, 0)
        let up = edgeDirection(0, 1)
        let down = edgeDirection(0, -1)
        return SIMD4<Float>(
            tangent(left.x, left.z),
            tangent(right.x, right.z),
            tangent(up.y, up.z),
            tangent(down.y, down.z)
        )
    }

    /// Model-view-projection for one eye, given the eye's drawable transform (eye ← origin),
    /// the head transform (origin ← world), and the model (world placement).
    static func mvp(
        projection: simd_float4x4,
        eyeTransform: simd_float4x4,
        head: simd_float4x4,
        model: simd_float4x4
    ) -> simd_float4x4 {
        let eyeWorld = head * eyeTransform
        return projection * eyeWorld.inverse * model
    }

    /// A pure translation matrix.
    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1)
        )
    }

    // MARK: - view_config

    /// One eye's contribution to a `view_config`: its frustum tangents and recommended render size.
    struct EyeView {
        let index: Int
        let tangents: SIMD4<Float>   // [left, right, up, down]
        let width: Int
        let height: Int
    }

    /// Serialize a `bridge/protocol.md` `view_config` line (newline-terminated). Minecraft renders
    /// the asymmetric per-eye frustum it describes, so this keeps the geometry contract in one place.
    static func viewConfigJSON(eyes: [EyeView], ipdMeters: Float) -> String {
        let eyeFragments = eyes.map { eye in
            "{\"index\":\(eye.index),\"tangents\":[\(fmt(eye.tangents.x)),\(fmt(eye.tangents.y)),\(fmt(eye.tangents.z)),\(fmt(eye.tangents.w))],\"width\":\(eye.width),\"height\":\(eye.height)}"
        }
        return "{\"type\":\"view_config\",\"version\":1,\"ipd_m\":\(fmt(ipdMeters)),\"views\":[\(eyeFragments.joined(separator: ","))]}\n"
    }
}
