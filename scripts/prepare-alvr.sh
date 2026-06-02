#!/usr/bin/env bash
#
# Prepare the vendored ALVR visionOS client and macOS server_core artifacts.
#
# The source of truth for the ALVR protocol is the `visionos-app` submodule and
# its nested `ALVR` submodule. This script keeps the local checkout reproducible:
# it initializes nested submodules, applies tiny local patches needed for this
# pinned commit, builds the visionOS client_core xcframework, and builds the
# macOS server_core dylib/header consumed by VisionCraftHost.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALVR_VISIONOS="$REPO_ROOT/visionos-app"
ALVR_TREE="$ALVR_VISIONOS/ALVR"
HOST_VENDOR="$REPO_ROOT/mac-host/Vendor/ALVRServerCore"
TEAM_ID="${VISIONCRAFT_DEVELOPMENT_TEAM:-}"
CLIENT_BUNDLE_ID="${VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID:-visioncraft.alvrclient}"
PATCH_VERSION="visioncraft-alvr-artifacts-v3-controller-input"
REBUILD=0

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '==> %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

step "Checking host prerequisites"
command -v git >/dev/null 2>&1 || die "git not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v cargo >/dev/null 2>&1 || die "cargo not found; run rustup-init -y"
command -v rustup >/dev/null 2>&1 || die "rustup not found; run rustup-init -y"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode 26+"
if [[ -z "$TEAM_ID" ]]; then
  warn "VISIONCRAFT_DEVELOPMENT_TEAM is unset; generated AVP project signing team will be blank"
fi
ok "core prerequisites present"

step "Initializing ALVR submodules"
git -C "$REPO_ROOT" submodule update --init visionos-app
[[ -d "$ALVR_VISIONOS/.git" || -f "$ALVR_VISIONOS/.git" ]] \
  || die "visionos-app must be the alvr-visionos submodule"
git -C "$ALVR_VISIONOS" submodule update --init --recursive
[[ -d "$ALVR_TREE/.git" || -f "$ALVR_TREE/.git" ]] \
  || die "visionos-app/ALVR nested submodule did not initialize"
[[ -f "$ALVR_VISIONOS/ALVRClient.xcodeproj/project.pbxproj" ]] \
  || die "visionos-app is missing ALVRClient.xcodeproj"

step "Applying local ALVR compatibility patches"
python3 - "$REPO_ROOT" "$TEAM_ID" "$CLIENT_BUNDLE_ID" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
team_id = sys.argv[2]
client_bundle_id = sys.argv[3]

def replace_if_present(text: str, old: str, new: str) -> str:
    return text.replace(old, new) if old in text else text

project = repo / "visionos-app" / "ALVRClient.xcodeproj" / "project.pbxproj"
text = project.read_text()
team_assignment = f"DEVELOPMENT_TEAM = {team_id};" if team_id else "DEVELOPMENT_TEAM = \"\";"
replacements = {
    "PRODUCT_BUNDLE_IDENTIFIER = alvr.client;": f"PRODUCT_BUNDLE_IDENTIFIER = {client_bundle_id};",
    "PRODUCT_BUNDLE_IDENTIFIER = alvr.client.ALVREyeBroadcast;": f"PRODUCT_BUNDLE_IDENTIFIER = {client_bundle_id}.ALVREyeBroadcast;",
}
for old, new in replacements.items():
    text = text.replace(old, new)
text = re.sub(r"DEVELOPMENT_TEAM = [A-Z0-9\"]*;", team_assignment, text)
project.write_text(text)

xcconfig = repo / "visionos-app" / "ALVRClient.xcconfig"
text = xcconfig.read_text()
text = re.sub(r"^DEVELOPMENT_TEAM = .*$", f"DEVELOPMENT_TEAM = {team_id}", text, flags=re.MULTILINE)
text = re.sub(r"^PRODUCT_BUNDLE_IDENTIFIER = .*$", f"PRODUCT_BUNDLE_IDENTIFIER = {client_bundle_id}", text, flags=re.MULTILINE)
xcconfig.write_text(text)

