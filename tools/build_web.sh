#!/usr/bin/env bash
# 导出 Web 版到 build/web/,并做制品自检。
#
# **CI 也跑这个脚本**(.github/workflows/web-image.yml)。刻意只留一条导出
# 路径 —— 以前 CI 里是另一串手写的 godot 命令,本地和线上的导出参数各走各的,
# 这类分叉正是 2026-08-26「本地能玩、集群里连不上」那个故障的土壤。
#
# 导出完用 tools/serve_web.py 起本地服务(它会把 Nakama 反代成同源,和线上一致)。
#
# Godot 不在默认位置时:GODOT=/path/to/godot tools/build_web.sh
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
if ! [ -x "$GODOT" ] && ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "找不到 Godot:$GODOT(用 GODOT=... 指定)" >&2
	exit 1
fi

mkdir -p build/web

# 首次运行要先导入资源,否则导出会缺资源。
echo "导入资源…"
"$GODOT" --headless --path godot --import || true

# 场景节点路径是 .gd 里的硬编码字符串,改了 .tscn 的节点名不会有编译错误,
# 只会在运行时炸。推制品之前必须过这关 —— 跟模块镜像先跑 busted 同理。
echo "场景路径检查…"
"$GODOT" --headless --path godot --script res://tests/check_scenes.gd

# 字体覆盖。Web 拿不到系统字体,主题里没有带汉字的字体就是满屏豆腐块,
# 而桌面版靠系统回退看不出来 —— 必须在推制品之前挡住。
echo "字体覆盖检查…"
"$GODOT" --headless --path godot --script res://tests/check_fonts.gd

echo "导出中…"
"$GODOT" --headless --path godot --export-release "Web" ../build/web/index.html

# ---- 制品自检(契约 §4.3)----
test -s build/web/index.wasm

# 测试脚手架不该发到线上。export_presets.cfg 的 exclude_filter 管这个,
# 而那一行曾经填的是没用的 "nakama.cfg",脚手架就这么进了镜像。
if grep -qa 'res://tests/' build/web/index.pck; then
	echo "✗ 制品里带着测试脚手架 —— 检查 export_presets.cfg 的 exclude_filter" >&2
	exit 1
fi

# nakama.cfg 进不了导出包(.cfg 是非资源文件),也**不该**进:Web 版的地址
# 一律从页面自身来源推导(契约 §3.3)。真进去了说明有人加了 include_filter,
# 那就等于把某个环境的地址烙进了镜像。
if grep -qa 'nakama.cfg' build/web/index.pck; then
	echo "✗ nakama.cfg 进了制品 —— Web 版不该携带任何环境地址" >&2
	exit 1
fi

# 汉字字体必须真的在包里。check_fonts.gd 验的是主题配置,这条验的是导出结果 ——
# 万一将来有人给 export_presets 加了把 ui/ 排掉的 filter,这里会拦住。
if ! grep -qa 'NotoSansSC' build/web/index.pck; then
	echo "✗ 制品里没有汉字字体 —— Web 版会满屏豆腐块" >&2
	exit 1
fi

echo
ls -lh build/web | tail -n +2 | awk '{printf "  %-34s %s\n", $9, $5}'
