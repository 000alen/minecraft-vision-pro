import Foundation
import Network
import os

private let bridgeLogger = Logger(subsystem: "VisionCraftHost", category: "Bridge")

enum BridgeServerError: Error, CustomStringConvertible {
    case invalidPort(Int)

    var description: String {
        switch self {
        case .invalidPort(let port): "Invalid TCP port \(port) (expected 1...65535)"
        }
    }
}

private func bridgeMessageVersion(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber:
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let intValue = number.intValue
        guard number.doubleValue == Double(intValue) else { return nil }
        return intValue
    case is Bool:
        return nil
    case let intValue as Int:
        return intValue
    default:
        return nil
    }
}

private func isBridgeV1Message(_ object: [String: Any]) -> Bool {
    bridgeMessageVersion(object["version"]) == 1
}

/// TCP server implementing bridge/protocol.md v1.
///
/// Threading: all access to `connections` and `currentSession` is confined to
/// `queue`. The listener and per-connection close callbacks marshal onto it, so
/// there is no cross-thread mutation of the connection table.
final class JavaBridgeServer {
    weak var appModel: VisionCraftAppModel?
    weak var posePublisher: PosePublisher?
    weak var alvr: AlvrServerCoordinator?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private let queue = DispatchQueue(label: "visioncraft.bridge.server")
    private var currentSession: BridgeSessionState = .closed
    private var latestViewConfigLine: String?
    private var viewConfigHeartbeat: DispatchSourceTimer?

    func start(port: Int) throws {
        guard let portValue = UInt16(exactly: port), portValue > 0 else {
            throw BridgeServerError.invalidPort(port)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: portValue)!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener?.start(queue: queue)
        posePublisher?.attach { [weak self] line in
            self?.broadcast(line)
        }
        posePublisher?.startTimer()
        startViewConfigHeartbeat()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        posePublisher?.stop()
        posePublisher?.detach()
        queue.async {
            self.viewConfigHeartbeat?.cancel()
            self.viewConfigHeartbeat = nil
            self.connections.values.forEach { $0.close(reason: "bridge server stopping") }
            self.connections.removeAll()
            self.currentSession = .closed
            self.latestViewConfigLine = nil
        }
    }

    func broadcastSession(_ state: BridgeSessionState) {
        let json = "{\"type\":\"session\",\"version\":1,\"state\":\"\(state.rawValue)\"}\n"
        let data = Data(json.utf8)
        queue.async {
            self.currentSession = state
            if state != .ready {
                self.latestViewConfigLine = nil
            }
            self.connections.values.forEach { $0.send(data) }
            if state == .ready, let latestViewConfigLine = self.latestViewConfigLine {
                let viewConfigData = Data(latestViewConfigLine.utf8)
                self.connections.values.forEach { $0.send(viewConfigData) }
            }
        }
    }

