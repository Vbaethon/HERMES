#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# Collection-view resource actions have their own native-media regression.
utility_sources=()
for source in Sources/Utilities/*.swift; do
  [[ "$source" == Sources/Utilities/NativeMediaResources.swift ]] || utility_sources+=("$source")
done
xcrun swiftc -parse-as-library -swift-version 6 Sources/dydl.swift Sources/rndl.swift Sources/dwdl.swift Sources/DewuLogStore.swift Sources/DownloaderHTTPCompatibility.swift Sources/UIModels.swift "${utility_sources[@]}" Tests/DownloadRegression/main.swift Tests/DownloadRegression/XHSCachedMotionRegression.swift Tests/DownloadRegression/XHSReplacementRegression.swift -o "$test_dir/regression" -lsqlite3
"$test_dir/regression" "$@"
