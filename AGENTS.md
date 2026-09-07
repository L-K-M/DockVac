# AGENTS.md

## Tooling

Use Swift 6.3.3 (`.swift-version` pins the toolchain).

- `swift test` verifies the Foundation-only core.
- `scripts/build.sh [--clean] [--run] [--install]` verifies and packages the native macOS app.
- `scripts/release.sh X.Y.Z [--push]` bumps, commits, tags, and optionally pushes a release.
- `--install` replaces `/Applications/DockVac.app` and reveals it in Finder.

## Architecture

Keep `DockVacCore` independent of AppKit and raw process I/O. It owns validated domain models and cleanup policy.

Put Docker CLI/socket mechanics behind a dedicated driver in the macOS layer. UI code may call an application service, never `Process`, sockets, or the filesystem directly.

Treat every destructive Docker command as high risk. Show the exact resources and estimated reclaimable space, require explicit user confirmation, and test cancellation and partial-failure paths before enabling it.

## Releases

Release tags are annotated `vX.Y.Z` tags on `main`. GitHub Actions verifies the tag against `Resources/Info.plist`, rebuilds the app, produces ZIP and DMG assets with SHA-256 checksums, verifies uploaded bytes, and leaves the release as a draft.

Builds are ad-hoc signed. Do not describe them as notarized or Developer ID signed.

## AI review scope

GLM review defaults to hybrid: the first review is full, then follow-ups review changes since the last completed review plus a rotating sample of older PR changes.

Before the next review-triggering push, apply at most one override label:

- `zai-review:full` for high-risk changes or a final deep audit.
- `zai-review:hybrid` for the normal delta-plus-audit mode.
- `zai-review:incremental` only for low-risk follow-ups after a completed full review.

Labels select the next run but do not trigger one themselves. Missing/incomplete state and diverged history safely fall back to a full review.
