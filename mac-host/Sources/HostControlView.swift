import SwiftUI

struct HostControlView: View {
    @Bindable var appModel: VisionCraftAppModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VisionCraft Host")
                .font(.title2.bold())

            Text(appModel.diagnosticText)
                .foregroundStyle(.secondary)

            LabeledContent("Session", value: appModel.sessionState.rawValue)
            LabeledContent("Frames", value: "\(appModel.framesReceived)")
            LabeledContent("Last frame ID", value: "\(appModel.lastFrameId)")

            HStack {
                Button("Start bridge") { appModel.startBridge() }
                Button("Stop bridge") { appModel.stopBridge() }
            }

            HStack {
                Button("Open immersive") {
                    Task { await openImmersive() }
                }
                .disabled(appModel.immersiveSpaceOpen)

                Button("Close immersive") {
                    Task { await closeImmersive() }
                }
                .disabled(!appModel.immersiveSpaceOpen)
            }

            Text("Run Minecraft with Apple Vision provider after bridge + immersive space are active.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear { appModel.startBridge() }
    }

    private func openImmersive() async {
        #if canImport(CompositorServices)
        if #available(macOS 26.0, *) {
            let result = await openImmersiveSpace(id: VisionCraftImmersiveSpace.id)
            if result == .opened {
                appModel.onImmersiveSpaceOpened()
            } else {
                appModel.diagnosticText = "Failed to open immersive space: \(result)"
            }
            return
        }
        #endif
        appModel.diagnosticText = "RemoteImmersiveSpace requires macOS 26 SDK"
    }

    private func closeImmersive() async {
        await dismissImmersiveSpace()
        appModel.onImmersiveSpaceClosed()
    }
}
