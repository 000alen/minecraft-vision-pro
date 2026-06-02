#!/usr/bin/env bash
#
# vc.sh — VisionCraft local runbook orchestrator.
#
# One robust, reproducible entrypoint for the Mac side of the pipeline: detect stale state,
# clean it, build/launch the host, drive a frame source (Minecraft or the headless test pattern),
# build/install the Apple Vision Pro companion, and verify the stream end to end.
#
# Usage:  scripts/vc.sh <command>
#   doctor              Read-only health report (tools, ports, processes, host /status, AVP).
#   status              Compact live status (host /status + frame-flow sample).
#   clean               Stop ALL VisionCraft processes (host, frame sources, gradle daemons); free ports.
#   preflight           Verify toolchain + regenerate Xcode projects if missing. Mutates nothing else.
#   host [--rebuild]    Clean+(re)launch VisionCraftHost; wait until control API is healthy.
#   companion           Build + install + launch the companion on the paired AVP (best effort).
#   mc                  Launch the Minecraft Fabric dev client (openjdk@21) as the frame source.
#   sender [n]          Launch the headless test-pattern sender (bridge-test). n=frame count (0=continuous).
#   verify              Assert the live stream is healthy (viewer connected, frames flowing, session ready).
#   stop                Alias for clean.
#
# Ports (loopback):  control 19734 · bridge 19735 (Java/Minecraft) · relay 19736 (companion, Bonjour)
set -euo pipefail

# ----------------------------------------------------------------------------- constants
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$REPO_ROOT/.run"
CONTROL_PORT=19734
BRIDGE_PORT=19735
RELAY_PORT=19736
CONTROL_URL="http://127.0.0.1:${CONTROL_PORT}"
BONJOUR_TYPE="_visioncraft-stream._tcp"

HOST_PROJECT="$REPO_ROOT/mac-host/VisionCraftHost.xcodeproj"
HOST_SCHEME="VisionCraftHost"
HOST_DERIVED="$REPO_ROOT/mac-host/build"
HOST_APP="$HOST_DERIVED/Build/Products/Debug/VisionCraftHost.app"

COMPANION_PROJECT="$REPO_ROOT/visionos-app/VisionCraftCompanion.xcodeproj"
COMPANION_SCHEME="VisionCraftCompanion"
COMPANION_DERIVED="$REPO_ROOT/visionos-app/build"
COMPANION_APP="$COMPANION_DERIVED/Build/Products/Debug-xros/VisionCraftCompanion.app"
COMPANION_BUNDLE_ID="visioncraft.companion"

MC_DIR="$REPO_ROOT/minecraft/VivecraftMod"

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

ensure_projects() {
  [[ -d "$HOST_PROJECT" && -d "$COMPANION_PROJECT" ]] && return 0
  step "Generating missing Xcode projects"
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  "$REPO_ROOT/scripts/gen-projects.sh"
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
  for t in xcodebuild xcodegen lsof curl; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t missing"; fi
  done
  if command -v python3 >/dev/null 2>&1; then ok "python3 (JSON parsing)"; else warn "python3 missing — JSON parsing falls back to sed"; fi
  if brew --prefix openjdk@21 >/dev/null 2>&1; then ok "openjdk@21 ($(brew --prefix openjdk@21))"; else bad "openjdk@21 missing (brew install openjdk@21)"; fi
  [[ -d "$HOST_PROJECT" ]] && ok "host xcodeproj" || warn "host xcodeproj missing (run: scripts/vc.sh preflight)"
  [[ -d "$COMPANION_PROJECT" ]] && ok "companion xcodeproj" || warn "companion xcodeproj missing (run: scripts/vc.sh preflight)"

  step "Apple Vision Pro"
  local udid; udid="$(avp_udid)"
  if [[ -n "$udid" ]]; then ok "paired + connected: $udid"; else warn "no connected AVP (Settings ▸ General ▸ Remote Devices; pair in Xcode)"; fi

  step "Ports"
  for pp in "control:$CONTROL_PORT" "bridge:$BRIDGE_PORT" "relay:$RELAY_PORT"; do
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
  info "relay_running       = $(json_field "$s" relay_running)"
  info "relay_viewer        = $(json_field "$s" relay_viewer_connected)"
  info "ar_tracking_state   = $(json_field "$s" ar_tracking_state)"
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
  ( cd "$REPO_ROOT" && ./gradlew --stop >/dev/null 2>&1 || true )
  ( cd "$MC_DIR" && JAVA_HOME="$(brew --prefix openjdk@21 2>/dev/null)/libexec/openjdk.jdk/Contents/Home" ./gradlew --stop >/dev/null 2>&1 || true )
  local fs; fs="$(frame_source_pids | tr '\n' ' ')"
  if [[ -n "${fs// /}" ]]; then kill_pids "frame source" $fs; else info "no frame source connected"; fi
  pkill -f ':bridge-test:run' 2>/dev/null || true
  pkill -f ':fabric:runClient' 2>/dev/null || true

  step "Stopping VisionCraftHost"
  local hp; hp="$(host_pids | tr '\n' ' ')"
  if [[ -n "${hp// /}" ]]; then kill_pids "host" $hp; else info "host not running"; fi

  step "Freeing ports"
  for pp in "control:$CONTROL_PORT" "bridge:$BRIDGE_PORT" "relay:$RELAY_PORT"; do
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
  command -v lsof >/dev/null 2>&1 || die "lsof not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"
  brew --prefix openjdk@21 >/dev/null 2>&1 || die "openjdk@21 not found (brew install openjdk@21)"
  ok "core tools present"
  ensure_projects
  ok "Xcode projects present"
  cmd_doctor
}

