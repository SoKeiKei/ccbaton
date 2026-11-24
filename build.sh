#!/bin/zsh
# 编译并打包成 CCBaton.app（放在本目录的 build/ 下）。版本号在 VERSION 文件里改。
#   ./build.sh               只编译本机架构，开发时用，快
#   UNIVERSAL=1 ./build.sh   编译通用版（Apple 芯片 + Intel），发布用
# 一律按 macOS 14 为部署目标编译，这样用了新系统才有的接口会在编译时报错，而不是在别人电脑上崩。
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(date +%Y%m%d%H%M)
APP="build/CCBaton.app"
rm -rf "$APP" build/Baton.app build/ClaudeAccountBar.app build/.slice-arm64 build/.slice-x86_64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -file-prefix-map：编译进二进制的源码路径换成相对路径，不带本机的目录名
FLAGS=(-O -swift-version 5 -parse-as-library -file-prefix-map "$PWD=.")
if [[ "$UNIVERSAL" == "1" ]]; then
  swiftc $FLAGS -target arm64-apple-macos14.0 Sources/*.swift -o build/.slice-arm64
  swiftc $FLAGS -target x86_64-apple-macos14.0 Sources/*.swift -o build/.slice-x86_64
  lipo -create build/.slice-arm64 build/.slice-x86_64 -output "$APP/Contents/MacOS/CCBaton"
  rm -f build/.slice-arm64 build/.slice-x86_64
else
  swiftc $FLAGS -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/CCBaton"
fi
strip -x "$APP/Contents/MacOS/CCBaton"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CCBaton</string>
  <key>CFBundleDisplayName</key><string>CCBaton</string>
  <key>CFBundleIdentifier</key><string>local.ccbaton</string>
  <key>CFBundleExecutable</key><string>CCBaton</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP（版本 ${VERSION}，构建 ${BUILD}，$(lipo -archs "$APP/Contents/MacOS/CCBaton")）"
