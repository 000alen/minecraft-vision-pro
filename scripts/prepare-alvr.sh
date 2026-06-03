#!/usr/bin/env bash
#
# Prepare the vendored ALVR visionOS client and macOS server_core artifacts.
#
# The source of truth for the ALVR protocol is the `visionos-app` submodule and
# its nested `ALVR` submodule. VisionCraft ALVRClient/server_core changes are
# committed directly in the vendored source; this script validates those deltas
# and builds derived artifacts consumed by the headset client and Mac host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALVR_VISIONOS="$REPO_ROOT/visionos-app"
ALVR_TREE="$ALVR_VISIONOS/ALVR"
HOST_VENDOR="$REPO_ROOT/mac-host/Vendor/ALVRServerCore"
ARTIFACT_SOURCE_VERSION="visioncraft-alvr-artifacts-v4-direct-source"
REBUILD=0
CHECK_SOURCE_ONLY=0
CHECK_SOURCE_CONTROL=0

step() { printf '==> %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/prepare-alvr.sh [--rebuild] [--check-source] [--check-source-control]

Validates the source-controlled vendored ALVR/ALVRClient deltas and builds
derived artifacts:
  - visionos-app/ALVRClient/ALVRClientCore.xcframework
  - mac-host/Vendor/ALVRServerCore/alvr_server_core.h
  - mac-host/Vendor/ALVRServerCore/libalvr_server_core.dylib

Options:
  --rebuild               Rebuild artifacts even if the stamp matches.
  --check-source          Validate required vendored source deltas only; skip builds.
                          This mode allows dirty local development.
  --check-source-control  Pre-ship check: validate deltas, then fail if
                          visionos-app or visionos-app/ALVR has dirty/untracked
                          source or unrecorded submodule pointers.
  -h, --help              Show this help.

This script does not patch or rewrite tracked ALVRClient/ALVR source. Signing,
bundle identifier, entitlement, and Xcode project changes must be made as
deliberate source changes, Xcode UI changes, or command-line build settings.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --check-source|--validate-source) CHECK_SOURCE_ONLY=1 ;;
    --check-source-control) CHECK_SOURCE_ONLY=1; CHECK_SOURCE_CONTROL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step "Checking host prerequisites"
command -v git >/dev/null 2>&1 || die "git not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
if [[ $CHECK_SOURCE_ONLY -eq 0 ]]; then
  command -v cargo >/dev/null 2>&1 || die "cargo not found; run rustup-init -y"
  command -v rustup >/dev/null 2>&1 || die "rustup not found; run rustup-init -y"
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode 26+"
  ok "core prerequisites present"
else
  ok "source validation prerequisites present"
fi

if [[ $CHECK_SOURCE_ONLY -eq 0 ]]; then
  step "Initializing ALVR submodules"
  git -C "$REPO_ROOT" submodule update --init visionos-app
  [[ -d "$ALVR_VISIONOS/.git" || -f "$ALVR_VISIONOS/.git" ]] \
    || die "visionos-app must be the alvr-visionos submodule"
  git -C "$ALVR_VISIONOS" submodule update --init --recursive
else
  step "Checking vendored ALVR checkout"
fi
[[ -d "$ALVR_VISIONOS/.git" || -f "$ALVR_VISIONOS/.git" ]] \
  || die "visionos-app is missing; run: git submodule update --init --recursive visionos-app"
[[ -d "$ALVR_TREE/.git" || -f "$ALVR_TREE/.git" ]] \
  || die "visionos-app/ALVR is missing; run: git -C visionos-app submodule update --init --recursive"
[[ -f "$ALVR_VISIONOS/ALVRClient.xcodeproj/project.pbxproj" ]] \
  || die "visionos-app is missing ALVRClient.xcodeproj"

step "Checking local signing configuration"
if [[ -n "${VISIONCRAFT_DEVELOPMENT_TEAM:-}" || -n "${VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID:-}" ]]; then
  warn "prepare-alvr no longer rewrites tracked ALVRClient signing or bundle settings"
  info "Use Xcode, a deliberate project source change, or command-line build settings for target-level signing values"
fi
if [[ -f "$ALVR_VISIONOS/Override.xcconfig" ]]; then
  ok "local headset Override.xcconfig present and ignored by git"
  info "target-level Xcode build settings still override matching xcconfig values"
else
  info "no local headset Override.xcconfig; tracked Xcode target signing settings will be used"
fi

