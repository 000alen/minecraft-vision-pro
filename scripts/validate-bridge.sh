#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== VisionCraft bridge validation (no hardware) =="
if command -v brew >/dev/null 2>&1 && brew --prefix openjdk@21 >/dev/null 2>&1; then
  jdk="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
  export JAVA_HOME="$jdk"
  export PATH="$jdk/bin:$PATH"
fi
./gradlew test --no-daemon -q
echo "All bridge unit + integration tests passed."
echo ""
echo "Optional manual M1 check with mock host:"
echo "  ./scripts/run-mock-host.sh &"
echo "  ./gradlew :bridge-test:run  # bridge/java/test-pattern-sender"
