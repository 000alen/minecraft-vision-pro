# Tooling Architecture

VisionCraft tooling is treated as product code. `scripts/vc.sh` is the user-facing command dispatcher; shared behavior lives under `scripts/lib/`.

## Design Goals

- One command surface for users: `scripts/vc.sh <command>`.
- No duplicated hardcoded ports, paths, bundle IDs, or device-discovery snippets.
- Every hardware run should produce an evidence bundle.
- Tooling should separate workflow decisions from low-level mechanics.
- Each shell module should be small enough to audit without reading the entire runbook.

## Module Map

| Module | Responsibility |
|---|---|
| `scripts/lib/vc-env.sh` | Path, port, bundle ID, and artifact configuration. Supports `VISIONCRAFT_*` overrides. |
| `scripts/lib/vc-log.sh` | Consistent terminal output and fatal errors. |
| `scripts/lib/vc-json.sh` | JSON field extraction for `/status` and command output. |
| `scripts/lib/vc-process.sh` | Port ownership, process discovery, termination, and single-frame-source guards. |
| `scripts/lib/vc-device.sh` | Apple Vision Pro discovery through `devicectl` and `xcdevice`; installed ALVRClient bundle discovery. |
| `scripts/lib/vc-control.sh` | VisionCraftHost loopback control API calls and status rendering. |
| `scripts/lib/vc-tools.sh` | Toolchain checks, Java 21 discovery, generated project/artifact readiness. |
| `scripts/lib/vc-observe.sh` | Observability bundle capture, status sampling, Mac unified logs, AVP console capture. |

`scripts/vc.sh` should keep only high-level commands such as `doctor`, `host`, `headset`, `test-sender`, `verify`, and `package-beta`. Older aliases such as `alvr-client`, `sender`, and `mc` remain supported for compatibility.

## Configuration Contract

Prefer environment overrides over inline edits:

```bash
VISIONCRAFT_REPO_ROOT=/path/to/repo
VISIONCRAFT_RUN_DIR=/tmp/visioncraft-run
VISIONCRAFT_CONTROL_PORT=19734
VISIONCRAFT_BRIDGE_PORT=19735
VISIONCRAFT_DEVELOPMENT_TEAM=<team id>
VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID=com.example.VisionCraftALVRClient
```

When adding a new path, port, or bundle identifier, add it to `vc-env.sh` first and consume the variable from command code. ALVRClient launch commands should call `effective_alvr_client_bundle_id`, which resolves the bundle ID from `VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID`, Xcode build settings, or JSON `devicectl` app metadata. Do not add hardcoded fallback bundle IDs.

## Observability Model

The default evidence artifact is `.run/observability/<timestamp>/`.

Each bundle should include:

- Metadata: git revision, branch, control URL, bridge port, device IDs, bundle ID.
- Host state: `/status` before/after plus sampled `live/status.ndjson`.
- Process state: port holders, VisionCraft/Gradle/ALVR process snapshots.
- Logs: Mac unified log, host build log, sender log, Minecraft log, ALVR server-core logs.
- Device state: `devicectl` devices, apps, processes, and optional ALVRClient console output.

Use `scripts/vc.sh observe <seconds>` during every hardware reproduction. Use `scripts/vc.sh avp-console <seconds>` when headset stdout/stderr matters.

## Change Rules

- Do not add new long-lived helpers directly to `vc.sh`; add them to a module.
- Do not duplicate `xcrun devicectl`, `lsof`, `curl`, or JSON parsing snippets across commands.
- Do not introduce commands that mutate state without either printing next steps or writing logs.
- Do not make hardware triage depend on screenshots when a script can capture the same evidence.
- Treat the vendored ALVR version and VisionCraft ALVR source changes as repository source under `visionos-app/`; prepare scripts may validate/build artifacts, but must not be the only place project source changes live.
- `scripts/prepare-alvr.sh` must not patch or rewrite tracked ALVRClient/ALVR source, signing, entitlement, or project files. The tracked ALVRClient target has source-controlled signing and bundle settings in `ALVRClient.xcodeproj`; `Override.xcconfig` cannot override those target-level values unless the target build setting is removed or changed.

To validate required vendored ALVR deltas during local development, use:

```bash
scripts/prepare-alvr.sh --check-source
```

Before shipping, use the strict source-control gate:

```bash
scripts/prepare-alvr.sh --check-source-control
```

After editing tooling, run:

```bash
bash -n scripts/vc.sh
for f in scripts/lib/*.sh; do bash -n "$f"; done
scripts/vc.sh --help
git diff --check
```
