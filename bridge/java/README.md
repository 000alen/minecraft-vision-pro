# Bridge Java Modules

Bridge v1 protocol documentation remains canonical at `bridge/protocol.md`.

This directory contains the Java-side Gradle modules used to validate and exercise that protocol:

- `lib/` is the Java Bridge v1 client library module (`:bridge-lib`). Its sources are shared with the Vivecraft Apple provider under `minecraft/VivecraftMod/`.
- `test-pattern-sender/` is the deterministic frame-source module (`:bridge-test`). Run it through `scripts/vc.sh test-sender` or the legacy alias `scripts/vc.sh sender`.
- `mock-host/` is the headless Bridge v1 server module (`:bridge-mock-host`) used by unit/integration tests and `scripts/run-mock-host.sh`.

The physical paths moved under `bridge/java/`, but the Gradle project names intentionally remain unchanged for compatibility with scripts, CI, and existing developer commands.
