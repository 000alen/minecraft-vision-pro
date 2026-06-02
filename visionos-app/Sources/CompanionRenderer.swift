import Foundation
import Metal
import simd
import ARKit
import CompositorServices

/// Metal stereo renderer for the companion. Submits each frame to the `CompositorLayer`
/// drawable tagged with the on-device head pose; the platform compositor reprojects the
/// submitted image to the live pose at display time.
///
/// Two content paths, mirroring the macOS host:
///  - **Video** (`VideoSource.latestFrame != nil`): blit the decoded side-by-side game frame
///    into the two eye viewports (left half → left eye, right half → right eye).
///  - **Debug** (no video yet): a loud procedural stereo pattern so "immersive opened but no
///    host video" is visually distinct from a black/failed stage.
final class CompanionRenderer {
    /// Bounds outstanding GPU frames so command buffers (and the drawables/textures they retain)
    /// cannot accumulate if presentation lags submission. Same fix as the macOS host, where the
    /// unbounded case grew to hundreds of GB resident before a stall.
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: CompanionRenderer.maxFramesInFlight)

    /// Step-1 diagnostic gate: when `false`, the per-pixel fragment reproject is bypassed so a
    /// correctly-oriented stereo frame is presented head-locked (isolates fusion from timewarp).
    /// Step 2 supersedes this with ALVR-visionOS-style geometric reprojection.
    private static let enableShaderReproject = false

    private let layerRenderer: LayerRenderer
    private let worldTracking: WorldTrackingProvider
    private weak var videoSource: VideoSource?
    private weak var trackingUplink: TrackingUplink?
    private let onFrameDecoded: (UInt64) -> Void

    /// Emits a `bridge/protocol.md` `view_config` line (newline-terminated) whenever the device's
    /// per-eye frustum/IPD changes, plus a ~1 Hz heartbeat so a late-joining Java client still
    /// receives it. The owner routes this to the stream uplink. Unlike the macOS host, these
    /// tangents come from the *real device* drawable, so Minecraft renders the exact AVP frustum.
    var onViewConfig: ((String) -> Void)?
    /// Called when the compositor layer is invalidated (immersive space dismissed).
    var onCompositorEnded: (() -> Void)?
    private var lastViewConfig: String?
    private var viewConfigHeartbeat = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var debugPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var externalPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var depthStencilState: MTLDepthStencilState?
    private var sampler: MTLSamplerState?
    private var debugWorldTransform: simd_float4x4?

    private var renderLoopRunning = false
    private var presentedFrameCount: UInt64 = 0

    init(
        layerRenderer: LayerRenderer,
        worldTracking: WorldTrackingProvider,
        videoSource: VideoSource?,
        trackingUplink: TrackingUplink?,
        onFrameDecoded: @escaping (UInt64) -> Void
    ) {
        self.layerRenderer = layerRenderer
        self.worldTracking = worldTracking
        self.videoSource = videoSource
        self.trackingUplink = trackingUplink
        self.onFrameDecoded = onFrameDecoded
        self.device = layerRenderer.device
        self.commandQueue = layerRenderer.device.makeCommandQueue()!
    }

    func startRenderLoop() {
        guard !renderLoopRunning else { return }
        renderLoopRunning = true
        Thread.detachNewThread { [weak self] in
            self?.renderLoop()
        }
    }

    func stop() {
        renderLoopRunning = false
    }

    private func renderLoop() {
        // Long-lived background thread without a run loop draining autorelease pools: wrap each
        // iteration so per-frame command buffers/drawables/encoders are released promptly.
        while renderLoopRunning {
            autoreleasepool {
                switch layerRenderer.state {
                case .paused:
                    layerRenderer.waitUntilRunning()
                case .running:
                    renderNextFrame()
                case .invalidated:
                    renderLoopRunning = false
                    onCompositorEnded?()
                @unknown default:
                    Thread.sleep(forTimeInterval: 1.0 / 90.0)
                }
            }
        }
    }

    private func renderNextFrame() {
        // Bound frames in flight (each command buffer retains its drawable + textures). Acquire a
        // slot up front and release it on every exit path; the success path transfers ownership of
        // the slot to the command buffer completion handler instead.
        inFlightSemaphore.wait()
        var slotHeld = true
        defer { if slotHeld { inFlightSemaphore.signal() } }

        guard let frame = layerRenderer.queryNextFrame() else {
            Thread.sleep(forTimeInterval: 1.0 / 120.0)
            return
        }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else {
            Thread.sleep(forTimeInterval: 1.0 / 120.0)
            return
        }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        // An empty drawable list means the frame is no longer valid (typically the stage is tearing
        // down). Return WITHOUT calling endSubmission(): doing so on an invalid frame logs
        // "cp_frame_end_submission() failed because the frame is not valid".
        let drawables = frame.queryDrawables()
        guard let drawable = drawables.first(where: { $0.target == .builtIn }) ?? drawables.first,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let presentationSeconds = presentationTimeSeconds(drawable.frameTiming)
        trackingUplink?.setPresentationTimestamp(seconds: presentationSeconds)

        // Compositor Services drops any drawable presented without a device anchor ("Presenting a
        // drawable without a device anchor. This drawable won't be presented."). Always tag it with
        // the predicted presentation anchor. For streamed frames carrying `render_orientation_xyzw`,
        // the composite shader already timewarps the image to *this same* predicted head pose, so
        // the platform's late-stage reprojection corrects only the residual prediction error rather
        // than stacking a second full rotation on the warp.
        let anchor = deviceAnchor(presentationTime: drawable.frameTiming)
        drawable.deviceAnchor = anchor
        let headTransform = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        // Publish the device's true per-eye frustum + IPD to Java (via the uplink) so Minecraft
        // renders the matching asymmetric projection. Cheap: only serialized/sent on change or the
        // ~1 Hz heartbeat.
        publishViewConfigIfNeeded(drawable: drawable)

        let decoded = videoSource?.latestFrame
        if let decoded {
            compositeVideo(decoded, into: drawable, headTransform: headTransform, commandBuffer: commandBuffer)
            onFrameDecoded(decoded.frameID)
        } else {
            drawDebugScene(headTransform: headTransform, drawable: drawable, commandBuffer: commandBuffer)
        }

        drawable.encodePresent(commandBuffer: commandBuffer)
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        slotHeld = false // ownership of the in-flight slot transfers to the completion handler
        commandBuffer.commit()
        frame.endSubmission()
        presentedFrameCount &+= 1
    }

    // MARK: - view_config

    private func publishViewConfigIfNeeded(drawable: LayerRenderer.Drawable) {
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
        let changed = json != lastViewConfig
        // ~1 Hz heartbeat at 90 fps so a Java client connecting mid-session still receives it.
        guard changed || viewConfigHeartbeat >= 90 else { return }
        viewConfigHeartbeat = 0
        lastViewConfig = json
        onViewConfig?(json)
    }

    private func presentationTimeSeconds(_ timing: LayerRenderer.Frame.Timing) -> Double {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: timing.presentationTime)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func deviceAnchor(presentationTime: LayerRenderer.Frame.Timing) -> DeviceAnchor? {
        worldTracking.queryDeviceAnchor(atTimestamp: presentationTimeSeconds(presentationTime))
    }

    // MARK: - Video composite

    private func compositeVideo(
        _ decoded: DecodedFrame,
        into drawable: LayerRenderer.Drawable,
        headTransform: simd_float4x4,
        commandBuffer: MTLCommandBuffer
    ) {
        let views = drawable.views
        guard let colorTexture = drawable.colorTextures.first,
              let pass = commandBuffer.makeRenderCommandEncoder(
                descriptor: Self.passDescriptor(drawable: drawable, colorTexture: colorTexture)
              ) else { return }

        pass.label = "VisionCraft video composite"
        pass.setViewports(views.map(\.textureMap.viewport))
        if views.count > 1 {
            var mappings = views.indices.map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            pass.setVertexAmplificationCount(mappings.count, viewMappings: &mappings)
        }

        if let pipeline = externalPipeline(
            color: colorTexture.pixelFormat,
            depth: drawable.depthTextures.first?.pixelFormat ?? .invalid
        ) {
            var uniforms = compositeUniforms(decoded: decoded, drawable: drawable, headTransform: headTransform)
            pass.setRenderPipelineState(pipeline)
            pass.setDepthStencilState(depthState())
            pass.setFragmentTexture(decoded.luma, index: 0)
            pass.setFragmentTexture(decoded.chroma, index: 1)
            pass.setFragmentSamplerState(textureSampler(), index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        pass.endEncoding()
    }

    /// Build the per-frame composite parameters: per-eye frustum tangents (so the shader can map a
    /// display pixel ↔ a view ray) and the rotational-timewarp delta. The delta rotates the live
    /// display ray back into the orientation the frame was rendered for:
    /// `warp = R_render⁻¹ · R_now`, where both are ARKit-world head orientations. When the frame
    /// carries no render orientation, the warp is identity and reprojection is disabled.
    private func compositeUniforms(
        decoded: DecodedFrame,
        drawable: LayerRenderer.Drawable,
        headTransform: simd_float4x4
    ) -> CompositeUniforms {
        let views = drawable.views
        let leftTangents = StereoMath.tangents(fromProjection: drawable.computeProjection(viewIndex: 0))
        let rightIndex = min(1, max(0, views.count - 1))
        let rightTangents = StereoMath.tangents(fromProjection: drawable.computeProjection(viewIndex: rightIndex))

        var warp = matrix_identity_float4x4
        var reproject: UInt32 = 0
        // Step 1 (diagnostic): the per-pixel fragment ray-march reproject is disabled to isolate
        // stereo fusion from rotational timewarp. With it off, each eye samples its packed half 1:1
        // (head-locked, Compositor Services still corrects scanout via `drawable.deviceAnchor`), so a
        // correctly-oriented image should fuse. Step 2 replaces this with ALVR-visionOS's geometric
        // reprojection (place the video quad at the frame's predicted pose, render through the live
        // per-eye projection) rather than re-enabling the ray-march.
        if Self.enableShaderReproject, let qRender = decoded.renderOrientation {
            // Head orientation now (ARKit world ← device), same space as `qRender`.
            let qNow = simd_quatf(headTransform)
            let delta = qRender.inverse * qNow
            warp = simd_float4x4(delta)
            reproject = 1
        }

        return CompositeUniforms(
            tangentsLeft: leftTangents,
            tangentsRight: rightTangents,
            warp: warp,
            packing: decoded.packing == .sideBySide ? 0 : 1,
            reproject: reproject
        )
    }

    // MARK: - Debug scene

    private func drawDebugScene(
        headTransform: simd_float4x4,
        drawable: LayerRenderer.Drawable,
        commandBuffer: MTLCommandBuffer
    ) {
        let time = Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60))
        let views = drawable.views
        guard let colorTexture = drawable.colorTextures.first,
              let pass = commandBuffer.makeRenderCommandEncoder(
                descriptor: Self.passDescriptor(drawable: drawable, colorTexture: colorTexture)
              ) else { return }

        pass.label = "VisionCraft debug scene"
        pass.setViewports(views.map(\.textureMap.viewport))
        if views.count > 1 {
            var mappings = views.indices.map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            pass.setVertexAmplificationCount(mappings.count, viewMappings: &mappings)
        }

        if debugWorldTransform == nil {
            debugWorldTransform = headTransform * StereoMath.translation(0, 0, -1.5)
        }

        guard let pipeline = debugPipeline(
            color: colorTexture.pixelFormat,
            depth: drawable.depthTextures.first?.pixelFormat ?? .invalid
        ) else {
            pass.endEncoding()
            return
        }

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
        pass.setDepthStencilState(depthState())
        pass.setVertexBytes(&uniforms, length: MemoryLayout<DebugUniforms>.stride, index: 0)
        pass.setFragmentBytes(&uniforms, length: MemoryLayout<DebugUniforms>.stride, index: 0)
        pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        pass.endEncoding()
    }

    // MARK: - Pipeline / state caches

    private func debugPipeline(color: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = debugPipelines[color] { return cached }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "composite_vertex"),
              let fragment = library.makeFunction(name: "composite_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "VisionCraft debug pipeline"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.maxVertexAmplificationCount = 2
        descriptor.colorAttachments[0].pixelFormat = color
        descriptor.depthAttachmentPixelFormat = depth
        let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        debugPipelines[color] = pipeline
        return pipeline
    }

    private func externalPipeline(color: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = externalPipelines[color] { return cached }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "fullscreen_vertex"),
              let fragment = library.makeFunction(name: "companion_external_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "VisionCraft external frame pipeline"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.maxVertexAmplificationCount = 2
        descriptor.colorAttachments[0].pixelFormat = color
        descriptor.depthAttachmentPixelFormat = depth
        let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        externalPipelines[color] = pipeline
        return pipeline
    }

    private func depthState() -> MTLDepthStencilState? {
        if let depthStencilState { return depthStencilState }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: descriptor)
        return depthStencilState
    }

    private func textureSampler() -> MTLSamplerState? {
        if let sampler { return sampler }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: descriptor)
        return sampler
    }

    // MARK: - Helpers

    private static func passDescriptor(
        drawable: LayerRenderer.Drawable,
        colorTexture: MTLTexture
    ) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = colorTexture
        d.colorAttachments[0].loadAction = .clear
        d.colorAttachments[0].storeAction = .store
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        if let depthTexture = drawable.depthTextures.first {
            d.depthAttachment.texture = depthTexture
            d.depthAttachment.loadAction = .clear
            d.depthAttachment.storeAction = .store
            d.depthAttachment.clearDepth = 0
        }
        d.renderTargetArrayLength = max(1, drawable.views.count)
        if let rateMap = drawable.rasterizationRateMaps.first {
            d.rasterizationRateMap = rateMap
        }
        return d
    }
}

private struct DebugUniforms {
    var mvpLeft: simd_float4x4
    var mvpRight: simd_float4x4
    var time: Float
    var eyeIndex: UInt32
}

/// Mirrors `CompositeUniforms` in `Composite.metal` (same field order and 16-byte alignment).
private struct CompositeUniforms {
    var tangentsLeft: SIMD4<Float>   // [left, right, up, down]
    var tangentsRight: SIMD4<Float>
    var warp: simd_float4x4
    var packing: UInt32              // 0 side-by-side, 1 top-bottom
    var reproject: UInt32            // 0 disabled, 1 enabled
}
