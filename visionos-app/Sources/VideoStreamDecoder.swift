import Foundation
import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import simd

/// Decodes the HEVC video stream (`bridge/stream-protocol.md` `VIDEO_FRAME`) into Metal textures
/// for `CompanionRenderer`.
///
/// Pipeline: Annex-B access unit → split NALs → (on keyframe) rebuild `CMVideoFormatDescription`
/// from the inline VPS/SPS/PPS → wrap the VCL NALs as a length-prefixed `CMSampleBuffer` →
/// `VTDecompressionSession` → biplanar full-range YCbCr `CVPixelBuffer` → two `MTLTexture`s (luma
/// `.r8Unorm`, chroma `.rg8Unorm`) via `CVMetalTextureCache`. YUV→RGB conversion happens in the
/// composite shader, avoiding an extra CPU/GPU BGRA pass (matches ALVR's decode path).
///
/// Thread-safety: `decode(...)` is called on the stream client's queue; VideoToolbox invokes the
/// output handler on its own queue. The render thread consumes via `latestFrame`. A small bounded
/// jitter buffer (see `JitterBuffer`) smooths network/decode timing: frames are presented in
/// order, each once, repeating the last frame when the queue drains. Holds keep the backing
/// pixel buffers/textures of the presented (and previously-presented) frame alive so the GPU can
/// finish sampling after the next frame arrives.
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

    /// Everything that must outlive a published frame: the IOSurface-backed pixel buffer, the two
    /// CoreVideo↔Metal bridge objects, and the resulting plane textures.
    private final class FrameHold {
        let pixelBuffer: CVPixelBuffer
        let cvLuma: CVMetalTexture
        let cvChroma: CVMetalTexture
        let luma: MTLTexture
        let chroma: MTLTexture
        init(pixelBuffer: CVPixelBuffer, cvLuma: CVMetalTexture, cvChroma: CVMetalTexture,
             luma: MTLTexture, chroma: MTLTexture) {
            self.pixelBuffer = pixelBuffer
            self.cvLuma = cvLuma
            self.cvChroma = cvChroma
            self.luma = luma
            self.chroma = chroma
        }
    }

    /// A decoded frame plus the GPU resources backing it, queued for ordered presentation.
    private struct Entry {
        let frame: DecodedFrame
        let hold: FrameHold
    }

    /// Bounded FIFO of decoded frames. Decode enqueues; the render thread dequeues one per call,
    /// repeating the last presented frame when empty so the compositor always has content.
    private static let maxQueueDepth = 3

    /// Called (off the render thread) when a frame can't be decoded or the viewer is waiting for a
    /// keyframe — the owner forwards a `request_idr` uplink so the host emits a fresh IDR. Rate
    /// limited internally so a burst of failures produces at most one request per interval.
    var onDecodeFailure: (() -> Void)?
    private static let idrRequestMinInterval: CFAbsoluteTime = 0.5
    private var lastIdrRequestTime: CFAbsoluteTime = 0

    private let lock = NSLock()
    private var config: Config?
    private var pendingQueue: [Entry] = []
    private var presented: Entry?
    private var previouslyPresented: Entry?

    private let device: MTLDevice?
    private var textureCache: CVMetalTextureCache?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: [Data] = []
    private var packing: StereoPacking = .sideBySide
    private var awaitingKeyframe = true

    init(device: MTLDevice? = nil) {
        // Use the CompositorLayer's device so decoded textures are valid in its command buffers.
        self.device = device ?? MTLCreateSystemDefaultDevice()
        if let device = self.device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
    }

    var latestFrame: DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        // Present each queued frame exactly once, in order; repeat the last one when drained.
        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            previouslyPresented = presented
            presented = next
        }
        return presented?.frame
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
        self.awaitingKeyframe = true
        lock.unlock()
    }

    // MARK: - Decode

    func decode(meta: [String: Any], accessUnit: Data) {
        let frameID = (meta["frame_id"] as? NSNumber)?.uint64Value ?? 0
        let keyframe = (meta["keyframe"] as? Bool) ?? false
        let renderOrientation = Self.parseOrientation(meta["render_orientation_xyzw"])

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
        // delta frame can be decoded. Nudge the host for an IDR so the wait is bounded.
        lock.lock()
        let waitingForKeyframe = awaitingKeyframe
        lock.unlock()
        if waitingForKeyframe {
            guard keyframe, session != nil else {
                requestIdrThrottled()
                return
            }
            lock.lock()
            awaitingKeyframe = false
            lock.unlock()
        }

        guard let session, !vclData.isEmpty,
              let sampleBuffer = makeSampleBuffer(from: vclData) else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                // Lost a frame (corruption / dropped reference). Recover from the next keyframe and
                // ask the host to send one now rather than waiting for the periodic IDR.
                self.lock.lock()
                self.awaitingKeyframe = true
                self.lock.unlock()
                self.requestIdrThrottled()
                return
            }
            self.publish(imageBuffer: imageBuffer, frameID: frameID, renderOrientation: renderOrientation)
        }
    }

    private func requestIdrThrottled() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastIdrRequestTime >= Self.idrRequestMinInterval else { return }
        lastIdrRequestTime = now
        onDecodeFailure?()
    }

    private static func parseOrientation(_ value: Any?) -> simd_quatf? {
        guard let array = value as? [Any], array.count == 4 else { return nil }
        let q = array.compactMap { ($0 as? NSNumber)?.floatValue }
        guard q.count == 4 else { return nil }
        // JSON is xyzw; simd_quatf is (ix, iy, iz, r).
        return simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])
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

        // Native biplanar full-range YCbCr (4:2:0). Full range so the shader's BT.709 matrix needs
        // no 16–235 expansion; the encoder pins BT.709 primaries/transfer/matrix to match.
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            // Keep enough buffers for the in-flight jitter queue + the GPU's working set so the
            // decoder never stalls recycling a buffer the renderer still holds.
            kCVPixelBufferPoolMinimumBufferCountKey: Self.maxQueueDepth + 3
        ]
        // Prefer the dedicated HEVC hardware decode block (always present on Apple Silicon).
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpec as CFDictionary,
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

    private func publish(imageBuffer: CVImageBuffer, frameID: UInt64, renderOrientation: simd_quatf?) {
        guard let textureCache else { return }
        let pixelBuffer = imageBuffer as CVPixelBuffer
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }

        let lumaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var cvLuma: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, lumaW, lumaH, 0, &cvLuma
        ) == kCVReturnSuccess, let cvLuma, let luma = CVMetalTextureGetTexture(cvLuma) else { return }

        var cvChroma: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, chromaW, chromaH, 1, &cvChroma
        ) == kCVReturnSuccess, let cvChroma, let chroma = CVMetalTextureGetTexture(cvChroma) else { return }

        let hold = FrameHold(pixelBuffer: pixelBuffer, cvLuma: cvLuma, cvChroma: cvChroma,
                             luma: luma, chroma: chroma)

        lock.lock()
        let frame = DecodedFrame(luma: luma, chroma: chroma, packing: packing,
                                 frameID: frameID, renderOrientation: renderOrientation)
        pendingQueue.append(Entry(frame: frame, hold: hold))
        // Drop the oldest queued (not-yet-presented) frame if we're backing up, bounding latency.
        if pendingQueue.count > Self.maxQueueDepth {
            pendingQueue.removeFirst(pendingQueue.count - Self.maxQueueDepth)
        }
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
