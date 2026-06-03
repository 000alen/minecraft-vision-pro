#!/usr/bin/env bash

# Evidence collection for hardware and local runs.

write_observe_metadata() {
  local out="$1"
  {
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo=%s\n' "$REPO_ROOT"
    printf 'git_rev=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    printf 'branch=%s\n' "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
    printf 'coredevice_udid=%s\n' "$(avp_udid)"
    printf 'xcode_device_id=%s\n' "$(avp_xcode_id)"
    printf 'control_url=%s\n' "$CONTROL_URL"
    printf 'bridge_port=%s\n' "$BRIDGE_PORT"
    printf 'alvr_client_bundle_id=%s\n' "$(effective_alvr_client_bundle_id 2>/dev/null || printf 'unresolved')"
  } >"$out/metadata.txt"
  git -C "$REPO_ROOT" status --short >"$out/git-status.txt" 2>&1 || true
  xcodebuild -version >"$out/xcodebuild-version.txt" 2>&1 || true
}

snapshot_observability() {
  local out="$1"
  mkdir -p "$out"
  http_get /status >"$out/host-status.json" || true
  "$REPO_ROOT/scripts/vc.sh" status >"$out/vc-status.txt" 2>&1 || true
  lsof -nP -iTCP:"$CONTROL_PORT" -iTCP:"$BRIDGE_PORT" >"$out/lsof-ports.txt" 2>&1 || true
  ps -axo pid,ppid,stat,etime,command | grep -E 'VisionCraftHost|bridge-test|fabric:runClient|GradleDaemon|ALVRClient' | grep -v grep >"$out/processes.txt" 2>&1 || true

  mkdir -p "$out/alvr" "$out/logs"
  [[ -f "$RUN_DIR/sender.log" ]] && cp "$RUN_DIR/sender.log" "$out/logs/sender.log"
  [[ -f "$RUN_DIR/minecraft.log" ]] && cp "$RUN_DIR/minecraft.log" "$out/logs/minecraft.log"
  [[ -f "$RUN_DIR/host-build.log" ]] && cp "$RUN_DIR/host-build.log" "$out/logs/host-build.log"
  [[ -f "$RUN_DIR/fabric-build.log" ]] && cp "$RUN_DIR/fabric-build.log" "$out/logs/fabric-build.log"
  [[ -f "$RUN_DIR/alvr/config/session.json" ]] && cp "$RUN_DIR/alvr/config/session.json" "$out/alvr/session.json"
  if [[ -d "$RUN_DIR/alvr/logs" ]]; then
    cp -R "$RUN_DIR/alvr/logs/." "$out/alvr/" 2>/dev/null || true
  fi

  xcrun devicectl list devices --json-output "$out/devicectl-devices.json" --log-output "$out/devicectl-devices.log" >"$out/devicectl-devices.txt" 2>&1 || true
  xcrun xcdevice list >"$out/xcdevice-list.json" 2>&1 || true
  local udid; udid="$(avp_udid)"
  if [[ -n "$udid" ]]; then
    xcrun devicectl device info apps --device "$udid" --json-output "$out/avp-apps.json" --log-output "$out/avp-apps.log" >"$out/avp-apps.txt" 2>&1 || true
    xcrun devicectl device info processes --device "$udid" --json-output "$out/avp-processes.json" --log-output "$out/avp-processes.log" >"$out/avp-processes.txt" 2>&1 || true
  fi
}

sample_status_loop() {
  local seconds="$1" out="$2" end
  end=$(( $(date +%s) + seconds ))
  while [[ $(date +%s) -lt $end ]]; do
    printf '{"timestamp":"%s","status":' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out/status.ndjson"
    local status; status="$(http_get /status)"
    if [[ -n "$status" ]]; then
      printf '%s}\n' "$status" >>"$out/status.ndjson"
    else
      printf 'null}\n' >>"$out/status.ndjson"
    fi
    sleep 1
  done
}

cmd_observe() {
  local seconds="${1:-30}"
  [[ "$seconds" =~ ^[0-9]+$ ]] || die "observe duration must be seconds"
  mkdir -p "$RUN_DIR/observability"
  local out="$RUN_DIR/observability/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$out"

  step "Capturing observability bundle ($seconds seconds)"
  info "output: $out"
  write_observe_metadata "$out"
  snapshot_observability "$out/before"

  mkdir -p "$out/live"
  sample_status_loop "$seconds" "$out/live" &
  local status_pid=$!
  log stream --style compact \
    --predicate 'process == "VisionCraftHost" OR eventMessage CONTAINS "VisionCraft" OR eventMessage CONTAINS "ALVR"' \
    >"$out/live/mac-unified.log" 2>&1 &
  local log_pid=$!
  sleep "$seconds"
  kill "$log_pid" 2>/dev/null || true
  wait "$log_pid" 2>/dev/null || true
  wait "$status_pid" 2>/dev/null || true

  snapshot_observability "$out/after"
  ok "observability bundle ready: $out"
  info "Start with: $out/live/status.ndjson and $out/live/mac-unified.log"
}

cmd_avp_console() {
  local seconds="${1:-120}"
  [[ "$seconds" =~ ^[0-9]+$ ]] || die "avp-console duration must be seconds"
  local udid; udid="$(avp_udid)"
  [[ -n "$udid" ]] || die "no connected AVP found by devicectl"
  local bundle_id; bundle_id="$(effective_alvr_client_bundle_id)" || die "set VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID to launch ALVRClient if Xcode/device discovery cannot resolve it"

  mkdir -p "$RUN_DIR/observability"
  local out="$RUN_DIR/observability/avp-console-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$out"
  write_observe_metadata "$out"

  step "Launching ALVRClient through devicectl console ($seconds seconds)"
  info "device: $udid"
  info "bundle: $bundle_id"
  info "output: $out/avp-console.log"
  xcrun devicectl device process launch \
    --device "$udid" --console "$bundle_id" \
    --json-output "$out/avp-launch.json" \
    --log-output "$out/avp-launch-devicectl.log" \
    >"$out/avp-console.log" 2>&1 &
  local console_pid=$!
  sleep "$seconds"
  kill "$console_pid" 2>/dev/null || true
  wait "$console_pid" 2>/dev/null || true
  snapshot_observability "$out/after"
  ok "AVP console capture ready: $out"
}
