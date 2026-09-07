# Contributing

Create a focused branch and pull request against `main`.

Before pushing:

```bash
swift format lint --recursive --strict Sources Tests Package.swift
bash -n scripts/*.sh
swift test
```

On macOS, also run `scripts/build.sh --clean`.

The integration tests in `Tests/DockVacDockerTests/LiveDockerTests.swift` run against a real daemon when one is reachable and `alpine:3.20` is present locally; otherwise they skip. They create and remove resources prefixed `dockvac-test-`.

Keep Docker socket access behind the `DockVacDocker` driver. Changes that can delete Docker data require tests for confirmation, cancellation, malformed output, and partial failure.
