import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import Accelerate

/// Packs the two RGBA8 eye buffers side-by-side and HEVC-encodes them with VideoToolbox into an
/// Annex-B elementary stream, per `bridge/stream-protocol.md`.
///
/// - Channel order: Minecraft sends **RGBA** bytes; the encoder source pixel buffer is **BGRA**, so
///   each eye is permuted R↔B with vImage (HW-friendly, no per-pixel Swift loop).
/// - Orientation: **no vertical flip here.** Java/OpenGL frames are bottom-left origin; the
///   ALVRClient video shader performs the vertical flip at sample time.
/// - Low latency: real-time, no frame reordering, no B-frames. Keyframes carry their parameter
///   sets inline so a mid-stream viewer recovers at the next IDR.
///
/// All session access is confined to `queue`; `encode` copies its inputs before returning, so the
/// caller may reuse/free its buffers immediately.
final class StereoFrameEncoder {
    struct AccessUnit {
        let data: Data
        let keyframe: Bool
        let frameId: UInt64
        let targetTimestampNs: UInt64
        let ptsNanos: UInt64
        /// Head orientation (ARKit world, xyzw) the frame was rendered for, or `nil` if unknown.
        let renderOrientation: [Float]?
    }

    private struct PendingFrame {
        let left: Data
        let right: Data
        let eyeWidth: Int
        let eyeHeight: Int
        let frameId: UInt64
        let targetTimestampNs: UInt64
        let renderOrientation: [Float]?
    }

    /// Called on the encoder queue for each compressed access unit.
    var onAccessUnit: ((AccessUnit) -> Void)?

    private let queue = DispatchQueue(label: "visioncraft.encoder")
    private var session: VTCompressionSession?
    private var eyeWidth = 0
    private var eyeHeight = 0
    private var fps: Int32 = 90
    private var frameIndex: Int64 = 0
    private var forceKeyframeNext = true
    private var pendingFrame: PendingFrame?
    private var encodeInFlight = false

    // MARK: - Lifecycle

    /// (Re)configure the encoder for a given per-eye size. Cheap to call repeatedly; only rebuilds
    /// the session when the geometry actually changes.
    func configure(eyeWidth: Int, eyeHeight: Int, fps: Int) {
        queue.async { self.configureLocked(eyeWidth: eyeWidth, eyeHeight: eyeHeight, fps: Int32(fps)) }
    }

    func requestKeyframe() {
        queue.async { self.forceKeyframeNext = true }
    }

    func stop() {
        queue.async {
            if let session = self.session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            self.session = nil
            self.eyeWidth = 0
            self.eyeHeight = 0
            self.pendingFrame = nil
            self.encodeInFlight = false
        }
    }

    // MARK: - Encode

    /// Pack + encode one stereo pair. `left`/`right` are RGBA8, `eyeWidth × eyeHeight` each.
    func encode(left: Data, right: Data, eyeWidth: Int, eyeHeight: Int, frameId: UInt64,
                targetTimestampNs: UInt64, renderOrientation: [Float]? = nil) {
        // Copy out of any caller-owned/transient storage so the async work is self-contained.
        let frame = PendingFrame(
            left: Data(left),
            right: Data(right),
            eyeWidth: eyeWidth,
            eyeHeight: eyeHeight,
            frameId: frameId,
            targetTimestampNs: targetTimestampNs,
            renderOrientation: renderOrientation
        )
        queue.async {
            // Latest-frame-wins: if VideoToolbox is still encoding, replace any
            // queued frame instead of building seconds of stale video latency.
            self.pendingFrame = frame
            self.encodeLatestPendingIfIdleLocked()
        }
    }

    // MARK: - Private (queue-confined)

