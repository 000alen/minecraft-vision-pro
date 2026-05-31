#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== VisionCraft bridge validation =="
./gradlew test --no-daemon -q
echo "Unit tests OK."
echo ""
echo "For M1 integration: start VisionCraftHost, then:"
echo "  ./gradlew :bridge-test:run"
