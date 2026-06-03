# Repository Structure

VisionCraft's current top-level repository layout is intentionally stable. This document defines the names to use in docs, rules, scripts, and reviews while keeping high-risk app/vendor moves out of the current phase.

## Canonical Names

| Canonical name | Current path | Responsibility |
|---|---|---|
| Mac ALVR host | `mac-host/` | macOS Swift host app, Java bridge server, VideoToolbox HEVC encode, ALVR `server_core` lifecycle |
| VisionCraft headset client (ALVRClient) | `visionos-app/` | Vendored `alvr-visionos` client and nested ALVR source used by Apple Vision Pro |
| Vivecraft Apple provider | `minecraft/VivecraftMod/` | Vendored Vivecraft fork with the Apple provider, bridge client, frame submitter, and input mapping |
| Bridge v1 | `bridge/` | Loopback Java-to-Mac protocol for pose, controller, hand, view config, and frame messages |
| Bridge Java library | `bridge/java/lib/` | Gradle-backed Java bridge client sources shared with the Vivecraft Apple provider |
| Test-pattern sender | `bridge/java/test-pattern-sender/` | Deterministic Java frame source for validating the bridge without Minecraft |
| Mock host | `bridge/java/mock-host/` | Headless Bridge v1 server for unit and integration tests without Mac/AVP hardware |
| Tooling | `scripts/` | `scripts/vc.sh` command surface plus shared shell modules under `scripts/lib/` |
| Documentation | `docs/` | Architecture, build, runbook, hardware playbook, and legacy research notes |

## Current Paths vs Future Names

No high-risk top-level app/vendor path moves are part of this cleanup. Keep these directories in place until a later migration explicitly updates project files, scripts, docs, and developer workflows together.

| Current path | Possible future name | Current action |
|---|---|---|
| `mac-host/` | `mac-alvr-host/` | Keep path; call it "Mac ALVR host" in prose |
| `visionos-app/` | `headset-client/` | Keep path; call it "VisionCraft headset client (ALVRClient)" |
| `minecraft/VivecraftMod/` | `vivecraft-apple-provider/` | Keep path; call it "Vivecraft Apple provider" |
| `bridge/` | `bridge-v1/` | Keep path; call it "Bridge v1" |

## Bridge Java Modules

The Java bridge modules now live under `bridge/java/` for locality with the protocol docs:

| Gradle project | Physical path | Purpose |
|---|---|---|
| `:bridge-lib` | `bridge/java/lib/` | Java Bridge v1 client library and bridge tests |
| `:bridge-test` | `bridge/java/test-pattern-sender/` | Test-pattern sender; launched by `scripts/vc.sh test-sender` and legacy alias `sender` |
| `:bridge-mock-host` | `bridge/java/mock-host/` | Mock Bridge v1 host used by tests and `scripts/run-mock-host.sh` |

The Gradle project names remain unchanged for compatibility with existing commands and CI. A future cleanup may rename Gradle paths after downstream references are audited.

## Source Ownership

- Vendored ALVR source is project source under `visionos-app/`; VisionCraft deltas are tracked directly in the vendored files.
- `scripts/prepare-alvr.sh` validates and builds artifacts from tracked source. It must not be the only place VisionCraft ALVR behavior exists.
- Do not reintroduce patch-file workflows for ALVR client or server-core changes.
- Legacy docs may remain in place with explicit banners when moving them would create noisy link churn.
