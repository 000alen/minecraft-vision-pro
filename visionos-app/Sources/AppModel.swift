import Foundation
import ARKit
import CompositorServices
import Observation

/// App-wide state and lifecycle owner. Holds the ARKit session + providers, the network stream
/// client, the tracking uplink, and the active renderer.
///
/// Not `@MainActor`: the `CompositorLayer` content closure (which calls `startImmersive`) runs off
/// the main actor and hands us a non-`Sendable` `LayerRenderer`, matching Apple's Metal-immersive
/// sample. Observable UI state is therefore mutated through `mainAsync` so SwiftUI always reads
/// values written on the main thread.
@Observable
final class AppModel {
    static let immersiveSpaceID = "ImmersiveSpace"

    enum Phase: String {
        case idle, searching, connecting, streaming, immersiveNoVideo, error
    }

    private(set) var phase: Phase = .idle
    private(set) var statusDetail = ""
    private(set) var handTrackingAuthorized = false
    private(set) var framesDecoded: UInt64 = 0

    /// Manual host override (used when Bonjour discovery is unavailable). Blank → auto-discover.
    var manualHost: String = ""
    var pairingToken: String = ""

    // ARKit (on-device). Unlike the macOS host, HandTrackingProvider IS available here.
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let handTracking = HandTrackingProvider()

    private var renderer: CompanionRenderer?
    private var uplink: TrackingUplink?
    private var streamClient: StreamClient?
    private(set) var immersiveSessionActive = false

    // MARK: - UI state (always written on main)

    private func mainAsync(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func setPhase(_ phase: Phase, detail: String) {
        mainAsync { [weak self] in
            self?.phase = phase
            if !detail.isEmpty { self?.statusDetail = detail }
        }
    }

    /// Surface a launch/immersive-open failure from the UI layer.
    func reportError(_ detail: String) {
        setPhase(.error, detail: detail)
    }

    // MARK: - Authorization

    /// Request ARKit authorizations up front so the immersive transition does not stall on a
    /// permission prompt. Called from the launch view's `.task`.
    @MainActor
    func requestAuthorizations() async {
        let result = await arSession.requestAuthorization(for: [.handTracking, .worldSensing])
        handTrackingAuthorized = result[.handTracking] == .allowed
        if !handTrackingAuthorized {
            statusDetail = "Hand tracking permission not granted — pinch input disabled."
        }
    }

    // MARK: - Immersive lifecycle

    /// Invoked from the `CompositorLayer` content closure (off the main actor) when the immersive
    /// space opens. Wires the network client, tracking uplink, and renderer, then starts them.
    func startImmersive(layerRenderer: LayerRenderer) {
        guard !immersiveSessionActive else { return }
        immersiveSessionActive = true

        let handEnabled = handTrackingAuthorized
        let uplink = TrackingUplink(
            worldTracking: worldTracking,
            handTracking: handTracking,
            handTrackingEnabled: handEnabled
        )
        self.uplink = uplink

        let client = StreamClient(
            manualHost: manualHost.isEmpty ? nil : manualHost,
            token: pairingToken,
            metalDevice: layerRenderer.device
        )
        client.onPhaseChange = { [weak self] phase, detail in
            self?.setPhase(phase, detail: detail)
        }
        uplink.sendLine = { [weak client] line in client?.sendUplink(line) }
        client.onDownlinkLine = { [weak uplink] line in uplink?.handleDownlinkLine(line) }
        self.streamClient = client

        var decodedFrameCount: UInt64 = 0
        let renderer = CompanionRenderer(
            layerRenderer: layerRenderer,
            worldTracking: worldTracking,
            videoSource: client.videoSource,
            trackingUplink: uplink,
            onFrameDecoded: { [weak self] frameID in
                self?.mainAsync {
                    guard let self else { return }
                    if frameID > 0 {
                        decodedFrameCount += 1
                        if self.phase == .immersiveNoVideo {
                            self.phase = .streaming
                        }
                        self.framesDecoded = decodedFrameCount
                    }
                }
            }
        )
        renderer.onViewConfig = { [weak client] line in client?.sendUplink(line) }
        // Fired from the render thread when the compositor layer is invalidated (system exit, e.g.
        // the Digital Crown). Hop to main so the observable lifecycle/UI state resets reliably.
        renderer.onCompositorEnded = { [weak self] in
            self?.mainAsync { self?.stopImmersive() }
        }
        self.renderer = renderer

        Task { await self.runTrackingSession(uplink: uplink, handEnabled: handEnabled) }
        client.start()
        renderer.startRenderLoop()
    }

    /// Run the ARKit providers and pump anchor updates into the uplink for the lifetime of the
    /// immersive space.
    private func runTrackingSession(uplink: TrackingUplink, handEnabled: Bool) async {
        var providers: [any DataProvider] = [worldTracking]
        if handEnabled {
            providers.append(handTracking)
        }
        do {
            try await arSession.run(providers)
        } catch {
            setPhase(.error, detail: "ARKit run failed: \(error.localizedDescription)")
            return
        }
        await uplink.run()
    }

    func stopImmersive() {
        guard immersiveSessionActive else { return }
        immersiveSessionActive = false

        renderer?.stop()
        renderer = nil
        streamClient?.stop()
        streamClient = nil
        uplink?.stop()
        uplink = nil
        arSession.stop()
        mainAsync { [weak self] in
            self?.framesDecoded = 0
            self?.phase = .idle
            self?.statusDetail = ""
        }
    }
}
