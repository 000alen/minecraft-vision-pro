# Latency integration tests

Run on Mac with VisionCraftHost + the test-pattern sender (`:bridge-test`, under `bridge/java/test-pattern-sender/`):

```bash
./gradlew :bridge-test:run
```

Capture logs from host and Java; compare `send=` ms lines against targets in [docs/latency.md](../../docs/latency.md).

Future: automated threshold assertions in CI (macOS runner + paired device).
