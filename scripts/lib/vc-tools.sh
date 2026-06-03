#!/usr/bin/env bash

# Toolchain and generated-artifact helpers.

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
    info "VISIONCRAFT_DEVELOPMENT_TEAM unset — tracked Xcode project settings or Xcode UI selection will be used"
  fi
  local bundle_id
  if bundle_id="$(effective_alvr_client_bundle_id 2>/dev/null)"; then
    info "ALVR client bundle id: $bundle_id"
  else
    warn "ALVR client bundle id unresolved — set VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID if Xcode build settings are unavailable"
  fi
}

check_tool() {
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
