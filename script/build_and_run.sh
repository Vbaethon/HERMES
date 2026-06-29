#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/project_config.sh"
DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData/HERMES-Codex"
PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

build_app() {
  "$ROOT_DIR/build.sh" --no-run
}

open_app() {
  /usr/bin/open -n "$APP_PATH"
}

case "$MODE" in
  run)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    open_app
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --help|help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

printf '%s\n' "$APP_PATH"
