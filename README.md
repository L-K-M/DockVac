# DockVac

DockVac is a native macOS utility for inspecting and reclaiming disk space used by Docker.

> [!NOTE]
> DockVac is an early scaffold. The app shell, validated storage model, packaging, and release pipeline exist; Docker inspection and cleanup actions are not implemented yet.

## Requirements

- macOS 13 or newer
- Swift 6.3.3
- Xcode command-line tools
- Docker Desktop (once Docker integration lands)

## Build

```bash
swift test
scripts/build.sh --clean
open build/DockVac.app
```

Build, copy to `/Applications`, and reveal it in Finder:

```bash
scripts/build.sh --install
```

Use `scripts/build.sh --run` to build and launch without installing.

## Architecture

`DockVacCore` contains platform-neutral models and cleanup policy. The `DockVac` target owns AppKit. Docker CLI or socket access must live behind a dedicated driver so the UI never executes destructive commands directly.

## Release

```bash
scripts/release.sh 0.1.0 --push
```

The annotated tag triggers GitHub Actions. It rebuilds the app, creates draft ZIP and DMG release assets plus SHA-256 checksums, and verifies the uploaded bytes. Builds are ad-hoc signed and not notarized.

## License

[Unlicense](LICENSE)
