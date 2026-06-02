import Metal
import simd

/// How the two eyes are packed into a single decoded video texture.
enum StereoPacking {
    case sideBySide  // [ left | right ], left in u∈[0,0.5), right in u∈[0.5,1]
    case topBottom   // [ left / right ]
}

/// One decoded video frame ready to composite.
///
/// The decoder hands the renderer the native biplanar YCbCr planes (no CPU/GPU BGRA conversion)
/// — `luma` is the full-resolution Y plane (`.r8Unorm`) and `chroma` the half-resolution
/// interleaved CbCr plane (`.rg8Unorm`). The composite shader converts to RGB on sample.
struct DecodedFrame {
    let luma: MTLTexture
    let chroma: MTLTexture
    let packing: StereoPacking
    let frameID: UInt64
    /// Head orientation (ARKit world space, the same frame `WorldTrackingProvider` reports) the
    /// frame was rendered for, or `nil` when unknown. Drives the renderer's rotational
    /// reprojection; `nil` makes the warp a no-op.
    let renderOrientation: simd_quatf?
}

/// A source of decoded stereo frames for the renderer. The render thread reads `latestFrame`;
/// the decoder thread publishes new frames. Implementations must make this access thread-safe.
protocol VideoSource: AnyObject {
    var latestFrame: DecodedFrame? { get }
}
