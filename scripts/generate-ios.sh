#!/bin/bash
# iOS 用 Xcode プロジェクト（Koe.xcodeproj）を XcodeGen で生成する。
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen が見つかりません: brew install xcodegen" >&2
  exit 1
fi

if [ ! -f ios/Config.xcconfig ]; then
  cp ios/Config.sample.xcconfig ios/Config.xcconfig
  echo "ios/Config.xcconfig を作成しました。DEVELOPMENT_TEAM 等を記入してください。"
fi

xcodegen generate
echo "生成完了: open Koe.xcodeproj"
