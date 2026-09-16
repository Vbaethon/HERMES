#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/project_config.sh"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

build_app() {
  "$ROOT_DIR/build.sh" --no-run
}

open_app() {
  /usr/bin/open "$APP_PATH"
}

case "$MODE" in
  --help|help) usage; exit 0 ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) usage; exit 2 ;;
esac
prepare_build_paths
export HERMES_PRODUCTS_DIR="$PRODUCTS_DIR"
build_app
if app_is_running; then
  echo "HERMES is running; kept current tasks intact. New build: $APP_PATH" >&2
  # Do not report the old process as verification of this new build.
  case "$MODE" in --debug|debug|--verify|verify) exit 1 ;; esac
  exit 0
fi

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
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
