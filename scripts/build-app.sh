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

# Apple Development 証明書を順に試し、失効(CSSMERR_TP_CERT_REVOKED)していない
# ものを採用する。失効証明書で署名すると Gatekeeper に「マルウェア」扱いされる。
SIGNED=""
while read -r HASH NAME; do
    [ -z "$HASH" ] && continue
    echo "trying identity: $NAME ($HASH)"
    codesign --force --options runtime --sign "$HASH" "$APP"
    if codesign --verify --deep --strict -v "$APP" 2>&1 | grep -q "REVOKED"; then
        echo "  -> 失効証明書のためスキップ"
        continue
    fi
    echo "signed with: $NAME"
    SIGNED=1
    break
done < <(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Development" | grep -v "REVOKED" \
  | sed 's/^ *[0-9]*) \([0-9A-F]*\) "\(.*\)"/\1 \2/')

if [ -z "$SIGNED" ]; then
    echo "signing ad-hoc（有効なApple Development証明書なし。TCC許可が再ビルドで外れる可能性あり）"
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
