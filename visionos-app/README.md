# VisionCraft companion (visionOS)

A native visionOS app that runs **on the Vision Pro** and turns it into a low-latency display +
input device for Minecraft running on the Mac. This is the Mac-only path to **real hand/pinch
input**: `HandTrackingProvider` is an on-device feature and cannot run in the macOS
RemoteImmersiveSpace host.

## Architecture

```
 Minecraft (Java)          Mac relay (Swift)                 VisionCraft companion (this app)
 ───────────────           ─────────────────                 ────────────────────────────────
 raw RGBA eye frames ─bridge/protocol.md (loopback)─▶ JavaBridgeServer
                                    │ HEVC encode (VideoToolbox, M4)
                                    │ bridge/stream-protocol.md (LAN TCP)
                                    ├──────── VIDEO_FRAME ────────────▶ decode → composite → CompositorLayer
   pose / hand / recenter ◀─bridge/protocol.md─┤◀────── UPLINK (pose/hand) ──────  ARKit world + hand tracking
```

- The **Java side and the loopback bridge are unchanged** — Minecraft already streams eye frames
  and consumes `pose`/`hand`/`view_config`.
- The **Mac relay** (Phase 2, `mac-host/`) swaps the frame sink (compositor → HEVC encoder) and
  the pose/hand source (Mac WorldTracking → this app's uplink).
- This app submits each decoded frame to a `CompositorLayer`; **the visionOS compositor reprojects
  to the live head pose at display time**, so head-look stays locked despite stream latency.

See `../bridge/stream-protocol.md` for the wire format.

## Status (phased)

- **Phase 1 (done):** app + immersive stage + on-device head/hand tracking + uplink + stream client
  framing. The renderer shows a debug stereo pattern until video arrives, so this is **testable on
  the headset alone** (no Mac needed) to validate tracking, pinch, and the stage.
- **Phase 2 (done):** end-to-end video + frustum.
  - **Mac relay** (`mac-host/`): `StereoFrameEncoder` (vImage RGBA→BGRA pack + VideoToolbox HEVC →
    Annex-B) → `StreamRelayServer` (Bonjour `_visioncraft-stream._tcp`, single viewer) wired through
    `StreamRelayCoordinator`. The companion's uplink is forwarded into the loopback bridge and the
    host's local pose emitter is suppressed while the headset is connected.
  - **Companion**: `VideoStreamDecoder` rebuilds a `CMVideoFormatDescription` from each keyframe's
    inline VPS/SPS/PPS, feeds VCL NALs to a low-latency `VTDecompressionSession`, and wraps the
    output `CVPixelBuffer` as an `MTLTexture` via `CVMetalTextureCache` (latest-frame-wins, current
    + previous frame retained for in-flight GPU reads). `CompanionRenderer` also emits the device's
    true per-eye `view_config` (tangents + IPD) over the uplink, so Minecraft renders the exact AVP
    frustum.
- **Remaining:** on-device bring-up (decode latency/color/orientation verification on the headset).

## Files

| File | Role |
|------|------|
| `Sources/VisionCraftCompanionApp.swift` | App entry, `ImmersiveSpace` + `CompositorLayer` config |
| `Sources/AppModel.swift` | Lifecycle owner: ARKit session, client, uplink, renderer |
| `Sources/ContentView.swift` | Launch window: status + connect + enter |
| `Sources/CompanionRenderer.swift` | Metal stereo render loop (video composite / debug) |
| `Sources/TrackingUplink.swift` | World+hand tracking → `pose`/`hand` lines |
| `Sources/HandPinch.swift` | Index↔thumb pinch strength |
| `Sources/StreamClient.swift` | Bonjour discovery + `stream-protocol` client |
| `Sources/StreamProtocol.swift` | Envelope framing |
| `Sources/VideoStreamDecoder.swift` | HEVC decode → `MTLTexture` (VideoToolbox + `CVMetalTextureCache`) |
| `Sources/VideoSource.swift` | `VideoSource` protocol + `DecodedFrame` |
| `Shaders/Composite.metal` | Debug pattern + per-eye video sampling |
| `Resources/Info.plist` | Usage strings + Bonjour service |
| `Resources/VisionCraftCompanion.entitlements` | (no special capability needed) |

## Create the Xcode target

This repo keeps sources flat (like `mac-host/`); create the app target in Xcode on the Mac:

1. **File → New → Project → visionOS → App.** Product name `VisionCraftCompanion`,
   interface **SwiftUI**, language **Swift**. Set deployment target to **visionOS 2.0+**.
2. Delete the template `ContentView`/`App` files; **add** all of `Sources/*.swift` and
   `Shaders/Composite.metal` to the target.
3. Set the target's **Info.plist** to `Resources/Info.plist` (or merge its keys), and the
   **Code Signing Entitlements** to `Resources/VisionCraftCompanion.entitlements`.
4. Signing & Capabilities: select your team. No extra capability is required — hand/world tracking
   are gated by the Info.plist usage strings; LAN networking by `NSLocalNetworkUsageDescription`.
5. If the new target defaults to the Swift 6 language mode and the `CompositorLayer` closure
   produces concurrency errors, set **Swift Language Version → Swift 5** for the target (matches
   Apple's Metal-immersive sample structure).

## Deploy to the device

1. Pair the Vision Pro in **Xcode → Window → Devices and Simulators** (same Wi-Fi/account).
2. Enable **Developer Mode** on the Vision Pro (Settings → Privacy & Security).
3. Select the device as the run destination and **Run**. Grant hand-tracking and local-network
   prompts on first launch.
4. Phase 1 check (no Mac required): tap **Enter VisionCraft** → you should see the debug stereo
   pattern locked in front of you and, with the Mac relay running, the status should reach
   "streaming". Pinch to confirm input once the relay is live.

## Why not Foveated Streaming?

Apple's Foveated Streaming framework (visionOS 26.4) requires an NVIDIA CloudXR host (Windows +
RTX). That violates the Mac-only constraint, so this companion uses standard CompositorServices +
our own HEVC transport instead. We still get the platform's free head-pose reprojection.
