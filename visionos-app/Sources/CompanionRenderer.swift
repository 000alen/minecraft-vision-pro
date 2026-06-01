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

    private let layerRenderer: LayerRenderer
    private let worldTracking: WorldTrackingProvider
    private weak var videoSource: VideoSource?
    private let onFrameDecoded: (UInt64) -> Void

    /// Emits a `bridge/protocol.md` `view_config` line (newline-terminated) whenever the device's
    /// per-eye frustum/IPD changes, plus a ~1 Hz heartbeat so a late-joining Java client still
    /// receives it. The owner routes this to the stream uplink. Unlike the macOS host, these
    /// tangents come from the *real device* drawable, so Minecraft renders the exact AVP frustum.
    var onViewConfig: ((String) -> Void)?
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
        onFrameDecoded: @escaping (UInt64) -> Void
    ) {
        self.layerRenderer = layerRenderer
        self.worldTracking = worldTracking
        self.videoSource = videoSource
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
                @unknown default:
                    Thread.sleep(forTimeInterval: 1.0 / 90.0)
                }
            }
        }
    }

    private func renderNextFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        guard let drawable = frame.queryDrawables().first,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let anchor = deviceAnchor(presentationTime: drawable.frameTiming)
        drawable.deviceAnchor = anchor
        let headTransform = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        // Publish the device's true per-eye frustum + IPD to Java (via the uplink) so Minecraft
        // renders the matching asymmetric projection. Cheap: only serialized/sent on change or the
        // ~1 Hz heartbeat.
        publishViewConfigIfNeeded(drawable: drawable)

        if let decoded = videoSource?.latestFrame {
            compositeVideo(decoded, into: drawable, commandBuffer: commandBuffer)
            onFrameDecoded(decoded.frameID)
        } else {
            drawDebugScene(headTransform: headTransform, drawable: drawable, commandBuffer: commandBuffer)
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        if inFlightSemaphore.wait(timeout: .now() + 0.5) == .timedOut {
            // GPU completion stalled (e.g. stage tearing down). Balance submission and drop.
            frame.endSubmission()
            return
        }
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
        frame.endSubmission()
        presentedFrameCount &+= 1
    }

    // MARK: - view_config

    private func publishViewConfigIfNeeded(drawable: LayerRenderer.Drawable) {
        let views = drawable.views
        guard !views.isEmpty else { return }

        var eyeFragments: [String] = []
        eyeFragments.reserveCapacity(views.count)
        for index in views.indices {
            let projection = drawable.computeProjection(viewIndex: index)
            let tangents = Self.tangents(fromProjection: projection)
            let viewport = views[index].textureMap.viewport
            eyeFragments.append(
                "{\"index\":\(index),\"tangents\":[\(Self.fmt(tangents.x)),\(Self.fmt(tangents.y)),\(Self.fmt(tangents.z)),\(Self.fmt(tangents.w))],\"width\":\(Int(viewport.width)),\"height\":\(Int(viewport.height))}"
            )
        }

        // IPD = distance between the two eye origins (eye-to-device translations).
        var ipd: Float = 0
        if views.count >= 2 {
            let a = views[0].transform.columns.3
            let b = views[1].transform.columns.3
            ipd = simd_distance(SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(b.x, b.y, b.z))
        }

        let json = "{\"type\":\"view_config\",\"version\":1,\"ipd_m\":\(Self.fmt(ipd)),\"views\":[\(eyeFragments.joined(separator: ","))]}\n"

        viewConfigHeartbeat += 1
        let changed = json != lastViewConfig
        // ~1 Hz heartbeat at 90 fps so a Java client connecting mid-session still receives it.
        guard changed || viewConfigHeartbeat >= 90 else { return }
        viewConfigHeartbeat = 0
        lastViewConfig = json
        onViewConfig?(json)
    }

    /// Recover the positive frustum tangents `[left, right, up, down]` from a Compositor Services
    /// projection matrix — same convention-agnostic method as the macOS host, so both ends agree.
    /// For any perspective projection, the inverse maps an NDC edge point to a view-space ray whose
    /// lateral/forward ratio is that edge's tangent; magnitudes make it robust to handedness /
    /// reverse-Z.
    private static func tangents(fromProjection projection: simd_float4x4) -> SIMD4<Float> {
        let inverse = projection.inverse
        func edgeDirection(_ ndcX: Float, _ ndcY: Float) -> SIMD3<Float> {
            let view = inverse * SIMD4<Float>(ndcX, ndcY, 0.5, 1)
            let w = abs(view.w) > 1e-7 ? view.w : 1
            return SIMD3<Float>(view.x, view.y, view.z) / w
        }
        func tangent(_ lateral: Float, _ forward: Float) -> Float {
            let denom = max(abs(forward), 1e-6)
            return min(max(abs(lateral) / denom, 0.05), 10.0)
        }
        let left = edgeDirection(-1, 0)
        let right = edgeDirection(1, 0)
        let up = edgeDirection(0, 1)
        let down = edgeDirection(0, -1)
        return SIMD4<Float>(
            tangent(left.x, left.z),
            tangent(right.x, right.z),
            tangent(up.y, up.z),
            tangent(down.y, down.z)
        )
    }

    private static func fmt(_ value: Float) -> String {
        String(format: "%.6g", value)
    }

    private func deviceAnchor(presentationTime: LayerRenderer.Frame.Timing) -> DeviceAnchor? {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: presentationTime.presentationTime)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return worldTracking.queryDeviceAnchor(atTimestamp: seconds)
    }

    // MARK: - Video composite

    private func compositeVideo(
        _ decoded: DecodedFrame,
        into drawable: LayerRenderer.Drawable,
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
            var packing = UInt32(decoded.packing == .sideBySide ? 0 : 1)
            pass.setRenderPipelineState(pipeline)
            pass.setDepthStencilState(depthState())
            pass.setFragmentTexture(decoded.texture, index: 0)
            pass.setFragmentSamplerState(textureSampler(), index: 0)
            pass.setFragmentBytes(&packing, length: MemoryLayout<UInt32>.stride, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        pass.endEncoding()
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
            debugWorldTransform = headTransform * Self.translation(0, 0, -1.5)
        }

        guard let pipeline = debugPipeline(
            color: colorTexture.pixelFormat,
            depth: drawable.depthTextures.first?.pixelFormat ?? .invalid
        ) else {
            pass.endEncoding()
            return
        }

        let model = debugWorldTransform ?? matrix_identity_float4x4
        var uniforms = DebugUniforms(
            mvpLeft: Self.mvp(drawable: drawable, viewIndex: 0, model: model, head: headTransform),
            mvpRight: Self.mvp(drawable: drawable, viewIndex: min(1, views.count - 1), model: model, head: headTransform),
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

    private static func mvp(
        drawable: LayerRenderer.Drawable,
        viewIndex: Int,
        model: simd_float4x4,
        head: simd_float4x4
    ) -> simd_float4x4 {
        let index = min(max(0, viewIndex), max(0, drawable.views.count - 1))
        let eyeWorld = head * drawable.views[index].transform
        let projection = drawable.computeProjection(viewIndex: index)
        return projection * eyeWorld.inverse * model
    }

    private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1)
        )
    }
}

private struct DebugUniforms {
    var mvpLeft: simd_float4x4
    var mvpRight: simd_float4x4
    var time: Float
    var eyeIndex: UInt32
}
