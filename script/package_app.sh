#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="Release"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/project_config.sh"
BUILD_DIR="$ROOT_DIR/Build"
DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData/HERMES-Codex"
PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION"
PROJECT_FILE="$ROOT_DIR/$PROJECT_NAME/project.pbxproj"
BUILT_APP="$PRODUCTS_DIR/$APP_NAME.app"
STAGED_APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/Applications}"
FINAL_APP="$INSTALL_DIR/$APP_NAME.app"
TEMP_APP="$INSTALL_DIR/.$APP_NAME.installing.$$.app"
MAC_ARCH="$(uname -m)"
XCODE_DESTINATION="platform=macOS,arch=$MAC_ARCH"
SHOULD_BUMP_VERSION=true
SHOULD_OPEN=true
PROJECT_FILE_BACKUP=""

XCODE_DEVELOPER_DIR="$(resolve_developer_dir)"
XCODEBUILD="$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild"

usage() {
  echo "usage: $0 [--no-version-bump] [--no-open]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-version-bump)
      SHOULD_BUMP_VERSION=false
      ;;
    --no-open)
      SHOULD_OPEN=false
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

bump_build_number() {
  local current_build build_width next_build next_build_padded
  if [[ ! -f "$PROJECT_FILE" ]]; then
    echo "missing Xcode project file: $PROJECT_FILE" >&2
    exit 1
  fi
  current_build="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);/\1/p' "$PROJECT_FILE" | head -n 1)"
  if [[ ! "$current_build" =~ ^[0-9]+$ ]]; then
    current_build="0"
  fi
  build_width=${#current_build}
  next_build=$((10#$current_build + 1))
  next_build_padded="$(printf "%0${build_width}d" "$next_build")"
  perl -0pi -e "s/CURRENT_PROJECT_VERSION = \\d+;/CURRENT_PROJECT_VERSION = $next_build_padded;/g" "$PROJECT_FILE"
}

cleanup() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 && -n "$PROJECT_FILE_BACKUP" && -f "$PROJECT_FILE_BACKUP" ]]; then
    cp "$PROJECT_FILE_BACKUP" "$PROJECT_FILE"
  fi
  rm -f "$PROJECT_FILE_BACKUP"
  rm -rf "$TEMP_APP"
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR" "$DERIVED_DATA_DIR" "$PRODUCTS_DIR" "$INSTALL_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ "$SHOULD_BUMP_VERSION" == true ]]; then
  PROJECT_FILE_BACKUP="$BUILD_DIR/project.pbxproj.prebuild.$$"
  cp "$PROJECT_FILE" "$PROJECT_FILE_BACKUP"
  bump_build_number
fi

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODEBUILD" \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination "$XCODE_DESTINATION" \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "missing built app: $BUILT_APP" >&2
  exit 1
fi

rm -rf "$STAGED_APP" "$TEMP_APP"
ditto "$BUILT_APP" "$STAGED_APP"
/usr/bin/find "$STAGED_APP" -name .DS_Store -delete
xattr -cr "$STAGED_APP" || true

ditto "$STAGED_APP" "$TEMP_APP"
rm -rf "$FINAL_APP"
mv "$TEMP_APP" "$FINAL_APP"

if [[ "$SHOULD_OPEN" == true ]]; then
  /usr/bin/open -n "$FINAL_APP"
fi

printf '%s\n' "$FINAL_APP"
