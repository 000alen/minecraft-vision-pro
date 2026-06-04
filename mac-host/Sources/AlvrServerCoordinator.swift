import Foundation
import simd

/// Owns the ALVR server_core C ABI and adapts it to VisionCraft's existing Java bridge.
final class AlvrServerCoordinator {
    private static let runtimePreparationLock = NSLock()
    private static var runtimePrepared = false

    private enum ControllerHand: String, CaseIterable {
        case left
        case right

        var deviceId: UInt64 {
            switch self {
            case .left: vc_alvr_left_hand_device_id()
            case .right: vc_alvr_right_hand_device_id()
            }
        }
    }

    private struct ControllerButtonPath {
        let hand: ControllerHand
        let name: String
        let isAxis: Bool
    }

    private struct ControllerInputState {
        var tracked = false
        var pose: VCAlvrPoseSample?
        var buttons: [String: Bool] = [:]
        var axes: [String: Float] = [:]

        var hasInput: Bool {
            buttons.values.contains(true) || axes.values.contains { abs($0) > 0.001 }
        }
    }

    struct StatusSnapshot {
        let running: Bool
        let clientConnected: Bool
        let bridgeStreamingReady: Bool
        let sentVideoConfig: Bool
        let syntheticFramesEnabled: Bool
        let framesEncoded: UInt64
        let framesSent: UInt64
        let framesDroppedNoConfig: UInt64
        let targetEyeWidth: Int
        let targetEyeHeight: Int
        let fps: Int
        let lastTrackingSampleTimestampNs: UInt64
        let lastVideoTargetTimestampNs: UInt64
    }

    var onStatus: ((String) -> Void)?
    /// ALVR TCP/session connected (headset link up).
    var onClientConnectionChange: ((Bool) -> Void)?
    /// Bridge v1 `session` state for Java (`paused` until tracking + view_config, then `ready`).
    var onBridgeSessionState: ((BridgeSessionState) -> Void)?
    var onUplinkLine: ((String) -> Void)?

    private let queue = DispatchQueue(label: "visioncraft.alvr.server")
    private let pollQueue = DispatchQueue(label: "visioncraft.alvr.poll")
    private let pollStateLock = NSLock()
    private let encoder = StereoFrameEncoder()

    private var running = false
    private var clientConnected = false
    private var pollLoopActive = false
    private var pollLoopShouldRun = false
    private var pollLoopGeneration: UInt64 = 0
    private var syntheticTimer: DispatchSourceTimer?
    private var syntheticFramesEnabled = false
    private var negotiatedEyeWidth = 2144
    private var negotiatedEyeHeight = 1206
    private var targetEyeWidth = 2144
    private var targetEyeHeight = 1206
    private var viewConfigEyeWidth = 2144
    private var viewConfigEyeHeight = 1206
    private var fps = 90
    private var nextFrameId: UInt64 = 1
    private var framesEncoded: UInt64 = 0
    private var framesSent: UInt64 = 0
    private var framesDroppedNoConfig: UInt64 = 0
    private var droppedNoRenderTs: UInt64 = 0
    private var bridgeStreamingReady = false
    private var lastViewConfigPublishNs: UInt64 = 0
    private var lastViewConfigLeftFov = VCAlvrFov()
    private var lastViewConfigRightFov = VCAlvrFov()
    private var lastViewConfigIpdM: Float = 0.063
    private var lastTrackingSampleTimestampNs: UInt64 = 0
    private var lastVideoTargetTimestampNs: UInt64 = 0
    private var recenterCounter: UInt64 = 0
    private var lastVideoConfig = Data()
    private var sentVideoConfig = false
    private var controllerStates: [ControllerHand: ControllerInputState] = [
        .left: ControllerInputState(),
        .right: ControllerInputState()
    ]
    private lazy var controllerButtonPaths = Self.makeControllerButtonPaths()

    init() {
        encoder.onAccessUnit = { [weak self] accessUnit in
            self?.queue.async {
                self?.send(accessUnit)
            }
        }
        encoder.onDecoderConfigAnnexB = { [weak self] config in
            self?.queue.async {
                guard let self, !config.isEmpty else { return }
                if config != self.lastVideoConfig {
                    self.lastVideoConfig = config
                    self.sentVideoConfig = false
                }
            }
        }
    }

