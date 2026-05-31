import Foundation
import Metal
import simd

#if canImport(CompositorServices)
import CompositorServices
import SwiftUI
#endif

/// Metal stereo renderer — M0 debug cube or M1 Java-submitted frames.
final class CompositorRenderer {
    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var frameReceiver: FrameReceiver?
    private weak var layer: AnyObject?

    #if canImport(CompositorServices)
    @available(macOS 26.0, *)
    func attach(layer: LayerRenderer) {
        self.layer = layer
        guard let device else { return }
        frameReceiver = FrameReceiver(device: device)
        startRenderLoop(layer: layer)
    }
    #endif

    func detach() {
        layer = nil
        frameReceiver = nil
    }

    #if canImport(CompositorServices)
    @available(macOS 26.0, *)
    private func startRenderLoop(layer: LayerRenderer) {
        guard let device, let frameReceiver else { return }

        layer.onRenderThread = { context in
            let pose = context.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            self.drawFrame(context: context, device: device, receiver: frameReceiver, headTransform: pose)
        }
    }

    @available(macOS 26.0, *)
    private func drawFrame(
        context: LayerRenderer.DrawContext,
        device: MTLDevice,
        receiver: FrameReceiver,
        headTransform: simd_float4x4
    ) {
        let drawable = context.drawable
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else { return }

        if let stereo = receiver.latestStereoTextures {
            // M1+: blit Java frames per eye
            compositeExternalTextures(stereo, into: drawable, commandBuffer: commandBuffer)
        } else {
            // M0: procedural stereo cube + axis gizmo
            drawDebugScene(headTransform: headTransform, drawable: drawable, commandBuffer: commandBuffer, device: device)
        }

        commandBuffer.present(drawable.colorTextures.first!)
        commandBuffer.commit()
    }

    @available(macOS 26.0, *)
    private func drawDebugScene(
        headTransform: simd_float4x4,
        drawable: LayerRenderer.Drawable,
        commandBuffer: MTLCommandBuffer,
        device: MTLDevice
    ) {
        // Minimal clear per eye — replace with Composite.metal cube pass on device validation.
        for texture in drawable.colorTextures {
            guard let pass = commandBuffer.makeRenderCommandEncoder(
                descriptor: Self.clearPassDescriptor(texture: texture)
            ) else { continue }
            pass.label = "VisionCraft M0 debug"
            pass.endEncoding()
        }
        _ = headTransform // used when cube shader is wired
    }

    @available(macOS 26.0, *)
    private func compositeExternalTextures(
        _ stereo: FrameReceiver.StereoTextures,
        into drawable: LayerRenderer.Drawable,
        commandBuffer: MTLCommandBuffer
    ) {
        let textures = drawable.colorTextures
        if textures.count >= 2 {
            blit(stereo.left, to: textures[0], commandBuffer: commandBuffer)
            blit(stereo.right, to: textures[1], commandBuffer: commandBuffer)
        } else if let first = textures.first {
            blit(stereo.left, to: first, commandBuffer: commandBuffer)
        }
    }

    private func blit(_ source: MTLTexture, to dest: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let size = MTLSize(width: min(source.width, dest.width),
                           height: min(source.height, dest.height),
                           depth: 1)
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: size,
                  to: dest, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    @available(macOS 26.0, *)
    private static func clearPassDescriptor(texture: MTLTexture) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = texture
        d.colorAttachments[0].loadAction = .clear
        d.colorAttachments[0].storeAction = .store
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1)
        return d
    }
    #endif

    func uploadFrame(left: Data, right: Data, width: Int, height: Int) {
        frameReceiver?.upload(left: left, right: right, width: width, height: height)
    }
}