    private func configureLocked(eyeWidth: Int, eyeHeight: Int, fps: Int32) {
        guard eyeWidth > 0, eyeHeight > 0 else { return }
        if session != nil, self.eyeWidth == eyeWidth, self.eyeHeight == eyeHeight, self.fps == fps {
            return
        }
        if let existing = session {
            VTCompressionSessionInvalidate(existing)
            session = nil
        }
        self.eyeWidth = eyeWidth
        self.eyeHeight = eyeHeight
        self.fps = fps
        self.frameIndex = 0
        self.forceKeyframeNext = true

        let frameWidth = eyeWidth * 2
        let frameHeight = eyeHeight

        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: frameWidth,
            kCVPixelBufferHeightKey: frameHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(frameWidth),
            height: Int32(frameHeight),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            NSLog("[VisionCraft] VTCompressionSessionCreate failed: \(status)")
            return
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(fps) * 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2.0))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: Int(fps)))
        // LAN link: favor quality. ~80 Mbps average keeps text/blocks crisp at AVP resolution.
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 80_000_000))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    private func encodeLatestPendingIfIdleLocked() {
        guard !encodeInFlight, let frame = pendingFrame else { return }
        pendingFrame = nil
        encodeInFlight = true
        if !encodeLocked(left: frame.left, right: frame.right, eyeWidth: frame.eyeWidth,
                         eyeHeight: frame.eyeHeight, frameId: frame.frameId,
                         targetTimestampNs: frame.targetTimestampNs,
                         renderOrientation: frame.renderOrientation) {
            encodeInFlight = false
            encodeLatestPendingIfIdleLocked()
        }
    }

    @discardableResult
    private func encodeLocked(left: Data, right: Data, eyeWidth: Int, eyeHeight: Int, frameId: UInt64,
                              targetTimestampNs: UInt64, renderOrientation: [Float]?) -> Bool {
        if session == nil || self.eyeWidth != eyeWidth || self.eyeHeight != eyeHeight {
            configureLocked(eyeWidth: eyeWidth, eyeHeight: eyeHeight, fps: fps)
        }
        guard let session,
              let pool = VTCompressionSessionGetPixelBufferPool(session) else { return false }

        let bytesPerEyeRow = eyeWidth * 4
        guard left.count >= bytesPerEyeRow * eyeHeight,
              right.count >= bytesPerEyeRow * eyeHeight else { return false }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return false }

        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
            var permuteMap: [UInt8] = [2, 1, 0, 3] // RGBA -> BGRA
            let height = vImagePixelCount(eyeHeight)
            let width = vImagePixelCount(eyeWidth)

            left.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let src = raw.baseAddress else { return }
                var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                                           height: height, width: width, rowBytes: bytesPerEyeRow)
                var dstBuf = vImage_Buffer(data: base,
                                           height: height, width: width, rowBytes: dstRowBytes)
                vImagePermuteChannels_ARGB8888(&srcBuf, &dstBuf, &permuteMap, 0)
            }
            right.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let src = raw.baseAddress else { return }
                var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                                           height: height, width: width, rowBytes: bytesPerEyeRow)
                var dstBuf = vImage_Buffer(data: base.advanced(by: eyeWidth * 4),
                                           height: height, width: width, rowBytes: dstRowBytes)
                vImagePermuteChannels_ARGB8888(&srcBuf, &dstBuf, &permuteMap, 0)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let pts = CMTime(value: frameIndex, timescale: fps)
        let duration = CMTime(value: 1, timescale: fps)
        frameIndex += 1

        var frameProperties: [CFString: Any]?
        if forceKeyframeNext {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any]
            forceKeyframeNext = false
        }

        let ptsNanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pb,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties as CFDictionary?,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self else { return }
            self.queue.async {
                defer {
                    self.encodeInFlight = false
                    self.encodeLatestPendingIfIdleLocked()
                }
                guard status == noErr, let sample else { return }
                self.handleEncoded(sample: sample, frameId: frameId,
                                   targetTimestampNs: targetTimestampNs, ptsNanos: ptsNanos,
                                   renderOrientation: renderOrientation)
            }
        }
        return status == noErr
    }

    private func handleEncoded(sample: CMSampleBuffer, frameId: UInt64, targetTimestampNs: UInt64,
                               ptsNanos: UInt64, renderOrientation: [Float]?) {
        guard CMSampleBufferDataIsReady(sample) else { return }

        let keyframe = Self.isKeyframe(sample)
        var au = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for paramSet in Self.hevcParameterSets(format) {
                au.append(contentsOf: startCode)
                au.append(paramSet)
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let base = dataPointer else { return }

        // The block buffer holds length-prefixed NAL units (HVCC: 4-byte big-endian length).
        // Rewrite each length prefix as an Annex-B start code.
        var offset = 0
        base.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
            while offset + 4 <= totalLength {
                let nalLength = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                offset += 4
                guard nalLength > 0, offset + nalLength <= totalLength else { break }
                au.append(contentsOf: startCode)
                au.append(UnsafeBufferPointer(start: bytes + offset, count: nalLength))
                offset += nalLength
            }
        }

        guard !au.isEmpty else { return }
        onAccessUnit?(AccessUnit(data: au, keyframe: keyframe, frameId: frameId,
                                 targetTimestampNs: targetTimestampNs, ptsNanos: ptsNanos,
                                 renderOrientation: renderOrientation))
    }

    // MARK: - Helpers

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else {
            return true // no attachments → treat as sync sample
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        var value: UnsafeRawPointer?
        if CFDictionaryGetValueIfPresent(dict, key, &value), let value {
            // NotSync present and true → delta frame.
            let notSync = unsafeBitCast(value, to: CFBoolean.self)
            return !CFBooleanGetValue(notSync)
        }
        return true
    }

    private static func hevcParameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        var nalHeaderLength: Int32 = 0
        // Query the parameter set count.
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
        ) == noErr else { return [] }

        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}
