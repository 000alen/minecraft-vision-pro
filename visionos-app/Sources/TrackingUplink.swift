import Foundation
import ARKit
import simd
import QuartzCore

/// Reads on-device head + hand tracking and emits `pose`/`hand` lines (exactly as defined in
/// `bridge/protocol.md`) through `sendLine`. These travel to the Mac relay as `UPLINK` envelopes
/// and are forwarded into the loopback bridge unchanged, so Minecraft's existing consumers see
/// them as if a local host produced them.
///
/// This is the capability the macOS RemoteImmersiveSpace host lacks: `HandTrackingProvider` is a
/// local on-device feature, so only an on-device app can vend real pinch input.
final class TrackingUplink {
    /// Set by the owner to forward a newline-terminated JSON line to the network client.
    var sendLine: ((String) -> Void)?

    private let worldTracking: WorldTrackingProvider
    private let handTracking: HandTrackingProvider
    private let handTrackingEnabled: Bool

    private let lock = NSLock()
    private var latestLeft: HandAnchor?
    private var latestRight: HandAnchor?
    private var recenterCounter = 0
    private var running = false
    /// Head pose sample time in ARKit session seconds (from `LayerRenderer` presentation time).
    private var presentationTimestampSeconds: Double?

    init(
        worldTracking: WorldTrackingProvider,
        handTracking: HandTrackingProvider,
        handTrackingEnabled: Bool
    ) {
        self.worldTracking = worldTracking
        self.handTracking = handTracking
        self.handTrackingEnabled = handTrackingEnabled
    }

    /// Called from the compositor render thread so pose matches the frame being displayed.
    func setPresentationTimestamp(seconds: Double) {
        lock.lock()
        presentationTimestampSeconds = seconds
        lock.unlock()
    }

    func recenter() {
        lock.lock()
        recenterCounter += 1
        let counter = recenterCounter
        lock.unlock()
        sendLine?("{\"type\":\"recenter\",\"version\":1,\"recenter_counter\":\(counter)}\n")
    }

    /// Apply a `recenter` line forwarded from Java via the Mac relay (`DOWNLINK`).
    func handleDownlinkLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "recenter",
              let counter = obj["recenter_counter"] as? Int else { return }
        lock.lock()
        recenterCounter = counter
        lock.unlock()
    }

    func stop() { running = false }

    /// Runs until the immersive space closes. Pumps hand anchor updates into `latest*` and
    /// publishes pose + hand at a steady cadence.
    func run() async {
        running = true
        await withTaskGroup(of: Void.self) { group in
            if handTrackingEnabled {
                group.addTask { [weak self] in await self?.pumpHandUpdates() }
            }
            group.addTask { [weak self] in await self?.publishLoop() }
        }
    }

    private func pumpHandUpdates() async {
        for await update in handTracking.anchorUpdates {
            let anchor = update.anchor
            lock.lock()
            switch anchor.chirality {
            case .left: latestLeft = anchor
            case .right: latestRight = anchor
            @unknown default: break
            }
            lock.unlock()
            if !running { break }
        }
    }

    private func publishLoop() async {
        // ~90 Hz. A fixed cadence keeps `pose` and `hand` aligned and matches the device frame rate.
        let intervalNanos: UInt64 = 11_111_111
        while running {
            publishPose()
            publishHands()
            try? await Task.sleep(nanoseconds: intervalNanos)
        }
    }

    private func publishPose() {
        lock.lock()
        let sampleTime = presentationTimestampSeconds ?? CACurrentMediaTime()
        let counter = recenterCounter
        lock.unlock()

        let anchor = worldTracking.queryDeviceAnchor(atTimestamp: sampleTime)
        let ts = Self.epochNanos()

        guard let anchor, anchor.isTracked else {
            sendLine?("{\"type\":\"pose\",\"version\":1,\"timestamp_ns\":\(ts),\"position_m\":[0,1.65,0],\"orientation_xyzw\":[0,0,0,1],\"tracking_state\":\"\(anchor == nil ? "unavailable" : "lost")\",\"recenter_counter\":\(counter)}\n")
            return
        }
        let transform = anchor.originFromAnchorTransform
        let p = transform.columns.3
        let q = simd_quatf(transform).vector
        sendLine?("{\"type\":\"pose\",\"version\":1,\"timestamp_ns\":\(ts),\"position_m\":[\(StereoMath.fmt(p.x)),\(StereoMath.fmt(p.y)),\(StereoMath.fmt(p.z))],\"orientation_xyzw\":[\(StereoMath.fmt(q.x)),\(StereoMath.fmt(q.y)),\(StereoMath.fmt(q.z)),\(StereoMath.fmt(q.w))],\"tracking_state\":\"valid\",\"recenter_counter\":\(counter)}\n")
    }

    private func publishHands() {
        guard handTrackingEnabled else { return }

        lock.lock()
        let left = latestLeft
        let right = latestRight
        lock.unlock()

        let ts = Self.epochNanos()
        var fragments: [String] = []
        if let frag = Self.handFragment(left, chirality: "left") { fragments.append(frag) }
        if let frag = Self.handFragment(right, chirality: "right") { fragments.append(frag) }
        if fragments.isEmpty {
            fragments = [
                Self.untrackedHandFragment(chirality: "left"),
                Self.untrackedHandFragment(chirality: "right"),
            ]
        }
        sendLine?("{\"type\":\"hand\",\"version\":1,\"timestamp_ns\":\(ts),\"hands\":[\(fragments.joined(separator: ","))]}\n")
    }

    private static func untrackedHandFragment(chirality: String) -> String {
        "{\"chirality\":\"\(chirality)\",\"tracked\":false,\"position_m\":[0,0,0],\"orientation_xyzw\":[0,0,0,1],\"pinch\":0,\"pinch_middle\":0}"
    }

    private static func handFragment(_ anchor: HandAnchor?, chirality: String) -> String? {
        guard let anchor else { return nil }
        guard anchor.isTracked else {
            return untrackedHandFragment(chirality: chirality)
        }
        let transform = anchor.originFromAnchorTransform
        let p = transform.columns.3
        let q = simd_quatf(transform).vector
        let pinch = HandPinch.strength(for: anchor) ?? 0
        let pinchMiddle = HandPinch.middleStrength(for: anchor) ?? 0
        return "{\"chirality\":\"\(chirality)\",\"tracked\":true,\"position_m\":[\(StereoMath.fmt(p.x)),\(StereoMath.fmt(p.y)),\(StereoMath.fmt(p.z))],\"orientation_xyzw\":[\(StereoMath.fmt(q.x)),\(StereoMath.fmt(q.y)),\(StereoMath.fmt(q.z)),\(StereoMath.fmt(q.w))],\"pinch\":\(StereoMath.fmt(pinch)),\"pinch_middle\":\(StereoMath.fmt(pinchMiddle))}"
    }

    private static func epochNanos() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
}
