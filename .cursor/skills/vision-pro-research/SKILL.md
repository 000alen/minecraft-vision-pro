---
name: vision-pro-research
description: >-
  Researches Apple Vision Pro and visionOS APIs before implementing or changing
  companion app code, hand tracking, CompositorLayer immersive rendering, stream
  decode, or pose/hand uplink. Use when editing visionos-app/, when the user
  mentions Vision Pro, visionOS, HandTrackingProvider, ImmersiveSpace, pinch
  input, companion app, or on-device tracking — and before any Apple spatial
  API change in this repo.
---

# Vision Pro research workflow

Complete this workflow **before** proposing code changes for Apple Vision Pro or visionOS work in VisionCraft.

## Step 1 — Identify the rendering path

| Question | If yes → path |
|----------|----------------|
| Editing `visionos-app/`? | **On-device companion** |
| Editing `mac-host/`? | **Mac RemoteImmersiveSpace** |
| Touching `hand` / pinch? | **Companion only** — never mac-host |

Read [AGENTS.md](../../../AGENTS.md) path table if unsure.

## Step 2 — Read in-repo sources

**Companion (Vision Pro on-device):**

- `visionos-app/Sources/VisionCraftCompanionApp.swift`
- `visionos-app/Sources/AppModel.swift`
- `visionos-app/Sources/CompanionRenderer.swift`
- `visionos-app/Sources/TrackingUplink.swift`
- `visionos-app/Sources/HandPinch.swift`
- `visionos-app/Sources/VideoStreamDecoder.swift`
- `visionos-app/README.md`

**Mac host (remote display):**

- `mac-host/Sources/VisionCraftImmersiveContent.swift`
- `mac-host/Sources/CompositorRenderer.swift`

**Wire contracts:**

- `bridge/protocol.md` — `pose`, `hand`, `view_config`, `recenter`
- `bridge/stream-protocol.md` — Mac ↔ companion stream

**Curated links:**

- `docs/vision-pro-references.md`
- `docs/apple-spatial-rendering-notes.md`

Search the repo for existing usage of the API you plan to change (`grep` / semantic search).

## Step 3 — Query official Apple documentation

Use **Context7** MCP:

1. `resolve-library-id` with libraryName `Apple Developer Documentation` (or use ID directly).
2. `query-docs` with libraryId `/websites/developer_apple` and a **specific** query.

Example queries:

- `ImmersiveSpace CompositorLayer LayerRenderer Metal render loop visionOS`
- `HandTrackingProvider ARKitSession requestAuthorization hand tracking`
- `WorldTrackingProvider queryDeviceAnchor device transform`
- `RemoteImmersiveSpace macOS compositor remote device`

Also useful: `/websites/developer_apple_technologyoverviews` for conceptual spatial computing docs.

If Context7 returns nothing useful for a macOS 26 / visionOS 26 API, **WebFetch** the documentation URL from `docs/vision-pro-references.md`.

## Step 4 — Prefer Apple samples for lifecycle; prefer repo code for integration

- **Lifecycle / threading** (render thread, `CompositorLayer` closure, session run): follow Apple doc samples.
- **Wire format, reprojection, foveation off, view_config, stream decode**: follow **this repo** — it encodes product-specific decisions Apple samples do not cover.

## Step 5 — Research notes (required output before diffs)

Provide a short block:

```markdown
## Research notes
- Path: companion | mac-host
- In-repo precedent: <file:area>
- Apple docs: <title + URL>
- API/lifecycle: <1–3 sentences>
- Risks: <simulator vs device, threading, protocol compatibility>
```

## Step 6 — Implement

- Match existing naming, threading, and protocol shapes.
- Minimal diff; do not refactor unrelated code.
- After Swift changes, note if validation requires **physical Vision Pro** (hand tracking, immersive stage, decode latency).

## Common mistakes to avoid

- `HandTrackingProvider` on macOS
- `RemoteImmersiveSpace` in the companion app
- Enabling foveation on blitted game frames
- Blocking the compositor thread on main-actor UI work
- Changing `hand` / `pose` JSON without updating `bridge/protocol.md` and Java consumers
