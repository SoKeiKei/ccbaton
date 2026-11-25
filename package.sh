#!/bin/zsh
# 打包发布用的文件，放在 dist/：
#   CCBaton-<版本>-macos.dmg        给人下载：打开后拖进"应用程序"
#   CCBaton-<版本>-macos.zip        给软件自动更新用
#   CCBaton-<版本>-macos.zip.sig    自动更新的签名（需要这台电脑钥匙串里的发布钥匙，系统会弹窗确认）
#   *.sha256                        校验码
# 都是通用版（Apple 芯片 + Intel）。只想试打包、不签名：SKIP_SIGN=1 ./package.sh
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
UNIVERSAL=1 ./build.sh
mkdir -p dist
NAME="CCBaton-${VERSION}-macos"
rm -f "dist/$NAME".{zip,zip.sig,zip.sha256,dmg,dmg.sha256}
# ditto 会保留 macOS 应用包里的符号链接和属性，比普通 zip 稳妥
ditto -c -k --sequesterRsrc --keepParent build/CCBaton.app "dist/$NAME.zip"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/CCBaton.app "$STAGE/CCBaton.app"
ln -s /Applications "$STAGE/应用程序"
hdiutil create -volname "CCBaton $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg" >/dev/null

( cd dist && for f in "$NAME.zip" "$NAME.dmg"; do shasum -a 256 "$f" > "$f.sha256"; done )
if [[ "$SKIP_SIGN" == "1" ]]; then
  echo "按要求没有签名：这样打出来的包不能用于自动更新，别发布。"
else
  swift tools/release-key.swift sign "dist/$NAME.zip"
fi
echo "发布时把这些文件都传到 GitHub Release（标签 v${VERSION}）："
ls -1 dist/$NAME.*
