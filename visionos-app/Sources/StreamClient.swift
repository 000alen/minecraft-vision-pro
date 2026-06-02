import Foundation
import Metal
import Network

/// Network client for `bridge/stream-protocol.md`. Discovers (Bonjour) or connects (manual) to
/// the Mac relay, performs the `HELLO` handshake, receives `VIDEO_CONFIG`/`VIDEO_FRAME`, and sends
/// `UPLINK` lines (pose/hand/recenter). Decoded frames are exposed via `videoSource`.
///
/// ## Connection state machine
///
/// ```
///   ┌────────┐  start()   ┌───────────┐  Bonjour result   ┌────────────┐
///   │ (init) │ ─────────► │ searching │ ────────────────► │ connecting │
///   └────────┘            └───────────┘  (manual → skip)  └────────────┘
///                              ▲  no host yet (8 s hint)        │ TCP .ready
///                              │                                ▼
///                              │                       send HELLO + arm watchdog
///                              │ reconnect (backoff)            │ recv HELLO (≤5 s)
///                              │                                ▼
///   error/drop ───────────────┴──────────────────────► handshakeComplete
///                                                          (immersiveNoVideo)
///                                                                │ VIDEO_CONFIG
///                                                                ▼
///                                                        decoder.configure
///                                                                │ first VIDEO_FRAME decoded
///                                                                ▼   (owner flips → streaming)
/// ```
///
/// Robustness: a watchdog fails the handshake if no `HELLO` reply arrives; any drop (socket
/// failure, host close, framing desync) schedules an exponential-backoff reconnect (capped),
/// rather than wedging in a terminal state. `stop()` is the only path that ends reconnection.
final class StreamClient {
    /// (phase, detail) — marshalled to the main actor by the owner.
    var onPhaseChange: ((AppModel.Phase, String) -> Void)?
    /// One `bridge/protocol.md` line from the Mac (`DOWNLINK`, e.g. Java-initiated `recenter`).
    var onDownlinkLine: ((String) -> Void)?

    let videoSource: VideoSource
    private let decoder: VideoStreamDecoder

    private let manualHost: String?
    private let token: String
    private let queue = DispatchQueue(label: "visioncraft.stream.client")

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let framer = StreamFramer()
    private var handshakeComplete = false

    // Lifecycle / reconnection (all touched only on `queue`).
    private var stopped = false
    private var reconnectAttempt = 0
    private var handshakeWatchdog: DispatchWorkItem?
    private var searchingHint: DispatchWorkItem?
    private static let handshakeTimeout: TimeInterval = 5
    private static let searchingHintDelay: TimeInterval = 8
    private static let maxBackoff: TimeInterval = 5

    init(manualHost: String?, token: String, metalDevice: MTLDevice? = nil) {
        self.manualHost = manualHost
        self.token = token
        let decoder = VideoStreamDecoder(device: metalDevice)
        self.decoder = decoder
        self.videoSource = decoder
        // A decode failure / mid-stream join asks the host for a fresh IDR so the viewer recovers
        // without waiting for the periodic keyframe. The decoder rate-limits these internally.
        decoder.onDecodeFailure = { [weak self] in self?.requestKeyframe() }
    }

    func start() {
        queue.async { [weak self] in
            self?.stopped = false
            self?.beginConnect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.cancelTimers()
            self.browser?.cancel(); self.browser = nil
            self.connection?.cancel(); self.connection = nil
        }
    }

    // MARK: - Connect / reconnect

    /// Entry point for both the first attempt and every reconnect: manual host connects directly;
    /// otherwise (re)start Bonjour discovery.
    private func beginConnect() {
        guard !stopped else { return }
        teardownConnection()
        if let manualHost, !manualHost.isEmpty {
            connect(to: .hostPort(host: NWEndpoint.Host(manualHost),
                                  port: NWEndpoint.Port(rawValue: StreamProtocol.defaultPort)!))
        } else {
            startBrowsing()
        }
    }

    /// Schedule a backoff reconnect after any drop. No-op once `stop()` has been called so a
    /// deliberate teardown never resurrects the connection.
    private func scheduleReconnect(_ reason: String) {
        guard !stopped else { return }
        teardownConnection()
        let backoff = min(0.5 * pow(2.0, Double(reconnectAttempt)), Self.maxBackoff)
        reconnectAttempt += 1
        onPhaseChange?(.searching, "reconnecting in \(String(format: "%.0f", backoff))s — \(reason)")
        queue.asyncAfter(deadline: .now() + backoff) { [weak self] in self?.beginConnect() }
    }

    private func teardownConnection() {
        cancelTimers()
        handshakeComplete = false
        framer.reset()
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
    }

    private func cancelTimers() {
        handshakeWatchdog?.cancel(); handshakeWatchdog = nil
        searchingHint?.cancel(); searchingHint = nil
    }

