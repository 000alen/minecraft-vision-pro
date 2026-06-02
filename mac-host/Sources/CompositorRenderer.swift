import Foundation
import Metal
import simd

#if canImport(ARKit)
import ARKit
import QuartzCore
#endif

#if canImport(CompositorServices)
import CompositorServices
import SwiftUI
#endif

/// Metal stereo renderer — M0 debug cube or M1 Java-submitted frames.
final class CompositorRenderer {
    /// Maximum number of GPU frames whose command buffers (and the drawables +
    /// per-eye textures they retain) may be outstanding at once. Bounds memory if
    /// GPU completion lags submission — critical on the remote Vision Pro path
    /// where presentation happens over the network. Without this bound, command
    /// buffers accumulate unbounded and the process is OOM-killed (observed
    /// hundreds of GB resident before a system stall).
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: CompositorRenderer.maxFramesInFlight)

    private var commandQueue: MTLCommandQueue?
    private var frameReceiver: FrameReceiver?
    private var debugPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var externalFramePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var debugDepthState: MTLDepthStencilState?
    private var textureSamplerState: MTLSamplerState?
    private var debugWorldTransform: simd_float4x4?
    private weak var layer: AnyObject?
    #if canImport(CompositorServices)
    @available(macOS 26.0, *)
    private weak var activeLayer: LayerRenderer?
    #endif
    private weak var posePublisher: PosePublisher?
    private var renderLoopRunning = false
    private let diagnosticsLock = NSLock()
    private var layerState = "detached"
    private var submittedFrameCount: UInt64 = 0
    private var lastDrawableCount = 0
    private var lastViewCount = 0
    private var lastTextureCount = 0
    private var lastPixelFormat = "unknown"
    private var lastTextureType = "unknown"
    private var lastRenderError = "none"
    private var lastAnchorState = "unknown"
    private var lastViewportSummary = "unknown"
    private var lastCommandBufferStatus = "unknown"
    private var lastSentViewConfig: String?
    private var viewConfigHeartbeat = 0

    #if canImport(ARKit)
    private var arKitSession: ARKitSession?
    private var worldTrackingProvider: WorldTrackingProvider?
    #endif

    #if canImport(CompositorServices)
    @available(macOS 26.0, *)
    func attach(
        layer: LayerRenderer,
        arKitSession: ARKitSession? = nil,
        worldTrackingProvider: WorldTrackingProvider? = nil,
        posePublisher: PosePublisher? = nil
    ) {
        self.layer = layer
        self.activeLayer = layer
        self.posePublisher = posePublisher
        self.arKitSession = arKitSession
        self.worldTrackingProvider = worldTrackingProvider
        let renderDevice = layer.device
        commandQueue = renderDevice.makeCommandQueue()
        frameReceiver = FrameReceiver(device: renderDevice)
        startRenderLoop()
    }
    #endif

    func detach() {
        layer = nil
        #if canImport(CompositorServices)
        if #available(macOS 26.0, *) {
            activeLayer = nil
        }
        #endif
        renderLoopRunning = false
        commandQueue = nil
        debugPipelines = [:]
        externalFramePipelines = [:]
        debugDepthState = nil
        textureSamplerState = nil
        debugWorldTransform = nil
        posePublisher = nil
        #if canImport(ARKit)
        // Release tracking resources; an orphaned session keeps the providers running.
        arKitSession?.stop()
        #endif
        arKitSession = nil
        worldTrackingProvider = nil
        frameReceiver = nil
        updateDiagnostics(layerState: "detached")
    }

    func statusJsonFragment() -> String {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }

        return """
        "renderer_layer_state":"\(Self.escapeJson(layerState))","renderer_submitted_frames":\(submittedFrameCount),"renderer_last_drawable_count":\(lastDrawableCount),"renderer_last_view_count":\(lastViewCount),"renderer_last_texture_count":\(lastTextureCount),"renderer_last_pixel_format":"\(Self.escapeJson(lastPixelFormat))","renderer_last_texture_type":"\(Self.escapeJson(lastTextureType))","renderer_last_anchor_state":"\(Self.escapeJson(lastAnchorState))","renderer_last_viewport":"\(Self.escapeJson(lastViewportSummary))","renderer_last_command_buffer_status":"\(Self.escapeJson(lastCommandBufferStatus))","renderer_last_error":"\(Self.escapeJson(lastRenderError))"
        """
    }

    #if canImport(CompositorServices)
    @available(macOS 26.0, *)
    private func startRenderLoop() {
        guard !renderLoopRunning else { return }
        renderLoopRunning = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.renderLoop()
        }
    }

    @available(macOS 26.0, *)
    private func renderLoop() {
        // CRITICAL: this loop runs on a long-lived background GCD block, so there
        // is no run loop draining the thread's autorelease pool. Every Metal
        // command buffer, drawable, and render encoder returned per frame is
        // autoreleased; without an explicit pool per iteration they accumulate
        // until the process is OOM-killed (observed ~119 GB). Wrap each iteration.
        while renderLoopRunning {
            autoreleasepool {
                guard let layer = activeLayer else {
                    Thread.sleep(forTimeInterval: 1.0 / 120.0)
                    return
                }
                switch layer.state {
                case .paused:
                    updateDiagnostics(layerState: "paused")
                    layer.waitUntilRunning()
                case .running:
                    updateDiagnostics(layerState: "running")
                    renderNextFrame(layer: layer)
                case .invalidated:
                    updateDiagnostics(layerState: "invalidated")
                    renderLoopRunning = false
                @unknown default:
                    updateDiagnostics(layerState: "unknown")
                    Thread.sleep(forTimeInterval: 1.0 / 120.0)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private func renderNextFrame(layer: LayerRenderer) {
        guard let frame = layer.queryNextFrame() else {
            updateDiagnostics(lastRenderError: "queryNextFrame returned nil")
            Thread.sleep(forTimeInterval: 1.0 / 120.0)
            return
        }

        // Update phase: the compositor measures startUpdate→endUpdate to predict
        // encode timing, so do non-pose work here. Apple's contract: do NOT touch
        // pose data during the update phase, and call predictTiming() after the
        // update phase but BEFORE queryDrawables().
        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else {
            updateDiagnostics(lastRenderError: "predictTiming returned nil")
            return
        }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        // Submission phase: query the drawable only when ready to encode (per the
        // CompositorServices header), then do all pose-dependent work.
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        guard let drawable = drawables.first(where: { $0.target == .builtIn }) ?? drawables.first,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let frameReceiver else {
            // A zero-count array means the frame was cancelled; discard it. Leaving
            // submission unbalanced here is expected (matches Apple's sample).
            updateDiagnostics(lastDrawableCount: drawables.count, lastRenderError: "missing drawable, command buffer, or frame receiver")
            return
        }
        updateDiagnostics(lastDrawableCount: drawables.count, lastRenderError: "none")

        // Publish the device's true per-eye frustum + IPD to Java so it can render with
        // the matching asymmetric projection (otherwise the symmetric fallback distorts).
        // Cheap: only serialized/sent on change or the ~1 Hz heartbeat.
        publishViewConfigIfNeeded(drawable: drawable)

        let anchor = currentDeviceAnchor(timing: drawable.frameTiming)
        updateDiagnostics(lastAnchorState: anchor == nil ? "nil" : "available")
        drawable.deviceAnchor = anchor
        posePublisher?.update(anchor: anchor)

        let headTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        if let stereo = frameReceiver.latestStereoTextures {
            // M1+: draw Java frames per eye through a depth-writing pass.
            compositeExternalTextures(
                stereo,
                headTransform: headTransform,
                into: drawable,
                commandBuffer: commandBuffer
            )
        } else {
            // M0: procedural stereo cube + axis gizmo
            drawDebugScene(
                headTransform: headTransform,
                drawable: drawable,
                commandBuffer: commandBuffer
            )
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        // Throttle GPU submission to `maxFramesInFlight`. A timed wait (rather than
        // an unbounded one) lets the loop re-check `renderLoopRunning` for clean
        // teardown, and degrades to dropping frames — not leaking them — if GPU
        // completion stalls entirely (e.g. the remote device disconnects mid-frame).
        if inFlightSemaphore.wait(timeout: .now() + 0.5) == .timedOut {
            updateDiagnostics(lastRenderError: "frame in-flight limit timeout; dropping frame")
            // Balance the submission we opened above so the compositor's frame
            // accounting stays consistent; the un-committed command buffer presents
            // nothing and is released with this frame.
            frame.endSubmission()
            return
        }
        // Capture the semaphore (not self) so the signal is guaranteed to pair with
        // the wait above even if the renderer is detached before the GPU completes.
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.updateDiagnostics(lastCommandBufferStatus: "\(buffer.status.rawValue)")
            semaphore.signal()
        }
        commandBuffer.commit()
        frame.endSubmission()
        updateDiagnostics(submittedFrameDelta: 1)
    }

    @available(macOS 26.0, *)
    private func drawDebugScene(
        headTransform: simd_float4x4,
        drawable: LayerRenderer.Drawable,
        commandBuffer: MTLCommandBuffer
    ) {
        let time = Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60))
        let views = drawable.views
        updateDiagnostics(lastViewCount: views.count, lastTextureCount: drawable.colorTextures.count)

        guard let colorTexture = drawable.colorTextures.first else {
            updateDiagnostics(lastRenderError: "missing color texture")
            return
        }

        updateDiagnostics(
            lastPixelFormat: "\(colorTexture.pixelFormat.rawValue)",
            lastTextureType: "\(colorTexture.textureType.rawValue)"
        )

        let descriptor = Self.layeredPassDescriptor(drawable: drawable, colorTexture: colorTexture)

        guard let pass = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            updateDiagnostics(lastRenderError: "failed to create render encoder")
            return
        }

        pass.label = "VisionCraft M0 debug"
        let viewports = views.map(\.textureMap.viewport)
        pass.setViewports(viewports)
        updateDiagnostics(lastViewportSummary: viewports.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.originX)),\(Int($0.originY))" }.joined(separator: ";"))

        if views.count > 1 {
            var viewMappings = views.indices.map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            pass.setVertexAmplificationCount(viewMappings.count, viewMappings: &viewMappings)
        }

        if debugWorldTransform == nil {
            debugWorldTransform = headTransform * StereoMath.translation(0, 0, -1.5)
        }

        if let pipeline = debugPipeline(
            for: colorTexture.pixelFormat,
            depthFormat: drawable.depthTextures.first?.pixelFormat ?? .invalid,
            device: colorTexture.device
        ) {
            let model = debugWorldTransform ?? matrix_identity_float4x4
            let rightIndex = min(1, max(0, views.count - 1))
            var uniforms = DebugUniforms(
                mvpLeft: StereoMath.mvp(
                    projection: drawable.computeProjection(viewIndex: 0),
                    eyeTransform: views[0].transform, head: headTransform, model: model
                ),
                mvpRight: StereoMath.mvp(
                    projection: drawable.computeProjection(viewIndex: rightIndex),
                    eyeTransform: views[rightIndex].transform, head: headTransform, model: model
                ),
                time: time,
                eyeIndex: 0
            )
            pass.setRenderPipelineState(pipeline)
            pass.setDepthStencilState(depthState(device: colorTexture.device))
            pass.setVertexBytes(&uniforms, length: MemoryLayout<DebugUniforms>.stride, index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<DebugUniforms>.stride, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            updateDiagnostics(lastRenderError: "none: direct shader debug")
        } else {
            updateDiagnostics(lastRenderError: "debug pipeline unavailable")
        }

        pass.endEncoding()
        _ = headTransform // used when cube shader is wired
    }

    private func debugPipeline(
        for pixelFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        device: MTLDevice
    ) -> MTLRenderPipelineState? {
        if let pipeline = debugPipelines[pixelFormat] {
            return pipeline
        }

        do {
            guard let library = device.makeDefaultLibrary() else {
                updateDiagnostics(lastRenderError: "default Metal library unavailable")
                return nil
            }
            guard let vertex = library.makeFunction(name: "composite_vertex"),
                  let fragment = library.makeFunction(name: "composite_fragment") else {
                updateDiagnostics(lastRenderError: "debug shader functions unavailable")
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "VisionCraft M0 debug pipeline"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.maxVertexAmplificationCount = 2
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.depthAttachmentPixelFormat = depthFormat

            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            debugPipelines[pixelFormat] = pipeline
            return pipeline
        } catch {
            updateDiagnostics(lastRenderError: "pipeline failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func externalFramePipeline(
        for pixelFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        device: MTLDevice
    ) -> MTLRenderPipelineState? {
        if let pipeline = externalFramePipelines[pixelFormat] {
            return pipeline
        }

        do {
            guard let library = device.makeDefaultLibrary() else {
                updateDiagnostics(lastRenderError: "default Metal library unavailable")
                return nil
            }
            guard let vertex = library.makeFunction(name: "fullscreen_vertex"),
                  let fragment = library.makeFunction(name: "external_frame_fragment") else {
                updateDiagnostics(lastRenderError: "external frame shader functions unavailable")
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "VisionCraft external frame pipeline"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.maxVertexAmplificationCount = 2
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.depthAttachmentPixelFormat = depthFormat

            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            externalFramePipelines[pixelFormat] = pipeline
            return pipeline
        } catch {
            updateDiagnostics(lastRenderError: "external pipeline failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func depthState(device: MTLDevice) -> MTLDepthStencilState? {
        if let debugDepthState {
            return debugDepthState
        }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = true
        let state = device.makeDepthStencilState(descriptor: descriptor)
        debugDepthState = state
        return state
    }

    private func textureSampler(device: MTLDevice) -> MTLSamplerState? {
        if let textureSamplerState {
            return textureSamplerState
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        let state = device.makeSamplerState(descriptor: descriptor)
        textureSamplerState = state
        return state
    }

    @available(macOS 26.0, *)
    private func compositeExternalTextures(
        _ stereo: FrameReceiver.StereoTextures,
        headTransform: simd_float4x4,
        into drawable: LayerRenderer.Drawable,
        commandBuffer: MTLCommandBuffer
    ) {
        let views = drawable.views
        updateDiagnostics(lastViewCount: views.count, lastTextureCount: drawable.colorTextures.count)

        guard let colorTexture = drawable.colorTextures.first else {
            updateDiagnostics(lastRenderError: "missing color texture")
            return
        }

        updateDiagnostics(
            lastPixelFormat: "\(colorTexture.pixelFormat.rawValue)",
            lastTextureType: "\(colorTexture.textureType.rawValue)"
        )

        let descriptor = Self.layeredPassDescriptor(drawable: drawable, colorTexture: colorTexture)
        guard let pass = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            updateDiagnostics(lastRenderError: "failed to create external render encoder")
            return
        }

        pass.label = "VisionCraft external frames"
        let viewports = views.map(\.textureMap.viewport)
        pass.setViewports(viewports)
        updateDiagnostics(lastViewportSummary: viewports.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.originX)),\(Int($0.originY))" }.joined(separator: ";"))

        if views.count > 1 {
            var viewMappings = views.indices.map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            pass.setVertexAmplificationCount(viewMappings.count, viewMappings: &viewMappings)
        }

        if let pipeline = externalFramePipeline(
            for: colorTexture.pixelFormat,
            depthFormat: drawable.depthTextures.first?.pixelFormat ?? .invalid,
            device: colorTexture.device
        ) {
            // Present the game's per-eye frames fullscreen (1:1) into each eye
            // viewport. The frames already carry their own projection from the
            // game, so no MVP / world transform is applied here. `headTransform`
            // is unused for presentation; the pose is published to the game
            // separately so the rendered frames already track the head.
            pass.setRenderPipelineState(pipeline)
            pass.setDepthStencilState(depthState(device: colorTexture.device))
            pass.setFragmentTexture(stereo.left, index: 0)
            pass.setFragmentTexture(stereo.right, index: 1)
            pass.setFragmentSamplerState(textureSampler(device: colorTexture.device), index: 0)
            // Single oversized triangle (3 verts) covering NDC; amplification fans
            // it out to both eye viewports.
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            updateDiagnostics(lastRenderError: "none: external frame fullscreen")
        } else {
            updateDiagnostics(lastRenderError: "external frame pipeline unavailable")
        }

        pass.endEncoding()
        _ = headTransform
    }

    @available(macOS 26.0, *)
    private func currentDeviceAnchor(timing: LayerRenderer.Frame.Timing) -> DeviceAnchor? {
        #if canImport(ARKit)
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: timing.presentationTime)
        let timestamp = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return worldTrackingProvider?.queryDeviceAnchor(atTimestamp: timestamp)
        #else
        nil
        #endif
    }

    @available(macOS 26.0, *)
    private static func layeredPassDescriptor(
        drawable: LayerRenderer.Drawable,
        colorTexture: MTLTexture
    ) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = colorTexture
        d.colorAttachments[0].loadAction = .clear
        d.colorAttachments[0].storeAction = .store
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0.90, green: 0.05, blue: 0.75, alpha: 1)
        if let depthTexture = drawable.depthTextures.first {
            d.depthAttachment.texture = depthTexture
            d.depthAttachment.loadAction = .clear
            d.depthAttachment.storeAction = .store
            d.depthAttachment.clearDepth = 0
        }
        d.renderTargetArrayLength = max(1, drawable.views.count)
        if let rasterizationRateMap = drawable.rasterizationRateMaps.first {
            d.rasterizationRateMap = rasterizationRateMap
        }
        return d
    }

    /// Compute the device's per-eye frustum tangents + IPD and broadcast a `view_config`
    /// to Java. The frustum is static for a session, so we only send on change and as a
    /// ~1 Hz heartbeat (so a Java client that connects after the first frame still gets it).
    @available(macOS 26.0, *)
    private func publishViewConfigIfNeeded(drawable: LayerRenderer.Drawable) {
        guard let posePublisher else { return }
        let views = drawable.views
        guard !views.isEmpty else { return }

        let eyes = views.indices.map { index -> StereoMath.EyeView in
            let viewport = views[index].textureMap.viewport
            return StereoMath.EyeView(
                index: index,
                tangents: StereoMath.tangents(fromProjection: drawable.computeProjection(viewIndex: index)),
                width: Int(viewport.width),
                height: Int(viewport.height)
            )
        }

        // IPD = distance between the two eye origins (eye-to-device translations).
        var ipd: Float = 0
        if views.count >= 2 {
            let a = views[0].transform.columns.3
            let b = views[1].transform.columns.3
            ipd = simd_distance(SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(b.x, b.y, b.z))
        }

        let json = StereoMath.viewConfigJSON(eyes: eyes, ipdMeters: ipd)

        viewConfigHeartbeat += 1
        let changed = json != lastSentViewConfig
        // 72 frames ≈ 1 s at the AVP frame rate.
        guard changed || viewConfigHeartbeat >= 72 else { return }
        lastSentViewConfig = json
        viewConfigHeartbeat = 0
        posePublisher.publishViewConfig(json)
    }
    #endif

    func uploadFrame(left: Data, right: Data, width: Int, height: Int) {
        frameReceiver?.upload(left: left, right: right, width: width, height: height)
    }
}

private struct DebugUniforms {
    var mvpLeft: simd_float4x4
    var mvpRight: simd_float4x4
    var time: Float
    var eyeIndex: UInt32
}

private extension CompositorRenderer {
    func updateDiagnostics(
        layerState: String? = nil,
        submittedFrameDelta: UInt64 = 0,
        lastDrawableCount: Int? = nil,
        lastViewCount: Int? = nil,
        lastTextureCount: Int? = nil,
        lastPixelFormat: String? = nil,
        lastTextureType: String? = nil,
        lastAnchorState: String? = nil,
        lastViewportSummary: String? = nil,
        lastCommandBufferStatus: String? = nil,
        lastRenderError: String? = nil
    ) {
        diagnosticsLock.lock()
        if let layerState {
            self.layerState = layerState
        }
        submittedFrameCount += submittedFrameDelta
        if let lastDrawableCount {
            self.lastDrawableCount = lastDrawableCount
        }
        if let lastViewCount {
            self.lastViewCount = lastViewCount
        }
        if let lastTextureCount {
            self.lastTextureCount = lastTextureCount
        }
        if let lastPixelFormat {
            self.lastPixelFormat = lastPixelFormat
        }
        if let lastTextureType {
            self.lastTextureType = lastTextureType
        }
        if let lastAnchorState {
            self.lastAnchorState = lastAnchorState
        }
        if let lastViewportSummary {
            self.lastViewportSummary = lastViewportSummary
        }
        if let lastCommandBufferStatus {
            self.lastCommandBufferStatus = lastCommandBufferStatus
        }
        if let lastRenderError {
            self.lastRenderError = lastRenderError
        }
        diagnosticsLock.unlock()
    }

    static func escapeJson(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