    func start(enableSyntheticFrames: Bool = false) {
        queue.async {
            guard !self.running else {
                if enableSyntheticFrames {
                    self.startSyntheticFramesLocked()
                }
                return
            }

            self.prepareRuntimeDirectories()
            let target = vc_alvr_initialize()
            self.negotiatedEyeWidth = max(1, Int(target.game_render_width))
            self.negotiatedEyeHeight = max(1, Int(target.game_render_height))
            self.targetEyeWidth = self.negotiatedEyeWidth
            self.targetEyeHeight = self.negotiatedEyeHeight
            self.viewConfigEyeWidth = self.negotiatedEyeWidth
            self.viewConfigEyeHeight = self.negotiatedEyeHeight
            self.fps = 90
            self.resetFrameCountersLocked()
            self.lastTrackingSampleTimestampNs = 0
            self.sentVideoConfig = false
            self.lastVideoConfig.removeAll(keepingCapacity: true)
            self.bridgeStreamingReady = false
            self.lastViewConfigPublishNs = 0

            vc_alvr_start_connection()
            self.running = true
            self.setStatus("ALVR server_core started; waiting for headset client")
            self.startPollingLocked()
            if enableSyntheticFrames {
                self.startSyntheticFramesLocked()
            }
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.syntheticTimer?.cancel()
            self.syntheticTimer = nil
            self.syntheticFramesEnabled = false
            self.setPollingEnabled(false)
            self.pollQueue.sync { }
            vc_alvr_shutdown()
            self.running = false
            self.clientConnected = false
            self.pollLoopActive = false
            self.encoder.stop()
            self.resetFrameCountersLocked()
            self.lastTrackingSampleTimestampNs = 0
            self.bridgeStreamingReady = false
            self.setStatus("ALVR server_core stopped")
            self.onBridgeSessionState?(.closed)
            self.onClientConnectionChange?(false)
        }
    }

    func requestKeyframe() {
        encoder.requestKeyframe()
    }

    func recordRecenter() -> UInt64? {
        queue.sync {
            guard running, clientConnected else { return nil }
            recenterCounter &+= 1
            return recenterCounter
        }
    }

    func sendHaptics(hand: String, durationSeconds: Float, frequency: Float, amplitude: Float) {
        queue.async {
            guard self.running, self.clientConnected else { return }
            let clampedDuration = max(0, min(durationSeconds, 2.0))
            let clampedFrequency = max(0, frequency)
            let clampedAmplitude = max(0, min(amplitude, 1.0))
            let handKind: VCAlvrHandKind = hand == "left" ? UInt8(VC_ALVR_HAND_LEFT) : UInt8(VC_ALVR_HAND_RIGHT)
            vc_alvr_send_haptics(handKind, clampedDuration, clampedFrequency, clampedAmplitude)
        }
    }

    func submitFrame(left: Data, right: Data, eyeWidth: Int, eyeHeight: Int,
                     frameId: UInt64, renderSampleTimestampNs: UInt64 = 0) {
        queue.async {
            guard self.running, self.clientConnected, self.lastTrackingSampleTimestampNs != 0 else { return }
            guard !self.syntheticFramesEnabled else { return }
            // ALVR per-frame render-pose contract: a frame MUST be submitted under the EXACT
            // tracking-sample timestamp it was rendered for, so the client can look up the head pose
            // it predicted for that sample and reproject correctly. Vivecraft echoes that id on the
            // frame. If it is missing we cannot satisfy the contract — drop the frame rather than
            // submit an arbitrary timestamp: a non-matching id makes the client fall back to an
            // identity head pose, which double-counts the entire head orientation (severe swim +
            // per-eye divergence / non-fusion).
            guard renderSampleTimestampNs != 0 else {
                self.droppedNoRenderTs &+= 1
                if Self.logPoseEnabled, self.droppedNoRenderTs % 90 == 1 {
                    NSLog("[VisionCraft] dropping frame %llu: no render timestamp echoed (count=%llu)",
                          frameId, self.droppedNoRenderTs)
                }
                return
            }
            let targetTimestampNs = renderSampleTimestampNs

            let dimsChanged = self.targetEyeWidth != eyeWidth || self.targetEyeHeight != eyeHeight
            self.targetEyeWidth = eyeWidth
            self.targetEyeHeight = eyeHeight
            if dimsChanged {
                self.viewConfigEyeWidth = eyeWidth
                self.viewConfigEyeHeight = eyeHeight
                self.encoder.configure(eyeWidth: eyeWidth, eyeHeight: eyeHeight, fps: self.fps)
                self.republishViewConfigIfNeeded(force: true)
            }

            // Frame-timing report: the frame is composed (rendered, pre-encode) now. ALVR uses this
            // (with report_present at NAL submit) for its latency stats, which drive the client's
            // pose-prediction horizon. offset 0 = the event happened at call time.
            vc_alvr_report_composed(targetTimestampNs, 0)

            // Diagnostic: confirm the submit ts is a real recent tracking sample and how far the
            // render lags the newest sample (VISIONCRAFT_LOG_POSE=1).
            if Self.logPoseEnabled, frameId % 90 == 0 {
                let behind = self.lastTrackingSampleTimestampNs >= targetTimestampNs
                    ? self.lastTrackingSampleTimestampNs - targetTimestampNs : 0
                NSLog("[VisionCraft] submit frame=%llu render_ts=%llu newest_sample=%llu behind_ns=%llu",
                      frameId, targetTimestampNs, self.lastTrackingSampleTimestampNs, behind)
            }

            self.encoder.encode(
                left: left,
                right: right,
                eyeWidth: eyeWidth,
                eyeHeight: eyeHeight,
                frameId: frameId,
                targetTimestampNs: targetTimestampNs
            )
        }
    }

