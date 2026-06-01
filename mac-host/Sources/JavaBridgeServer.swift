import Foundation
import Network

enum BridgeServerError: Error, CustomStringConvertible {
    case invalidPort(Int)

    var description: String {
        switch self {
        case .invalidPort(let port): "Invalid TCP port \(port) (expected 1...65535)"
        }
    }
}

/// TCP server implementing bridge/protocol.md v1.
///
/// Threading: all access to `connections` and `currentSession` is confined to
/// `queue`. The listener and per-connection close callbacks marshal onto it, so
/// there is no cross-thread mutation of the connection table.
final class JavaBridgeServer {
    weak var appModel: VisionCraftAppModel?
    weak var compositor: CompositorRenderer?
    weak var posePublisher: PosePublisher?
    weak var relay: StreamRelayCoordinator?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private let queue = DispatchQueue(label: "visioncraft.bridge.server")
    private var currentSession: BridgeSessionState = .closed

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
    }

    func stop() {
        listener?.cancel()
        listener = nil
        posePublisher?.stop()
        posePublisher?.detach()
        queue.async {
            self.connections.values.forEach { $0.close() }
            self.connections.removeAll()
            self.currentSession = .closed
        }
    }

    func broadcastSession(_ state: BridgeSessionState) {
        let json = "{\"type\":\"session\",\"version\":1,\"state\":\"\(state.rawValue)\"}\n"
        let data = Data(json.utf8)
        queue.async {
            self.currentSession = state
            self.connections.values.forEach { $0.send(data) }
        }
    }

    /// Forward a verbatim `bridge/protocol.md` line received over the companion uplink (pose /
    /// hand / view_config / recenter) to all connected Java clients. The companion is the
    /// authoritative source for these while it is connected.
    func forwardUplink(_ line: String) {
        broadcast(line)
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
        bridge.onFrame = { [weak self] left, right, w, h, frameId in
            Task { @MainActor in
                self?.appModel?.lastFrameId = frameId
                self?.appModel?.framesReceived += 1
            }
            // Local immersive path (RemoteImmersiveSpace) and the companion relay path are
            // independent sinks for the same frame; either, both, or neither may be active.
            self?.compositor?.uploadFrame(left: left, right: right, width: w, height: h)
            self?.relay?.submitFrame(left: left, right: right, width: w, height: h, frameId: frameId)
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
            posePublisher?.recenter()
            let counter = posePublisher?.recenterCounter ?? 0
            broadcast("{\"type\":\"recenter\",\"version\":1,\"recenter_counter\":\(counter)}\n")
        case "ping":
            if let ts = obj["timestamp_ns"] {
                bridge.send("{\"type\":\"pong\",\"version\":1,\"timestamp_ns\":\(ts)}\n")
            }
        default:
            break
        }
    }
}

// MARK: - Connection

private final class BridgeConnection {
    let connection: NWConnection
    var onFrame: ((Data, Data, Int, Int, UInt64) -> Void)?
    var onLine: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var pendingMeta: [String: Any]?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.onClose?() }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    func close() {
        connection.cancel()
        onClose?()
    }

    func send(_ string: String) {
        send(Data(string.utf8))
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.close()
                return
            }
            if let data {
                self.buffer.append(data)
                self.processBuffer()
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
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if line.contains("\"type\":\"frame\"") {
                if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    pendingMeta = json
                } else {
                    // A frame header we can't parse means we can't know the binary
                    // payload length that follows, so the stream is desynced. Drop the
                    // connection rather than scan the binary payload as if it were text.
                    close()
                    break
                }
            } else {
                onLine?(line)
            }
        }
    }

    private func consumeFrameBinary(meta: [String: Any]) -> Bool {
        guard let left = meta["left"] as? [String: Any],
              let right = meta["right"] as? [String: Any],
              let lw = left["width"] as? Int,
              let lh = left["height"] as? Int,
              let rw = right["width"] as? Int,
              let rh = right["height"] as? Int,
              let leftLen = left["byte_length"] as? Int,
              let rightLen = right["byte_length"] as? Int,
              lw > 0, lh > 0, rw > 0, rh > 0,
              leftLen >= 0, rightLen >= 0 else {
            // Unparseable metadata: we cannot know the payload size, so the stream is
            // unrecoverable. Drop the connection rather than desync silently.
            close()
            return false
        }

        let frameId: UInt64
        if let n = meta["frame_id"] as? NSNumber {
            frameId = n.uint64Value
        } else if let n = meta["frame_id"] as? UInt64 {
            frameId = n
        } else {
            close()
            return false
        }

        let total = leftLen + rightLen
        guard buffer.count >= total else { return false }

        // Frame the payload using byte_length (authoritative for the wire), but only
        // hand a frame to the renderer when the declared bytes actually match the
        // RGBA8 dimensions. A mismatch is dropped (per protocol.md) without desyncing.
        if leftLen == lw * lh * 4 && rightLen == rw * rh * 4 && lw == rw && lh == rh {
            // `onFrame` consumes synchronously (texture upload), so pass the buffer
            // slices directly — no extra ~10 MB/eye copy before the GPU upload.
            // Compaction below happens only after the handler returns.
            onFrame?(buffer.prefix(leftLen), buffer.dropFirst(leftLen).prefix(rightLen), lw, lh, frameId)
        }
        buffer.removeFirst(total)
        return true
    }
}
