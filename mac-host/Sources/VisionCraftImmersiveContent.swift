import SwiftUI

#if canImport(CompositorServices)
import CompositorServices
#endif

/// Immersive scene presented on Vision Pro via RemoteImmersiveSpace.
struct VisionCraftImmersiveContent: View {
    let appModel: VisionCraftAppModel

    var body: some View {
        #if canImport(CompositorServices)
        if #available(macOS 26.0, *) {
            CompositorLayer(configuration: compositorConfig) { layer in
                CompositorRendererView(layer: layer, appModel: appModel)
            }
        } else {
            Text("Compositor Services unavailable")
        }
        #else
        Text("Build with macOS 26 SDK (CompositorServices)")
        #endif
    }

    #if canImport(CompositorServices)
  @available(macOS 26.0, *)
  private var compositorConfig: LayerConfiguration {
        LayerConfiguration { capabilities in
            capabilities.supportsFoveation = false
        }
    }
    #endif
}

#if canImport(CompositorServices)
@available(macOS 26.0, *)
private struct CompositorRendererView: View {
    let layer: LayerRenderer
  @Bindable var appModel: VisionCraftAppModel

    var body: some View {
        CompositorRenderer(layer: layer, appModel: appModel)
            .onAppear {
                appModel.compositor.attach(layer: layer)
            }
            .onDisappear {
                appModel.compositor.detach()
            }
    }
}
#endif
