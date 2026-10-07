#!/bin/zsh
set -euo pipefail

demo_source="${0:A:h}"
demo_repo="${demo_source:h:h}"
demo_output="$demo_repo/.build/location-card-demo"
demo_app="$demo_output/HERMESLocationDemo.app"

if /bin/ps -axo comm= | /usr/bin/awk -v executable="$demo_app/Contents/MacOS/HERMESLocationDemo" '$0 == executable { found = 1 } END { exit !found }'; then
  print -u2 -- "请先退出位置 Demo，再重新构建。"
  exit 1
fi

mkdir -p "$demo_app/Contents/MacOS"
xcrun swiftc -O -swift-version 6 -parse-as-library \
  "$demo_repo/Sources/Views/Other/MediaLocationCard.swift" "$demo_source/LocationCardDemo.swift" \
  -framework AppKit -framework MapKit -framework CoreLocation \
  -o "$demo_app/Contents/MacOS/HERMESLocationDemo"

cat > "$demo_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hermes.demo.location-card</string>
<key>CFBundleName</key><string>HERMES 位置 Demo</string>
<key>CFBundleDisplayName</key><string>HERMES 位置 Demo</string>
<key>CFBundleExecutable</key><string>HERMESLocationDemo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$demo_app"
if [[ "${1:-}" == "--test" ]]; then
  "$demo_app/Contents/MacOS/HERMESLocationDemo" --self-test
else
  print -r -- "$demo_app"
fi