    /// Geometry/context header for a capture bundle: latest device view_config (positive
    /// `[left,right,up,down]` tangents + IPD), per-eye dims, fps, and the synthetic-frames flag.
    func captureHeaderJSON() -> String {
        queue.sync {
            let left = Self.tangents(from: lastViewConfigLeftFov)
            let right = Self.tangents(from: lastViewConfigRightFov)
            return "{\"ipd_m\":\(StereoMath.fmt(lastViewConfigIpdM)),"
                + "\"eye_width\":\(viewConfigEyeWidth),\"eye_height\":\(viewConfigEyeHeight),"
                + "\"fps\":\(fps),\"synthetic_frames\":\(syntheticFramesEnabled),"
                + "\"left_tangents\":[\(StereoMath.fmt(left.x)),\(StereoMath.fmt(left.y)),\(StereoMath.fmt(left.z)),\(StereoMath.fmt(left.w))],"
                + "\"right_tangents\":[\(StereoMath.fmt(right.x)),\(StereoMath.fmt(right.y)),\(StereoMath.fmt(right.z)),\(StereoMath.fmt(right.w))]}"
        }
    }

    func snapshot() -> StatusSnapshot {
        queue.sync {
            StatusSnapshot(
                running: running,
                clientConnected: clientConnected,
                bridgeStreamingReady: bridgeStreamingReady,
                sentVideoConfig: sentVideoConfig,
                syntheticFramesEnabled: syntheticFramesEnabled,
                framesEncoded: framesEncoded,
                framesSent: framesSent,
                framesDroppedNoConfig: framesDroppedNoConfig,
                targetEyeWidth: targetEyeWidth,
                targetEyeHeight: targetEyeHeight,
                fps: fps,
                lastTrackingSampleTimestampNs: lastTrackingSampleTimestampNs,
                lastVideoTargetTimestampNs: lastVideoTargetTimestampNs
            )
        }
    }

    // MARK: - Runtime

