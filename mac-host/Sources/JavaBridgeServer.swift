import Foundation
import Network

/// TCP server implementing bridge/protocol.md v1.
final class JavaBridgeServer {
    weak var appModel: VisionCraftAppModel?
    weak var compositor: CompositorRenderer?
    weak var posePublisher: PosePublisher?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private let queue = DispatchQueue(label: "visioncraft.bridge.server")

    func start(port: Int) throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port))!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
    }

    func broadcastSession(_ state: BridgeSessionState) {
        let json = "{\"type\":\"session\",\"version\":1,\"state\":\"\(state.rawValue)\"}\n"
        broadcast(json)
    }

    private func broadcast(_ line: String) {
        let data = Data(line.utf8)
        queue.async {
            self.connections.values.forEach { $0.send(data) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let bridge = BridgeConnection(connection: connection)
        bridge.onFrame = { [weak self] left, right, w, h, frameId in
            Task { @MainActor in
                self?.appModel?.lastFrameId = frameId
                self?.appModel?.framesReceived += 1
            }
            self?.compositor?.uploadFrame(left: left, right: right, width: w, height: h)
        }
        bridge.onLine = { [weak self] line in
            self?.handleClientLine(line, bridge: bridge)
        }
        let id = ObjectIdentifier(connection)
        connections[id] = bridge
        bridge.onClose = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        bridge.onReady = { [weak self] in
            self?.posePublisher?.startPublishing { line in
                bridge.send(line)
            }
        }
        bridge.start()
    }

    private func handleClientLine(_ line: String, bridge: BridgeConnection) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "recenter":
            posePublisher?.recenter()
            let counter = posePublisher?.recenterCounter ?? 0
            bridge.send("{\"type\":\"recenter\",\"version\":1,\"recenter_counter\":\(counter)}\n")
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
    var onReady: (() -> Void)?

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
        onReady?()
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
            if line.contains("\"type\":\"frame\"") || line.contains("\"type\": \"frame\"") {
                if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    pendingMeta = json
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
              let leftLen = left["byte_length"] as? Int,
              let rightLen = right["byte_length"] as? Int,
              let frameId = meta["frame_id"] as? UInt64 else { return false }

        let total = leftLen + rightLen
        guard buffer.count >= total else { return false }

        let leftData = buffer.prefix(leftLen)
        let rightData = buffer.dropFirst(leftLen).prefix(rightLen)
        buffer.removeFirst(total)

        onFrame?(Data(leftData), Data(rightData), lw, lh, frameId)
        return true
    }
}
