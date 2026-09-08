#!/usr/bin/env bash
# Assemble and ad-hoc sign build/DockVac.app.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly APP_ROOT="$REPOSITORY_ROOT/build/DockVac.app"
readonly CONTENTS="$APP_ROOT/Contents"
readonly MACOS_DIR="$CONTENTS/MacOS"
readonly RESOURCES_DIR="$CONTENTS/Resources"
readonly HOST_MACOS="Darwin"

if [[ "$(uname -s)" != "$HOST_MACOS" ]]; then
  echo "App packaging requires macOS." >&2
  exit 1
fi

cd "$REPOSITORY_ROOT"
swift build -c release --product DockVac
binary_dir="$(swift build -c release --show-bin-path)"

rm -rf -- "$APP_ROOT"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$binary_dir/DockVac" "$MACOS_DIR/DockVac"
cp "$REPOSITORY_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
# Regenerate with scripts/make-icon.py when media-sources/icon.png changes.
cp "$REPOSITORY_ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$REPOSITORY_ROOT/LICENSE" "$RESOURCES_DIR/LICENSE.txt"

# Ad-hoc signing is enough for a local build; releases remain unnotarized.
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$APP_ROOT"
codesign --verify --strict "$APP_ROOT"

echo "$APP_ROOT"