step "Validating vendored ALVR source deltas"
python3 - "$REPO_ROOT" "$ALVR_VISIONOS" <<'PY'
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
contains_checks = [
    ("ALVRClient/Entry/Entry.swift", "VisionCraft headset setup panel", "VisionCraftSetupPanel"),
    ("ALVRClient/Entry/EntryControls.swift", "VisionCraft entry flow guidance", "Waiting for VisionCraftHost"),
    ("ALVRClient/WorldTracker.swift", "ARKit startup fallback", "ARKit failed to start"),
    ("ALVRClient/WorldTracker.swift", "personal-team accessory tracking gate", "XCODE_BETA_26 && VISIONCRAFT_ENABLE_ACCESSORY_TRACKING"),
    ("ALVRClient/EventHandler.swift", "stable headset discovery listener", "mdnsListener != nil && mdnsListenerRegistered && mdnsListenerReady && !streamingActive"),
    ("ALVRClient/Info.plist", "local network usage description", "VisionCraft uses the local network"),
    ("ALVRClient/EventHandler.swift", "decoder config fallback", "Missing decoder config; trying to create decoder"),
    ("ALVRClient/Renderer.swift", "renderer frame reuse fallback", "if queuedFrame == nil, let lastQueuedFrame = EventHandler.shared.lastQueuedFrame"),
    ("ALVR/alvr/server_core/src/connection.rs", "PSVR2 controller reset profile", "ControllersEmulationMode::PSVR2Sense => 30,"),
    ("ALVR/alvr/server_core/src/connection.rs", "raw ALVR button event forwarding", "ServerCoreEvent::RawButtons("),
    ("ALVR/alvr/server_core/src/lib.rs", "raw button server_core event", "RawButtons(Vec<ButtonEntry>)"),
    ("ALVR/alvr/server_core/src/c_api.rs", "raw button C API queue", "RAW_BUTTONS_QUEUE"),
    ("ALVR/alvr/server_core/src/c_api.rs", "raw button C API event", "RawButtonsUpdated"),
    ("ALVR/alvr/server_core/src/c_api.rs", "raw button C API getter", "alvr_get_raw_buttons"),
    ("ALVR/alvr/server_core/src/input_mapping.rs", "PSVR2 input mapping profile", "ControllersEmulationMode::PSVR2Sense => CONTROLLER_PROFILE_INFO"),
    ("ALVR/alvr/session/src/settings.rs", "VisionCraft default refresh rate", "preferred_fps: 90."),
    ("ALVR/alvr/session/src/settings.rs", "VisionCraft default codec", "variant: CodecTypeDefaultVariant::Hevc"),
    ("ALVR/alvr/session/src/settings.rs", "foveated encoding disabled for uniform frames", "foveated_encoding: SwitchDefault {\n                enabled: false,"),
    ("ALVR/alvr/session/src/settings.rs", "game audio disabled by default", "game_audio: SwitchDefault {\n                enabled: false,"),
]
absent_checks = [
    ("ALVRClient/ALVRClient.entitlements", "personal-team ALVRClient entitlements", "com.apple.developer"),
    ("ALVREyeBroadcast/ALVREyeBroadcast.entitlements", "personal-team eye broadcast entitlements", "com.apple.developer"),
]

missing = []
for relative, label, needle in contains_checks:
    path = root / relative
    if not path.exists():
        missing.append((relative, label, "file is missing"))
        continue
    if needle not in path.read_text():
        missing.append((relative, label, f"missing sentinel: {needle!r}"))
for relative, label, needle in absent_checks:
    path = root / relative
    if not path.exists():
        missing.append((relative, label, "file is missing"))
        continue
    if needle in path.read_text():
        missing.append((relative, label, f"unexpected restricted entitlement sentinel: {needle!r}"))

patch_artifacts = [repo / "scripts" / "patches" / "alvrclient-visioncraft-ui.patch"]
for path in patch_artifacts:
    if path.exists():
        missing.append((str(path.relative_to(repo)), "retired ALVRClient patch artifact", "patch file must not be source of truth"))

if missing:
    print("error: required VisionCraft vendored ALVR source deltas are missing:", file=sys.stderr)
    for relative, label, reason in missing:
        print(f"  - {label} ({relative}): {reason}", file=sys.stderr)
    print(
        "\nVisionCraft ALVR changes must be committed directly under visionos-app/.\n"
        "Reapply/review the missing delta against the pinned upstream source, commit it directly,\n"
        "then rerun scripts/prepare-alvr.sh. For review/audit, use:\n"
        "  scripts/prepare-alvr.sh --check-source\n"
        "  git -C visionos-app diff -- ALVRClient ALVREyeBroadcast ALVRClient.xcodeproj ALVR\n"
        "  git -C visionos-app/ALVR diff -- alvr/server_core alvr/session",
        file=sys.stderr,
    )
    sys.exit(1)
PY
ok "vendored ALVR source deltas present"

check_clean_git_tree() {
  local label="$1"
  local dir="$2"
  local status
  status="$(git -C "$dir" status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$status" ]]; then
    printf 'error: %s has uncommitted or untracked source changes:\n' "$label" >&2
    printf '%s\n' "$status" >&2
    return 1
  fi
}

git_tree_object() {
  local dir="$1"
  local path="$2"
  git -C "$dir" ls-tree HEAD -- "$path" | awk '{ print $3; exit }'
}

