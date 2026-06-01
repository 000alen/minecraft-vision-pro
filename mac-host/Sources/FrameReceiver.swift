import Foundation
import Metal

/// Converts incoming RGBA8 eye buffers to Metal textures for compositing.
///
/// Thread-safety: `upload(...)` is called on the bridge's network thread while
/// `latestStereoTextures` is read on the compositor render thread. Both the
/// published pointer and the underlying texture memory are protected:
///  - A lock guards reads/writes of the published `StereoTextures`.
///  - Textures are N-buffered. Each upload writes the *next* slot in the ring,
///    so the CPU never overwrites the texture pair the render thread most
///    recently sampled (which the GPU may still be reading). This removes the
///    CPU-write-while-GPU-reads tearing that showed up as flicker.
final class FrameReceiver {
    struct StereoTextures {
        let left: MTLTexture
        let right: MTLTexture
    }

    /// Number of in-flight texture pairs. 3 covers CPU upload + GPU read of the
    /// previously published frame with margin.
    private static let bufferCount = 3

    private let device: MTLDevice
    private let lock = NSLock()

    private var leftPool: [MTLTexture?]
    private var rightPool: [MTLTexture?]
    private var writeIndex = 0
    private var dimensions: (width: Int, height: Int)?

    private var published: StereoTextures?

    var latestStereoTextures: StereoTextures? {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    init(device: MTLDevice) {
        self.device = device
        self.leftPool = Array(repeating: nil, count: Self.bufferCount)
        self.rightPool = Array(repeating: nil, count: Self.bufferCount)
    }

    func upload(left: Data, right: Data, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }

        // Reset the pool if the eye resolution changed.
        if dimensions?.width != width || dimensions?.height != height {
            leftPool = Array(repeating: nil, count: Self.bufferCount)
            rightPool = Array(repeating: nil, count: Self.bufferCount)
            dimensions = (width, height)
        }

        let slot = writeIndex
        guard
            let l = makeOrUpdateTexture(leftPool[slot], data: left, width: width, height: height),
            let r = makeOrUpdateTexture(rightPool[slot], data: right, width: width, height: height)
        else { return }

        leftPool[slot] = l
        rightPool[slot] = r
        writeIndex = (writeIndex + 1) % Self.bufferCount

        lock.lock()
        published = StereoTextures(left: l, right: r)
        lock.unlock()
    }

    private func makeOrUpdateTexture(_ existing: MTLTexture?, data: Data, width: Int, height: Int) -> MTLTexture? {
        let bytesPerRow = width * 4
        let expected = bytesPerRow * height
        guard data.count >= expected else { return existing }

        let texture: MTLTexture
        if let existing, existing.width == width, existing.height == height {
            texture = existing
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            guard let created = device.makeTexture(descriptor: desc) else { return existing }
            texture = created
        }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}