connection = repo / "visionos-app" / "ALVR" / "alvr" / "server_core" / "src" / "connection.rs"
text = connection.read_text()
needle = "            ControllersEmulationMode::Pico4 => 10,\n            ControllersEmulationMode::ValveIndex => 20,"
if needle in text:
    text = text.replace(
        needle,
        "            ControllersEmulationMode::Pico4 => 10,\n"
        "            ControllersEmulationMode::PSVR2Sense => 30,\n"
        "            ControllersEmulationMode::ValveIndex => 20,"
    )
if "ButtonEntry, ClientConnectionResult" not in text:
    text = replace_if_present(
        text,
        "    ClientConnectionResult, ClientControlPacket, ClientListAction, ClientStatistics,\n",
        "    ButtonEntry, ClientConnectionResult, ClientControlPacket, ClientListAction, ClientStatistics,\n",
    )
raw_buttons_send = (
    "                        ctx.events_sender\n"
    "                            .send(ServerCoreEvent::RawButtons(\n"
    "                                entries\n"
    "                                    .iter()\n"
    "                                    .map(|entry| ButtonEntry {\n"
    "                                        path_id: entry.path_id,\n"
    "                                        value: entry.value,\n"
    "                                    })\n"
    "                                    .collect(),\n"
    "                            ))\n"
    "                            .ok();\n"
)
text = replace_if_present(
    text,
    "                        ctx.events_sender\n"
    "                            .send(ServerCoreEvent::RawButtons(entries.clone()))\n"
    "                            .ok();\n",
    raw_buttons_send,
)
if "ServerCoreEvent::RawButtons(" not in text:
    text = replace_if_present(
        text,
        "                    ClientControlPacket::Buttons(entries) => {\n"
        "                        {\n",
        "                    ClientControlPacket::Buttons(entries) => {\n"
        f"{raw_buttons_send}"
        "\n"
        "                        {\n",
    )
connection.write_text(text)

server_core_lib = repo / "visionos-app" / "ALVR" / "alvr" / "server_core" / "src" / "lib.rs"
text = server_core_lib.read_text()
if "RawButtons(Vec<ButtonEntry>)" not in text:
    text = replace_if_present(
        text,
        "    Buttons(Vec<ButtonEntry>), // Note: this is after mapping\n",
        "    RawButtons(Vec<ButtonEntry>),\n"
        "    Buttons(Vec<ButtonEntry>), // Note: this is after mapping\n",
    )
server_core_lib.write_text(text)

c_api = repo / "visionos-app" / "ALVR" / "alvr" / "server_core" / "src" / "c_api.rs"
text = c_api.read_text()
if "RAW_BUTTONS_QUEUE" not in text:
    text = replace_if_present(
        text,
        "static BUTTONS_QUEUE: Lazy<Mutex<VecDeque<Vec<ButtonEntry>>>> =\n"
        "    Lazy::new(|| Mutex::new(VecDeque::new()));\n",
        "static BUTTONS_QUEUE: Lazy<Mutex<VecDeque<Vec<ButtonEntry>>>> =\n"
        "    Lazy::new(|| Mutex::new(VecDeque::new()));\n"
        "static RAW_BUTTONS_QUEUE: Lazy<Mutex<VecDeque<Vec<ButtonEntry>>>> =\n"
        "    Lazy::new(|| Mutex::new(VecDeque::new()));\n",
    )
if "RawButtonsUpdated" not in text:
    text = replace_if_present(
        text,
        "    ButtonsUpdated,\n",
        "    RawButtonsUpdated,\n"
        "    ButtonsUpdated,\n",
    )
if "ServerCoreEvent::RawButtons(entries)" not in text:
    text = replace_if_present(
        text,
        "                ServerCoreEvent::Buttons(entries) => {\n"
        "                    BUTTONS_QUEUE.lock().push_back(entries);\n"
        "                    *out_event = AlvrEvent::ButtonsUpdated;\n"
        "                }\n",
        "                ServerCoreEvent::RawButtons(entries) => {\n"
        "                    RAW_BUTTONS_QUEUE.lock().push_back(entries);\n"
        "                    *out_event = AlvrEvent::RawButtonsUpdated;\n"
        "                }\n"
        "                ServerCoreEvent::Buttons(entries) => {\n"
        "                    BUTTONS_QUEUE.lock().push_back(entries);\n"
        "                    *out_event = AlvrEvent::ButtonsUpdated;\n"
        "                }\n",
    )