    private func prepareRuntimeDirectories() {
        let rootPath = Self.repoRootPath()
        let root = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(".run/alvr", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        Self.runtimePreparationLock.lock()
        defer { Self.runtimePreparationLock.unlock() }
        guard !Self.runtimePrepared else { return }

        config.path.withCString { configPtr in
            logs.path.withCString { logsPtr in
                vc_alvr_initialize_environment(configPtr, logsPtr)
            }
        }
        let sessionLog = logs.appendingPathComponent("server-core.log").path
        let crashLog = logs.appendingPathComponent("server-core-crash.log").path
        sessionLog.withCString { sessionPtr in
            crashLog.withCString { crashPtr in
                vc_alvr_initialize_logging(sessionPtr, crashPtr)
            }
        }
        Self.runtimePrepared = true
    }

    private static func repoRootPath() -> String {
        if let env = ProcessInfo.processInfo.environment["VISIONCRAFT_REPO_ROOT"], !env.isEmpty {
            return env
        }
        let bundlePath = Bundle.main.bundleURL.path
        if let range = bundlePath.range(of: "/mac-host/build/") {
            return String(bundlePath[..<range.lowerBound])
        }
        return FileManager.default.currentDirectoryPath
    }

    private func startPollingLocked() {
        guard !pollLoopActive else { return }
        pollLoopActive = true
        let generation = setPollingEnabled(true)
        pollQueue.async { [weak self] in
            self?.pollLoop(generation: generation)
        }
    }

    private func pollLoop(generation: UInt64) {
        while isPollingEnabled(generation: generation) {
            var event = VCAlvrEvent()
            if vc_alvr_poll_event(&event, 100_000_000) {
                queue.async { [weak self] in
                    guard let self, self.running, self.pollLoopActive else { return }
                    self.handle(event)
                }
            }
        }
    }

    @discardableResult
    private func setPollingEnabled(_ enabled: Bool) -> UInt64 {
        pollStateLock.lock()
        pollLoopGeneration &+= 1
        pollLoopShouldRun = enabled
        let generation = pollLoopGeneration
        pollStateLock.unlock()
        return generation
    }

    private func isPollingEnabled(generation: UInt64) -> Bool {
        pollStateLock.lock()
        defer { pollStateLock.unlock() }
        return pollLoopShouldRun && pollLoopGeneration == generation
    }

    private func handle(_ event: VCAlvrEvent) {
        switch Int(event.kind) {
        case VC_ALVR_EVENT_CLIENT_CONNECTED:
            clientConnected = true
            sentVideoConfig = false
            resetFrameCountersLocked()
            lastTrackingSampleTimestampNs = 0
            bridgeStreamingReady = false
            // Drop stale Java bridge dimensions from a prior session; VIEWS_CONFIG reaffirms from AVP.
            targetEyeWidth = negotiatedEyeWidth
            targetEyeHeight = negotiatedEyeHeight
            viewConfigEyeWidth = negotiatedEyeWidth
            viewConfigEyeHeight = negotiatedEyeHeight
            nextFrameId = 1
            resetControllerState()
            refreshDynamicEncoderParamsLocked()
            requestKeyframe()
            setStatus("ALVR headset client connected; waiting for tracking")
            onBridgeSessionState?(.paused)
            onClientConnectionChange?(true)
        case VC_ALVR_EVENT_CLIENT_DISCONNECTED:
            clientConnected = false
            sentVideoConfig = false
            resetFrameCountersLocked()
            lastTrackingSampleTimestampNs = 0
            bridgeStreamingReady = false
            resetControllerState()
            publishControllerState(timestampNs: Self.epochNanoseconds())
            setStatus("ALVR headset client disconnected")
            onBridgeSessionState?(.closed)
            onClientConnectionChange?(false)
        case VC_ALVR_EVENT_VIEWS_CONFIG:
            // Headset FOV comes from the event; stream dimensions stay on the ALVR contract.
            viewConfigEyeWidth = negotiatedEyeWidth
            viewConfigEyeHeight = negotiatedEyeHeight
            targetEyeWidth = negotiatedEyeWidth
            targetEyeHeight = negotiatedEyeHeight
            encoder.configure(eyeWidth: viewConfigEyeWidth, eyeHeight: viewConfigEyeHeight, fps: fps)
            publishViewConfig(event)
            updateBridgeStreamingReadyLocked()
        case VC_ALVR_EVENT_TRACKING_UPDATED:
            lastTrackingSampleTimestampNs = event.sample_timestamp_ns
            publishPose(sampleTimestampNs: event.sample_timestamp_ns)
            updateControllerPoses(sampleTimestampNs: event.sample_timestamp_ns)
            publishControllerState(timestampNs: Self.epochNanoseconds())
            updateBridgeStreamingReadyLocked()
        case VC_ALVR_EVENT_RAW_BUTTONS_UPDATED:
            drainRawButtons()
            publishControllerState(timestampNs: Self.epochNanoseconds())
        case VC_ALVR_EVENT_REQUEST_IDR:
            requestKeyframe()
            setStatus("ALVR requested IDR")
        case VC_ALVR_EVENT_RESTART_PENDING:
            setStatus("ALVR restart pending")
        case VC_ALVR_EVENT_SHUTDOWN_PENDING:
            setStatus("ALVR shutdown pending")
        default:
            break
        }
    }

    // MARK: - Video

    private func send(_ accessUnit: StereoFrameEncoder.AccessUnit) {
        guard running, clientConnected else { return }

        refreshDynamicEncoderParamsLocked()
        let payload = accessUnit.data
        guard !payload.isEmpty else { return }

        if accessUnit.keyframe {
            let split = Self.splitHEVCParameterSets(from: payload)
            if !split.config.isEmpty, split.config != lastVideoConfig {
                lastVideoConfig = split.config
                sentVideoConfig = false
            }
            if lastVideoConfig.isEmpty {
                let cached = encoder.decoderConfigAnnexB()
                if !cached.isEmpty {
                    lastVideoConfig = cached
                    sentVideoConfig = false
                }
            }
            if !lastVideoConfig.isEmpty, !sentVideoConfig {
                lastVideoConfig.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    vc_alvr_set_video_config_hevc(base, Int32(lastVideoConfig.count))
                }
                sentVideoConfig = true
            }
            // Keep parameter sets inline on IDR frames too. ALVR normally receives them out of
            // band, but inline VPS/SPS/PPS lets the visionOS client recover if its decoder resets
            // after the first config handoff.
        }

        guard sentVideoConfig else {
            if accessUnit.keyframe {
                framesDroppedNoConfig += 1
            }
            return
        }

        let timestamp = accessUnit.targetTimestampNs
        var mutablePayload = payload
        let payloadCount = Int32(mutablePayload.count)
        mutablePayload.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            vc_alvr_send_video_nal(timestamp, base, payloadCount, accessUnit.keyframe)
        }
        // Frame-timing report: the frame is presented (handed to ALVR for transmit) now. Pairs with
        // report_composed in submitFrame so ALVR's pipeline-latency stats are complete.
        vc_alvr_report_present(timestamp, 0)
        lastVideoTargetTimestampNs = timestamp
        framesEncoded += 1
        framesSent += 1
    }

    private func refreshDynamicEncoderParamsLocked() {
        var params = VCAlvrDynamicEncoderParams()
        guard vc_alvr_get_dynamic_encoder_params(&params) else { return }
        let negotiatedFps = Int(params.framerate.rounded())
        if negotiatedFps > 0, negotiatedFps != fps {
            fps = min(max(negotiatedFps, 1), 120)
            encoder.configure(eyeWidth: viewConfigEyeWidth, eyeHeight: viewConfigEyeHeight, fps: fps)
        }
        let bitrate = Int(params.bitrate_bps.rounded())
        if bitrate > 0 {
            encoder.setAverageBitrate(bitrate)
        }
    }

    private func resetFrameCountersLocked() {
        framesEncoded = 0
        framesSent = 0
        framesDroppedNoConfig = 0
        lastVideoTargetTimestampNs = 0
    }

    private func updateBridgeStreamingReadyLocked() {
        guard clientConnected,
              lastTrackingSampleTimestampNs != 0,
              viewConfigEyeWidth > 0,
              viewConfigEyeHeight > 0 else { return }
        guard !bridgeStreamingReady else { return }
        bridgeStreamingReady = true
        setStatus("ALVR streaming ready for Java frames")
        onBridgeSessionState?(.ready)
    }

    private func republishViewConfigIfNeeded(force: Bool) {
        guard clientConnected else { return }
        let now = Self.epochNanoseconds()
        if !force, now &- lastViewConfigPublishNs < 100_000_000 { return }
        lastViewConfigPublishNs = now
        let left = Self.tangents(from: lastViewConfigLeftFov)
        let right = Self.tangents(from: lastViewConfigRightFov)
        let eyes = [
            StereoMath.EyeView(index: 0, tangents: left, width: viewConfigEyeWidth, height: viewConfigEyeHeight),
            StereoMath.EyeView(index: 1, tangents: right, width: viewConfigEyeWidth, height: viewConfigEyeHeight)
        ]
        onUplinkLine?(StereoMath.viewConfigJSON(eyes: eyes, ipdMeters: lastViewConfigIpdM))
    }

    private func startSyntheticFramesLocked() {
        guard syntheticTimer == nil else {
            syntheticFramesEnabled = true
            return
        }
        syntheticFramesEnabled = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)))
        timer.setEventHandler { [weak self] in
            self?.submitSyntheticFrameLocked()
        }
        syntheticTimer = timer
        timer.resume()
        setStatus("ALVR synthetic test pattern enabled")
    }

    private func submitSyntheticFrameLocked() {
        guard running, clientConnected, lastTrackingSampleTimestampNs != 0 else { return }
        let width = max(64, viewConfigEyeWidth)
        let height = max(64, viewConfigEyeHeight)
        let frameId = nextFrameId
        nextFrameId += 1

        let pattern = Self.makeTestPattern(width: width, height: height, frameId: frameId)
        let left = pattern
        let right = pattern
        encoder.encode(left: left, right: right, eyeWidth: width, eyeHeight: height,
                       frameId: frameId, targetTimestampNs: lastTrackingSampleTimestampNs)
    }

    private static func makeTestPattern(width: Int, height: Int, frameId: UInt64) -> Data {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let px = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let framePhase = UInt8((frameId / 4) % 255)
            let bar = max(8, min(width, height) / 16)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let checker = ((x / 64) ^ (y / 64)) & 1
                    let stripe = UInt8((x * 255) / max(1, width - 1))
                    if y < bar {
                        px[i + 0] = 0
                        px[i + 1] = 220
                        px[i + 2] = 0
                    } else if y >= height - bar {
                        px[i + 0] = 220
                        px[i + 1] = 0
                        px[i + 2] = 0
                    } else if x < bar {
                        px[i + 0] = 255
                        px[i + 1] = 255
                        px[i + 2] = 0
                    } else if x >= width - bar {
                        px[i + 0] = 0
                        px[i + 1] = 180
                        px[i + 2] = 255
                    } else {
                        px[i + 0] = UInt8(180 + checker * 50)
                        px[i + 1] = stripe
                        px[i + 2] = framePhase
                    }
                    px[i + 3] = 255
                }
            }
        }
        return data
    }

    private static func splitHEVCParameterSets(from accessUnit: Data) -> (config: Data, payload: Data) {
        let nals = annexBNALRanges(in: accessUnit)
        guard !nals.isEmpty else { return (Data(), accessUnit) }

        var config = Data()
        var payload = Data()
        let startCode = Data([0, 0, 0, 1])
        for range in nals {
            let nal = accessUnit.subdata(in: range)
            guard let first = nal.first else { continue }
            let nalType = (first >> 1) & 0x3f
            if nalType == 32 || nalType == 33 || nalType == 34 {
                config.append(startCode)
                config.append(nal)
            } else {
                payload.append(startCode)
                payload.append(nal)
            }
        }
        return (config, payload)
    }

    private static func annexBNALRanges(in data: Data) -> [Range<Data.Index>] {
        let bytes = [UInt8](data)
        var starts: [(prefix: Int, payload: Int)] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else if i + 4 < bytes.count,
                      bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append((i, i + 4))
                i += 4
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return [] }

        var ranges: [Range<Data.Index>] = []
        for index in starts.indices {
            let start = starts[index].payload
            let end = index + 1 < starts.count ? starts[index + 1].prefix : bytes.count
            if start < end {
                ranges.append(data.index(data.startIndex, offsetBy: start)..<data.index(data.startIndex, offsetBy: end))
            }
        }
        return ranges
    }

    // MARK: - Java bridge uplink

    private func publishPose(sampleTimestampNs: UInt64) {
        var pose = VCAlvrPoseSample()
        let trackingState: String
        if vc_alvr_get_head_pose(sampleTimestampNs, &pose) {
            trackingState = "valid"
        } else {
            trackingState = "lost"
            return
        }
        let bridgeTimestampNs = Self.epochNanoseconds()
        // sample_timestamp_ns is the ALVR tracking-sample id this pose was resolved for. Vivecraft
        // echoes it back on the rendered frame so the client reprojects (timewarp) against the
        // exact pose that was rendered, instead of a newer sample (which causes lag/judder).
        let line = """
        {"type":"pose","version":1,"timestamp_ns":\(bridgeTimestampNs),"sample_timestamp_ns":\(sampleTimestampNs),"position_m":[\(StereoMath.fmt(pose.position_x)),\(StereoMath.fmt(pose.position_y)),\(StereoMath.fmt(pose.position_z))],"orientation_xyzw":[\(StereoMath.fmt(pose.orientation_x)),\(StereoMath.fmt(pose.orientation_y)),\(StereoMath.fmt(pose.orientation_z)),\(StereoMath.fmt(pose.orientation_w))],"tracking_state":"\(trackingState)","recenter_counter":\(recenterCounter)}
        """
        onUplinkLine?(line + "\n")

        // Diagnostic: throttled head-pose log (VISIONCRAFT_LOG_POSE=1). Hold the head still and watch
        // whether orientation drifts — distinguishes a runaway upstream pose (AVP/ARKit/host) from a
        // downstream application bug in Vivecraft. Off by default.
        if Self.logPoseEnabled {
            let now = Self.epochNanoseconds()
            if now &- lastPoseLogNs > 250_000_000 {
                lastPoseLogNs = now
                let yawDeg = atan2(2 * (pose.orientation_w * pose.orientation_y
                    + pose.orientation_x * pose.orientation_z),
                    1 - 2 * (pose.orientation_y * pose.orientation_y
                    + pose.orientation_z * pose.orientation_z)) * 180 / .pi
                NSLog("[VisionCraft] pose yaw=%.1f deg pos=[%.3f,%.3f,%.3f] quat=[%.4f,%.4f,%.4f,%.4f]",
                      yawDeg, pose.position_x, pose.position_y, pose.position_z,
                      pose.orientation_x, pose.orientation_y, pose.orientation_z, pose.orientation_w)
            }
        }
    }

    private static let logPoseEnabled = ProcessInfo.processInfo.environment["VISIONCRAFT_LOG_POSE"] == "1"
    private var lastPoseLogNs: UInt64 = 0

    private static func fovIsFinite(_ f: VCAlvrFov) -> Bool {
        f.left.isFinite && f.right.isFinite && f.up.isFinite && f.down.isFinite
    }

    private func publishViewConfig(_ event: VCAlvrEvent) {
        // The client's first ViewsConfig can be a placeholder with NaN FOV / ipd≈0. Forwarding it
        // would poison Java's view_config (and the capture header) and produce NaN projections.
        // Reject non-finite configs and keep the last good one.
        guard Self.fovIsFinite(event.left_fov), Self.fovIsFinite(event.right_fov),
              event.ipd_m.isFinite, event.ipd_m > 0 else {
            return
        }
        lastViewConfigLeftFov = event.left_fov
        lastViewConfigRightFov = event.right_fov
        lastViewConfigIpdM = event.ipd_m
        let left = Self.tangents(from: event.left_fov)
        let right = Self.tangents(from: event.right_fov)
        let eyes = [
            StereoMath.EyeView(index: 0, tangents: left, width: viewConfigEyeWidth, height: viewConfigEyeHeight),
            StereoMath.EyeView(index: 1, tangents: right, width: viewConfigEyeWidth, height: viewConfigEyeHeight)
        ]
        lastViewConfigPublishNs = Self.epochNanoseconds()
        onUplinkLine?(StereoMath.viewConfigJSON(eyes: eyes, ipdMeters: event.ipd_m))
    }

    private func updateControllerPoses(sampleTimestampNs: UInt64) {
        for hand in ControllerHand.allCases {
            var pose = VCAlvrPoseSample()
            if vc_alvr_get_device_pose(hand.deviceId, sampleTimestampNs, &pose) {
                var state = controllerStates[hand] ?? ControllerInputState()
                state.tracked = true
                state.pose = pose
                controllerStates[hand] = state
            } else {
                var state = controllerStates[hand] ?? ControllerInputState()
                state.tracked = false
                state.pose = nil
                controllerStates[hand] = state
            }
        }
    }

    private func drainRawButtons() {
        while true {
            let count = vc_alvr_get_raw_buttons(nil)
            guard count > 0 else { return }

            var entries = Array(repeating: VCAlvrButtonEntry(), count: Int(count))
            let written = entries.withUnsafeMutableBufferPointer { buffer -> UInt64 in
                guard let base = buffer.baseAddress else { return 0 }
                return vc_alvr_get_raw_buttons(base)
            }
            for entry in entries.prefix(Int(written)) {
                guard let path = controllerButtonPaths[entry.id] else { continue }
                var state = controllerStates[path.hand] ?? ControllerInputState()
                if path.isAxis {
                    state.axes[path.name] = max(-1, min(1, entry.scalar_value))
                } else {
                    state.buttons[path.name] = entry.bool_value
                }
                controllerStates[path.hand] = state
            }
        }
    }

    private func publishControllerState(timestampNs: UInt64) {
        let controllers = ControllerHand.allCases
            .map { controllerJSON(hand: $0, state: controllerStates[$0] ?? ControllerInputState()) }
            .joined(separator: ",")
        onUplinkLine?("""
        {"type":"controller","version":1,"timestamp_ns":\(timestampNs),"controllers":[\(controllers)]}
        """ + "\n")
        publishHandProjection(timestampNs: timestampNs)
    }

    private func publishHandProjection(timestampNs: UInt64) {
        let hands = ControllerHand.allCases
            .map { handJSON(hand: $0, state: controllerStates[$0] ?? ControllerInputState()) }
            .joined(separator: ",")
        onUplinkLine?("""
        {"type":"hand","version":1,"timestamp_ns":\(timestampNs),"hands":[\(hands)]}
        """ + "\n")
    }

    private func controllerJSON(hand: ControllerHand, state: ControllerInputState) -> String {
        let buttons = Self.jsonObject(state.buttons.mapValues { $0 ? "true" : "false" })
        let axes = Self.jsonObject(state.axes.mapValues { StereoMath.fmt($0) })
        let pose = state.pose
        let position = pose.map {
            "[\(StereoMath.fmt($0.position_x)),\(StereoMath.fmt($0.position_y)),\(StereoMath.fmt($0.position_z))]"
        } ?? "[0,0,0]"
        let orientation = pose.map {
            "[\(StereoMath.fmt($0.orientation_x)),\(StereoMath.fmt($0.orientation_y)),\(StereoMath.fmt($0.orientation_z)),\(StereoMath.fmt($0.orientation_w))]"
        } ?? "[0,0,0,1]"
        let tracked = state.tracked ? "true" : "false"
        return """
        {"hand":"\(hand.rawValue)","tracked":\(tracked),"position_m":\(position),"orientation_xyzw":\(orientation),"buttons":\(buttons),"axes":\(axes)}
        """
    }

    private func handJSON(hand: ControllerHand, state: ControllerInputState) -> String {
        let pose = state.pose
        let position = pose.map {
            "[\(StereoMath.fmt($0.position_x)),\(StereoMath.fmt($0.position_y)),\(StereoMath.fmt($0.position_z))]"
        } ?? "[0,0,0]"
        let orientation = pose.map {
            "[\(StereoMath.fmt($0.orientation_x)),\(StereoMath.fmt($0.orientation_y)),\(StereoMath.fmt($0.orientation_z)),\(StereoMath.fmt($0.orientation_w))]"
        } ?? "[0,0,0,1]"
        let trigger = max(state.axes["trigger"] ?? 0, (state.buttons["trigger_click"] ?? false) ? 1.0 : 0.0)
        let squeeze = max(state.axes["squeeze"] ?? 0, (state.buttons["squeeze_click"] ?? false) ? 1.0 : 0.0)
        let tracked = (state.tracked || state.hasInput) ? "true" : "false"
        return """
        {"chirality":"\(hand.rawValue)","tracked":\(tracked),"position_m":\(position),"orientation_xyzw":\(orientation),"pinch":\(StereoMath.fmt(trigger)),"pinch_middle":\(StereoMath.fmt(squeeze))}
        """
    }

    private func resetControllerState() {
        controllerStates = [
            .left: ControllerInputState(),
            .right: ControllerInputState()
        ]
    }

    private static func makeControllerButtonPaths() -> [UInt64: ControllerButtonPath] {
        let binaryNames = [
            ("a", "a/click"),
            ("b", "b/click"),
            ("x", "x/click"),
            ("y", "y/click"),
            ("trigger_click", "trigger/click"),
            ("trigger_touch", "trigger/touch"),
            ("squeeze_click", "squeeze/click"),
            ("squeeze_touch", "squeeze/touch"),
            ("thumbstick_click", "thumbstick/click"),
            ("thumbstick_touch", "thumbstick/touch"),
            ("system_click", "system/click"),
            ("system_touch", "system/touch"),
            ("menu_click", "menu/click"),
            ("menu_touch", "menu/touch")
        ]
        let axisNames = [
            ("trigger", "trigger/value"),
            ("trigger_sensor", "trigger/sensor/value"),
            ("squeeze", "squeeze/value"),
            ("squeeze_force", "squeeze/force"),
            ("squeeze_sensor", "squeeze/sensor/value"),
            ("thumbstick_x", "thumbstick/x"),
            ("thumbstick_y", "thumbstick/y")
        ]

        var paths: [UInt64: ControllerButtonPath] = [:]
        for hand in ControllerHand.allCases {
            let prefix = "/user/hand/\(hand.rawValue)/input/"
            for (name, suffix) in binaryNames {
                paths[pathId(prefix + suffix)] = ControllerButtonPath(hand: hand, name: name, isAxis: false)
            }
            for (name, suffix) in axisNames {
                paths[pathId(prefix + suffix)] = ControllerButtonPath(hand: hand, name: name, isAxis: true)
            }
        }
        return paths
    }

    private static func pathId(_ path: String) -> UInt64 {
        path.withCString { vc_alvr_path_to_id($0) }
    }

    private static func jsonObject(_ values: [String: String]) -> String {
        guard !values.isEmpty else { return "{}" }
        return "{" + values.keys.sorted().map { "\"\($0)\":\(values[$0]!)" }.joined(separator: ",") + "}"
    }

    private static func tangents(from fov: VCAlvrFov) -> SIMD4<Float> {
        SIMD4<Float>(
            tan(-fov.left),
            tan(fov.right),
            tan(fov.up),
            tan(-fov.down)
        )
    }

    private func setStatus(_ status: String) {
        onStatus?(status)
    }

    private static func epochNanoseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
}
