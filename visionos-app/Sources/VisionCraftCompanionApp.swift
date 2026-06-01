import SwiftUI
import CompositorServices

/// VisionCraft companion — a native visionOS app that renders Minecraft frames streamed
/// from the Mac relay and feeds on-device head + hand tracking back over the stream protocol.
///
/// Architecture (see `bridge/stream-protocol.md`):
///  - The Mac relay HEVC-encodes the eye frames Minecraft already produces and streams them here.
///  - This app decodes + composites them into a `CompositorLayer` (the platform compositor
///    reprojects each submitted frame to the live head pose, so head-look stays locked).
///  - On-device `WorldTrackingProvider` + `HandTrackingProvider` drive `pose`/`hand` uplink —
///    the hand/pinch input the macOS RemoteImmersiveSpace host cannot produce.
@main
struct VisionCraftCompanionApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        // Launch / status window: connection state and the button to enter the immersive game.
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowStyle(.plain)
        .defaultSize(width: 520, height: 360)

        // Fully immersive Metal stage. Foveation is disabled in the configuration because we
        // present a uniform-resolution blit of the game's eye frames (see ContentStageConfiguration).
        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                // Runs off the main actor; AppModel handles its own thread hops for UI state.
                appModel.startImmersive(layerRenderer: layerRenderer)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // Keep the user's real hands visible so pinch input feels direct.
        .upperLimbVisibility(.visible)
    }
}

/// `CompositorLayer` configuration. Mirrors the macOS host's choices so the on-device
/// composite path matches: layered (both eyes in one amplified pass), foveation OFF
/// (the game frames are uniform-resolution; a rate map would warp them).
struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        configuration.layout = .layered
        configuration.drawableRenderContextRasterSampleCount = 1

        let supportsBGRA = capabilities.supportedColorFormats.contains(.bgra8Unorm_srgb)
        configuration.colorFormat = supportsBGRA ? .bgra8Unorm_srgb : capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float

        if capabilities.supportsFoveation {
            configuration.isFoveationEnabled = false
        }
    }
}
