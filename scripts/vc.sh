#!/usr/bin/env bash
#
# vc.sh — VisionCraft local runbook orchestrator.
#
# One robust, reproducible entrypoint for the Mac side of the pipeline: detect stale state,
# clean it, build/launch the host, drive a frame source (Minecraft or the headless test pattern),
# launch the VisionCraft headset client (ALVRClient), and verify the stream end to end.
#
# Usage:  scripts/vc.sh <command>
#   bootstrap           First-run beta setup: check prerequisites, prepare artifacts, print next steps.
#   doctor              Read-only health report (tools, signing, artifacts, ports, host /status, AVP).
#   status              Compact live status (host /status + frame-flow sample).
#   clean               Stop ALL VisionCraft processes (host, frame sources, gradle daemons); free ports.
#   preflight           Verify toolchain + regenerate Xcode projects / ALVR artifacts if missing.
#   package-beta        Build/package host + Fabric mod into .run/beta (use --dry-run to check only).
#   host [--rebuild] [--synthetic]
#                       Clean+(re)launch VisionCraftHost; optionally arm host-native test frames.
#   headset             Open the VisionCraft headset client (ALVRClient) project. Alias: alvr-client.
#   synthetic           Enable host-native ALVR test frames (no Java/Minecraft bridge source).
#   minecraft           Launch the Minecraft Fabric dev client (openjdk@21) as the frame source. Alias: mc.
#   test-sender [n]     Launch the headless test-pattern sender (:bridge-test). n=frame count (0=continuous). Alias: sender.
#   verify              Assert the live stream is healthy (ALVR client connected, frames flowing, session ready).
#   observe [seconds]    Capture a reproducible diagnostics bundle under .run/observability/.
#   avp-console [seconds] Launch ALVRClient via devicectl --console and capture headset stdout/stderr.
#   stop                Alias for clean.
#
# Ports (loopback):  control 19734 · bridge 19735 (Java/Minecraft). ALVR uses its own LAN ports.
set -euo pipefail

VC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VC_SCRIPT_DIR/lib/vc-env.sh"
source "$VC_SCRIPT_DIR/lib/vc-log.sh"
source "$VC_SCRIPT_DIR/lib/vc-json.sh"
source "$VC_SCRIPT_DIR/lib/vc-process.sh"
source "$VC_SCRIPT_DIR/lib/vc-device.sh"
source "$VC_SCRIPT_DIR/lib/vc-control.sh"
source "$VC_SCRIPT_DIR/lib/vc-tools.sh"
source "$VC_SCRIPT_DIR/lib/vc-observe.sh"

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
  info "4) scripts/vc.sh headset"
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
  local package_bundle_id
  package_bundle_id="$(effective_alvr_client_bundle_id 2>/dev/null || printf 'unresolved; set VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID if needed')"
  cat >"$BETA_DIR/README-FIRST.txt" <<EOF
VisionCraft Beta
================

1. Run the Mac host:
   open "$BETA_DIR/Host/VisionCraftHost.app"

2. Install/run the headset client:
   scripts/vc.sh headset
   Xcode must sign/install ALVRClient on the paired Apple Vision Pro.

3. Launch Minecraft:
   Use the Fabric mod jar in "$BETA_DIR/Minecraft".
   For development, you can also run: scripts/vc.sh minecraft

4. Verify:
   scripts/vc.sh verify

Detected configuration:
   Control API: http://127.0.0.1:$CONTROL_PORT
   Bridge port: $BRIDGE_PORT
   ALVR client bundle id: $package_bundle_id
   Apple team: ${VISIONCRAFT_DEVELOPMENT_TEAM:-tracked project setting or Xcode UI selection}

If the headset app cannot install, open visionos-app/ALVRClient.xcodeproj and select your team/bundle id in Signing & Capabilities.
EOF
  cat >"$BETA_DIR/Headset/INSTALL-ON-AVP.txt" <<EOF
Run this from the repo root:

  scripts/vc.sh headset

Then choose your paired Apple Vision Pro in Xcode and press Cmd-R.
This manual Xcode step is still required unless you distribute through TestFlight or another signed beta channel.
EOF
  ok "beta package written to $BETA_DIR"
  info "Open: $BETA_DIR/README-FIRST.txt"
}

cmd_host() {
  local rebuild=0
  local synthetic=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild) rebuild=1;;
      --synthetic) synthetic=1;;
      *) die "unknown host option: $1";;
    esac
    shift
  done
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
  if [[ $synthetic -eq 1 ]]; then
    step "Enabling host-native synthetic test frames"
    http_post "/alvr/start?synthetic=true" >/dev/null || die "failed to enable synthetic ALVR frames"
    print_status "$(http_get /status)"
  fi
  step "Next"
  info "1) Put on the AVP and run ALVRClient  →  alvr_client_connected=true"
  if [[ $synthetic -eq 1 ]]; then
    info "2) Press Enter in ALVRClient; host-native test pattern should appear"
    info "3) scripts/vc.sh verify  # confirm ALVR-only stream is live"
  else
    info "2) scripts/vc.sh synthetic  # ALVR-only test, or scripts/vc.sh minecraft + F7"
    info "3) scripts/vc.sh verify     # confirm the stream is live"
  fi
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
  warn "'companion' is deprecated; use: scripts/vc.sh headset"
  cmd_alvr_client "$@"
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

cmd_synthetic() {
  [[ -n "$(http_get /health)" ]] || die "host not running — run: scripts/vc.sh host --synthetic"
  step "Enabling host-native ALVR test pattern"
  http_post "/alvr/start?synthetic=true" >/dev/null || die "failed to enable synthetic ALVR frames"
  ok "synthetic source armed"
  info "This bypasses Java/Minecraft. Frames advance once ALVRClient is connected and immersive."
  print_status "$(http_get /status)"
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
    bad "frames not advancing (${a} → ${b}) — run vc.sh synthetic for ALVR-only, or vc.sh test-sender/minecraft + F7"; fail=1
  fi
  [[ $fail -eq 0 ]] && step "${C_GREEN}STREAM LIVE${C_RESET}" || step "${C_YEL}stream not fully live (see above)${C_RESET}"
  return "$fail"
}

usage() { sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
    headset|alvr-client|client) cmd_alvr_client "$@";;
    companion) cmd_companion "$@";;
    synthetic) cmd_synthetic "$@";;
    minecraft|mc) cmd_mc "$@";;
    test-sender|sender) cmd_sender "$@";;
    verify)    cmd_verify "$@";;
    observe)   cmd_observe "$@";;
    avp-console) cmd_avp_console "$@";;
    -h|--help|help) usage;;
    *) printf '%s\n' "unknown command: $cmd" >&2; usage; exit 2;;
  esac
}
main "$@"
