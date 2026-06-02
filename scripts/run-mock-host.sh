#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-19735}"
echo "Starting MockVisionCraftHost on port $PORT"
if command -v brew >/dev/null 2>&1 && brew --prefix openjdk@21 >/dev/null 2>&1; then
  jdk="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
  export JAVA_HOME="$jdk"
  export PATH="$jdk/bin:$PATH"
fi
exec ./gradlew :bridge-mock-host:run --args="$PORT" -q
