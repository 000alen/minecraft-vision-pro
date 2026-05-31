#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-19735}"
echo "Starting MockVisionCraftHost on port $PORT"
exec ./gradlew :bridge-mock-host:run --args="$PORT" -q
