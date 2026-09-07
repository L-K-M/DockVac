#!/usr/bin/env bash
# Bump, verify, commit, and tag a native macOS release.
# Usage: scripts/release.sh X.Y.Z [--push]
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly INFO_PLIST="$REPOSITORY_ROOT/Resources/Info.plist"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly HOST_MACOS="Darwin"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

usage() {
  echo "Usage: scripts/release.sh X.Y.Z [--push]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

readonly version="$1"
readonly push_option="${2:-}"

if [[ ! "$version" =~ $VERSION_PATTERN ]]; then
  echo "Version must use X.Y.Z." >&2
  exit 2
fi

if [[ -n "$push_option" && "$push_option" != "--push" ]]; then
  usage
  exit 2
fi

if [[ "$(uname -s)" != "$HOST_MACOS" ]]; then
  echo "Releases require macOS." >&2
  exit 1
fi

cd "$REPOSITORY_ROOT"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Releases must start on main." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree must be clean." >&2
  exit 1
fi

readonly tag="v$version"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

current_build="$($PLIST_BUDDY -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ ! "$current_build" =~ ^[0-9]+$ ]]; then
  echo "CFBundleVersion must be numeric." >&2
  exit 1
fi

# Keep user-facing and internal versions in the app bundle metadata.
next_build=$((current_build + 1))
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $version" "$INFO_PLIST"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $next_build" "$INFO_PLIST"

"$SCRIPT_DIR/build.sh" --clean

git add "$INFO_PLIST"
git commit -s -m "Release DockVac $version" \
  -m "Prepare the native macOS release metadata."
git tag -a "$tag" -m "DockVac $version"

if [[ "$push_option" == "--push" ]]; then
  git push origin main "$tag"
fi

echo "Created $tag."
