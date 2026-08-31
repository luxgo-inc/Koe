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

# Apple Development 証明書を署名前に OCSP で実検証し、有効なものだけ使う。
# 注意: codesign --verify は失効チェックがソフトフェイルのため信用できない。
# 失効/期限切れ証明書で署名すると amfid が実行時に signature invalid と判定し
# syspolicyd がアプリを「マルウェア」としてゴミ箱に移動する（実際に発生した）。
verify_identity() {  # $1 = SHA-1 hash → 0 なら有効
    local pem rc
    pem=$(mktemp)
    security find-certificate -a -Z -p 2>/dev/null | awk -v h="$1" '
        /^SHA-1 hash:/ { cur=$3 }
        /BEGIN CERTIFICATE/ { buf=""; cap=(cur==h) }
        cap { buf=buf $0 "\n" }
        /END CERTIFICATE/ && cap { printf "%s", buf; exit }
    ' > "$pem"
    if [ -s "$pem" ]; then
        security verify-cert -c "$pem" -p codeSign -R ocsp >/dev/null 2>&1
        rc=$?
    else
        rc=1
    fi
    rm -f "$pem"
    return $rc
}

SIGNED=""
while read -r HASH NAME; do
    [ -z "$HASH" ] && continue
    if ! verify_identity "$HASH"; then
        echo "skip (expired/revoked): $NAME ($HASH)"
        continue
    fi
    echo "signing with: $NAME ($HASH)"
    codesign --force --options runtime \
        --entitlements Resources/Koe.entitlements --sign "$HASH" "$APP"
    SIGNED=1
    break
done < <(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Development" \
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
