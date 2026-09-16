#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 Sources/dydl.swift Sources/rndl.swift Sources/dwdl.swift Sources/DewuLogStore.swift Sources/DownloaderHTTPCompatibility.swift Sources/Utilities/*.swift Tests/DownloadRegression/main.swift -o "$test_dir/regression" -lsqlite3
"$test_dir/regression" "$@"
