import SwiftUI

/// Launch / status surface. Requests ARKit authorization, lets the user optionally enter a
/// manual host + pairing token, and opens the immersive game stage.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var immersiveOpen = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 20) {
            Text("VisionCraft")
                .font(.largeTitle.weight(.bold))
            Text("Stream Minecraft from your Mac with on-device hand tracking.")
                .foregroundStyle(.secondary)

            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Mac host (optional — auto-discovers if blank)", text: $appModel.manualHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("Pairing token", text: $appModel.pairingToken)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(6)
            }

            HStack(spacing: 12) {
                statusDot
                Text(statusText).font(.headline)
            }
            if !appModel.statusDetail.isEmpty {
                Text(appModel.statusDetail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button(immersiveOpen ? "Leave" : "Enter VisionCraft") {
                Task { await toggleImmersive() }
            }
            .font(.title3.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(28)
        .task { await appModel.requestAuthorizations() }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 12, height: 12)
    }

    private var dotColor: Color {
        switch appModel.phase {
        case .streaming: .green
        case .immersiveNoVideo, .connecting, .searching: .yellow
        case .error: .red
        case .idle: .gray
        }
    }

    private var statusText: String {
        switch appModel.phase {
        case .idle: "Ready"
        case .searching: "Searching for Mac…"
        case .connecting: "Connecting…"
        case .streaming: "Streaming (\(appModel.framesDecoded) frames)"
        case .immersiveNoVideo: "Immersive — waiting for host video"
        case .error: "Error"
        }
    }

    private func toggleImmersive() async {
        if immersiveOpen {
            await dismissImmersiveSpace()
            appModel.stopImmersive()
            immersiveOpen = false
        } else {
            switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
            case .opened:
                immersiveOpen = true
            case .error, .userCancelled:
                appModel.reportError("Could not open immersive space")
            @unknown default:
                break
            }
        }
    }
}
