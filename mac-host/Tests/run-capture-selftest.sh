#!/usr/bin/env bash
#
# Headless self-test for the Mac-side frame-capture pipeline. Compiles the REAL production sources
# (StereoFrameEncoder + FrameCapture, which depend only on system frameworks) together with
# Tests/main.swift and runs them — no GUI, no ALVR server_core, no Apple Vision Pro.
#
# Usage: mac-host/Tests/run-capture-selftest.sh [out_root] [eye_width] [eye_height] [frames]
#
# Produces <out_root>/.run/captures/<ts>/{recv,sbs,decoded}/*.png + header.json + manifest.ndjson.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_dir="$(cd "$here/.." && pwd)"

out_root="${1:-/tmp/vc-selftest}"
eye_w="${2:-512}"
eye_h="${3:-512}"
frames="${4:-3}"

bin_dir="$(mktemp -d)"
bin="$bin_dir/captest"

echo "==> Compiling capture self-test (real StereoFrameEncoder + FrameCapture)"
swiftc -O \
  "$host_dir/Sources/StereoFrameEncoder.swift" \
  "$host_dir/Sources/FrameCapture.swift" \
  "$here/main.swift" \
  -o "$bin"

echo "==> Running self-test ($eye_w x $eye_h, $frames frames) -> $out_root"
"$bin" "$out_root" "$eye_w" "$eye_h" "$frames"

rm -rf "$bin_dir"
