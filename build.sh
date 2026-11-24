#!/bin/zsh
# 编译并打包成 CCBaton.app（放在本目录的 build/ 下）。版本号在 VERSION 文件里改。
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(date +%Y%m%d%H%M)
APP="build/CCBaton.app"
rm -rf "$APP" build/Baton.app build/ClaudeAccountBar.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/CCBaton"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CCBaton</string>
  <key>CFBundleDisplayName</key><string>CCBaton</string>
  <key>CFBundleIdentifier</key><string>local.ccbaton</string>
  <key>CFBundleExecutable</key><string>CCBaton</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP（版本 ${VERSION}，构建 ${BUILD}）"
