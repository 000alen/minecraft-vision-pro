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
    var diagnosticText: String = "Idle"

    let bridgeServer = JavaBridgeServer()
    let compositor = CompositorRenderer()
    let posePublisher = PosePublisher()

    func startBridge() {
        bridgeServer.appModel = self
        bridgeServer.compositor = compositor
        bridgeServer.posePublisher = posePublisher
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
}

enum BridgeSessionState: String {
    case ready, paused, lost, closed
}

enum VisionCraftImmersiveSpace {
    static let id = "visioncraft.immersive.main"
}
