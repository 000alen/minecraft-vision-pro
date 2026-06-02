#!/usr/bin/env bash
#
# vc.sh — VisionCraft local runbook orchestrator.
#
# One robust, reproducible entrypoint for the Mac side of the pipeline: detect stale state,
# clean it, build/launch the host, drive a frame source (Minecraft or the headless test pattern),
# launch the ALVR Apple Vision Pro client, and verify the stream end to end.
#
# Usage:  scripts/vc.sh <command>
#   bootstrap           First-run beta setup: check prerequisites, prepare artifacts, print next steps.
#   doctor              Read-only health report (tools, signing, artifacts, ports, host /status, AVP).
#   status              Compact live status (host /status + frame-flow sample).
#   clean               Stop ALL VisionCraft processes (host, frame sources, gradle daemons); free ports.
#   preflight           Verify toolchain + regenerate Xcode projects / ALVR artifacts if missing.
#   package-beta        Build/package host + Fabric mod into .run/beta (use --dry-run to check only).
#   host [--rebuild]    Clean+(re)launch VisionCraftHost; wait until control API is healthy.
#   alvr-client         Open the ALVR client project and print AVP run steps.
#   mc                  Launch the Minecraft Fabric dev client (openjdk@21) as the frame source.
#   sender [n]          Launch the headless test-pattern sender (bridge-test). n=frame count (0=continuous).
#   verify              Assert the live stream is healthy (ALVR client connected, frames flowing, session ready).
#   stop                Alias for clean.
#
# Ports (loopback):  control 19734 · bridge 19735 (Java/Minecraft). ALVR uses its own LAN ports.
set -euo pipefail

# ----------------------------------------------------------------------------- constants
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$REPO_ROOT/.run"
CONTROL_PORT=19734
BRIDGE_PORT=19735
CONTROL_URL="http://127.0.0.1:${CONTROL_PORT}"

HOST_PROJECT="$REPO_ROOT/mac-host/VisionCraftHost.xcodeproj"
HOST_SCHEME="VisionCraftHost"
HOST_DERIVED="$REPO_ROOT/mac-host/build"
HOST_APP="$HOST_DERIVED/Build/Products/Debug/VisionCraftHost.app"

ALVR_CLIENT_PROJECT="$REPO_ROOT/visionos-app/ALVRClient.xcodeproj"
ALVR_CLIENT_SCHEME="ALVRClient"
ALVR_CLIENT_DERIVED="$REPO_ROOT/visionos-app/build"
ALVR_CLIENT_APP="$ALVR_CLIENT_DERIVED/Build/Products/Debug-xros/ALVRClient.app"
ALVR_CLIENT_CORE="$REPO_ROOT/visionos-app/ALVRClient/ALVRClientCore.xcframework"
ALVR_CLIENT_BUNDLE_ID="${VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID:-visioncraft.alvrclient}"

MC_DIR="$REPO_ROOT/minecraft/VivecraftMod"
HOST_VENDOR="$REPO_ROOT/mac-host/Vendor/ALVRServerCore"
SERVER_CORE_HEADER="$HOST_VENDOR/alvr_server_core.h"
SERVER_CORE_DYLIB="$HOST_VENDOR/libalvr_server_core.dylib"
BETA_DIR="$RUN_DIR/beta"

