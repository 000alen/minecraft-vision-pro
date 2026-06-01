import SwiftUI

/// VisionCraft macOS host — M0/M1 entry point.
/// Requires macOS 26+ for RemoteImmersiveSpace / Compositor Services.
@main
struct VisionCraftHostApp: App {
    @State private var appModel = VisionCraftAppModel()
    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup {
            HostControlView(appModel: appModel)
                .frame(minWidth: 420, minHeight: 320)
        }

        #if canImport(CompositorServices)
        if #available(macOS 26.0, *) {
            RemoteImmersiveSpace(id: VisionCraftImmersiveSpace.id) {
                VisionCraftImmersiveContent(appModel: appModel)
            }
            .immersionStyle(selection: $immersionStyle, in: .full)
        }
        #endif
    }
}
