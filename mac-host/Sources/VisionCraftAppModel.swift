import Foundation
import Observation

@MainActor
@Observable
final class VisionCraftAppModel {
    var immersiveSpaceOpen = false
    var sessionState: BridgeSessionState = .closed
    var lastFrameId: UInt64 = 0
    var framesReceived: UInt64 = 0
    var bridgePort: Int = 19735
    var controlPort: Int = 19734
    var relayPort: Int = 19736
    var relayToken: String = ""
    var diagnosticText: String = "Idle"
    var autoStartBridge = true
    var autoStartRelay = true
    var autoOpenImmersive = false
    var supportsRemoteScenes = false
    var remoteDeviceIdentifierAvailable = false
    var arTrackingState = "unavailable"
    var relayRunning = false
    var relayViewerConnected = false
    var framesEncoded: UInt64 = 0

    let bridgeServer = JavaBridgeServer()
    let controlApiServer = ControlApiServer()
    let compositor = CompositorRenderer()
    let posePublisher = PosePublisher()
    let relay: StreamRelayCoordinator

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
        var resolvedRelayPort = 19736 // mirrors the `relayPort` default below
        if let configuredRelayPort = Self.intValue(
            for: "VISIONCRAFT_RELAY_PORT",
            arguments: arguments,
            environment: environment
        ) {
            resolvedRelayPort = configuredRelayPort
        }
        let resolvedRelayToken = environment["VISIONCRAFT_RELAY_TOKEN"] ?? ""

        // Initialize `relay` before any `self.` property reads (all stored properties must be set
        // before `self` is usable in init).
        relayPort = resolvedRelayPort
        relayToken = resolvedRelayToken
        relay = StreamRelayCoordinator(port: UInt16(clamping: resolvedRelayPort), token: resolvedRelayToken)

        autoStartBridge = !Self.boolValue(
            for: "VISIONCRAFT_NO_AUTO_START_BRIDGE",
            arguments: arguments,
            environment: environment
        )
        autoStartRelay = !Self.boolValue(
            for: "VISIONCRAFT_NO_AUTO_START_RELAY",
            arguments: arguments,
            environment: environment
        )
        autoOpenImmersive = Self.boolValue(
            for: "VISIONCRAFT_AUTO_OPEN_IMMERSIVE",
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
        bridgeServer.compositor = compositor
        bridgeServer.posePublisher = posePublisher
        bridgeServer.relay = relay
        do {
            try bridgeServer.start(port: bridgePort)
            diagnosticText = "Bridge listening on :\(bridgePort)"
            if immersiveSpaceOpen {
                bridgeServer.broadcastSession(.ready)
            }
        } catch {
            diagnosticText = "Bridge failed: \(error.localizedDescription)"
        }
    }

    func stopBridge() {
        bridgeServer.stop()
        diagnosticText = "Bridge stopped"
    }

    func startRelay() {
        // Forward the companion's on-device pose/hand/view_config straight into the loopback bridge.
        relay.onUplinkLine = { [weak self] line in
            self?.bridgeServer.forwardUplink(line)
        }
        relay.onStatus = { [weak self] status in
            Task { @MainActor in self?.diagnosticText = status }
        }
        relay.onViewerChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                self.relayViewerConnected = connected
                // While the headset is the pose source, silence the host's local pose emitter.
                self.posePublisher.setSuppressLocalPose(connected)
                self.diagnosticText = connected ? "Companion connected" : "Companion disconnected"
            }
        }
        do {
            try relay.start()
            relayRunning = true
            diagnosticText = "Relay listening on :\(relayPort) (Bonjour _visioncraft-stream._tcp)"
        } catch {
            relayRunning = false
            diagnosticText = "Relay failed: \(error.localizedDescription)"
        }
    }

    func stopRelay() {
        relay.stop()
        relayRunning = false
        relayViewerConnected = false
        posePublisher.setSuppressLocalPose(false)
        diagnosticText = "Relay stopped"
    }

    /// Pull the relay's live counters onto the main-actor observable state (called from the UI tick).
    func refreshRelayStats() {
        framesEncoded = relay.framesEncoded
        relayViewerConnected = relay.viewerConnected
    }

    func onImmersiveSpaceOpened() {
        immersiveSpaceOpen = true
        sessionState = .ready
        bridgeServer.broadcastSession(.ready)
        diagnosticText = "Immersive space active"
    }

    func onImmersiveSpaceClosed() {
        immersiveSpaceOpen = false
        sessionState = .closed
        bridgeServer.broadcastSession(.closed)
        diagnosticText = "Immersive space closed"
    }

    func setSupportsRemoteScenes(_ supported: Bool) {
        supportsRemoteScenes = supported
    }

    func setRemoteDeviceIdentifierAvailable(_ available: Bool) {
        remoteDeviceIdentifierAvailable = available
    }

    func setARTrackingState(_ state: String) {
        arTrackingState = state
    }

    private func handleControlRequest(_ request: ControlApiServer.Request) async -> ControlApiServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(#"{"ok":true}"#)
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
        case ("POST", "/relay/start"):
            if let port = request.query["port"].flatMap(Int.init) {
                relayPort = port
            }
            startRelay()
            return .json(statusJson())
        case ("POST", "/relay/stop"):
            stopRelay()
            return .json(statusJson())
        case ("POST", "/immersive/open"):
            diagnosticText = "Control API requested immersive open"
            NotificationCenter.default.post(name: .visionCraftOpenImmersiveRequest, object: nil)
            return .json(status: 202, #"{"requested":true}"#)
        case ("POST", "/immersive/closed"):
            onImmersiveSpaceClosed()
            return .json(statusJson())
        default:
            return .json(status: 404, #"{"error":"not_found"}"#)
        }
    }

    private func statusJson() -> String {
        refreshRelayStats()
        return """
        {"ok":true,"bridge_port":\(bridgePort),"control_port":\(controlPort),"relay_port":\(relayPort),"relay_running":\(relayRunning),"relay_viewer_connected":\(relayViewerConnected),"frames_encoded":\(framesEncoded),"supports_remote_scenes":\(supportsRemoteScenes),"remote_device_identifier_available":\(remoteDeviceIdentifierAvailable),"ar_tracking_state":"\(Self.escapeJson(arTrackingState))","immersive_open":\(immersiveSpaceOpen),"session_state":"\(sessionState.rawValue)","frames_received":\(framesReceived),"last_frame_id":\(lastFrameId),\(compositor.statusJsonFragment()),"diagnostic":"\(Self.escapeJson(diagnosticText))"}
        """
    }
}

enum BridgeSessionState: String {
    case ready, paused, lost, closed
}

enum VisionCraftImmersiveSpace {
    static let id = "visioncraft.immersive.main"
}

extension Notification.Name {
    static let visionCraftOpenImmersiveRequest = Notification.Name("VisionCraftOpenImmersiveRequest")
}

private extension VisionCraftAppModel {
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
