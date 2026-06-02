import SwiftUI

struct HostControlView: View {
    @Bindable var appModel: VisionCraftAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VisionCraft Host")
                            .font(.largeTitle.bold())
                        Text("Mac bridge and ALVR server for Apple Vision Pro.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        text: appModel.pipelineReady ? "Stream live" : "Setup in progress",
                        color: appModel.pipelineReady ? .green : .orange
                    )
                }

                HostCard(title: "Next Step", systemImage: "arrow.forward.circle") {
                    Text(appModel.nextStepTitle)
                        .font(.title3.bold())
                    Text(appModel.nextStepDetail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(alignment: .top, spacing: 14) {
                    HostCard(title: "Setup", systemImage: "shippingbox") {
                        StatusLine(
                            label: "ALVR artifacts",
                            value: appModel.setupArtifactsReady ? "ready" : "missing",
                            ok: appModel.setupArtifactsReady
                        )
                        Text("Missing artifacts mean `scripts/vc.sh bootstrap` or `scripts/prepare-alvr.sh` has not completed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HostCard(title: "Headset", systemImage: "visionpro") {
                        StatusLine(label: "ALVR server", value: appModel.alvrRunning ? "running" : "stopped", ok: appModel.alvrRunning)
                        StatusLine(label: "ALVRClient", value: appModel.alvrClientConnected ? "connected" : "waiting", ok: appModel.alvrClientConnected)
                        StatusLine(label: "Target eye", value: "\(appModel.alvrTargetEyeWidth)x\(appModel.alvrTargetEyeHeight)", ok: appModel.alvrTargetEyeWidth > 0)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    HostCard(title: "Bridge", systemImage: "cable.connector") {
                        StatusLine(label: "Session", value: appModel.sessionState.rawValue, ok: appModel.sessionState == .ready)
                        StatusLine(label: "Bridge port", value: "\(appModel.bridgePort)", ok: appModel.bridgeRunning)
                        StatusLine(label: "Frames received", value: "\(appModel.framesReceived)", ok: appModel.framesReceived > 0)
                        StatusLine(label: "Last frame ID", value: "\(appModel.lastFrameId)", ok: appModel.lastFrameId > 0)
                    }

                    HostCard(title: "Frame Source", systemImage: "gamecontroller") {
                        StatusLine(label: "Frames encoded", value: "\(appModel.framesEncoded)", ok: appModel.framesEncoded > 0)
                        StatusLine(label: "ALVR frames sent", value: "\(appModel.alvrFramesSent)", ok: appModel.alvrFramesSent > 0)
                        Text("Use `scripts/vc.sh sender` for a test pattern, or `scripts/vc.sh mc` then press F7 in Minecraft.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HostCard(title: "Controls", systemImage: "switch.2") {
                    HStack {
                        Button("Start Bridge") { appModel.startBridge() }
                            .disabled(appModel.bridgeRunning)
                        Button("Stop Bridge") { appModel.stopBridge() }
                            .disabled(!appModel.bridgeRunning)
                        Divider()
                        Button("Start ALVR") { appModel.startAlvr() }
                            .disabled(appModel.alvrRunning)
                        Button("Stop ALVR") { appModel.stopAlvr() }
                            .disabled(!appModel.alvrRunning)
                    }
                    HStack {
                        Button("Copy Verify Command") { appModel.copyVerifyCommand() }
                        Button("Open Runbook") { appModel.openRunbook() }
                        Button("Reveal Beta Bundle") { appModel.revealBetaBundle() }
                    }
                    Text(appModel.diagnosticText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .onAppear {
            appModel.startControlApi()
            if appModel.autoStartBridge {
                appModel.startBridge()
            }
            if appModel.autoStartAlvr {
                appModel.startAlvr()
            }
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            appModel.refreshAlvrStats()
        }
    }
}

private struct HostCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StatusLine: View {
    let label: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
