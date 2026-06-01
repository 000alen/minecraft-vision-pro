import Metal

/// How the two eyes are packed into a single decoded video texture.
enum StereoPacking {
    case sideBySide  // [ left | right ], left in u∈[0,0.5), right in u∈[0.5,1]
    case topBottom   // [ left / right ]
}

/// One decoded video frame ready to composite.
struct DecodedFrame {
    let texture: MTLTexture
    let packing: StereoPacking
    let frameID: UInt64
}

/// A source of decoded stereo frames for the renderer. The render thread reads `latestFrame`;
/// the decoder thread publishes new frames. Implementations must make this access thread-safe.
protocol VideoSource: AnyObject {
    var latestFrame: DecodedFrame? { get }
}
