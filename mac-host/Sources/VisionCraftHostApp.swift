import SwiftUI

/// VisionCraft macOS host.
@main
struct VisionCraftHostApp: App {
    @State private var appModel = VisionCraftAppModel()

    var body: some Scene {
        WindowGroup {
            HostControlView(appModel: appModel)
                .frame(minWidth: 760, minHeight: 720)
        }
    }
}