check_recorded_submodule_pointer() {
  local parent_label="$1"
  local parent_dir="$2"
  local submodule_path="$3"
  local child_dir="$4"
  local expected actual
  expected="$(git_tree_object "$parent_dir" "$submodule_path")"
  actual="$(git -C "$child_dir" rev-parse HEAD)"
  if [[ -z "$expected" ]]; then
    printf 'error: %s does not record submodule path %s\n' "$parent_label" "$submodule_path" >&2
    return 1
  fi
  if [[ "$expected" != "$actual" ]]; then
    printf 'error: %s records %s at %s, but checkout is at %s\n' "$parent_label" "$submodule_path" "$expected" "$actual" >&2
    return 1
  fi
}

check_vendored_source_control() {
  local fail=0
  step "Checking vendored ALVR source-control state"

  check_clean_git_tree "visionos-app" "$ALVR_VISIONOS" || fail=1
  check_clean_git_tree "visionos-app/ALVR" "$ALVR_TREE" || fail=1
  check_recorded_submodule_pointer "parent repo" "$REPO_ROOT" "visionos-app" "$ALVR_VISIONOS" || fail=1
  check_recorded_submodule_pointer "visionos-app" "$ALVR_VISIONOS" "ALVR" "$ALVR_TREE" || fail=1

  if [[ $fail -ne 0 ]]; then
    printf '%s\n' >&2
    printf 'This is expected during active vendored ALVR development, but it is not shippable.\n' >&2
    printf 'Before shipping, commit vendored source changes in visionos-app and visionos-app/ALVR,\n' >&2
    printf 'then record the resulting submodule pointers in their parent repositories.\n' >&2
    printf 'For local dirty development, use: scripts/prepare-alvr.sh --check-source\n' >&2
    return 1
  fi

  ok "vendored ALVR source-control state is clean and recorded"
}

if [[ $CHECK_SOURCE_ONLY -eq 1 ]]; then
  if [[ $CHECK_SOURCE_CONTROL -eq 1 ]]; then
    check_vendored_source_control
  fi
  step "Source-control audit commands"
  info "git submodule status --recursive visionos-app"
  info "git -C visionos-app status --short"
  info "git -C visionos-app/ALVR status --short"
  info "git -C visionos-app diff -- ALVRClient ALVREyeBroadcast ALVRClient.xcodeproj ALVR"
  info "git -C visionos-app/ALVR diff -- alvr/server_core alvr/session"
  ok "source validation complete"
  exit 0
fi

step "Checking Rust tools"
command -v cargo >/dev/null 2>&1 || die "cargo not found"
command -v rustup >/dev/null 2>&1 || die "rustup not found"
command -v cbindgen >/dev/null 2>&1 || cargo install cbindgen
rustup target add aarch64-apple-ios >/dev/null
ok "Rust toolchain ready"

client_artifact="$ALVR_VISIONOS/ALVRClient/ALVRClientCore.xcframework"
server_header="$HOST_VENDOR/alvr_server_core.h"
server_dylib="$HOST_VENDOR/libalvr_server_core.dylib"
artifact_stamp="$HOST_VENDOR/.alvr-artifacts.stamp"
alvr_commit="$(git -C "$ALVR_TREE" rev-parse HEAD)"
expected_stamp="$(
  printf 'alvr_commit=%s\n' "$alvr_commit"
  printf 'source_version=%s\n' "$ARTIFACT_SOURCE_VERSION"
)"
current_stamp=""
if [[ -f "$artifact_stamp" ]]; then
  current_stamp="$(grep -E '^(alvr_commit|source_version)=' "$artifact_stamp" || true)"
fi
needs_rebuild=0
if [[ $REBUILD -eq 1 || ! -d "$client_artifact" || ! -f "$server_header" || ! -f "$server_dylib" || "$current_stamp" != "$expected_stamp" ]]; then
  needs_rebuild=1
fi

if [[ $needs_rebuild -eq 1 ]]; then
  step "Building alvr_client_core xcframework"
  (cd "$ALVR_VISIONOS" && ./build_and_repack.sh)
else
  ok "client core already built: $client_artifact"
fi

if [[ $needs_rebuild -eq 1 ]]; then
  step "Building alvr_server_core macOS dylib"
  mkdir -p "$HOST_VENDOR"
  (
    cd "$ALVR_VISIONOS"
    CARGO_TARGET_DIR=ALVR/target cargo build --manifest-path ALVR/Cargo.toml \
      -p alvr_server_core --profile distribution
    (cd ALVR/alvr/server_core && \
      cbindgen --config cbindgen.toml --crate alvr_server_core \
        --output "$server_header")
    python3 - "$server_header" <<'PY'
import pathlib
import sys

header = pathlib.Path(sys.argv[1])
text = header.read_text()
text = text.replace("    float float;\n", "    float float_value;\n")
header.write_text(text)
PY
    cp ALVR/target/distribution/libalvr_server_core.dylib "$server_dylib"
    install_name_tool -id "@rpath/libalvr_server_core.dylib" "$server_dylib"
  )
else
  ok "server core already built: $server_dylib"
fi

mkdir -p "$HOST_VENDOR"
printf '%s\n' "$expected_stamp" > "$artifact_stamp"

info "server header: $server_header"
info "server dylib: $server_dylib"
ok "ALVR preparation complete"
