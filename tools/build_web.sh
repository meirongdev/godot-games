#!/usr/bin/env bash
# 导出 Web 版到 build/web/,然后用 tools/serve_web.py 起服务。
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
mkdir -p build/web
echo "导出中…"
"$GODOT" --headless --path godot --export-release "Web" ../build/web/index.html
echo
ls -lh build/web | tail -n +2 | awk '{printf "  %-34s %s\n", $9, $5}'
