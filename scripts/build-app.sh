#!/bin/bash
# Koe.app をビルドして dist/ に生成。--install で /Applications へ配置。
# 署名は Apple Development identity があればそれを使い、無ければ ad-hoc。
# TCC許可維持のため署名identityと bundle id は変えないこと。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product KoeApp

APP=dist/Koe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/KoeApp "$APP/Contents/MacOS/KoeApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
if [ -n "$IDENTITY" ]; then
    echo "signing with: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "signing ad-hoc（TCC許可が再ビルドで外れる可能性あり）"
    codesign --force --sign - "$APP"
fi

if [ "${1:-}" = "--install" ]; then
    osascript -e 'quit app "Koe"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Koe.app
    cp -R "$APP" /Applications/Koe.app
    echo "installed: /Applications/Koe.app — 起動します"
    open /Applications/Koe.app
else
    echo "built: $APP"
fi
