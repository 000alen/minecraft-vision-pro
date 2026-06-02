# Apple Vision Pro — references for agents and developers

Curated index for visionOS companion work, Mac remote immersive host, and shared compositor patterns. **Read this before querying external docs** so lookups stay on-target.

Platform pins: **macOS 26+, visionOS 26+, Xcode 26+**.

## In-repo architecture

| Doc | Contents |
|-----|----------|
| [architecture.md](architecture.md) | End-to-end data flow, milestones |
| [apple-spatial-rendering-notes.md](apple-spatial-rendering-notes.md) | RemoteImmersiveSpace, compositor, Metal interop |
| [../bridge/protocol.md](../bridge/protocol.md) | `pose`, `hand`, `view_config`, `frame`, platform notes |
| [../bridge/stream-protocol.md](../bridge/stream-protocol.md) | HEVC stream Mac ↔ companion |
| [../AGENTS.md](../AGENTS.md) | Mac vs visionOS path split, golden files |

## In-repo code samples (prefer over generic Apple samples)

### On-device companion (`visionos-app/`)

| Topic | File |
|-------|------|
| App + immersive scene | `Sources/VisionCraftCompanionApp.swift` |
| ARKit auth + lifecycle | `Sources/AppModel.swift` |
| Metal render loop + reprojection | `Sources/CompanionRenderer.swift` |
| Pose / hand / recenter uplink | `Sources/TrackingUplink.swift` |
| Pinch from joints | `Sources/HandPinch.swift` |
| HEVC decode → Metal | `Sources/VideoStreamDecoder.swift` |
| Stream client | `Sources/StreamClient.swift` |
| Bring-up / pairing | `README.md` |

### Mac remote display (`mac-host/`)

| Topic | File |
|-------|------|
| RemoteImmersiveSpace + remote ARKit | `Sources/VisionCraftImmersiveContent.swift` |
| Metal compositor | `Sources/CompositorRenderer.swift` |
| Stream relay when companion joins | `Sources/StreamRelayCoordinator.swift` |

## Official Apple documentation

### Spatial rendering & compositor

| API | URL |
|-----|-----|
| Compositor Services | https://developer.apple.com/documentation/compositorservices |
| CompositorLayer | https://developer.apple.com/documentation/compositorservices/compositorlayer |
| RemoteImmersiveSpace (macOS → AVP) | https://developer.apple.com/documentation/swiftui/remoteimmersivespace |
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

### Video / Metal interop (stream path)

| API | URL |
|-----|-----|
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
| `RemoteImmersiveSpace` | ✓ | ✗ |
| `ImmersiveSpace` | ✗ | ✓ |
| `HandTrackingProvider` | ✗ (unavailable) | ✓ |
| Head pose to Java | ✓ (local or relay) | ✓ (uplink) |
| Hand pinch to Java | ✗ (mock/tests only) | ✓ |
| HEVC | encode | decode |
| Compositor reprojection | Mac compositor | On-device compositor |

## Product-specific decisions (not in Apple samples)

1. **Foveation disabled** — game frames are uniform resolution; foveation would warp them (`ContentStageConfiguration`, mac host config).
2. **Latest-frame-wins** — decoder and renderer drop stale frames under load.
3. **`view_config` from device drawable** — Java uses real AVP frustum tangents and IPD.
4. **Hand visible** — `.upperLimbVisibility(.visible)` so pinch feels direct.
5. **Render thread off main actor** — UI hops via `AppModel.mainAsync`.
6. **Relay suppresses Mac pose** — when companion is connected, uplink is authoritative.

## Device bring-up checklist

1. Vision Pro paired in Xcode → Devices and Simulators (same network / account).
2. **Developer Mode** enabled on headset.
3. Development Team set in generated Xcode projects (`scripts/gen-projects.sh`).
4. Hand tracking: call `requestAuthorization(for: [.handTracking, .worldSensing])` before immersive transition.
5. Validate pinch and immersive stage on **hardware** — simulator is insufficient for full tracking UX.

## SDK drift note

`LayerRenderer` / drawable APIs may differ slightly in the shipping Xcode 26 SDK. After API changes, compile on Xcode 26 and adjust method names per compiler errors — do not invent signatures. See `mac-host/README.md` API notes.
