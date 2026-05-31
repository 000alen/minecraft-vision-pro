# Vendored upstream

VisionCraft **vendors** VivecraftMod in-tree for full control. No git submodules.

| Field | Value |
|-------|--------|
| Upstream | https://github.com/Vivecraft/VivecraftMod |
| Vendored commit | `7624f943a30718f9c1575763d89c853577a85610` |
| Vendored date | 2026-05-31 |
| Clone depth | 1 (snapshot); replace with full history if you need `git log` against upstream |

## VisionCraft changes (in vendored tree)

- `org.vivecraft.client_vr.provider.apple.*` — Apple Vision VR backend
- `visioncraft.bridge.*` — Java ↔ macOS host protocol client
- `VRSettings.VRProvider.APPLE_VISION` (default provider for this fork)
- `VRState` selects `AppleVisionProvider` when Apple Vision is chosen
- `DeviceSource.Source.APPLE`

## Refreshing upstream

```bash
cd minecraft/VivecraftMod
# Optional: keep a remote for diffing
git init && git remote add upstream https://github.com/Vivecraft/VivecraftMod.git
git fetch upstream && git merge upstream/main
# Re-apply VisionCraft edits if conflicts; update this file's commit SHA.
```

Prefer merging upstream into the vendored tree on a dedicated branch, then porting Apple provider changes.

## License

VivecraftMod remains under its upstream license (see `minecraft/VivecraftMod/LICENSE`). VisionCraft additions are part of the same vendored fork; confirm distribution terms before release.
