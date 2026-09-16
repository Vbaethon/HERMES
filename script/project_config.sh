#!/usr/bin/env bash

APP_NAME="HERMES"
BUNDLE_ID="com.codex.Hermes"
PROJECT_NAME="HERMES.xcodeproj"
SCHEME="HERMES"
MINIMUM_MACOS_VERSION="27.0"

resolve_developer_dir() {
  local candidate
  if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "$DEVELOPER_DIR"
    return
  fi

  for candidate in \
    "/Applications/Xcode.app/Contents/Developer" \
    "/Applications/Xcode-beta.app/Contents/Developer"; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "Xcode not found. Install Xcode 27 or set DEVELOPER_DIR." >&2
  exit 1
}

# Build into a new product directory, so an existing debug app is never overwritten.
prepare_build_paths() {
  DERIVED_DATA_DIR="${HERMES_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData/HERMES-Codex}"
  mkdir -p "$DERIVED_DATA_DIR/Build/Products"
  PRODUCTS_DIR="${HERMES_PRODUCTS_DIR:-$(mktemp -d "$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION.XXXXXX")}"
  APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
}

app_is_running() {
  pgrep -x "$APP_NAME" >/dev/null 2>&1
}