if "fn alvr_get_buttons_from_queue" not in text:
    text = replace_if_present(
        text,
        "pub unsafe extern \"C\" fn alvr_get_buttons(out_entries: *mut AlvrButtonEntry) -> u64 {\n"
        "    let entries_count = BUTTONS_QUEUE.lock().front().map_or(0, |e| e.len()) as u64;\n",
        "pub unsafe extern \"C\" fn alvr_get_buttons(out_entries: *mut AlvrButtonEntry) -> u64 {\n"
        "    alvr_get_buttons_from_queue(out_entries, &BUTTONS_QUEUE)\n"
        "}\n"
        "\n"
        "/// Call with null out_entries to get the buffer length.\n"
        "/// Call with non-null out_entries to get raw client buttons and advance the internal queue.\n"
        "#[no_mangle]\n"
        "pub unsafe extern \"C\" fn alvr_get_raw_buttons(out_entries: *mut AlvrButtonEntry) -> u64 {\n"
        "    alvr_get_buttons_from_queue(out_entries, &RAW_BUTTONS_QUEUE)\n"
        "}\n"
        "\n"
        "unsafe fn alvr_get_buttons_from_queue(\n"
        "    out_entries: *mut AlvrButtonEntry,\n"
        "    queue: &Mutex<VecDeque<Vec<ButtonEntry>>>,\n"
        ") -> u64 {\n"
        "    let entries_count = queue.lock().front().map_or(0, |e| e.len()) as u64;\n",
    )
    text = replace_if_present(text, "    if let Some(button_entries) = BUTTONS_QUEUE.lock().pop_front() {\n", "    if let Some(button_entries) = queue.lock().pop_front() {\n")
c_api.write_text(text)

mapping = repo / "visionos-app" / "ALVR" / "alvr" / "server_core" / "src" / "input_mapping.rs"
text = mapping.read_text()
needle = (
    "        | ControllersEmulationMode::Quest3Plus\n"
    "        | ControllersEmulationMode::QuestPro => CONTROLLER_PROFILE_INFO"
)
if needle in text:
    text = text.replace(
        needle,
        "        | ControllersEmulationMode::Quest3Plus\n"
        "        | ControllersEmulationMode::QuestPro\n"
        "        | ControllersEmulationMode::PSVR2Sense => CONTROLLER_PROFILE_INFO"
    )
mapping.write_text(text)

settings = repo / "visionos-app" / "ALVR" / "alvr" / "session" / "src" / "settings.rs"
text = settings.read_text()
text = text.replace("            preferred_fps: 72.,", "            preferred_fps: 90.,")
text = text.replace(
    "            preferred_codec: CodecTypeDefault {\n"
    "                variant: CodecTypeDefaultVariant::H264,\n"
    "            },",
    "            preferred_codec: CodecTypeDefault {\n"
    "                variant: CodecTypeDefaultVariant::Hevc,\n"
    "            },",
)
text = text.replace(
    "            foveated_encoding: SwitchDefault {\n"
    "                enabled: true,",
    "            foveated_encoding: SwitchDefault {\n"
    "                enabled: false,",
)
text = text.replace(
    "            game_audio: SwitchDefault {\n"
    "                enabled: true,",
    "            game_audio: SwitchDefault {\n"
    "                enabled: false,",
)
settings.write_text(text)
PY
ok "patched signing, server_core compile gap, and VisionCraft ALVR defaults"

ui_patch="$REPO_ROOT/scripts/patches/alvrclient-visioncraft-ui.patch"
step "Applying VisionCraft ALVRClient UI patch"
if git -C "$ALVR_VISIONOS" apply --check "$ui_patch"; then
  git -C "$ALVR_VISIONOS" apply "$ui_patch"
  ok "VisionCraft headset onboarding patch applied"
elif git -C "$ALVR_VISIONOS" apply -R --check "$ui_patch"; then
  ok "VisionCraft headset onboarding patch already applied"
else
  die "VisionCraft ALVRClient UI patch no longer applies cleanly"
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
  printf 'patch_version=%s\n' "$PATCH_VERSION"
)"
current_stamp=""
if [[ -f "$artifact_stamp" ]]; then
  current_stamp="$(grep -E '^(alvr_commit|patch_version)=' "$artifact_stamp" || true)"
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

info "client bundle id: $CLIENT_BUNDLE_ID"
info "server header: $server_header"
info "server dylib: $server_dylib"
ok "ALVR preparation complete"
