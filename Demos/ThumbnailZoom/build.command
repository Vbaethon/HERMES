#!/bin/zsh
set -euo pipefail

demo_source="${0:A:h}"
demo_repo="${demo_source:h:h}"
demo_output="$demo_repo/.build/thumbnail-zoom-demo"
demo_app="$demo_output/HERMESThumbnailZoomDemo.app"

if /bin/ps -axo comm= | /usr/bin/awk -v executable="$demo_app/Contents/MacOS/HERMESThumbnailZoomDemo" '$0 == executable { found = 1 } END { exit !found }'; then
  print -u2 -- "请先退出缩略图缩放 Demo，再重新构建。"
  exit 1
fi

mkdir -p "$demo_app/Contents/MacOS"
xcrun swiftc -O -swift-version 6 -parse-as-library \
  "$demo_source/ThumbnailZoomDemo.swift" "$demo_repo/Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift" \
  "$demo_repo/Sources/Views/CollectionViews/ThumbnailGridArrangementController.swift" \
  "$demo_source/ZoomOverlay.swift" "$demo_source/ZoomChecks.swift" \
  -framework AppKit -framework QuartzCore -framework ImageIO \
  -o "$demo_app/Contents/MacOS/HERMESThumbnailZoomDemo"

if [[ ! -d "$demo_app/Contents/Resources/Previews" ]]; then
  xcrun swift "$demo_source/PrepareDemoAssets.swift" \
    "$HOME/Downloads/HERMES/Downloader" "$demo_app/Contents/Resources/Previews"
fi

cat > "$demo_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hermes.demo.thumbnail-zoom</string>
<key>CFBundleName</key><string>HERMES 缩略图缩放 Demo</string>
<key>CFBundleDisplayName</key><string>HERMES 缩略图缩放 Demo</string>
<key>CFBundleExecutable</key><string>HERMESThumbnailZoomDemo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.10</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$demo_app"
if [[ "${1:-}" == "--test" ]]; then
  "$demo_app/Contents/MacOS/HERMESThumbnailZoomDemo" --self-test
else
  print -r -- "$demo_app"
fi
