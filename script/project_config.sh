#!/usr/bin/env bash

APP_NAME="HERMES"
BUNDLE_ID="com.codex.Hermes"
PROJECT_NAME="HERMES.xcodeproj"
SCHEME="Hermes"
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
