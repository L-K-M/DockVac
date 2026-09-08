# AGENTS.md

## Tooling

Use Swift 6.3.3 (`.swift-version` pins the toolchain).

- `swift test` verifies the Foundation-only core.
- `scripts/build.sh [--clean] [--run] [--install]` verifies and packages the native macOS app.
- `scripts/release.sh X.Y.Z [--push]` bumps, commits, tags, and optionally pushes a release.
- `--install` replaces `/Applications/DockVac.app` and reveals it in Finder.

## Architecture

Keep `DockVacCore` independent of AppKit and raw process I/O. It owns validated domain models (`Models.swift`), Engine API decoding, usage analysis (`UsageAnalyzer` decides removability and explanations), the squarified treemap layout, and cleanup policy (`CleanupPlan`, `CleanupRunState`).

`DockVacDocker` is the dedicated driver: the unix-socket HTTP client, the typed `DockerEngineClient`, `DockerEndpointLocator`, `DockerScanner`, and `CleanupRunner`. It compiles on Linux so it can be tested against a live daemon there. Only it may open sockets or read Docker's config files.

UI code in `DockVac` calls `DockerService` (the application service), never `Process`, sockets, or the filesystem directly. Views render `ReportViewState` and call back through `ReportActions`.

Treat every destructive Docker command as high risk. All removals go through `CleanupPlan.make`, which excludes blocked items and orders prerequisites, and through the confirmation sheet. Never add `force`, never stop containers, never prune wholesale. Keep tests for cancellation, malformed output, and partial failure green when touching the runner or client.

Fixtures under `Tests/DockVacCoreTests/Fixtures` are real Engine API responses; regenerate them from a daemon rather than editing by hand. Live tests in `Tests/DockVacDockerTests/LiveDockerTests.swift` need a reachable daemon with `alpine:3.20` present and skip otherwise.

Regenerate `Resources/AppIcon.icns` with `scripts/make-icon.py` (needs Pillow) when `media-sources/icon.png` changes.

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
