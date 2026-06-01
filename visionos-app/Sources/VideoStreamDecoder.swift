import Foundation
import Metal

/// Decodes the HEVC video stream into Metal textures for the renderer.
///
/// Phase 1 (current): parses `VIDEO_CONFIG` and accepts `VIDEO_FRAME` envelopes but does not yet
/// decode — `latestFrame` stays nil, so `CompanionRenderer` shows the debug scene while the
/// pose/hand uplink runs live. This makes the on-device tracking path testable on the headset
/// alone, before the video spine exists.
///
/// Phase 2 (avp-decoder): build a `CMVideoFormatDescription` from the keyframe parameter sets,
/// feed access units to a low-latency `VTDecompressionSession`, and wrap the output
/// `CVPixelBuffer` as an `MTLTexture` via a `CVMetalTextureCache`. Publishing must remain
/// thread-safe against the render thread's `latestFrame` read (latest-frame-wins under a lock).
final class VideoStreamDecoder: VideoSource {
    struct Config {
        var codec: String
        var packing: StereoPacking
        var eyeWidth: Int
        var eyeHeight: Int
        var frameWidth: Int
        var frameHeight: Int
        var fps: Int
    }

    private let lock = NSLock()
    private var config: Config?
    private var published: DecodedFrame?

    var latestFrame: DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    func configure(with json: [String: Any]) {
        let packing: StereoPacking = (json["packing"] as? String) == "top_bottom" ? .topBottom : .sideBySide
        let config = Config(
            codec: (json["codec"] as? String) ?? "hevc",
            packing: packing,
            eyeWidth: (json["eye_width"] as? Int) ?? 0,
            eyeHeight: (json["eye_height"] as? Int) ?? 0,
            frameWidth: (json["frame_width"] as? Int) ?? 0,
            frameHeight: (json["frame_height"] as? Int) ?? 0,
            fps: (json["fps"] as? Int) ?? 90
        )
        lock.lock()
        self.config = config
        lock.unlock()
    }

    func decode(meta: [String: Any], accessUnit: Data) {
        // Phase 2: VTDecompressionSession decode → CVPixelBuffer → MTLTexture, then publish:
        //   lock.lock(); published = DecodedFrame(texture:packing:frameID:); lock.unlock()
        _ = meta
        _ = accessUnit
    }
}
