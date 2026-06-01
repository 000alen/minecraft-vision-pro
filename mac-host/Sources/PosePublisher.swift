import Foundation
import simd

#if canImport(ARKit)
import ARKit
#endif

/// Publishes head pose to all connected Java clients at 72 Hz.
final class PosePublisher {
    private struct PoseSample {
        let position: SIMD3<Float>
        let orientation: simd_quatf
        let trackingState: String
    }

    private(set) var recenterCounter = 0
    private var timer: DispatchSourceTimer?
    private var sendToAll: ((String) -> Void)?
    private var simulatedYaw: Float = 0
    private var latestPose: PoseSample?
    private let lock = NSLock()

    func attach(broadcast: @escaping (String) -> Void) {
        sendToAll = broadcast
        if timer == nil {
            startTimer()
        }
    }

    func detach() {
        sendToAll = nil
    }

    func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: 1.0 / 72.0)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func recenter() {
        recenterCounter += 1
        simulatedYaw = 0
    }

    #if canImport(ARKit)
    @available(macOS 26.0, *)
    func update(anchor: DeviceAnchor?) {
        lock.lock()
        defer { lock.unlock() }

        guard let anchor else {
            latestPose = PoseSample(
                position: SIMD3<Float>(0, 1.65, 0),
                orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                trackingState: "unavailable"
            )
            return
        }

        let transform = anchor.originFromAnchorTransform
        latestPose = PoseSample(
            position: SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
            orientation: simd_quatf(transform),
            trackingState: anchor.isTracked ? "valid" : "lost"
        )
    }
    #endif

    func tick() {
        let pose = currentPose()
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let json = """
        {"type":"pose","version":1,"timestamp_ns":\(ts),"position_m":[\(pose.position.x),\(pose.position.y),\(pose.position.z)],"orientation_xyzw":[\(pose.orientation.vector.x),\(pose.orientation.vector.y),\(pose.orientation.vector.z),\(pose.orientation.vector.w)],"tracking_state":"\(pose.trackingState)","recenter_counter":\(recenterCounter)}
        """
        sendToAll?(json + "\n")
    }

    private func currentPose() -> PoseSample {
        lock.lock()
        let pose = latestPose
        lock.unlock()

        if let pose {
            return pose
        }

        simulatedYaw += 0.002
        return PoseSample(
            position: SIMD3<Float>(0, 1.65, 0),
            orientation: simd_quatf(angle: simulatedYaw, axis: SIMD3<Float>(0, 1, 0)),
            trackingState: "valid"
        )
    }
}
