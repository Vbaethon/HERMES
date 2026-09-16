#!/usr/bin/env bash
# Display version: major.feature.patch. Internal build numbers remain monotonic.
next_marketing_version() {
  local current="$1" scope="$2" major feature patch
  if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
    echo "Invalid version: $current" >&2
    return 1
  fi
  major=$((10#${BASH_REMATCH[1]}))
  feature=$((10#${BASH_REMATCH[2]}))
  patch="${BASH_REMATCH[4]:-0}"
  patch=$((10#$patch))
  case "$scope" in
    patch) patch=$((patch + 1)) ;;
    minor) feature=$((feature + 1)); patch=0 ;;
    major) major=$((major + 1)); feature=0; patch=0 ;;
    *) echo "Invalid update size: $scope (use patch, minor, or major)" >&2; return 1 ;;
  esac
  printf '%d.%d.%02d\n' "$major" "$feature" "$patch"
}
