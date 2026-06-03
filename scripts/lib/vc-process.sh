#!/usr/bin/env bash

# Process and port ownership helpers. These keep vc.sh command implementations
# focused on workflows rather than lsof/pgrep details.

port_pids() { lsof -nP -iTCP:"$1" -t 2>/dev/null | sort -u || true; }
port_estab_pids() { lsof -nP -iTCP:"$1" -sTCP:ESTABLISHED -t 2>/dev/null | sort -u || true; }
host_pids() { pgrep -f "VisionCraftHost.app/Contents/MacOS/VisionCraftHost" 2>/dev/null | sort -u || true; }

kill_pids() {
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

wait_port_free() {
  local port="$1" timeout="${2:-8}" t=0
  while :; do
    [[ -z "$(port_pids "$port")" ]] && return 0
    awk "BEGIN{exit !($t >= $timeout)}" && return 1
    sleep 0.3; t=$(awk "BEGIN{print $t + 0.3}")
  done
}

frame_source_pids() {
  local hp; hp="$(host_pids | tr '\n' ' ')"
  local out=""
  for p in $(port_estab_pids "$BRIDGE_PORT"); do
    case " $hp " in *" $p "*) ;; *) out+="$p ";; esac
  done
  printf '%s' "$out" | xargs -n1 2>/dev/null | sort -u || true
}

guard_single_frame_source() {
  local fs; fs="$(frame_source_pids | tr '\n' ' ')"
  if [[ -n "$fs" ]]; then
    die "a frame source is already connected on :$BRIDGE_PORT (pid ${fs}). Only one allowed. Run: scripts/vc.sh clean"
  fi
}
