import Foundation
import Metal
import VideoToolbox
import CoreVideo
import CoreMedia

/// Decodes the HEVC video stream (`bridge/stream-protocol.md` `VIDEO_FRAME`) into Metal textures
/// for `CompanionRenderer`.
///
/// Pipeline: Annex-B access unit → split NALs → (on keyframe) rebuild `CMVideoFormatDescription`
/// from the inline VPS/SPS/PPS → wrap the VCL NALs as a length-prefixed `CMSampleBuffer` →
/// `VTDecompressionSession` → `CVPixelBuffer` (BGRA) → `MTLTexture` via `CVMetalTextureCache`.
///
/// Thread-safety: `decode(...)` is called on the stream client's queue; VideoToolbox invokes the
/// output handler on its own queue. `latestFrame` is read on the render thread. Publication is
/// latest-frame-wins under `lock`, and the backing `CVMetalTexture`/`CVPixelBuffer` of the current
/// and previous frame are retained so the GPU can finish sampling a frame after the next arrives.
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

    /// Holds everything that must outlive a published frame: the IOSurface-backed pixel buffer, the
    /// CoreVideo↔Metal bridge object, and the resulting texture.
    private final class FrameHold {
        let pixelBuffer: CVPixelBuffer
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
        init(pixelBuffer: CVPixelBuffer, cvTexture: CVMetalTexture, texture: MTLTexture) {
            self.pixelBuffer = pixelBuffer
            self.cvTexture = cvTexture
            self.texture = texture
        }
    }

    private let lock = NSLock()
    private var config: Config?
    private var published: DecodedFrame?
    private var currentHold: FrameHold?
    private var previousHold: FrameHold?

    private let device: MTLDevice?
    private var textureCache: CVMetalTextureCache?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: [Data] = []
    private var packing: StereoPacking = .sideBySide
    private var awaitingKeyframe = true

    init() {
        // Single-GPU device (Apple Silicon): the same physical device the CompositorLayer renders
        // with, so textures created here are valid in the renderer's command buffers.
        device = MTLCreateSystemDefaultDevice()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
    }

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
        self.packing = packing
        lock.unlock()
    }

    // MARK: - Decode

    func decode(meta: [String: Any], accessUnit: Data) {
        let frameID = (meta["frame_id"] as? NSNumber)?.uint64Value ?? 0
        let keyframe = (meta["keyframe"] as? Bool) ?? false

        let nalUnits = Self.splitAnnexB(accessUnit)
        guard !nalUnits.isEmpty else { return }

        var vps: [Data] = []
        var sps: [Data] = []
        var pps: [Data] = []
        var vclData = Data()

        for nal in nalUnits {
            guard let first = nal.first else { continue }
            let nalType = (first >> 1) & 0x3F
            switch nalType {
            case 32: vps.append(nal) // VPS
            case 33: sps.append(nal) // SPS
            case 34: pps.append(nal) // PPS
            case 35, 36, 37, 38: break // AUD / EOS / EOB / FD — not needed for decode
            default:
                // VCL slice (and SEI): emit length-prefixed (HVCC 4-byte big-endian length).
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { vclData.append(contentsOf: $0) }
                vclData.append(nal)
            }
        }

        // Rebuild the format description + session whenever the keyframe carries parameter sets.
        if !vps.isEmpty || !sps.isEmpty || !pps.isEmpty {
            let sets = vps + sps + pps
            if sets != parameterSets {
                parameterSets = sets
                rebuildSession(vps: vps, sps: sps, pps: pps)
            }
        }

        // A mid-stream joiner must wait for the first keyframe (parameter sets + IDR) before any
        // delta frame can be decoded.
        if awaitingKeyframe {
            guard keyframe, session != nil else { return }
            awaitingKeyframe = false
        }

        guard let session, !vclData.isEmpty,
              let sampleBuffer = makeSampleBuffer(from: vclData) else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self, status == noErr, let imageBuffer else { return }
            self.publish(imageBuffer: imageBuffer, frameID: frameID)
        }
    }

    // MARK: - Session / format

    private func rebuildSession(vps: [Data], sps: [Data], pps: [Data]) {
        let sets = vps + sps + pps
        guard !sets.isEmpty else { return }

        // Copy each parameter set into a stable allocation that outlives the create call. (Buffer
        // pointers from `withUnsafeBufferPointer` are only valid inside the closure, so they can't
        // be collected into an array for a later API call.) The format description copies the bytes
        // internally, so freeing them afterward is safe.
        var allocations: [UnsafeMutablePointer<UInt8>] = []
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in sets {
            let count = set.count
            guard count > 0 else { continue }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            set.copyBytes(to: buf, count: count)
            allocations.append(buf)
            pointers.append(UnsafePointer(buf))
            sizes.append(count)
        }
        defer { allocations.forEach { $0.deallocate() } }
        guard pointers.count == sets.count else { return }

        var format: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { sizeBuf in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: ptrBuf.baseAddress!,
                    parameterSetSizes: sizeBuf.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else {
            NSLog("[VisionCraft] HEVC format description failed: \(status)")
            return
        }
        formatDescription = format

        if let existing = session {
            VTDecompressionSessionInvalidate(existing)
            session = nil
        }

        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard sessionStatus == noErr, let created else {
            NSLog("[VisionCraft] VTDecompressionSessionCreate failed: \(sessionStatus)")
            return
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    private func makeSampleBuffer(from avccData: Data) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        let length = avccData.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = avccData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }

    // MARK: - Publish

    private func publish(imageBuffer: CVImageBuffer, frameID: UInt64) {
        guard let textureCache else { return }
        let pixelBuffer = imageBuffer as CVPixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        let hold = FrameHold(pixelBuffer: pixelBuffer, cvTexture: cvTexture, texture: texture)
        let currentPacking = { lock.lock(); defer { lock.unlock() }; return packing }()

        lock.lock()
        // Retain current + previous so a frame the GPU is still sampling isn't freed underneath it.
        previousHold = currentHold
        currentHold = hold
        published = DecodedFrame(texture: texture, packing: currentPacking, frameID: frameID)
        lock.unlock()
    }

    // MARK: - Annex-B

    /// Split an Annex-B buffer into NAL units (payload bytes only, start codes removed). Handles
    /// both 3-byte (`00 00 01`) and 4-byte (`00 00 00 01`) start codes.
    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        var nals: [Data] = []
        var i = 0
        var nalStart = -1
        while i + 3 <= n {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if nalStart >= 0 {
                    var end = i
                    // A preceding 0x00 belongs to a 4-byte start code, not the NAL.
                    if end > nalStart && bytes[end - 1] == 0 { end -= 1 }
                    if end > nalStart { nals.append(Data(bytes[nalStart..<end])) }
                }
                nalStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if nalStart >= 0 && nalStart < n {
            nals.append(Data(bytes[nalStart..<n]))
        }
        return nals
    }
}
