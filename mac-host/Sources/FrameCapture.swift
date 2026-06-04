import Foundation
import CoreVideo
import CoreGraphics
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

/// Off-by-default, bounded frame-capture sink. When armed via `arm(frames:)`, it writes PNGs at
/// each Mac-side pipeline stage into a timestamped bundle under `.run/captures/<ts>/`:
///
/// - `recv/<id>_left.png`, `recv/<id>_right.png` — the raw per-eye RGBA8 buffers received from
///   Java over the bridge (vertically flipped to upright, since Java/OpenGL frames are bottom-left
///   origin per `bridge/protocol.md`).
/// - `sbs/<id>.png` — the side-by-side BGRA `CVPixelBuffer` exactly as it is handed to HEVC encode.
/// - `decoded/<id>.png` — the host's own HEVC self-decode of that frame, to validate the bitstream.
///
/// Each stage has an independent remaining counter so a small skew between stages still yields
/// correlated files (filenames are keyed by `frame_id`). All state and IO are guarded by a lock;
/// capture is bounded (N frames) so the inline PNG/IO cost is acceptable for a debug feature.
final class FrameCapture {
    static let shared = FrameCapture()

    private let lock = NSLock()
    private var bundleDir: URL?
    private var manifest: FileHandle?
    private var remainingRecv = 0
    private var remainingSbs = 0
    private var remainingDecoded = 0

    private init() {}

    /// True if any stage still wants frames; used by hooks to skip work cheaply when idle.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return remainingRecv > 0 || remainingSbs > 0 || remainingDecoded > 0
    }

    var wantsRecv: Bool { lock.lock(); defer { lock.unlock() }; return remainingRecv > 0 }
    var wantsSbs: Bool { lock.lock(); defer { lock.unlock() }; return remainingSbs > 0 }
    var wantsDecoded: Bool { lock.lock(); defer { lock.unlock() }; return remainingDecoded > 0 }

    /// Arm capture of the next `frames` at each stage. Creates the bundle directory, writes a
    /// `header.json` (caller-supplied geometry/context), and opens a `manifest.ndjson`.
    /// Returns the absolute bundle path (empty string on failure).
    @discardableResult
    func arm(frames: Int, repoRoot: String, header: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let count = max(1, frames)
        let stamp = Self.timestamp()
        let dir = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".run", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        let fm = FileManager.default
        do {
            for sub in ["recv", "sbs", "decoded"] {
                try fm.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true),
                                       withIntermediateDirectories: true)
            }
            try header.data(using: .utf8)?.write(to: dir.appendingPathComponent("header.json"))
            let manifestURL = dir.appendingPathComponent("manifest.ndjson")
            fm.createFile(atPath: manifestURL.path, contents: nil)
            manifest = try FileHandle(forWritingTo: manifestURL)
        } catch {
            NSLog("[VisionCraft] FrameCapture.arm failed: \(error.localizedDescription)")
            return ""
        }
        bundleDir = dir
        remainingRecv = count
        remainingSbs = count
        remainingDecoded = count
        NSLog("[VisionCraft] FrameCapture armed for \(count) frames -> \(dir.path)")
        return dir.path
    }

    // MARK: - Stage hooks

    /// Dump the raw per-eye RGBA8 buffers received from Java (vertically flipped to upright).
    func captureReceived(left: Data, right: Data, width: Int, height: Int, frameId: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard remainingRecv > 0, let dir = bundleDir else { return }
        let stem = Self.stem(frameId)
        if let l = Self.makeCGImageRGBA8(left, width: width, height: height, flipVertical: true) {
            Self.writePNG(l, to: dir.appendingPathComponent("recv/\(stem)_left.png"))
        }
        if let r = Self.makeCGImageRGBA8(right, width: width, height: height, flipVertical: true) {
            Self.writePNG(r, to: dir.appendingPathComponent("recv/\(stem)_right.png"))
        }
        remainingRecv -= 1
    }

    /// Dump the side-by-side BGRA pixel buffer exactly as it is submitted to the encoder.
    func captureSBS(_ pixelBuffer: CVPixelBuffer, frameId: UInt64, eyeWidth: Int, eyeHeight: Int,
                    targetTimestampNs: UInt64, keyframe: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard remainingSbs > 0, let dir = bundleDir else { return }
        let stem = Self.stem(frameId)
        if let img = Self.makeCGImage(from: pixelBuffer) {
            Self.writePNG(img, to: dir.appendingPathComponent("sbs/\(stem).png"))
        }
        appendManifestLocked(
            "{\"frame_id\":\(frameId),\"eye_width\":\(eyeWidth),\"eye_height\":\(eyeHeight),"
            + "\"sbs_width\":\(eyeWidth * 2),\"sbs_height\":\(eyeHeight),"
            + "\"target_timestamp_ns\":\(targetTimestampNs),\"keyframe\":\(keyframe)}")
        remainingSbs -= 1
    }

    /// Dump the host's own HEVC self-decode of a frame (bitstream validation).
    func captureDecoded(_ pixelBuffer: CVPixelBuffer, frameId: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard remainingDecoded > 0, let dir = bundleDir else { return }
        let stem = Self.stem(frameId)
        if let img = Self.makeCGImage(from: pixelBuffer) {
            Self.writePNG(img, to: dir.appendingPathComponent("decoded/\(stem).png"))
        }
        remainingDecoded -= 1
    }

    // MARK: - Manifest

    private func appendManifestLocked(_ line: String) {
        guard let manifest else { return }
        if let data = (line + "\n").data(using: .utf8) {
            manifest.write(data)
        }
        if remainingSbs <= 1 {
            try? manifest.close()
            self.manifest = nil
        }
    }

    // MARK: - Image helpers

    private static func stem(_ frameId: UInt64) -> String {
        String(format: "frame_%08llu", frameId)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// RGBA8 row-major -> CGImage. `flipVertical` reverses row order (bottom-left -> top-left).
    static func makeCGImageRGBA8(_ data: Data, width: Int, height: Int, flipVertical: Bool) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        let needed = rowBytes * height
        guard data.count >= needed else { return nil }
        var pixels = [UInt8](repeating: 0, count: needed)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let src = raw.baseAddress else { return }
            if flipVertical {
                for y in 0..<height {
                    let srcRow = (height - 1 - y) * rowBytes
                    _ = pixels.withUnsafeMutableBytes { dst in
                        memcpy(dst.baseAddress!.advanced(by: y * rowBytes), src.advanced(by: srcRow), rowBytes)
                    }
                }
            } else {
                _ = pixels.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress!, src, needed)
                }
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// CVPixelBuffer (BGRA, as encoded) -> CGImage via VideoToolbox.
    static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return status == noErr ? image : nil
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
