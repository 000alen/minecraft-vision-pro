#!/usr/bin/env bash
# Regenerate the Xcode projects for both native apps from their `project.yml` specs.
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

for app in mac-host visionos-app; do
  spec="$repo_root/$app/project.yml"
  if [[ -f "$spec" ]]; then
    echo "==> Generating $app/*.xcodeproj"
    (cd "$repo_root/$app" && xcodegen generate --spec project.yml)
  fi
done

echo "Done. Open mac-host/VisionCraftHost.xcodeproj or visionos-app/VisionCraftCompanion.xcodeproj."
