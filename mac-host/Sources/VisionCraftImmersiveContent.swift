import SwiftUI

#if canImport(ARKit)
import ARKit
import _ARKit_SwiftUI
#endif

#if canImport(CompositorServices)
import CompositorServices
#endif

/// Immersive scene presented on Vision Pro via RemoteImmersiveSpace.
#if canImport(CompositorServices)
@available(macOS 26.0, *)
struct VisionCraftImmersiveContent: CompositorContent {
    @Environment(\.remoteDeviceIdentifier) private var remoteDeviceIdentifier
    let appModel: VisionCraftAppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: VisionCraftCompositorConfiguration()) { layer in
            appModel.setRemoteDeviceIdentifierAvailable(remoteDeviceIdentifier != nil)

            #if canImport(ARKit)
            if let remoteDeviceIdentifier {
                let session = ARKitSession(device: remoteDeviceIdentifier)
                let worldTrackingProvider = WorldTrackingProvider()

                appModel.setARTrackingState("starting")

                appModel.startRemoteImmersiveSession(
                    layer: layer,
                    session: session,
                    worldTrackingProvider: worldTrackingProvider
                )
            } else {
                appModel.setARTrackingState("missing remoteDeviceIdentifier")
                appModel.compositor.attach(layer: layer, posePublisher: appModel.posePublisher)
            }
            #else
            appModel.setARTrackingState("ARKit unavailable")
            appModel.compositor.attach(layer: layer, posePublisher: appModel.posePublisher)
            #endif
        }
    }

}

@available(macOS 26.0, *)
private struct VisionCraftCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        // `.layered` is REQUIRED by the renderer: it draws both eyes in one pass via
        // vertex amplification into a single array-backed color texture with
        // `renderTargetArrayLength == views.count`. Changing this to `.dedicated`
        // or `.shared` would break the amplification path in CompositorRenderer.
        configuration.layout = .layered
        configuration.drawableRenderContextRasterSampleCount = 1

        // Foveation is intentionally LEFT OFF. The M1 path presents Minecraft's
        // uniform-resolution eye frames as a 1:1 fullscreen blit; a foveated
        // rasterization-rate map would warp that uniform image. Re-enable only when
        // the renderer draws foveation-aware content natively.
        if capabilities.supportsFoveation {
            configuration.isFoveationEnabled = false
        }
    }
}
#endif
