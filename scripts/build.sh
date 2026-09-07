#!/usr/bin/env bash
# Verify DockVac and assemble the native app.
# Usage: scripts/build.sh [--clean] [--run] [--install]
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly APP_PATH="$REPOSITORY_ROOT/build/DockVac.app"
readonly INSTALL_PATH="/Applications/DockVac.app"
readonly HOST_MACOS="Darwin"

clean_requested=0
run_requested=0
install_requested=0

for argument in "$@"; do
  case "$argument" in
    --clean) clean_requested=1 ;;
    --run) run_requested=1 ;;
    --install) install_requested=1 ;;
    -h|--help) sed -n '2,3s/^# //p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done

cd "$REPOSITORY_ROOT"

if ((clean_requested)); then
  swift package clean
  rm -rf -- "$APP_PATH"
fi

swift test

if [[ "$(uname -s)" != "$HOST_MACOS" ]]; then
  if ((install_requested || run_requested)); then
    echo "--install and --run require macOS; only core verification runs here." >&2
    exit 1
  fi
  echo "Core verified; app packaging requires macOS."
  exit 0
fi

"$SCRIPT_DIR/make-app.sh"

if ((install_requested)); then
  rm -rf -- "$INSTALL_PATH"
  ditto "$APP_PATH" "$INSTALL_PATH"
  open -R "$INSTALL_PATH" >/dev/null 2>&1 || true
fi

if ((run_requested)); then
  if ((install_requested)); then
    open "$INSTALL_PATH"
  else
    open "$APP_PATH"
  fi
fi
