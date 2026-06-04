import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class VisionCraftAppModel {
    var sessionState: BridgeSessionState = .closed
    var lastFrameId: UInt64 = 0
    var framesReceived: UInt64 = 0
    var bridgePort: Int = 19735
    var controlPort: Int = 19734
    var diagnosticText: String = "Idle"
    var autoStartBridge = true
    var autoStartAlvr = true
    var bridgeRunning = false
    var alvrRunning = false
    var alvrClientConnected = false
    var alvrFramesSent: UInt64 = 0
    var alvrTargetEyeWidth = 0
    var alvrTargetEyeHeight = 0
    var framesEncoded: UInt64 = 0
    var alvrLastTrackingTimestampNs: UInt64 = 0
    var alvrLastVideoTimestampNs: UInt64 = 0
    var bridgeStreamingReady = false
    var sentVideoConfig = false
    var syntheticFramesEnabled = false
    var framesDroppedNoConfig: UInt64 = 0

    let bridgeServer = JavaBridgeServer()
    let controlApiServer = ControlApiServer()
    let posePublisher = PosePublisher()
    let alvr = AlvrServerCoordinator()

    var pipelineReady: Bool {
        bridgeRunning && alvrRunning && alvrClientConnected && framesEncoded > 0
    }

    var setupArtifactsReady: Bool {
        let root = Self.repoRootPath()
        return FileManager.default.fileExists(
            atPath: "\(root)/mac-host/Vendor/ALVRServerCore/libalvr_server_core.dylib"
        ) && FileManager.default.fileExists(
            atPath: "\(root)/visionos-app/ALVRClient/ALVRClientCore.xcframework"
        )
    }

    var nextStepTitle: String {
        if !setupArtifactsReady { return "Run beta preflight" }
        if !bridgeRunning { return "Start the Java bridge" }
        if !alvrRunning { return "Start ALVR server_core" }
        if !alvrClientConnected { return "Run ALVRClient on Apple Vision Pro" }
        if framesEncoded == 0 {
            if syntheticFramesEnabled {
                return "Enter immersive mode on AVP"
            }
            return "Run scripts/vc.sh synthetic"
        }
        return "Stream is live"
    }

    var nextStepDetail: String {
        if !setupArtifactsReady {
            return "Run scripts/vc.sh bootstrap to generate ALVR artifacts and projects."
        }
        if !bridgeRunning {
            return "The bridge listens on 127.0.0.1:\(bridgePort) for Minecraft or the test sender."
        }
        if !alvrRunning {
            return "ALVR server_core advertises the headset stream and waits for the visionOS client."
        }
        if !alvrClientConnected {
            return "On the headset, run ALVRClient from Xcode or your beta install, then allow permissions."
        }
        if framesEncoded == 0 {
            return "Run scripts/vc.sh synthetic first. If ALVR-only frames work, then try scripts/vc.sh sender or scripts/vc.sh mc + F7."
        }
        return "Use scripts/vc.sh verify if you want a terminal health check."
    }

    init(processInfo: ProcessInfo = .processInfo) {
        let environment = processInfo.environment
        let arguments = processInfo.arguments

        if let configuredPort = Self.intValue(
            for: "VISIONCRAFT_BRIDGE_PORT",
            arguments: arguments,
            environment: environment
        ) {
            bridgePort = configuredPort
        }
        if let configuredControlPort = Self.intValue(
            for: "VISIONCRAFT_CONTROL_PORT",
            arguments: arguments,
            environment: environment
        ) {
            controlPort = configuredControlPort
        }
        autoStartBridge = !Self.boolValue(
            for: "VISIONCRAFT_NO_AUTO_START_BRIDGE",
            arguments: arguments,
            environment: environment
        )
        autoStartAlvr = !Self.boolValue(
            for: "VISIONCRAFT_NO_AUTO_START_ALVR",
            arguments: arguments,
            environment: environment
        )
    }

    func startControlApi() {
        do {
            try controlApiServer.start(port: controlPort) { [weak self] request in
                await self?.handleControlRequest(request) ?? .json(status: 503, #"{"error":"unavailable"}"#)
            }
            diagnosticText = "Control API listening on :\(controlPort)"
        } catch {
            diagnosticText = "Control API failed: \(error.localizedDescription)"
        }
    }

    func startBridge() {
        bridgeServer.appModel = self
        bridgeServer.posePublisher = posePublisher
        bridgeServer.alvr = alvr
        do {
            try bridgeServer.start(port: bridgePort)
            bridgeRunning = true
            diagnosticText = "Bridge listening on :\(bridgePort)"
        } catch {
            bridgeRunning = false
            diagnosticText = "Bridge failed: \(error.localizedDescription)"
        }
    }

    func stopBridge() {
        bridgeServer.stop()
        bridgeRunning = false
        diagnosticText = "Bridge stopped"
    }

    func startAlvr(enableSyntheticFrames: Bool = false) {
        alvr.onUplinkLine = { [weak self] line in
            self?.bridgeServer.forwardUplink(line)
        }
        alvr.onStatus = { [weak self] status in
            Task { @MainActor in self?.diagnosticText = status }
        }
        alvr.onClientConnectionChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                self.alvrClientConnected = connected
                self.posePublisher.setSuppressLocalPose(connected)
                self.posePublisher.setSuppressLocalViewConfig(connected)
                if !connected {
                    self.sessionState = .closed
                    self.bridgeStreamingReady = false
                    self.bridgeServer.broadcastSession(.closed)
                    self.framesReceived = 0
                    self.lastFrameId = 0
                    self.framesEncoded = 0
                    self.alvrFramesSent = 0
                    self.diagnosticText = "ALVR headset disconnected"
                } else {
                    self.diagnosticText = "ALVR headset connected; waiting for tracking"
                }
            }
        }
        alvr.onBridgeSessionState = { [weak self] session in
            self?.bridgeServer.broadcastSession(session)
            Task { @MainActor in
                guard let self else { return }
                self.sessionState = session
                self.bridgeStreamingReady = session == .ready
            }
        }
        alvr.start(enableSyntheticFrames: enableSyntheticFrames)
        alvrRunning = true
        framesEncoded = 0
        alvrFramesSent = 0
        refreshAlvrStats()
    }

    func stopAlvr() {
        alvr.stop()
        alvrRunning = false
        alvrClientConnected = false
        framesEncoded = 0
        alvrFramesSent = 0
        posePublisher.setSuppressLocalPose(false)
        posePublisher.setSuppressLocalViewConfig(false)
        sessionState = .closed
        bridgeServer.broadcastSession(sessionState)
        diagnosticText = "ALVR stopped"
    }

    func refreshAlvrStats() {
        let snapshot = alvr.snapshot()
        alvrRunning = snapshot.running
        alvrClientConnected = snapshot.clientConnected
        framesEncoded = snapshot.framesEncoded
        alvrFramesSent = snapshot.framesSent
        alvrTargetEyeWidth = snapshot.targetEyeWidth
        alvrTargetEyeHeight = snapshot.targetEyeHeight
        alvrLastTrackingTimestampNs = snapshot.lastTrackingSampleTimestampNs
        alvrLastVideoTimestampNs = snapshot.lastVideoTargetTimestampNs
        bridgeStreamingReady = snapshot.bridgeStreamingReady
        sentVideoConfig = snapshot.sentVideoConfig
        syntheticFramesEnabled = snapshot.syntheticFramesEnabled
        framesDroppedNoConfig = snapshot.framesDroppedNoConfig
        if snapshot.clientConnected, !snapshot.bridgeStreamingReady {
            sessionState = .paused
        }
    }

    private func handleControlRequest(_ request: ControlApiServer.Request) async -> ControlApiServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(#"{"ok":true}"#)
        case ("GET", "/ready"):
            return .json(status: pipelineReady ? 200 : 503, statusJson())
        case ("GET", "/status"):
            return .json(statusJson())
        case ("POST", "/bridge/start"):
            if let port = request.query["port"].flatMap(Int.init) {
                bridgePort = port
            }
            startBridge()
            return .json(statusJson())
        case ("POST", "/bridge/stop"):
            stopBridge()
            return .json(statusJson())
        case ("POST", "/alvr/start"):
            let synthetic = request.query["synthetic"].map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? false
            startAlvr(enableSyntheticFrames: synthetic)
            return .json(statusJson())
        case ("POST", "/alvr/stop"):
            stopAlvr()
            return .json(statusJson())
        case ("POST", "/debug/capture"):
            let frames = request.query["frames"].flatMap(Int.init) ?? 1
            // Force an IDR so the self-decode roundtrip starts from a clean keyframe.
            alvr.requestKeyframe()
            let path = FrameCapture.shared.arm(
                frames: frames, repoRoot: Self.repoRootPath(), header: alvr.captureHeaderJSON())
            let body = "{\"ok\":true,\"frames\":\(frames),\"bundle\":\"\(Self.escapeJson(path))\"}"
            return .json(body)
        default:
            return .json(status: 404, #"{"error":"not_found"}"#)
        }
    }

    private func statusJson() -> String {
        refreshAlvrStats()
        return """
        {"ok":true,"pipeline_ready":\(pipelineReady),"bridge_running":\(bridgeRunning),"bridge_port":\(bridgePort),"control_port":\(controlPort),"alvr_running":\(alvrRunning),"alvr_client_connected":\(alvrClientConnected),"bridge_streaming_ready":\(bridgeStreamingReady),"sent_video_config":\(sentVideoConfig),"synthetic_frames_enabled":\(syntheticFramesEnabled),"alvr_frames_sent":\(alvrFramesSent),"alvr_target_eye_width":\(alvrTargetEyeWidth),"alvr_target_eye_height":\(alvrTargetEyeHeight),"alvr_last_tracking_timestamp_ns":\(alvrLastTrackingTimestampNs),"alvr_last_video_timestamp_ns":\(alvrLastVideoTimestampNs),"frames_encoded":\(framesEncoded),"frames_dropped_no_config":\(framesDroppedNoConfig),"session_state":"\(sessionState.rawValue)","frames_received":\(framesReceived),"last_frame_id":\(lastFrameId),"diagnostic":"\(Self.escapeJson(diagnosticText))","next_step":"\(Self.escapeJson(nextStepTitle))"}
        """
    }

    func copyVerifyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("scripts/vc.sh verify", forType: .string)
        diagnosticText = "Copied verification command"
    }

    func openRunbook() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(Self.repoRootPath())/docs/alvr-hardware-playbook.md"))
    }

    func revealBetaBundle() {
        let url = URL(fileURLWithPath: "\(Self.repoRootPath())/.run/beta")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum BridgeSessionState: String {
    case ready, paused, lost, closed
}

private extension VisionCraftAppModel {
    static func repoRootPath() -> String {
        if let env = ProcessInfo.processInfo.environment["VISIONCRAFT_REPO_ROOT"], !env.isEmpty {
            return env
        }
        let bundlePath = Bundle.main.bundleURL.path
        if let range = bundlePath.range(of: "/mac-host/build/") {
            return String(bundlePath[..<range.lowerBound])
        }
        return FileManager.default.currentDirectoryPath
    }

    static func escapeJson(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func boolValue(
        for key: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        let dashed = dashedArgumentName(for: key)
        let shortDashed = dashed.replacingOccurrences(of: "--visioncraft-", with: "--")
        if arguments.contains(dashed) || arguments.contains(shortDashed) {
            return true
        }
        guard let raw = environment[key]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    static func intValue(
        for key: String,
        arguments: [String],
        environment: [String: String]
    ) -> Int? {
        if let value = environment[key], let port = Int(value) {
            return port
        }

        let dashed = dashedArgumentName(for: key)
        let shortDashed = dashed.replacingOccurrences(of: "--visioncraft-", with: "--")
        for (index, argument) in arguments.enumerated() {
            if (argument == dashed || argument == shortDashed),
               arguments.indices.contains(index + 1),
               let port = Int(arguments[index + 1]) {
                return port
            }

            for prefix in ["\(dashed)=", "\(shortDashed)="] {
                if argument.hasPrefix(prefix),
                   let port = Int(argument.dropFirst(prefix.count)) {
                    return port
                }
            }
        }

        return nil
    }

    static func dashedArgumentName(for key: String) -> String {
        "--\(key.lowercased().replacingOccurrences(of: "_", with: "-"))"
    }
}