    /// Forward a verbatim `bridge/protocol.md` line received from ALVR tracking/view events to all
    /// connected Java clients. The headset is the authoritative source while it is connected.
    func forwardUplink(_ line: String) {
        let data = Data(line.utf8)
        let isViewConfig = line.contains(#""type":"view_config""#)
        queue.async {
            if isViewConfig {
                self.latestViewConfigLine = line
                guard self.currentSession == .ready else { return }
            }
            self.connections.values.forEach { $0.send(data) }
        }
    }

    private func broadcast(_ line: String) {
        let data = Data(line.utf8)
        queue.async {
            self.connections.values.forEach { $0.send(data) }
        }
    }

    private func accept(_ connection: NWConnection) {
        // Loopback-only: the bridge is a localhost IPC channel. Reject any peer
        // that is not 127.0.0.0/8 or ::1 so the server is never reachable off-box.
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        let bridge = BridgeConnection(connection: connection)
        bridge.onFrame = { [weak self] left, right, w, h, frameId, renderSampleTimestampNs in
            Task { @MainActor in
                self?.appModel?.lastFrameId = frameId
                self?.appModel?.framesReceived += 1
            }
            // Debug capture: dump the raw per-eye RGBA8 exactly as received from Java, before any
            // host processing. Copies the slices to contiguous Data. Off unless /debug/capture armed.
            if FrameCapture.shared.wantsRecv {
                FrameCapture.shared.captureReceived(left: Data(left), right: Data(right),
                                                    width: w, height: h, frameId: frameId)
            }
            self?.alvr?.submitFrame(left: left, right: right, eyeWidth: w, eyeHeight: h,
                                    frameId: frameId, renderSampleTimestampNs: renderSampleTimestampNs)
        }
        bridge.onLine = { [weak self] line in
            self?.handleClientLine(line, bridge: bridge)
        }
        let id = ObjectIdentifier(connection)
        connections[id] = bridge
        bridge.onClose = { [weak self] in
            guard let self else { return }
            self.queue.async { self.connections.removeValue(forKey: id) }
        }
        bridge.start()
        if currentSession != .closed {
            bridge.send("{\"type\":\"session\",\"version\":1,\"state\":\"\(currentSession.rawValue)\"}\n")
        }
        if currentSession == .ready, let latestViewConfigLine {
            bridge.send(latestViewConfigLine)
        }
    }

    private func startViewConfigHeartbeat() {
        queue.async {
            guard self.viewConfigHeartbeat == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
            timer.setEventHandler { [weak self] in
                guard let self,
                      self.currentSession == .ready,
                      let line = self.latestViewConfigLine else { return }
                let data = Data(line.utf8)
                self.connections.values.forEach { $0.send(data) }
            }
            self.viewConfigHeartbeat = timer
            timer.resume()
        }
    }

    /// True if a Network endpoint is an IPv4 (127.0.0.0/8) or IPv6 (::1) loopback
    /// address, or the literal "localhost". Used to keep the TCP servers local-only.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == .loopback || "\(address)".hasPrefix("127.")
        case .ipv6(let address):
            return address == .loopback || "\(address)" == "::1"
        case .name(let name, _):
            return name == "localhost" || name.hasSuffix(".localhost")
        @unknown default:
            return false
        }
    }

    private func handleClientLine(_ line: String, bridge: BridgeConnection) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "recenter":
            guard isBridgeV1Message(obj) else {
                bridge.close(reason: "recenter version mismatch")
                return
            }
            let counter: UInt64
            if let alvrCounter = alvr?.recordRecenter() {
                counter = alvrCounter
            } else {
                posePublisher?.recenter()
                counter = UInt64(posePublisher?.recenterCounter ?? 0)
            }
            let line = "{\"type\":\"recenter\",\"version\":1,\"recenter_counter\":\(counter)}\n"
            broadcast(line)
        case "ping":
            guard isBridgeV1Message(obj) else {
                bridge.close(reason: "ping version mismatch")
                return
            }
            if let ts = obj["timestamp_ns"] {
                bridge.send("{\"type\":\"pong\",\"version\":1,\"timestamp_ns\":\(ts)}\n")
            }
        case "haptic":
            guard isBridgeV1Message(obj) else {
                bridge.close(reason: "haptic version mismatch")
                return
            }
            guard let hand = obj["hand"] as? String,
                  hand == "left" || hand == "right" else { break }
            let duration = Self.floatField(obj["duration_s"], fallback: 0.02)
            let frequency = Self.floatField(obj["frequency_hz"], fallback: 120)
            let amplitude = Self.floatField(obj["amplitude"], fallback: 0.5)
            alvr?.sendHaptics(hand: hand, durationSeconds: duration, frequency: frequency, amplitude: amplitude)
        default:
            break
        }
    }

    private static func floatField(_ value: Any?, fallback: Float) -> Float {
        switch value {
        case let value as Float:
            return value
        case let value as Double:
            return Float(value)
        case let value as Int:
            return Float(value)
        case let value as NSNumber:
            return value.floatValue
        default:
            return fallback
        }
    }
}

// MARK: - Connection

private final class BridgeConnection {
    let connection: NWConnection
    var onFrame: ((Data, Data, Int, Int, UInt64, UInt64) -> Void)?
    var onLine: ((String) -> Void)?
    var onClose: (() -> Void)?

    private static let maxFramePayloadBytes = 256 * 1024 * 1024

    private let queue = DispatchQueue(label: "visioncraft.bridge.connection")
    private let closeLock = NSLock()
    private var closed = false
    private var buffer = Data()
    private var pendingMeta: [String: Any]?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(reason: "network state \(String(describing: state))")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close(reason: String = "closed") {
        closeLock.lock()
        guard !closed else {
            closeLock.unlock()
            return
        }
        closed = true
        closeLock.unlock()

        bridgeLogger.error("Bridge connection closing: \(reason, privacy: .public)")
        connection.cancel()
        onClose?()
    }

    func send(_ string: String) {
        send(Data(string.utf8))
    }

