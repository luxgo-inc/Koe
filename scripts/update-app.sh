#!/bin/bash
# Koe をリポジトリ最新に更新して再インストールする。Terminal.app から実行される想定。
set -euo pipefail
cd "$(dirname "$0")/.."
echo "=== Koe を更新します ==="
git pull --ff-only origin main
bash scripts/build-app.sh --install
echo "=== 更新完了 ==="
