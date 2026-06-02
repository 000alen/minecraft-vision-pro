#!/usr/bin/env bash
# Regenerate the Mac host Xcode project from its `project.yml` spec.
# The generated `*.xcodeproj` bundles are git-ignored build artifacts; run this after a fresh
# clone or whenever you add/remove/rename source files.
#
# Requires XcodeGen:  brew install xcodegen
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with:  brew install xcodegen" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Generating mac-host/*.xcodeproj"
(cd "$repo_root/mac-host" && xcodegen generate --spec project.yml)

echo "Done. Open mac-host/VisionCraftHost.xcodeproj. The headset client is visionos-app/ALVRClient.xcodeproj."
