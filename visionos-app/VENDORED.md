# Vendored ALVR Source

`visionos-app/` is the VisionCraft headset client (ALVRClient). It is vendored from upstream `alvr-visionos` and contains a nested upstream ALVR tree used to build both the headset client core and the Mac ALVR host's `server_core` artifacts.

## Upstream and Pins

| Source | Path | Upstream |
|---|---|---|
| ALVR visionOS client | `visionos-app/` | `https://github.com/alvr-org/alvr-visionos.git` |
| Nested ALVR tree | `visionos-app/ALVR/` | `https://github.com/alvr-org/ALVR.git` (`master`) |

The pinned revisions are the git submodule commits recorded by the parent repository. To inspect them:

```bash
git submodule status --recursive visionos-app
git -C visionos-app rev-parse HEAD
git -C visionos-app/ALVR rev-parse HEAD
```

## Ownership Rules

- VisionCraft deltas are tracked directly in the vendored source tree. Edit and review files under `visionos-app/`, including `ALVRClient/`, `ALVREyeBroadcast/`, `ALVR/`, `*.xcconfig`, and `ALVRClient.xcodeproj`, as normal project source.
- Do not hide VisionCraft behavior behind patch files or regenerate source-only changes from `scripts/prepare-alvr.sh`.
- `scripts/prepare-alvr.sh` is allowed to initialize submodules, validate required deltas, and build artifacts from the tracked source. It must not rewrite tracked signing, entitlement, project, or source files.
- Local headset signing overrides must be explicit. The tracked ALVRClient target currently sets `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `ALVRClient.xcodeproj`, so those target-level settings override `ALVRClient.xcconfig` and the ignored `Override.xcconfig`. Use Xcode's Signing & Capabilities tab, an intentional project source change, or command-line build settings for those values.
- Keep the nested ALVR tree compatible with the Mac ALVR host; client and server-core protocol changes must be reviewed together.

## Diff and Audit Commands

Use these commands to review VisionCraft changes against the pinned vendored source:

```bash
scripts/prepare-alvr.sh --check-source
```

Before shipping, run the strict source-control gate:

```bash
scripts/prepare-alvr.sh --check-source-control
```

The strict mode fails if `visionos-app` or `visionos-app/ALVR` has dirty or untracked source, or if a parent repository has not recorded the checked-out submodule pointer.

To compare the pinned commits against upstream, fetch inside the relevant submodule and diff against the upstream branch or commit you intend to audit:

```bash
git -C visionos-app fetch origin
git -C visionos-app diff origin/main...HEAD
git -C visionos-app/ALVR fetch origin
git -C visionos-app/ALVR diff origin/master...HEAD
```

## Generated Artifacts

Generated build outputs are not the source of truth. Rebuild them from tracked source with:

```bash
scripts/prepare-alvr.sh
```

Important generated or derived artifacts include `visionos-app/ALVRClient/ALVRClientCore.xcframework` and the Mac host `server_core` header/dylib under `mac-host/Vendor/ALVRServerCore/`. If an artifact and source disagree, fix the tracked source first, then regenerate.
