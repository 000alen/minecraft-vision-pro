# Latency integration tests

Run on Mac with VisionCraftHost + bridge-test:

```bash
./gradlew :bridge-test:run
```

Capture logs from host and Java; compare `send=` ms lines against targets in [docs/latency.md](../../docs/latency.md).

Future: automated threshold assertions in CI (macOS runner + paired device).
