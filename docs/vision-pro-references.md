# Apple Vision Pro — references for agents and developers

Curated index for the ALVR-backed Vision Pro path. **Read this before querying external docs** so lookups stay on-target.

Platform pins: **macOS 26+, visionOS 26+, Xcode 26+**.

## In-repo architecture

| Doc | Contents |
|-----|----------|
| [architecture.md](architecture.md) | End-to-end data flow, milestones |
| [../bridge/protocol.md](../bridge/protocol.md) | `pose`, `controller`, `hand`, `view_config`, `frame`, platform notes |
| [../AGENTS.md](../AGENTS.md) | ALVR host/client layout, golden files |

## In-repo code samples (prefer over generic Apple samples)

### ALVR client (`visionos-app/`)

| Topic | File |
|-------|------|
| Xcode entry | `ALVRClient.xcodeproj` |
| Client shader contract | `ALVRClient/Shaders.metal` |
| Rust client build/repack | `build_and_repack.sh` |
| Matching ALVR tree | `ALVR/` |

### Mac ALVR host (`mac-host/`)

| Topic | File |
|-------|------|
| ALVR lifecycle + events | `Sources/AlvrServerCoordinator.swift` |
| C ABI wrapper | `Sources/ALVRServerCoreShim.h` / `Sources/ALVRServerCoreShim.c` |
| HEVC encode | `Sources/StereoFrameEncoder.swift` |
| Java bridge | `Sources/JavaBridgeServer.swift` |

## Official Apple documentation

### Spatial rendering & compositor

| API | URL |
|-----|-----|
| Compositor Services | https://developer.apple.com/documentation/compositorservices |
| CompositorLayer | https://developer.apple.com/documentation/compositorservices/compositorlayer |
| ImmersiveSpace (visionOS) | https://developer.apple.com/documentation/swiftui/immersivespace |
| Interacting with virtual content (passthrough context) | https://developer.apple.com/documentation/compositorservices/interacting-with-virtual-content-blended-with-passthrough |

### ARKit on visionOS

| API | URL |
|-----|-----|
| Hand tracking (article + samples) | https://developer.apple.com/documentation/visionos/tracking-and-visualizing-hand-movement |
| Placing entities / device anchor | https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform |
| ARKitSession | https://developer.apple.com/documentation/arkit/arkitsession |
| HandTrackingProvider | https://developer.apple.com/documentation/arkit/handtrackingprovider |
| WorldTrackingProvider | https://developer.apple.com/documentation/arkit/worldtrackingprovider |

### SwiftUI immersive presentation

| API | URL |
|-----|-----|
| upperLimbVisibility | https://developer.apple.com/documentation/swiftui/scene/upperlimbvisibility(_:) |
| immersionStyle | https://developer.apple.com/documentation/swiftui/immersionstyle |

### Video / Metal interop

| API | URL |
|-----|-----|
| VideoToolbox compression | https://developer.apple.com/documentation/videotoolbox |
| VideoToolbox decompression | https://developer.apple.com/documentation/videotoolbox |
| CVMetalTextureCache | https://developer.apple.com/documentation/corevideo/cvmetaltexturecache |

## Context7 library IDs

Use with the Context7 MCP `query-docs` tool:

| Library | ID |
|---------|-----|
| Apple Developer Documentation (primary) | `/websites/developer_apple` |
| Technology overviews | `/websites/developer_apple_technologyoverviews` |

Example query: *"HandTrackingProvider ARKitSession run authorization visionOS code example"*

## Feature matrix (do not confuse paths)

| Feature | mac-host | visionos-app |
|---------|----------|--------------|
| ALVR server_core | ✓ | ✗ |
| ALVRClient render/decode | ✗ | ✓ |
| `HandTrackingProvider` | ✗ (unavailable) | ✓ |
| Head pose to Java | ✓ (via ALVR event/device motion) | ✓ (source) |
| Controller/pinch input to Java | ✓ (via raw ALVR button queue) | ✓ (source) |
| HEVC | encode | decode |
| Compositor reprojection | ✗ | ALVR client/on-device compositor |

## Product-specific decisions (not in Apple samples)

1. **Foveation disabled** — game frames are uniform resolution; foveation would warp them.
2. **ALVR owns headset transport** — do not reimplement ALVR wire protocol in Swift.
3. **`view_config` from device/ALVR** — Java uses real AVP frustum tangents and IPD.
4. **Parameter sets out of band** — VPS/SPS/PPS go through `alvr_set_video_config_nals`.
5. **ALVR suppresses fallback pose** — when ALVR is connected, its tracking is authoritative.
6. **Controller state comes from raw ALVR inputs** — Java consumes `controller` first and keeps
   `hand` only as a compatibility projection.

## Device bring-up checklist

1. Vision Pro paired in Xcode → Devices and Simulators (same network / account).
2. **Developer Mode** enabled on headset.
3. ALVR artifacts prepared (`scripts/prepare-alvr.sh`).
4. Development Team set for `visionos-app/ALVRClient.xcodeproj`.
5. Validate decode, orientation, fusion, tracking, and controller mappings on **hardware**.

## SDK drift note

`LayerRenderer` / drawable APIs may differ slightly in the shipping Xcode 26 SDK. After API changes, compile on Xcode 26 and adjust method names per compiler errors — do not invent signatures.