    func send(_ data: Data) {
        let payload = Data(data)
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.close(reason: "send failed: \(String(describing: error))")
                }
            })
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if error != nil {
                self.close(reason: "receive failed: \(String(describing: error))")
                return
            }
            if let data {
                self.buffer.append(data)
                self.processBuffer()
            }
            guard !self.isClosed else { return }
            if isComplete {
                self.close(reason: "peer completed receive")
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        while true {
            if let meta = pendingMeta {
                guard consumeFrameBinary(meta: meta) else { break }
                pendingMeta = nil
                continue
            }
            guard let newline = buffer.firstIndex(of: 0x0A) else { break }
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                // If a header is malformed, we cannot know whether binary bytes follow.
                close(reason: "malformed line header")
                break
            }
            if type == "frame" {
                guard isBridgeV1Message(json) else {
                    close(reason: "frame version mismatch")
                    break
                }
                bridgeLogger.info("Frame header accepted")
                pendingMeta = json
            } else {
                onLine?(line)
            }
        }
    }

    private func consumeFrameBinary(meta: [String: Any]) -> Bool {
        guard let left = meta["left"] as? [String: Any],
              let right = meta["right"] as? [String: Any],
              let lw = bridgeMessageVersion(left["width"]),
              let lh = bridgeMessageVersion(left["height"]),
              let rw = bridgeMessageVersion(right["width"]),
              let rh = bridgeMessageVersion(right["height"]),
              let leftLen = bridgeMessageVersion(left["byte_length"]),
              let rightLen = bridgeMessageVersion(right["byte_length"]),
              lw > 0, lh > 0, rw > 0, rh > 0,
              leftLen >= 0, rightLen >= 0,
              leftLen <= Int.max - rightLen else {
            // Unparseable metadata: we cannot know the payload size, so the stream is
            // unrecoverable. Drop the connection rather than desync silently.
            close(reason: "unparseable frame metadata")
            return false
        }

        let frameId: UInt64
        if let n = meta["frame_id"] as? NSNumber {
            frameId = n.uint64Value
        } else if let n = meta["frame_id"] as? UInt64 {
            frameId = n
        } else {
            close(reason: "missing frame_id")
            return false
        }

        let total = leftLen + rightLen
        guard total <= Self.maxFramePayloadBytes else {
            close(reason: "frame payload too large: \(total)")
            return false
        }
        bridgeLogger.info("Frame metadata id=\(frameId) size=\(lw)x\(lh) payload=\(total)")
        guard buffer.count >= total else { return false }

        // ALVR sample timestamp the frame was rendered for: Vivecraft echoes the pose's
        // sample_timestamp_ns here, and the host submits the frame under it so the client matches
        // the head pose it predicted for that sample. 0 ⇒ no correlation; the host drops the frame.
        let renderSampleTimestampNs = (meta["timestamp_ns"] as? NSNumber)?.uint64Value ?? 0

        // Frame the payload using byte_length (authoritative for the wire), but only
        // hand a frame to the renderer when the declared bytes actually match the
        // RGBA8 dimensions. A mismatch is dropped (per protocol.md) without desyncing.
        let expectedLeftBytes = Self.rgbaByteCount(width: lw, height: lh)
        let expectedRightBytes = Self.rgbaByteCount(width: rw, height: rh)
        if expectedLeftBytes == leftLen && expectedRightBytes == rightLen && lw == rw && lh == rh {
            bridgeLogger.info("Frame payload complete id=\(frameId) size=\(lw)x\(lh)")
            // `onFrame` consumes synchronously (texture upload), so pass the buffer
            // slices directly — no extra ~10 MB/eye copy before the GPU upload.
            // Compaction below happens only after the handler returns.
            onFrame?(buffer.prefix(leftLen), buffer.dropFirst(leftLen).prefix(rightLen), lw, lh,
                     frameId, renderSampleTimestampNs)
        } else {
            bridgeLogger.warning(
                "Frame payload dropped id=\(frameId): metadata \(lw)x\(lh) rgba8=\(expectedLeftBytes ?? -1)+\(expectedRightBytes ?? -1) bytes, wire byte_length=\(leftLen)+\(rightLen)"
            )
        }
        buffer.removeFirst(total)
        return true
    }

    private var isClosed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return closed
    }

    private static func rgbaByteCount(width: Int, height: Int) -> Int? {
        guard width <= Int.max / height else { return nil }
        let pixels = width * height
        guard pixels <= Int.max / 4 else { return nil }
        return pixels * 4
    }
}
