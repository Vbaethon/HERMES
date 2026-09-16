#!/usr/bin/env bash
# Apple CFBundleShortVersionString: three period-separated integers.
# Internal CFBundleVersion build numbers increase independently.
normalize_marketing_version() {
  local version="$1"
  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Version must use X.Y.Z format: $version" >&2
    return 1
  fi
  printf '%d.%d.%d\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
}

next_marketing_version() {
  local current="$1" scope="$2" major minor patch
  # Accept the old two-component project version only during migration.
  if [[ "$current" =~ ^[0-9]+\.[0-9]+$ ]]; then current="$current.0"; fi
  current="$(normalize_marketing_version "$current")" || return 1
  IFS=. read -r major minor patch <<< "$current"
  case "$scope" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
    *) echo "Invalid update size: $scope (use patch, minor, or major)" >&2; return 1 ;;
  esac
  printf '%d.%d.%d\n' "$major" "$minor" "$patch"
}
