import Foundation
import Network

/// Network client for `bridge/stream-protocol.md`. Discovers (Bonjour) or connects (manual) to
/// the Mac relay, performs the `HELLO` handshake, receives `VIDEO_CONFIG`/`VIDEO_FRAME`, and sends
/// `UPLINK` lines (pose/hand/recenter). Decoded frames are exposed via `videoSource`.
final class StreamClient {
    static let defaultPort: UInt16 = 19736
    static let bonjourType = "_visioncraft-stream._tcp"

    /// (phase, detail) — marshalled to the main actor by the owner.
    var onPhaseChange: ((AppModel.Phase, String) -> Void)?

    /// Decoded video for the renderer. Phase 1: returns nil (decoder is Phase 2), so the renderer
    /// shows the debug scene; the uplink path is fully live.
    let videoSource: VideoSource
    private let decoder: VideoStreamDecoder

    private let manualHost: String?
    private let token: String
    private let queue = DispatchQueue(label: "visioncraft.stream.client")

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let framer = StreamFramer()
    private var handshakeComplete = false

    init(manualHost: String?, token: String) {
        self.manualHost = manualHost
        self.token = token
        let decoder = VideoStreamDecoder()
        self.decoder = decoder
        self.videoSource = decoder
    }

    func start() {
        if let manualHost, !manualHost.isEmpty {
            connect(to: .hostPort(host: NWEndpoint.Host(manualHost), port: NWEndpoint.Port(rawValue: Self.defaultPort)!))
        } else {
            startBrowsing()
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - Discovery

    private func startBrowsing() {
        onPhaseChange?(.searching, "browsing \(Self.bonjourType)")
        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let first = results.first else { return }
            self.browser?.cancel()
            self.browser = nil
            self.connect(to: first.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: - Connection

    private func connect(to endpoint: NWEndpoint) {
        onPhaseChange?(.connecting, "connecting")
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHello()
                self.receiveLoop()
            case .failed(let error), .waiting(let error):
                self.onPhaseChange?(.error, "connection: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func sendHello() {
        let hello = "{\"type\":\"hello\",\"version\":1,\"role\":\"viewer\",\"token\":\"\(Self.escape(token))\",\"device\":\"Apple Vision Pro\",\"capabilities\":{\"hevc_decode\":true,\"mvhevc_decode\":true}}"
        send(.hello, json: hello)
    }

    /// Sends a `bridge/protocol.md` line (pose/hand/recenter) as an `UPLINK` envelope.
    func sendUplink(_ line: String) {
        guard handshakeComplete else { return }
        send(.uplink, payload: Data(line.utf8))
    }

    private func send(_ type: StreamMessageType, json: String) {
        send(type, payload: Data(json.utf8))
    }

    private func send(_ type: StreamMessageType, payload: Data) {
        connection?.send(content: StreamProtocol.encode(type, payload: payload), completion: .contentProcessed { _ in })
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.onPhaseChange?(.error, "receive: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.framer.append(data)
                self.drain()
            }
            if isComplete {
                self.connection?.cancel()
                self.onPhaseChange?(.idle, "host closed")
                return
            }
            self.receiveLoop()
        }
    }

    private func drain() {
        do {
            while let message = try framer.next() {
                handle(message.type, payload: message.payload)
            }
        } catch {
            // Oversized/desynced stream — drop the connection.
            onPhaseChange?(.error, "stream framing error")
            connection?.cancel()
        }
    }

    private func handle(_ type: StreamMessageType, payload: Data) {
        switch type {
        case .hello:
            handshakeComplete = true
            onPhaseChange?(.immersiveNoVideo, "handshake complete")
        case .videoConfig:
            if let config = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                decoder.configure(with: config)
                onPhaseChange?(.streaming, "video configured")
            }
        case .videoFrame:
            if let parsed = StreamProtocol.parseVideoFrame(payload) {
                decoder.decode(meta: parsed.meta, accessUnit: parsed.accessUnit)
            }
        case .ping:
            send(.pong, payload: payload)
        case .bye:
            connection?.cancel()
            onPhaseChange?(.idle, "host said bye")
        case .pong, .uplink:
            break
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
