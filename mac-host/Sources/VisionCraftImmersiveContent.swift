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

                Task(priority: .high) {
                    do {
                        try await session.run([worldTrackingProvider])
                        await MainActor.run {
                            appModel.setARTrackingState(worldTrackingProvider.state.description)
                        }
                        appModel.compositor.attach(
                            layer: layer,
                            arKitSession: session,
                            worldTrackingProvider: worldTrackingProvider,
                            posePublisher: appModel.posePublisher
                        )
                    } catch {
                        await MainActor.run {
                            appModel.setARTrackingState("failed: \(error.localizedDescription)")
                        }
                    }
                }
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
        // M0 validation uses full immersion with a direct layered drawable clear.
        configuration.layout = .layered
        configuration.drawableRenderContextRasterSampleCount = 1
    }
}
#endif