    // MARK: - Discovery

    private func startBrowsing() {
        onPhaseChange?(.searching, "looking for VisionCraftHost on the local network…")
        // If nothing is found promptly, nudge the user toward the most common cause.
        let hint = DispatchWorkItem { [weak self] in
            self?.onPhaseChange?(.searching, "still searching — is VisionCraftHost running on your Mac, and both devices on the same Wi-Fi?")
        }
        searchingHint = hint
        queue.asyncAfter(deadline: .now() + Self.searchingHintDelay, execute: hint)

        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: StreamProtocol.bonjourServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let endpoint = Self.preferredEndpoint(from: results) else { return }
            self.searchingHint?.cancel(); self.searchingHint = nil
            self.browser?.cancel()
            self.browser = nil
            self.connect(to: endpoint)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.scheduleReconnect("discovery: \(error.localizedDescription)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: - Connection

    private func connect(to endpoint: NWEndpoint) {
        onPhaseChange?(.connecting, reconnectAttempt > 0 ? "connecting (attempt \(reconnectAttempt + 1))…" : "connecting to host…")
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHello()
                self.armHandshakeWatchdog()
                self.receiveLoop()
            case .failed(let error):
                self.scheduleReconnect("connection: \(error.localizedDescription)")
            case .waiting(let error):
                // Transient (e.g. host not yet listening) — surface but let NWConnection retry.
                self.onPhaseChange?(.connecting, "waiting: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func armHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.handshakeComplete else { return }
            self.scheduleReconnect("no handshake reply")
        }
        handshakeWatchdog = watchdog
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: watchdog)
    }

    private func sendHello() {
        let hello = "{\"type\":\"hello\",\"version\":1,\"role\":\"viewer\",\"token\":\"\(Self.escape(token))\",\"device\":\"Apple Vision Pro\",\"capabilities\":{\"hevc_decode\":true,\"mvhevc_decode\":false}}"
        send(.hello, json: hello)
    }

    /// Sends a `bridge/protocol.md` line (pose/hand/recenter) as an `UPLINK` envelope.
    func sendUplink(_ line: String) {
        guard handshakeComplete else { return }
        send(.uplink, payload: Data(line.utf8))
    }

    /// Ask the host to emit a keyframe (IDR) now — used after a decode failure or when joining
    /// mid-stream so recovery doesn't wait for the periodic keyframe interval.
    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self, self.handshakeComplete else { return }
            self.send(.requestIdr, payload: Data())
        }
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
                self.scheduleReconnect("receive: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.framer.append(data)
                self.drain()
            }
            if isComplete {
                self.scheduleReconnect("host closed the connection")
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
            // Oversized/desynced stream — drop and reconnect from a clean framer.
            scheduleReconnect("stream framing error")
        }
    }

    private func handle(_ type: StreamMessageType, payload: Data) {
        switch type {
        case .hello:
            handshakeComplete = true
            reconnectAttempt = 0
            handshakeWatchdog?.cancel(); handshakeWatchdog = nil
            onPhaseChange?(.immersiveNoVideo, "connected — waiting for host video")
        case .videoConfig:
            if let config = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                decoder.configure(with: config)
                // Stay in immersiveNoVideo until a frame actually decodes; the owner promotes to
                // `.streaming` on the first decoded frame so the green status never lies.
                onPhaseChange?(.immersiveNoVideo, "video configured — decoding first frame…")
            }
        case .videoFrame:
            guard let parsed = StreamProtocol.parseVideoFrame(payload) else {
                scheduleReconnect("invalid VIDEO_FRAME payload")
                return
            }
            decoder.decode(meta: parsed.meta, accessUnit: parsed.accessUnit)
        case .ping:
            send(.pong, payload: payload)
        case .bye:
            // Host is intentionally going away; try to rejoin (it may simply be restarting).
            scheduleReconnect("host said goodbye")
        case .downlink:
            if let line = String(data: payload, encoding: .utf8) {
                onDownlinkLine?(line)
            }
        case .pong, .uplink, .requestIdr:
            break // outbound-only / no client-side action
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Prefer a Bonjour result that looks like VisionCraft when several services are visible.
    private static func preferredEndpoint(from results: Set<NWBrowser.Result>) -> NWEndpoint? {
        let sorted = results.sorted { lhs, rhs in
            serviceName(lhs).localizedCaseInsensitiveCompare(serviceName(rhs)) == .orderedAscending
        }
        if let match = sorted.first(where: { serviceName($0).localizedCaseInsensitiveContains("visioncraft") }) {
            return match.endpoint
        }
        return sorted.first?.endpoint
    }

    private static func serviceName(_ result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint {
            return name
        }
        return ""
    }
}
