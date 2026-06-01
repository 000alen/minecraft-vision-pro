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

    private let lock = NSLock()
    private var latestLeft: HandAnchor?
    private var latestRight: HandAnchor?
    private var recenterCounter = 0
    private var running = false

    init(worldTracking: WorldTrackingProvider, handTracking: HandTrackingProvider) {
        self.worldTracking = worldTracking
        self.handTracking = handTracking
    }

    func recenter() {
        lock.lock()
        recenterCounter += 1
        let counter = recenterCounter
        lock.unlock()
        sendLine?("{\"type\":\"recenter\",\"version\":1,\"recenter_counter\":\(counter)}\n")
    }

    func stop() { running = false }

    /// Runs until the immersive space closes. Pumps hand anchor updates into `latest*` and
    /// publishes pose + hand at a steady cadence.
    func run() async {
        running = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.pumpHandUpdates() }
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
        let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        let ts = Self.epochNanos()
        lock.lock(); let counter = recenterCounter; lock.unlock()

        guard let anchor, anchor.isTracked else {
            sendLine?("{\"type\":\"pose\",\"version\":1,\"timestamp_ns\":\(ts),\"position_m\":[0,1.65,0],\"orientation_xyzw\":[0,0,0,1],\"tracking_state\":\"\(anchor == nil ? "unavailable" : "lost")\",\"recenter_counter\":\(counter)}\n")
            return
        }
        let transform = anchor.originFromAnchorTransform
        let p = transform.columns.3
        let q = simd_quatf(transform).vector
        sendLine?("{\"type\":\"pose\",\"version\":1,\"timestamp_ns\":\(ts),\"position_m\":[\(Self.f(p.x)),\(Self.f(p.y)),\(Self.f(p.z))],\"orientation_xyzw\":[\(Self.f(q.x)),\(Self.f(q.y)),\(Self.f(q.z)),\(Self.f(q.w))],\"tracking_state\":\"valid\",\"recenter_counter\":\(counter)}\n")
    }

    private func publishHands() {
        lock.lock()
        let left = latestLeft
        let right = latestRight
        lock.unlock()

        let ts = Self.epochNanos()
        var fragments: [String] = []
        if let frag = Self.handFragment(left, chirality: "left") { fragments.append(frag) }
        if let frag = Self.handFragment(right, chirality: "right") { fragments.append(frag) }
        guard !fragments.isEmpty else { return }
        sendLine?("{\"type\":\"hand\",\"version\":1,\"timestamp_ns\":\(ts),\"hands\":[\(fragments.joined(separator: ","))]}\n")
    }

    private static func handFragment(_ anchor: HandAnchor?, chirality: String) -> String? {
        guard let anchor else { return nil }
        guard anchor.isTracked else {
            return "{\"chirality\":\"\(chirality)\",\"tracked\":false,\"position_m\":[0,0,0],\"orientation_xyzw\":[0,0,0,1],\"pinch\":0}"
        }
        let transform = anchor.originFromAnchorTransform
        let p = transform.columns.3
        let q = simd_quatf(transform).vector
        let pinch = HandPinch.strength(for: anchor) ?? 0
        return "{\"chirality\":\"\(chirality)\",\"tracked\":true,\"position_m\":[\(f(p.x)),\(f(p.y)),\(f(p.z))],\"orientation_xyzw\":[\(f(q.x)),\(f(q.y)),\(f(q.z)),\(f(q.w))],\"pinch\":\(f(pinch))}"
    }

    private static func epochNanos() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    /// Compact, locale-independent float formatting (≈6 significant digits) for protocol JSON.
    private static func f(_ value: Float) -> String {
        String(format: "%.6g", value)
    }
}
