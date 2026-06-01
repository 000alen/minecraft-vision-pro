import SwiftUI

struct HostControlView: View {
    @Bindable var appModel: VisionCraftAppModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsRemoteScenes) private var supportsRemoteScenes
    @State private var didRunStartupAutomation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VisionCraft Host")
                .font(.title2.bold())

            Text(appModel.diagnosticText)
                .foregroundStyle(.secondary)

            LabeledContent("Session", value: appModel.sessionState.rawValue)
            LabeledContent("Remote scenes", value: appModel.supportsRemoteScenes ? "supported" : "unsupported")
            LabeledContent("AR tracking", value: appModel.arTrackingState)
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
        .onAppear {
            appModel.startControlApi()
            appModel.setSupportsRemoteScenes(supportsRemoteScenes)
            if appModel.autoStartBridge {
                appModel.startBridge()
            }
        }
        .task {
            guard !didRunStartupAutomation else { return }
            didRunStartupAutomation = true

            if appModel.autoOpenImmersive {
                await openImmersive()
            }
        }
        .onChange(of: appModel.immersiveOpenRequestId) { _, _ in
            Task { await openImmersive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .visionCraftOpenImmersiveRequest)) { _ in
            Task { await openImmersive() }
        }
        .onChange(of: supportsRemoteScenes) { _, supported in
            appModel.setSupportsRemoteScenes(supported)
        }
    }

    private func openImmersive() async {
        #if canImport(CompositorServices)
        if #available(macOS 26.0, *) {
            guard supportsRemoteScenes else {
                appModel.diagnosticText = "Remote immersive scenes are unsupported or no Vision Pro is selectable"
                return
            }
            let result = await openImmersiveSpace(id: VisionCraftImmersiveSpace.id)
            if result == .opened {
                appModel.onImmersiveSpaceOpened()
            } else {
                appModel.diagnosticText = "Failed to open immersive space: \(result). If the picker says No People Found, no Vision Pro target is discoverable."
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
