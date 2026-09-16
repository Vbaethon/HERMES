#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${HERMES_BUILD_CONFIGURATION:-Debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/script/project_config.sh"
MAC_ARCH="$(uname -m)"
XCODE_DESTINATION="platform=macOS,arch=$MAC_ARCH"

SHOULD_RUN=true
SHOULD_CLEAN=false

XCODE_DEVELOPER_DIR="$(resolve_developer_dir)"
XCODEBUILD="$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild"

usage() {
  echo "usage: $0 [--release] [--no-run] [--clean]" >&2
  echo "  --release   Build with Release configuration (default: Debug)" >&2
  echo "  --no-run    Build only, do not launch the app" >&2
  echo "  --clean     Clean build folder before building" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIGURATION="Release"
      ;;
    --no-run)
      SHOULD_RUN=false
      ;;
    --clean)
      SHOULD_CLEAN=true
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
  shift
done

if [[ "$SHOULD_CLEAN" == true ]]; then
  if app_is_running; then
    echo "HERMES is running; clean was skipped to protect current tasks. Quit the app before cleaning." >&2
    exit 1
  fi
  rm -rf "${HERMES_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData/HERMES-Codex}"
fi
prepare_build_paths

echo "Building $SCHEME ($CONFIGURATION)..."

mkdir -p "$DERIVED_DATA_DIR" "$PRODUCTS_DIR"


DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODEBUILD" \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  "${SIGNING_ARGS[@]}" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination "$XCODE_DESTINATION" \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "missing built app: $APP_PATH" >&2
  exit 1
fi

echo "Build complete: $APP_PATH"

if [[ "$SHOULD_RUN" == true ]]; then
  if app_is_running; then
    echo "Existing HERMES left running. Open this build after current tasks finish: $APP_PATH"
  else
    echo "Launching $APP_NAME..."
    /usr/bin/open "$APP_PATH"
  fi
fi
