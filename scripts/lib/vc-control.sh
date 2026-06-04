#!/usr/bin/env bash

# VisionCraftHost loopback control API helpers.

http_get()  { curl -fsS --max-time 3 "${CONTROL_URL}$1" 2>/dev/null || true; }
http_post() { curl -fsS --max-time 5 -X POST "${CONTROL_URL}$1" 2>/dev/null || true; }

wait_http_ok() {
  local path="$1" timeout="${2:-20}" t=0
  while :; do
    [[ -n "$(http_get "$path")" ]] && return 0
    awk "BEGIN{exit !($t >= $timeout)}" && return 1
    sleep 0.4; t=$(awk "BEGIN{print $t + 0.4}")
  done
}

print_status() {
  local s="$1"
  info "session_state       = $(json_field "$s" session_state)"
  info "bridge_streaming_ready = $(json_field "$s" bridge_streaming_ready)"
  info "alvr_running        = $(json_field "$s" alvr_running)"
  info "alvr_client         = $(json_field "$s" alvr_client_connected)"
  info "alvr_frames_sent    = $(json_field "$s" alvr_frames_sent)"
  info "frames_received     = $(json_field "$s" frames_received)"
  info "frames_encoded      = $(json_field "$s" frames_encoded)"
  info "frames_dropped_no_config = $(json_field "$s" frames_dropped_no_config)"
  info "sent_video_config   = $(json_field "$s" sent_video_config)"
  info "synthetic_frames    = $(json_field "$s" synthetic_frames_enabled)"
  info "diagnostic          = $(json_field "$s" diagnostic)"
}