cmd_host() {
  local rebuild=0
  [[ "${1:-}" == "--rebuild" ]] && rebuild=1
  ensure_projects
  step "Resetting host"
  cmd_clean >/dev/null
  if [[ $rebuild -eq 1 || ! -d "$HOST_APP" ]]; then
    step "Building VisionCraftHost (Debug)"
    xcodebuild -project "$HOST_PROJECT" -scheme "$HOST_SCHEME" -configuration Debug \
      -derivedDataPath "$HOST_DERIVED" build >/dev/null \
      && ok "build succeeded" || die "host build failed (run without redirect to see errors)"
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
  info "1) Put on the AVP, open VisionCraft companion, tap 'Enter VisionCraft'  →  relay_viewer=true"
  info "2) scripts/vc.sh mc      # launch Minecraft, then press F7 in-game"
  info "3) scripts/vc.sh verify  # confirm the stream is live"
}

cmd_companion() {
  # The companion is built + run from Xcode. This is deliberate: Xcode's ▶ resolves the device's
  # hardware id (e.g. 00008142-…, which differs from the devicectl CoreDevice UDID D196DA96-…),
  # automatic signing, and provisioning in one step — a headless xcodebuild + devicectl flow is
  # fragile against all three. This command just opens the project and prints the recipe.
  ensure_projects
  step "Open the companion in Xcode and Run on the AVP"
  local udid; udid="$(avp_udid)"
  [[ -n "$udid" ]] && ok "AVP connected (CoreDevice $udid)" \
                   || warn "no connected AVP detected — wake the headset; pair via Settings ▸ General ▸ Remote Devices"
  info "1) opening $COMPANION_PROJECT …"
  open "$COMPANION_PROJECT"
  info "2) in Xcode's run destination menu, pick: Alen’s Apple Vision Pro"
  info "3) press ▶ (Cmd-R) to build, install, and launch on the headset"
  info "4) put on the AVP and tap 'Enter VisionCraft'"
  info "then on the Mac:  scripts/vc.sh verify"
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
  local jdk; jdk="$(brew --prefix openjdk@21 2>/dev/null)/libexec/openjdk.jdk/Contents/Home"
  [[ -d "$jdk" ]] || die "openjdk@21 JAVA_HOME not found at $jdk"
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
  local jdk; jdk="$(brew --prefix openjdk@21 2>/dev/null)/libexec/openjdk.jdk/Contents/Home"
  [[ -d "$jdk" ]] || die "openjdk@21 JAVA_HOME not found at $jdk"
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
  [[ "$(json_field "$s" relay_viewer_connected)" == "true" ]] \
    && ok "companion connected to relay" \
    || { bad "companion NOT connected — wear AVP, open companion, tap 'Enter VisionCraft'"; fail=1; }
  local ss; ss="$(json_field "$s" session_state)"
  [[ "$ss" == "ready" ]] && ok "bridge session ready" || { warn "session_state=$ss (becomes 'ready' once companion is in)"; fail=1; }
  local a b; a="$(json_field "$s" frames_encoded)"; sleep 1.5; b="$(json_field "$(http_get /status)" frames_encoded)"
  if [[ "${a:-0}" =~ ^[0-9]+$ && "${b:-0}" =~ ^[0-9]+$ && "$b" -gt "$a" ]]; then
    ok "frames flowing (${a} → ${b})"
  else
    bad "frames not advancing (${a} → ${b}) — start a frame source (vc.sh mc + F7, or vc.sh sender)"; fail=1
  fi
  [[ $fail -eq 0 ]] && step "${C_GREEN}STREAM LIVE${C_RESET}" || step "${C_YEL}stream not fully live (see above)${C_RESET}"
  return 0
}

usage() { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-doctor}"; shift || true
  case "$cmd" in
    doctor)    cmd_doctor "$@";;
    status)    cmd_status "$@";;
    clean|stop) cmd_clean "$@";;
    preflight) cmd_preflight "$@";;
    host)      cmd_host "$@";;
    companion) cmd_companion "$@";;
    mc)        cmd_mc "$@";;
    sender)    cmd_sender "$@";;
    verify)    cmd_verify "$@";;
    -h|--help|help) usage;;
    *) printf '%s\n' "unknown command: $cmd" >&2; usage; exit 2;;
  esac
}
main "$@"
