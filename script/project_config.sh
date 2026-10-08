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
# Managed directories are temporary; callers remove failed builds and obsolete products.
prepare_build_paths() {
  DERIVED_DATA_DIR="${HERMES_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData/HERMES-Codex}"
  mkdir -p "$DERIVED_DATA_DIR/Build/Products"
  PRODUCTS_DIR_IS_MANAGED=false
  if [[ -n "${HERMES_PRODUCTS_DIR:-}" ]]; then
    PRODUCTS_DIR="$HERMES_PRODUCTS_DIR"
    if [[ "$PRODUCTS_DIR" == "${HERMES_MANAGED_PRODUCTS_DIR:-}" ]] && is_managed_products_directory "$PRODUCTS_DIR"; then
      PRODUCTS_DIR_IS_MANAGED=true
    else
      mkdir -p "$PRODUCTS_DIR"
      printf '%s\n' 'HERMES custom build products' > "$PRODUCTS_DIR/.hermes-custom-products"
    fi
  else
    PRODUCTS_DIR="$(mktemp -d "$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION.XXXXXX")"
    PRODUCTS_DIR_IS_MANAGED=true
    printf '%s\n%s\n' "$$" "$(LC_ALL=C ps -p "$$" -o lstart=)" > "$PRODUCTS_DIR/.hermes-active-build"
    printf '%s\n' 'HERMES managed build products' > "$PRODUCTS_DIR/.hermes-managed-products"
  fi
  APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
}

path_contains_running_app() {
  local candidate pids pid executable executable_dir
  candidate="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  if ! pids="$(pgrep -x "$APP_NAME" 2>/dev/null)"; then
    return 1
  fi
  # An unresolved live process is protected until its executable path can be read.
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    executable="$(ps -p "$pid" -o comm= 2>/dev/null)" || return 0
    [[ "$executable" == /* ]] || return 0
    executable_dir="$(cd "$(dirname "$executable")" 2>/dev/null && pwd -P)" || return 0
    case "$executable_dir/" in
      "$candidate/"*) return 0 ;;
    esac
  done <<< "$pids"
  return 1
}

is_managed_products_directory() {
  local candidate="$1" name bundle_id custom_marker
  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  [[ "$(dirname "$candidate")" == "$DERIVED_DATA_DIR/Build/Products" ]] || return 1
  name="$(basename "$candidate")"
  [[ "$name" =~ ^(Debug|Release)\.[[:alnum:]]{6}$ ]] || return 1
  custom_marker="$(/usr/bin/find "$candidate" -name .hermes-custom-products -print -quit 2>/dev/null)" || return 1
  [[ -z "$custom_marker" ]] || return 1
  if [[ -f "$candidate/.hermes-managed-products" ]]; then
    [[ "$(cat "$candidate/.hermes-managed-products")" == 'HERMES managed build products' ]]
    return
  fi
  # Recognize older default directories created before the ownership marker existed.
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/$APP_NAME.app/Contents/Info.plist" 2>/dev/null)" || return 1
  [[ "$bundle_id" == "$BUNDLE_ID" ]]
}

remove_current_managed_products() {
  [[ "${PRODUCTS_DIR_IS_MANAGED:-false}" == true ]] || return 0
  if is_managed_products_directory "$PRODUCTS_DIR" && ! path_contains_running_app "$PRODUCTS_DIR"; then
    rm -rf "$PRODUCTS_DIR"
  fi
}

managed_products_are_active() {
  local marker="$1/.hermes-active-build" owner expected_start actual_start
  [[ -f "$marker" ]] || return 1
  owner="$(sed -n '1p' "$marker")"
  [[ "$owner" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$owner" 2>/dev/null || return 1
  expected_start="$(sed -n '2p' "$marker")"
  [[ -n "$expected_start" ]] || return 0
  actual_start="$(LC_ALL=C ps -p "$owner" -o lstart= 2>/dev/null)" || return 0
  [[ "$actual_start" == "$expected_start" ]]
}

derived_data_has_protected_products() {
  local directory="$1" real_directory custom_directory marker candidate
  [[ -d "$directory" ]] || return 1
  real_directory="$(cd "$directory" && pwd -P)" || return 0
  if [[ -n "${HERMES_PRODUCTS_DIR:-}" ]]; then
    custom_directory="$(cd "$HERMES_PRODUCTS_DIR" 2>/dev/null && pwd -P)" || custom_directory="$HERMES_PRODUCTS_DIR"
    case "$custom_directory/" in "$real_directory/"*) return 0 ;; esac
  fi
  marker="$(/usr/bin/find "$directory" -name .hermes-custom-products -print -quit 2>/dev/null)" || return 0
  [[ -z "$marker" ]] || return 0
  for candidate in "$directory/Build/Products"/Debug.?????? \
                   "$directory/Build/Products"/Release.??????; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    if managed_products_are_active "$candidate"; then
      return 0
    fi
  done
  return 1
}

prune_obsolete_managed_products() {
  local keep="${1:-}" candidate result=0
  for candidate in "$DERIVED_DATA_DIR/Build/Products"/Debug.?????? \
                   "$DERIVED_DATA_DIR/Build/Products"/Release.??????; do
    [[ "$candidate" != "$keep" && "$candidate" != "${HERMES_PRODUCTS_DIR:-}" ]] || continue
    if is_managed_products_directory "$candidate" && ! managed_products_are_active "$candidate" \
      && ! path_contains_running_app "$candidate"; then
      rm -rf "$candidate" || result=1
    fi
  done
  return "$result"
}

# Only this checkout's default Debug products; retain its compilation cache.
prune_default_development_products() (
  local directory
  for directory in "$ROOT_DIR/.build" "$ROOT_DIR/.build/development" \
                   "$ROOT_DIR/.build/development/DerivedData" \
                   "$ROOT_DIR/.build/development/DerivedData/Build" \
                   "$ROOT_DIR/.build/development/DerivedData/Build/Products"; do
    [[ ! -L "$directory" ]] || return 0
  done
  DERIVED_DATA_DIR="$ROOT_DIR/.build/development/DerivedData"
  prune_obsolete_managed_products
)

app_is_running() {
  pgrep -x "$APP_NAME" >/dev/null 2>&1
}

# Optional machine-specific signing configuration; never commit this file.
# Callers use a guarded array expansion: Bash 3.2 treats an empty array as unset under set -u.
SIGNING_ARGS=()
if [[ -f "$ROOT_DIR/Signing.local.xcconfig" ]]; then
  SIGNING_ARGS=(-xcconfig "$ROOT_DIR/Signing.local.xcconfig")
fi
