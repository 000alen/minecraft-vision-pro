import Foundation
import Network

/// LAN TCP server for `bridge/stream-protocol.md`. The Mac is the server (it owns the video); the
/// Apple Vision Pro companion is the single client ("viewer"). Advertises Bonjour
/// `_visioncraft-stream._tcp` so the companion can discover it without a manual IP.
///
/// Threading: all connection-table and send state is confined to `queue`. `viewerReady` is mirrored
/// behind a lock so the hot frame path can skip encode work without hopping onto `queue`.
final class StreamRelayServer {
    /// One verbatim `bridge/protocol.md` line received over UPLINK (pose / hand / view_config / recenter).
    var onUplinkLine: ((String) -> Void)?
    var onViewerConnected: (() -> Void)?
    var onViewerDisconnected: (() -> Void)?
    var onRequestKeyframe: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "visioncraft.relay.server")
    private var listener: NWListener?
    private var viewer: NWConnection?
    private var framer = StreamFramer()
    private var handshakeDone = false

    private let stateLock = NSLock()
    private var _viewerReady = false

    /// True once a viewer has completed the HELLO handshake. Lock-guarded for the frame path.
    var viewerReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _viewerReady
    }

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true // low latency for the pose uplink; video frames are large anyway
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeServerError.invalidPort(Int(port))
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.service = NWListener.Service(name: nil, type: StreamProtocol.bonjourServiceType)
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case let .add(endpoint) = change {
                self?.onStatus?("Bonjour registered: \(endpoint)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStatus?("Relay listening on :\(self?.port ?? 0)")
            case .failed(let error): self?.onStatus?("Relay failed: \(error)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async {
            self.viewer?.cancel()
            self.viewer = nil
            self.listener?.cancel()
            self.listener = nil
            self.setViewerReady(false)
            self.handshakeDone = false
        }
    }

    // MARK: - Sending (Mac → AVP)

    func sendVideoConfig(_ json: String) {
        sendEnvelope(StreamProtocol.encode(.videoConfig, json: json))
    }

    func sendVideoFramePayload(_ payload: Data) {
        sendEnvelope(StreamProtocol.encode(.videoFrame, payload: payload))
    }

    /// Mac → AVP: one `bridge/protocol.md` line (e.g. `recenter` from Java).
    func sendDownlink(_ payload: Data) {
        sendEnvelope(StreamProtocol.encode(.downlink, payload: payload))
    }

    private func sendEnvelope(_ data: Data) {
        queue.async {
            guard self.handshakeDone, let viewer = self.viewer else { return }
            viewer.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Connection handling (queue-confined)

    private func accept(_ connection: NWConnection) {
        // Single viewer: a new connection replaces any existing one.
        if let existing = viewer {
            existing.cancel()
        }
        viewer = connection
        framer = StreamFramer()
        handshakeDone = false
        setViewerReady(false)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.handleViewerGone(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func handleViewerGone(_ connection: NWConnection) {
        guard viewer === connection else { return }
        viewer = nil
        if handshakeDone {
            onViewerDisconnected?()
        }
        handshakeDone = false
        setViewerReady(false)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.framer.append(data)
                self.drain(connection)
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func drain(_ connection: NWConnection) {
        while true {
            let message: (type: StreamMessageType, payload: Data)?
            do {
                message = try framer.next()
            } catch {
                onStatus?("Relay framing error: \(error); dropping viewer")
                connection.cancel()
                return
            }
            guard let message else { return }
            handle(message.type, payload: message.payload, on: connection)
        }
    }

    private func handle(_ type: StreamMessageType, payload: Data, on connection: NWConnection) {
        switch type {
        case .hello:
            handleHello(payload, on: connection)
        case .ping:
            // Echo back as PONG (payload is a bridge/protocol.md ping line carrying the timestamp).
            connection.send(content: StreamProtocol.encode(.pong, payload: payload),
                            completion: .contentProcessed { _ in })
        case .pong:
            break
        case .uplink:
            if let line = String(data: payload, encoding: .utf8) {
                onUplinkLine?(line.hasSuffix("\n") ? line : line + "\n")
            }
        case .requestIdr:
            // Viewer lost sync (decode failure / mid-stream join): force the next encoded frame
            // to be a keyframe so it can recover without waiting for the periodic IDR.
            onRequestKeyframe?()
        case .bye:
            connection.cancel()
        case .videoConfig, .videoFrame, .downlink:
            break // Mac → AVP only; ignore if echoed back.
        }
    }

    private func handleHello(_ payload: Data, on connection: NWConnection) {
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        if let version = json?["version"] as? Int, version != 1 {
            onStatus?("Relay rejected viewer: unsupported protocol version")
            connection.send(content: StreamProtocol.encode(.bye, json: #"{"type":"bye","version":1,"reason":"version_mismatch"}"#),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let presentedToken = json?["token"] as? String ?? ""
        if !token.isEmpty, presentedToken != token {
            onStatus?("Relay rejected viewer: pairing token mismatch")
            connection.send(content: StreamProtocol.encode(.bye, json: #"{"type":"bye","version":1,"reason":"token_mismatch"}"#),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let ack = #"{"type":"hello","version":1,"role":"host","capabilities":{"hevc_encode":true,"mvhevc_encode":false}}"#
        connection.send(content: StreamProtocol.encode(.hello, json: ack), completion: .contentProcessed { _ in })
        handshakeDone = true
        setViewerReady(true)
        onStatus?("Relay viewer connected")
        onViewerConnected?()
    }

    private func setViewerReady(_ ready: Bool) {
        stateLock.lock()
        _viewerReady = ready
        stateLock.unlock()
    }
}
