#!/usr/bin/env bash

# Apple Vision Pro discovery helpers. Keep CoreDevice/Xcode parsing in one place.

avp_udid() {
  local json_file
  json_file="$(mktemp "${TMPDIR:-/tmp}/visioncraft-devices.XXXXXX.json")"
  if xcrun devicectl list devices --json-output "$json_file" >/dev/null 2>&1; then
    python3 - "$json_file" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def text_at(obj, *keys):
    for key in keys:
        value = obj.get(key)
        if isinstance(value, str):
            return value
    return ""

for obj in walk(data):
    name = " ".join(
        value
        for value in [
            text_at(obj, "name", "deviceName"),
            text_at(obj, "modelName", "deviceType", "hardwareModel"),
        ]
        if value
    ).lower()
    state = text_at(obj, "connectionState", "state", "availability").lower()
    identifier = text_at(obj, "identifier", "udid", "ecid")
    if "vision pro" in name and "connected" in state and identifier:
        print(identifier)
        break
PY
  fi
  rm -f "$json_file"
}

avp_xcode_id() {
  xcrun xcdevice list 2>/dev/null \
    | python3 -c 'import json,sys
try:
    devices=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    if d.get("modelName") == "Apple Vision Pro" and d.get("available") and not d.get("simulator"):
        print(d.get("identifier",""))
        break' 2>/dev/null || true
}

effective_alvr_client_bundle_id() {
  if [[ -n "${VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID:-}" ]]; then
    printf '%s' "$VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID"
    return 0
  fi

  local project_bundle_id
  project_bundle_id="$(xcode_alvr_client_bundle_id)"
  if [[ -n "$project_bundle_id" ]]; then
    printf '%s' "$project_bundle_id"
    return 0
  fi

  local udid; udid="$(avp_udid)"
  if [[ -n "$udid" ]]; then
    local discovered; discovered="$(devicectl_alvr_client_bundle_id "$udid")"
    if [[ -n "$discovered" ]]; then
      printf '%s' "$discovered"
      return 0
    fi
  fi

  printf '%s\n' "error: unable to determine ALVRClient bundle identifier" >&2
  printf '%s\n' "Set VISIONCRAFT_ALVR_CLIENT_BUNDLE_ID to the installed app's bundle ID," >&2
  printf '%s\n' "or ensure xcodebuild can read $ALVR_CLIENT_PROJECT." >&2
  printf '%s\n' "The tracked project currently uses com.000alen.VisionCraftALVRClient." >&2
  return 1
}

xcode_alvr_client_bundle_id() {
  [[ -d "$ALVR_CLIENT_PROJECT" ]] || return 0
  command -v xcodebuild >/dev/null 2>&1 || return 0

  local build_settings
  build_settings="$(xcodebuild -project "$ALVR_CLIENT_PROJECT" \
    -scheme "$ALVR_CLIENT_SCHEME" \
    -configuration Debug \
    -showBuildSettings -json 2>/dev/null)" || return 0

  python3 -c '
import json
import sys

scheme = sys.argv[1]
try:
    targets = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for target in targets:
    if target.get("target") not in {scheme, "ALVRClient"}:
        continue
    bundle_id = target.get("buildSettings", {}).get("PRODUCT_BUNDLE_IDENTIFIER", "")
    if bundle_id and "$(" not in bundle_id:
        print(bundle_id)
        break
' "$ALVR_CLIENT_SCHEME" 2>/dev/null <<<"$build_settings" || true
}

devicectl_alvr_client_bundle_id() {
  local udid="$1"
  local json_file
  json_file="$(mktemp "${TMPDIR:-/tmp}/visioncraft-apps.XXXXXX.json")"
  if xcrun devicectl device info apps --device "$udid" --json-output "$json_file" >/dev/null 2>&1; then
    python3 - "$json_file" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def text_at(obj, *keys):
    for key in keys:
        value = obj.get(key)
        if isinstance(value, str):
            return value
    return ""

for obj in walk(data):
    bundle_id = text_at(obj, "bundleIdentifier", "bundleID", "identifier")
    labels = [
        text_at(obj, "name", "displayName", "localizedName"),
        text_at(obj, "bundleName", "applicationName", "executableName"),
        bundle_id,
    ]
    haystack = " ".join(label for label in labels if label).lower()
    if bundle_id and ("alvrclient" in haystack or "visioncraftalvrclient" in haystack):
        print(bundle_id)
        break
PY
  fi
  rm -f "$json_file"
}
