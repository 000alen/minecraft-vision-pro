import Foundation
import simd

/// Publishes head pose to connected Java clients (simulated until device tracking is wired).
final class PosePublisher {
    private(set) var recenterCounter = 0
    private var timer: DispatchSourceTimer?
    private weak var sendLine: ((String) -> Void)?

    var simulatedYaw: Float = 0

    func startPublishing(send: @escaping (String) -> Void) {
        sendLine = send
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

    private func tick() {
        simulatedYaw += 0.002
        let half = simulatedYaw / 2
        let qx: Float = 0
        let qy = sin(half)
        let qz: Float = 0
        let qw = cos(half)
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let json = """
        {"type":"pose","version":1,"timestamp_ns":\(ts),"position_m":[0.0,1.65,0.0],"orientation_xyzw":[\(qx),\(qy),\(qz),\(qw)],"tracking_state":"valid","recenter_counter":\(recenterCounter)}
        """
        sendLine?(json + "\n")
    }
}