# ----------------------------------------------------------------------------- output helpers
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YEL=""; C_BLUE=""; C_BOLD=""
fi
step() { printf '%s\n' "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { printf '%s\n' "  ${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "  ${C_YEL}!${C_RESET} $*"; }
bad()  { printf '%s\n' "  ${C_RED}✗${C_RESET} $*"; }
info() { printf '%s\n' "  ${C_DIM}·${C_RESET} $*"; }
die()  { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

# ----------------------------------------------------------------------------- low-level utils
# pids currently LISTENing/connected on a TCP port (empty if free)
port_pids() { lsof -nP -iTCP:"$1" -t 2>/dev/null | sort -u || true; }
# pids with an ESTABLISHED connection on a port (both ends; caller filters)
port_estab_pids() { lsof -nP -iTCP:"$1" -sTCP:ESTABLISHED -t 2>/dev/null | sort -u || true; }
host_pids() { pgrep -f "VisionCraftHost.app/Contents/MacOS/VisionCraftHost" 2>/dev/null | sort -u || true; }

# SIGTERM a set of pids, escalate to SIGKILL after a grace period.
kill_pids() { # $1=label  $2..=pids
  local label="$1"; shift
  local pids=("$@"); [[ ${#pids[@]} -eq 0 ]] && return 0
  info "stopping ${label}: ${pids[*]}"
  kill "${pids[@]}" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    local alive=()
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
    [[ ${#alive[@]} -eq 0 ]] && return 0
    sleep 0.3; pids=("${alive[@]}")
  done
  warn "force-killing ${label}: ${pids[*]}"
  kill -9 "${pids[@]}" 2>/dev/null || true
}

wait_port_free() { # $1=port $2=timeout_s
  local port="$1" timeout="${2:-8}" t=0
  while :; do
    [[ -z "$(port_pids "$port")" ]] && return 0
    awk "BEGIN{exit !($t >= $timeout)}" && return 1
    sleep 0.3; t=$(awk "BEGIN{print $t + 0.3}")
  done
}

http_get()  { curl -fsS --max-time 3 "${CONTROL_URL}$1" 2>/dev/null || true; }
http_post() { curl -fsS --max-time 5 -X POST "${CONTROL_URL}$1" 2>/dev/null || true; }

wait_http_ok() { # $1=path $2=timeout_s
  local path="$1" timeout="${2:-20}" t=0
  while :; do
    [[ -n "$(http_get "$path")" ]] && return 0
    awk "BEGIN{exit !($t >= $timeout)}" && return 1
    sleep 0.4; t=$(awk "BEGIN{print $t + 0.4}")
  done
}

# Extract one field from a JSON blob ($1=json, $2=key). python3 first, sed fallback.
json_field() {
  local json="$1" key="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    v=d.get(sys.argv[1],"")
    print("" if v is None else (str(v).lower() if isinstance(v,bool) else v))
except Exception:
    pass' "$key" 2>/dev/null && return 0
  fi
  printf '%s' "$json" | sed -n "s/.*\"$key\":\"\{0,1\}\([^,\"}]*\).*/\1/p" | head -1
}

avp_udid() { # UDID of a connected Apple Vision Pro, or empty
  xcrun devicectl list devices 2>/dev/null \
    | grep -i "vision pro" | grep -i "connected" \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
    | head -1 || true
}

brew_prefix() {
  command -v brew >/dev/null 2>&1 || return 1
  brew --prefix "$1" 2>/dev/null
}

java21_home() {
  local prefix
  prefix="$(brew_prefix openjdk@21 || true)"
  [[ -n "$prefix" ]] && printf '%s/libexec/openjdk.jdk/Contents/Home' "$prefix"
}

require_java21() {
  local jdk
  jdk="$(java21_home)"
  [[ -n "$jdk" && -d "$jdk" ]] || die "openjdk@21 JAVA_HOME not found (brew install openjdk@21)"
  printf '%s' "$jdk"
}

artifacts_ready() {
  [[ -d "$ALVR_CLIENT_PROJECT" && -d "$ALVR_CLIENT_CORE" && -f "$SERVER_CORE_HEADER" && -f "$SERVER_CORE_DYLIB" ]]
}

print_artifacts() {
  [[ -d "$ALVR_CLIENT_PROJECT" ]] && ok "ALVRClient.xcodeproj" || warn "missing ALVRClient.xcodeproj"
  [[ -d "$ALVR_CLIENT_CORE" ]] && ok "ALVRClientCore.xcframework" || warn "missing ALVRClientCore.xcframework"
  [[ -f "$SERVER_CORE_HEADER" ]] && ok "alvr_server_core.h" || warn "missing alvr_server_core.h"
  [[ -f "$SERVER_CORE_DYLIB" ]] && ok "libalvr_server_core.dylib" || warn "missing libalvr_server_core.dylib"
}

signing_summary() {
  if [[ -n "${VISIONCRAFT_DEVELOPMENT_TEAM:-}" ]]; then
    ok "development team: $VISIONCRAFT_DEVELOPMENT_TEAM"
  else
    warn "VISIONCRAFT_DEVELOPMENT_TEAM unset — Xcode will ask for a team before installing on AVP"
  fi
  info "ALVR client bundle id: $ALVR_CLIENT_BUNDLE_ID"
}

check_tool() { # $1=tool $2=install hint
  local tool="$1" hint="${2:-}"
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool"
  elif [[ -n "$hint" ]]; then
    bad "$tool missing ($hint)"
  else
    bad "$tool missing"
  fi
}

ensure_projects() {
  step "Refreshing generated Xcode projects"
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  "$REPO_ROOT/scripts/gen-projects.sh"
  if ! artifacts_ready; then
    "$REPO_ROOT/scripts/prepare-alvr.sh"
  fi
}

# A frame source = something other than the host with an ESTABLISHED socket on the bridge port.
frame_source_pids() {
  local hp; hp="$(host_pids | tr '\n' ' ')"
  local out=""
  for p in $(port_estab_pids "$BRIDGE_PORT"); do
    case " $hp " in *" $p "*) ;; *) out+="$p ";; esac
  done
  printf '%s' "$out" | xargs -n1 2>/dev/null | sort -u || true
}

# ----------------------------------------------------------------------------- commands
cmd_doctor() {
  step "Toolchain"
  check_tool brew "install Homebrew"
  check_tool git
  check_tool python3 "install Xcode Command Line Tools"
  check_tool xcodebuild "install Xcode 26+"
  check_tool xcodegen "brew install xcodegen"
  check_tool lsof
  check_tool curl
  check_tool cargo "run rustup-init -y"
  check_tool rustup "brew install rustup-init && rustup-init -y"
  if command -v cbindgen >/dev/null 2>&1; then ok "cbindgen"; else warn "cbindgen missing — prepare-alvr will install it with cargo"; fi
  local jdk; jdk="$(java21_home)"
  [[ -n "$jdk" && -d "$jdk" ]] && ok "openjdk@21 ($jdk)" || bad "openjdk@21 missing (brew install openjdk@21)"
  if xcode-select -p >/dev/null 2>&1; then ok "xcode-select: $(xcode-select -p)"; else bad "xcode-select not configured"; fi
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then ok "Xcode first launch/license complete"; else warn "Xcode first launch/license may need completion"; fi

  step "Signing"
  signing_summary

  step "Generated projects and artifacts"
  [[ -d "$HOST_PROJECT" ]] && ok "host xcodeproj" || warn "host xcodeproj missing (run: scripts/vc.sh preflight)"
  print_artifacts

  step "Apple Vision Pro"
  local udid; udid="$(avp_udid)"
  if [[ -n "$udid" ]]; then ok "paired + connected: $udid"; else warn "no connected AVP (Settings ▸ General ▸ Remote Devices; pair in Xcode)"; fi

  step "Ports"
  for pp in "control:$CONTROL_PORT" "bridge:$BRIDGE_PORT"; do
    local name="${pp%%:*}" port="${pp##*:}" pids; pids="$(port_pids "$port" | tr '\n' ' ')"
    if [[ -z "$pids" ]]; then info "$name :$port free"; else
      local owner; owner="$(ps -o comm= -p "${pids%% *}" 2>/dev/null | xargs basename 2>/dev/null || true)"
      ok "$name :$port held by [$owner] pid ${pids}"
    fi
  done

  step "VisionCraft processes"
  local hp; hp="$(host_pids | tr '\n' ' ')"
  [[ -n "$hp" ]] && ok "VisionCraftHost pid ${hp}" || warn "VisionCraftHost not running"
  local fs; fs="$(frame_source_pids | tr '\n' ' ')"
  [[ -n "$fs" ]] && ok "frame source connected on :$BRIDGE_PORT pid ${fs}" || info "no frame source connected"
  local gd; gd="$(pgrep -f 'org.gradle.launcher.daemon.bootstrap.GradleDaemon' 2>/dev/null | tr '\n' ' ' || true)"
  [[ -n "$gd" ]] && info "gradle daemon(s): ${gd}" || info "no gradle daemons"

  step "Host status (control API)"
  local s; s="$(http_get /status)"
  if [[ -z "$s" ]]; then warn "control API not responding on :$CONTROL_PORT"; else print_status "$s"; fi
}

print_status() { # $1 = /status json
  local s="$1"
  info "session_state       = $(json_field "$s" session_state)"
  info "alvr_running        = $(json_field "$s" alvr_running)"
  info "alvr_client         = $(json_field "$s" alvr_client_connected)"
  info "alvr_frames_sent    = $(json_field "$s" alvr_frames_sent)"
  info "frames_received     = $(json_field "$s" frames_received)"
  info "frames_encoded      = $(json_field "$s" frames_encoded)"
  info "diagnostic          = $(json_field "$s" diagnostic)"
}

cmd_status() {
  local s; s="$(http_get /status)"
  [[ -z "$s" ]] && die "control API not responding on :$CONTROL_PORT (is the host running? scripts/vc.sh host)"
  step "Host /status"
  print_status "$s"
  step "Frame-flow sample (1.5s)"
  local a b; a="$(json_field "$s" frames_encoded)"
  sleep 1.5
  b="$(json_field "$(http_get /status)" frames_encoded)"
  if [[ "${a:-0}" =~ ^[0-9]+$ && "${b:-0}" =~ ^[0-9]+$ && "$b" -gt "$a" ]]; then
    ok "frames_encoded ${a} → ${b} (flowing)"
  else
    warn "frames_encoded ${a} → ${b} (not advancing — no frame source, or Minecraft VR is OFF / session not ready)"
  fi
}

cmd_clean() {
  step "Stopping frame sources (bridge :$BRIDGE_PORT)"
  # Graceful gradle daemon shutdown for both wrappers, then sever any live bridge client.
  local jdk; jdk="$(java21_home)"
  ( cd "$REPO_ROOT" && ./gradlew --stop >/dev/null 2>&1 || true )
  if [[ -n "$jdk" && -d "$jdk" ]]; then
    ( cd "$MC_DIR" && JAVA_HOME="$jdk" ./gradlew --stop >/dev/null 2>&1 || true )
  fi
  local fs; fs="$(frame_source_pids | tr '\n' ' ')"
  if [[ -n "${fs// /}" ]]; then kill_pids "frame source" $fs; else info "no frame source connected"; fi
  pkill -f ':bridge-test:run' 2>/dev/null || true
  pkill -f ':fabric:runClient' 2>/dev/null || true

  step "Stopping VisionCraftHost"
  local hp; hp="$(host_pids | tr '\n' ' ')"
  if [[ -n "${hp// /}" ]]; then kill_pids "host" $hp; else info "host not running"; fi

  step "Freeing ports"
  for pp in "control:$CONTROL_PORT" "bridge:$BRIDGE_PORT"; do
    local name="${pp%%:*}" port="${pp##*:}"
    if wait_port_free "$port" 6; then ok "$name :$port free"; else
      local leftover; leftover="$(port_pids "$port" | tr '\n' ' ')"
      warn "$name :$port still held — killing ${leftover}"
      kill_pids "$name port holder" $leftover
      wait_port_free "$port" 4 && ok "$name :$port free" || bad "$name :$port STILL held (${leftover})"
    fi
  done
  ok "clean complete"
}

cmd_preflight() {
  step "Toolchain checks"
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (install Xcode)"
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  command -v git >/dev/null 2>&1 || die "git not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v lsof >/dev/null 2>&1 || die "lsof not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v cargo >/dev/null 2>&1 || die "cargo not found (run rustup-init -y)"
  command -v rustup >/dev/null 2>&1 || die "rustup not found (brew install rustup-init && rustup-init -y)"
  require_java21 >/dev/null
  ok "core tools present"
  ensure_projects
  artifacts_ready || die "ALVR artifacts missing after prepare-alvr"
  ok "Xcode projects and ALVR artifacts present"
  cmd_doctor
}

cmd_bootstrap() {
  step "VisionCraft beta bootstrap"
  info "This command installs nothing automatically. It checks prerequisites, prepares generated projects/artifacts, and prints the next action."
  cmd_preflight
  step "Next"
  info "1) scripts/vc.sh package-beta"
  info "2) open .run/beta/README-FIRST.txt"
  info "3) scripts/vc.sh host --rebuild"
  info "4) scripts/vc.sh alvr-client"
}

cmd_package_beta() {
  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && dry_run=1
  cmd_preflight

  step "Beta package inputs"
  info "host app: $HOST_APP"
  info "Fabric mod: minecraft/VivecraftMod/build/libs/*fabric*.jar"
  info "ALVR client project: $ALVR_CLIENT_PROJECT"
  if [[ $dry_run -eq 1 ]]; then
    ok "dry run complete — inputs are ready"
    return 0
  fi

  mkdir -p "$RUN_DIR"
  local host_log="$RUN_DIR/host-build.log"
  step "Building VisionCraftHost"
  xcodebuild -project "$HOST_PROJECT" -scheme "$HOST_SCHEME" -configuration Debug \
    -derivedDataPath "$HOST_DERIVED" CODE_SIGNING_ALLOWED="${VISIONCRAFT_CODE_SIGNING_ALLOWED:-NO}" \
    build >"$host_log" 2>&1 && ok "host build succeeded" || die "host build failed; see $host_log"

  local jdk; jdk="$(require_java21)"
  local mod_log="$RUN_DIR/fabric-build.log"
  step "Building Fabric mod"
  ( cd "$MC_DIR" && env JAVA_HOME="$jdk" PATH="$jdk/bin:$PATH" ./gradlew :fabric:build --console=plain >"$mod_log" 2>&1 ) \
    && ok "Fabric mod build succeeded" || die "Fabric mod build failed; see $mod_log"

  rm -rf "$BETA_DIR"
  mkdir -p "$BETA_DIR/Host" "$BETA_DIR/Minecraft" "$BETA_DIR/Headset"
  cp -R "$HOST_APP" "$BETA_DIR/Host/"
  shopt -s nullglob
  local jars=("$MC_DIR"/build/libs/*fabric*.jar)
  shopt -u nullglob
  [[ ${#jars[@]} -gt 0 ]] || die "Fabric mod jar not found under minecraft/VivecraftMod/build/libs"
  local last_index=$(( ${#jars[@]} - 1 ))
  cp "${jars[$last_index]}" "$BETA_DIR/Minecraft/"
  cat >"$BETA_DIR/README-FIRST.txt" <<EOF
VisionCraft Beta
================

1. Run the Mac host:
   open "$BETA_DIR/Host/VisionCraftHost.app"

2. Install/run the headset client:
   scripts/vc.sh alvr-client
   Xcode must sign/install ALVRClient on the paired Apple Vision Pro.

3. Launch Minecraft:
   Use the Fabric mod jar in "$BETA_DIR/Minecraft".
   For development, you can also run: scripts/vc.sh mc

4. Verify:
   scripts/vc.sh verify

Detected configuration:
   Control API: http://127.0.0.1:$CONTROL_PORT
   Bridge port: $BRIDGE_PORT
   ALVR client bundle id: $ALVR_CLIENT_BUNDLE_ID
   Apple team: ${VISIONCRAFT_DEVELOPMENT_TEAM:-not set; choose a team in Xcode}

If the headset app cannot install, open visionos-app/ALVRClient.xcodeproj and select your team/bundle id in Signing & Capabilities.
EOF
  cat >"$BETA_DIR/Headset/INSTALL-ON-AVP.txt" <<EOF
Run this from the repo root:

  scripts/vc.sh alvr-client

Then choose your paired Apple Vision Pro in Xcode and press Cmd-R.
This manual Xcode step is still required unless you distribute through TestFlight or another signed beta channel.
EOF
  ok "beta package written to $BETA_DIR"
  info "Open: $BETA_DIR/README-FIRST.txt"
}

cmd_host() {
  local rebuild=0
  [[ "${1:-}" == "--rebuild" ]] && rebuild=1
  ensure_projects
  step "Resetting host"
  cmd_clean >/dev/null
  if [[ $rebuild -eq 1 || ! -d "$HOST_APP" ]]; then
    step "Building VisionCraftHost (Debug)"
    mkdir -p "$RUN_DIR"
    local log="$RUN_DIR/host-build.log"
    xcodebuild -project "$HOST_PROJECT" -scheme "$HOST_SCHEME" -configuration Debug \
      -derivedDataPath "$HOST_DERIVED" CODE_SIGNING_ALLOWED="${VISIONCRAFT_CODE_SIGNING_ALLOWED:-NO}" build >"$log" 2>&1 \
      && ok "build succeeded" || die "host build failed; see $log"
  else
    info "reusing existing build: $HOST_APP"
  fi
  [[ -d "$HOST_APP" ]] || die "host app not found at $HOST_APP"
  step "Launching VisionCraftHost"
  open "$HOST_APP"
  if wait_http_ok /health 25; then
    ok "control API healthy on :$CONTROL_PORT"
  else
    die "host launched but control API never responded on :$CONTROL_PORT"
  fi
  print_status "$(http_get /status)"
  step "Next"
  info "1) Put on the AVP and run ALVRClient  →  alvr_client_connected=true"
  info "2) scripts/vc.sh mc      # launch Minecraft, then press F7 in-game"
  info "3) scripts/vc.sh verify  # confirm the stream is live"
}

cmd_alvr_client() {
  # The ALVR client is built + run from Xcode. This is deliberate: Xcode's ▶ resolves the device's
  # hardware id (e.g. 00008142-…, which differs from the devicectl CoreDevice UDID D196DA96-…),
  # automatic signing, and provisioning in one step — a headless xcodebuild + devicectl flow is
  # fragile against all three. This command just opens the project and prints the recipe.
  ensure_projects
  "$REPO_ROOT/scripts/prepare-alvr.sh"
  step "Open ALVRClient in Xcode and Run on the AVP"
  local udid; udid="$(avp_udid)"
  [[ -n "$udid" ]] && ok "AVP connected (CoreDevice $udid)" \
                   || warn "no connected AVP detected — wake the headset; pair via Settings ▸ General ▸ Remote Devices"
  info "1) opening $ALVR_CLIENT_PROJECT ..."
  open "$ALVR_CLIENT_PROJECT"
  info "2) in Xcode's run destination menu, pick your paired Apple Vision Pro"
  info "3) press ▶ (Cmd-R) to build, install, and launch on the headset"
  info "4) put on the AVP and allow camera/world tracking permissions"
  info "then on the Mac:  scripts/vc.sh verify"
}

cmd_companion() {
  warn "'companion' is deprecated; use: scripts/vc.sh alvr-client"
  cmd_alvr_client "$@"
}

guard_single_frame_source() {
  local fs; fs="$(frame_source_pids | tr '\n' ' ')"
  if [[ -n "$fs" ]]; then
    die "a frame source is already connected on :$BRIDGE_PORT (pid ${fs}). Only one allowed. Run: scripts/vc.sh clean"
  fi
}

cmd_mc() {
  [[ -n "$(http_get /health)" ]] || die "host not running — run: scripts/vc.sh host"
  guard_single_frame_source
  local jdk; jdk="$(require_java21)"
  mkdir -p "$RUN_DIR"
  local log="$RUN_DIR/minecraft.log"
  step "Launching Minecraft Fabric dev client"
  info "JAVA_HOME=$jdk"
  info "log: $log"
  ( cd "$MC_DIR" && nohup env JAVA_HOME="$jdk" PATH="$jdk/bin:$PATH" \
      ./gradlew :fabric:runClient --console=plain >"$log" 2>&1 & echo $! >"$RUN_DIR/mc.pid" )
  ok "started (pid $(cat "$RUN_DIR/mc.pid"))"
  info "When the title screen appears, press F7 (or the 'VR: OFF' toggle) to enable VR."
  info "Tail with:  tail -f $log"
}

cmd_sender() {
  [[ -n "$(http_get /health)" ]] || die "host not running — run: scripts/vc.sh host"
  guard_single_frame_source
  local n="${1:-0}"
  local jdk; jdk="$(require_java21)"
  mkdir -p "$RUN_DIR"
  local log="$RUN_DIR/sender.log"
  step "Launching headless test-pattern sender (frames=$n, 0=continuous)"
  info "JAVA_HOME=$jdk"
  info "log: $log"
  ( cd "$REPO_ROOT" && nohup env JAVA_HOME="$jdk" PATH="$jdk/bin:$PATH" \
      ./gradlew :bridge-test:run --console=plain --args="127.0.0.1 $BRIDGE_PORT $n" \
      >"$log" 2>&1 & echo $! >"$RUN_DIR/sender.pid" )
  ok "started (pid $(cat "$RUN_DIR/sender.pid"))"
  info "Tail with:  tail -f $log"
}

cmd_verify() {
  local s; s="$(http_get /status)"
  [[ -z "$s" ]] && die "control API not responding — host not running"
  local fail=0
  step "Stream verification"
  [[ "$(json_field "$s" alvr_client_connected)" == "true" ]] \
    && ok "ALVR client connected" \
    || { bad "ALVR client NOT connected — wear AVP and run ALVRClient"; fail=1; }
  local ss; ss="$(json_field "$s" session_state)"
  [[ "$ss" == "ready" ]] && ok "bridge session ready" || { warn "session_state=$ss (becomes 'ready' once ALVR client connects)"; fail=1; }
  local a b; a="$(json_field "$s" frames_encoded)"; sleep 1.5; b="$(json_field "$(http_get /status)" frames_encoded)"
  if [[ "${a:-0}" =~ ^[0-9]+$ && "${b:-0}" =~ ^[0-9]+$ && "$b" -gt "$a" ]]; then
    ok "frames flowing (${a} → ${b})"
  else
    bad "frames not advancing (${a} → ${b}) — start a frame source (vc.sh mc + F7, or vc.sh sender)"; fail=1
  fi
  [[ $fail -eq 0 ]] && step "${C_GREEN}STREAM LIVE${C_RESET}" || step "${C_YEL}stream not fully live (see above)${C_RESET}"
  return "$fail"
}

usage() { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-doctor}"; shift || true
  case "$cmd" in
    bootstrap) cmd_bootstrap "$@";;
    doctor)    cmd_doctor "$@";;
    status)    cmd_status "$@";;
    clean|stop) cmd_clean "$@";;
    preflight) cmd_preflight "$@";;
    package-beta|package) cmd_package_beta "$@";;
    host)      cmd_host "$@";;
    alvr-client|client) cmd_alvr_client "$@";;
    companion) cmd_companion "$@";;
    mc)        cmd_mc "$@";;
    sender)    cmd_sender "$@";;
    verify)    cmd_verify "$@";;
    -h|--help|help) usage;;
    *) printf '%s\n' "unknown command: $cmd" >&2; usage; exit 2;;
  esac
}
main "$@"
