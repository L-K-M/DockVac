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

To run the app without Docker, replay the fixtures with `scripts/fake-docker.py --socket /tmp/dockvac-fake.sock` and launch the binary with `DOCKER_HOST=unix:///tmp/dockvac-fake.sock`. Setting `DOCKVAC_SMOKE_SCRIPT=focus-images,select-first,add-safe,review` walks through the screens after the first scan; the manual `ui_smoke` CI job uses this to capture screenshots. Nothing is ever confirmed or removed by the script.

Keep Docker socket access behind the `DockVacDocker` driver. Changes that can delete Docker data require tests for confirmation, cancellation, malformed output, and partial failure.
