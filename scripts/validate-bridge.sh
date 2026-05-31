#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== VisionCraft bridge validation (no hardware) =="
./gradlew test --no-daemon -q
echo "All bridge unit + integration tests passed."
echo ""
echo "Optional manual M1 check with mock host:"
echo "  ./scripts/run-mock-host.sh &"
echo "  ./gradlew :bridge-test:run"
