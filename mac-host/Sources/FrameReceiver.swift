import Foundation
import Metal

/// Converts incoming RGBA8 eye buffers to Metal textures for compositing.
final class FrameReceiver {
    struct StereoTextures {
        let left: MTLTexture
        let right: MTLTexture
    }

    private let device: MTLDevice
    private var leftTexture: MTLTexture?
    private var rightTexture: MTLTexture?

    private(set) var latestStereoTextures: StereoTextures?

    init(device: MTLDevice) {
        self.device = device
    }

    func upload(left: Data, right: Data, width: Int, height: Int) {
        leftTexture = makeOrUpdateTexture(leftTexture, data: left, width: width, height: height)
        rightTexture = makeOrUpdateTexture(rightTexture, data: right, width: width, height: height)
        if let l = leftTexture, let r = rightTexture {
            latestStereoTextures = StereoTextures(left: l, right: r)
        }
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
