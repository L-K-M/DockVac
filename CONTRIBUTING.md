# Contributing

Create a focused branch and pull request against `main`.

Before pushing:

```bash
swift format lint --recursive --strict Sources Tests Package.swift
bash -n scripts/*.sh
swift test
```

On macOS, also run `scripts/build.sh --clean`.

Keep Docker process and socket access behind a driver. Changes that can delete Docker data require tests for confirmation, cancellation, malformed output, and partial failure.
