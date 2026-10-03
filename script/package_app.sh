#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="Release"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/project_config.sh"
source "$ROOT_DIR/script/versioning.sh"
BUILD_DIR="$ROOT_DIR/Build"
PROJECT_FILE="$ROOT_DIR/$PROJECT_NAME/project.pbxproj"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/Applications}"
FINAL_APP="$INSTALL_DIR/$APP_NAME.app"
TEMP_APP="$INSTALL_DIR/.$APP_NAME.installing.$$.app"
PREVIOUS_APP="$INSTALL_DIR/.$APP_NAME.previous.$$.app"
MAC_ARCH="$(uname -m)"
XCODE_DESTINATION="platform=macOS,arch=$MAC_ARCH"
SHOULD_BUMP_VERSION=true
VERSION_SCOPE="patch"
EXPLICIT_VERSION=""
SHOULD_OPEN=true
PROJECT_FILE_BACKUP=""
INSTALLATION_STARTED=false
HAD_PREVIOUS_APP=false
INSTALLATION_COMMITTED=false

XCODE_DEVELOPER_DIR="$(resolve_developer_dir)"
XCODEBUILD="$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild"

usage() {
  echo "usage: $0 [--bump patch|minor|major | --version X.Y.Z | --no-version-bump] [--no-open]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-version-bump)
      SHOULD_BUMP_VERSION=false
      ;;
    --bump)
      VERSION_SCOPE="${2:?missing update size}"
      shift
      ;;
    --version)
      EXPLICIT_VERSION="${2:?missing version}"
      shift
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
  local current_build next_build current_version next_version
  if [[ ! -f "$PROJECT_FILE" ]]; then
    echo "missing Xcode project file: $PROJECT_FILE" >&2
    exit 1
  fi
  current_version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT_FILE" | head -n 1)"
  if [[ -n "$EXPLICIT_VERSION" ]]; then
    next_version="$(normalize_marketing_version "$EXPLICIT_VERSION")"
  else
    next_version="$(next_marketing_version "$current_version" "$VERSION_SCOPE")"
  fi
  perl -0pi -e "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $next_version;/g" "$PROJECT_FILE"
  current_build="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);/\1/p' "$PROJECT_FILE" | head -n 1)"
  if [[ ! "$current_build" =~ ^[0-9]+$ ]]; then
    current_build="0"
  fi
  next_build=$((10#$current_build + 1))
  perl -0pi -e "s/CURRENT_PROJECT_VERSION = \\d+;/CURRENT_PROJECT_VERSION = $next_build;/g" "$PROJECT_FILE"
}

remove_legacy_staged_app() {
  local app="$BUILD_DIR/$APP_NAME.app" bundle_id custom_marker
  [[ -d "$app" && ! -L "$app" ]] || return 0
  [[ ! -e "$BUILD_DIR/.hermes-custom-products" ]] || return 0
  custom_marker="$(/usr/bin/find "$app" -name .hermes-custom-products -print -quit 2>/dev/null)" || return 0
  [[ -z "$custom_marker" ]] || return 0
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" || return 0
  if [[ "$bundle_id" == "$BUNDLE_ID" ]] && ! path_contains_running_app "$app"; then
    rm -rf "$app"
  fi
}

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$INSTALLATION_COMMITTED" != true ]]; then
    # Bash 3.2 can enter EXIT with status 0 after an unset-variable expansion error.
    if [[ "$exit_code" -eq 0 ]]; then exit_code=1; fi
    if [[ -e "$PREVIOUS_APP" || -L "$PREVIOUS_APP" ]]; then
      if ! rm -rf "$FINAL_APP" || ! mv "$PREVIOUS_APP" "$FINAL_APP"; then
        echo "Failed to restore HERMES; previous app retained at: $PREVIOUS_APP" >&2
        exit_code=1
      fi
    elif [[ "$INSTALLATION_STARTED" == true && "$HAD_PREVIOUS_APP" == false ]]; then
      rm -rf "$FINAL_APP"
    fi
    if [[ -n "$PROJECT_FILE_BACKUP" && -f "$PROJECT_FILE_BACKUP" ]]; then
      if cp "$PROJECT_FILE_BACKUP" "$PROJECT_FILE"; then
        rm -f "$PROJECT_FILE_BACKUP"
      else
        echo "Failed to restore project version; backup retained at: $PROJECT_FILE_BACKUP" >&2
        exit_code=1
      fi
    fi
  else
    rm -rf "$PREVIOUS_APP"
    rm -f "$PROJECT_FILE_BACKUP"
    if ! prune_obsolete_managed_products "$PRODUCTS_DIR" || ! remove_legacy_staged_app; then
      echo "HERMES was installed, but obsolete build products could not be fully removed." >&2
      exit_code=1
    fi
  fi
  rm -rf "$TEMP_APP"
  if ! remove_current_managed_products; then
    echo "Failed to remove temporary HERMES build products." >&2
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
prepare_build_paths
BUILT_APP="$PRODUCTS_DIR/$APP_NAME.app"

mkdir -p "$BUILD_DIR" "$DERIVED_DATA_DIR" "$PRODUCTS_DIR" "$INSTALL_DIR"

if [[ "$SHOULD_BUMP_VERSION" == true ]]; then
  PROJECT_FILE_BACKUP="$BUILD_DIR/project.pbxproj.prebuild.$$"
  cp "$PROJECT_FILE" "$PROJECT_FILE_BACKUP"
  bump_build_number
fi

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODEBUILD" \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} \
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

if app_is_running; then
  echo "Build complete: $BUILT_APP" >&2
  echo "HERMES is running; installation skipped to protect current downloads. Quit the app and rerun packaging." >&2
  exit 1
fi

rm -rf "$TEMP_APP"
ditto "$BUILT_APP" "$TEMP_APP"
/usr/bin/find "$TEMP_APP" -name .DS_Store -delete
xattr -cr "$TEMP_APP" || true
# Staging can take time; recheck before touching the installed app.
if app_is_running; then
  echo "HERMES is running; installation skipped to protect current downloads." >&2
  exit 1
fi
INSTALLATION_STARTED=true
if [[ -e "$FINAL_APP" || -L "$FINAL_APP" ]]; then
  HAD_PREVIOUS_APP=true
  mv "$FINAL_APP" "$PREVIOUS_APP"
fi
mv "$TEMP_APP" "$FINAL_APP"
INSTALLATION_COMMITTED=true

if [[ "$SHOULD_OPEN" == true ]]; then
  /usr/bin/open "$FINAL_APP"
fi

printf '%s\n' "$FINAL_APP"
