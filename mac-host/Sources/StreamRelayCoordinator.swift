import Foundation

/// Glues the relay together:
///  - bridge RGBA frames → `StereoFrameEncoder` → `StreamRelayServer` (downlink VIDEO_FRAME)
///  - companion UPLINK lines → `onUplinkLine` → loopback bridge broadcast (pose/hand/view_config)
///
/// Encode work only runs while a viewer is connected, so the host is idle (no copies, no
/// VideoToolbox) until the Apple Vision Pro companion joins.
final class StreamRelayCoordinator {
    /// Verbatim `bridge/protocol.md` line from the companion, to be broadcast to Java clients.
    var onUplinkLine: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onViewerChange: ((Bool) -> Void)?

    private let server: StreamRelayServer
    private let encoder = StereoFrameEncoder()
    private let queue = DispatchQueue(label: "visioncraft.relay.coord")
    private let fps = 90

    private var eyeWidth = 0
    private var eyeHeight = 0
    private var configSent = false
    private var keyframeTimer: DispatchSourceTimer?

    private let counterLock = NSLock()
    private var _framesEncoded: UInt64 = 0
    private var _viewerConnected = false

    var framesEncoded: UInt64 { counterLock.lock(); defer { counterLock.unlock() }; return _framesEncoded }
    var viewerConnected: Bool { counterLock.lock(); defer { counterLock.unlock() }; return _viewerConnected }

    init(port: UInt16, token: String) {
        server = StreamRelayServer(port: port, token: token)
        server.onUplinkLine = { [weak self] line in self?.onUplinkLine?(line) }
        server.onStatus = { [weak self] status in self?.onStatus?(status) }
        server.onViewerConnected = { [weak self] in self?.handleViewerConnected() }
        server.onViewerDisconnected = { [weak self] in self?.handleViewerDisconnected() }
        encoder.onAccessUnit = { [weak self] au in self?.handleAccessUnit(au) }
    }

    func start() throws {
        try server.start()
        startKeyframeTimer()
    }

    func stop() {
        keyframeTimer?.cancel()
        keyframeTimer = nil
        server.stop()
        encoder.stop()
        queue.async {
            self.configSent = false
            self.eyeWidth = 0
            self.eyeHeight = 0
        }
    }

    /// Called from the loopback bridge's frame path. `left`/`right` are RGBA8 eye buffers; they may
    /// be transient slices, so the encoder copies them. Cheap no-op when no viewer is connected.
    func submitFrame(left: Data, right: Data, width: Int, height: Int, frameId: UInt64) {
        guard server.viewerReady else { return }
        // Capture standalone copies synchronously (the caller's buffer is reused after return).
        let l = Data(left)
        let r = Data(right)
        queue.async {
            if self.eyeWidth != width || self.eyeHeight != height {
                self.eyeWidth = width
                self.eyeHeight = height
                self.configSent = false
                self.encoder.configure(eyeWidth: width, eyeHeight: height, fps: self.fps)
            }
            self.sendConfigIfNeeded()
            self.encoder.encode(left: l, right: r, eyeWidth: width, eyeHeight: height, frameId: frameId)
        }
    }

    // MARK: - Private

    private func handleViewerConnected() {
        counterLock.lock(); _viewerConnected = true; counterLock.unlock()
        onViewerChange?(true)
        queue.async {
            self.configSent = false
            self.sendConfigIfNeeded()
        }
        encoder.requestKeyframe()
    }

    private func handleViewerDisconnected() {
        counterLock.lock(); _viewerConnected = false; counterLock.unlock()
        onViewerChange?(false)
    }

    private func sendConfigIfNeeded() {
        guard !configSent, eyeWidth > 0, eyeHeight > 0, server.viewerReady else { return }
        let frameWidth = eyeWidth * 2
        let json = """
        {"type":"video_config","version":1,"codec":"hevc","packing":"side_by_side","eye_width":\(eyeWidth),"eye_height":\(eyeHeight),"frame_width":\(frameWidth),"frame_height":\(eyeHeight),"fps":\(fps),"color":"bt709","full_range":true}
        """
        server.sendVideoConfig(json)
        configSent = true
    }

    private func handleAccessUnit(_ au: StereoFrameEncoder.AccessUnit) {
        let meta = """
        {"frame_id":\(au.frameId),"pts_ns":\(au.ptsNanos),"keyframe":\(au.keyframe),"packing":"side_by_side","byte_length":\(au.data.count)}
        """
        let payload = StreamProtocol.videoFramePayload(metaJSON: meta, accessUnit: au.data)
        server.sendVideoFramePayload(payload)
        counterLock.lock(); _framesEncoded += 1; counterLock.unlock()
    }

    /// Request a keyframe every ~2 s while a viewer is connected, as a loss-recovery anchor for a
    /// mid-stream joiner (matches `bridge/stream-protocol.md`).
    private func startKeyframeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.server.viewerReady else { return }
            self.encoder.requestKeyframe()
        }
        timer.resume()
        keyframeTimer = timer
    }
}
