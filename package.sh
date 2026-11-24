#!/bin/zsh
# 打包发布用的压缩包：通用版（Apple 芯片 + Intel）CCBaton.app → dist/CCBaton-<版本>-macos.zip，并生成 SHA-256 校验码。
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
UNIVERSAL=1 ./build.sh
mkdir -p dist
ZIP="dist/CCBaton-${VERSION}-macos.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto 会保留 macOS 应用包里的符号链接和属性，比普通 zip 稳妥
ditto -c -k --sequesterRsrc --keepParent build/CCBaton.app "$ZIP"
( cd dist && shasum -a 256 "CCBaton-${VERSION}-macos.zip" > "CCBaton-${VERSION}-macos.zip.sha256" )
echo "已生成 $ZIP ($(du -h "$ZIP" | cut -f1))"
cat "$ZIP.sha256"
