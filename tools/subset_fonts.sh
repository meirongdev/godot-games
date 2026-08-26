#!/usr/bin/env bash
# 重新生成 godot/src/ui/ 下的两个子集字体。**需要联网**,不在构建链里 ——
# 字体是提交进仓库的成品,只有换字体或缺字时才需要跑这个。
#
# 为什么必须自带字体:Godot 内置的 Open Sans 一个汉字都没有。桌面/编辑器靠
# 系统字体回退看不出问题,但 Web 导出拿不到系统字体 —— 满屏豆腐块。
# 详见 godot/tests/check_fonts.gd 的注释。
#
# 产出:
#   NotoSansSC-Subset.ttf   汉字 = GB2312 全量(6763 字)+ 标点/全角/拉丁,~2.1MB
#   NotoEmoji-Subset.ttf    UI 用到的符号 ✊✋✌🏆👑 等,~5KB
# 两个都附 OFL-1.1 许可证文本。
#
# 汉字字表刻意用 GB2312 —— 它就是「一级 3755 + 二级 3008」的常用字集,
# Python 自带这个编码,离线可枚举、可复现,不依赖任何外部字表文件。
# 显示名和聊天是任意输入,所以不能只子集化"当前用到的字"。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=godot/src/ui
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "工作目录 $WORK"

# fonttools 装进临时 venv,不碰系统 Python。
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check fonttools
PY="$WORK/venv/bin/python"
SUBSET="$WORK/venv/bin/pyftsubset"

fetch() {  # fetch <url> <目标文件>
	curl -sSfL -o "$2" "$1"
}

# ---------------------------------------------------------------- 汉字字表
echo "生成码位表…"
"$PY" - "$WORK/cjk.txt" <<'PYCODE'
import sys, pathlib
cps = set()

# GB2312 可编码的汉字:一级 3755 + 二级 3008 = 6763
for cp in range(0x4E00, 0xA000):
    try:
        chr(cp).encode("gb2312")
        cps.add(cp)
    except UnicodeEncodeError:
        pass

# 仓库文案里真正出现的字,确保一个都不漏(含服务端下发的文案)
for root in ("godot/src", "nakama/modules"):
    for p in pathlib.Path(root).rglob("*"):
        if p.is_file() and p.suffix in (".gd", ".tscn", ".tres", ".lua"):
            for ch in p.read_text(encoding="utf-8"):
                if 0x2E80 <= ord(ch) <= 0x9FFF or 0xF900 <= ord(ch) <= 0xFAFF:
                    cps.add(ord(ch))

cps |= set(range(0x20, 0x100))      # ASCII + Latin-1
cps |= set(range(0x2000, 0x206F))   # 通用标点 — … ' "
cps |= set(range(0x3000, 0x3040))   # CJK 标点 。、「」
cps |= set(range(0xFF00, 0xFFF0))   # 全角
cps |= {0x2713, 0x2717}             # ✓ ✗
pathlib.Path(sys.argv[1]).write_text("\n".join(f"U+{c:04X}" for c in sorted(cps)))
print(f"  汉字子集码位 {len(cps)}")
PYCODE

# ---------------------------------------------------------------- Noto Sans SC
echo "Noto Sans SC:下载 → 钉 wght=400 → 子集化…"
fetch 'https://github.com/google/fonts/raw/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf' "$WORK/sc-var.ttf"
fetch 'https://github.com/google/fonts/raw/main/ofl/notosanssc/OFL.txt' "$OUT/NotoSansSC-Subset.LICENSE.txt"

# ⚠️ 这个可变字体的 fvar default 是 100(Thin),不是 400。不钉就会拿到极细的
# 字形;--update-name-table 是必须的,否则家族名会留在 "Noto Sans SC Thin"。
"$PY" -m fontTools.varLib.instancer "$WORK/sc-var.ttf" wght=400 \
	--update-name-table -o "$WORK/sc-400.ttf" >/dev/null
"$SUBSET" "$WORK/sc-400.ttf" --unicodes-file="$WORK/cjk.txt" \
	--output-file="$OUT/NotoSansSC-Subset.ttf" --drop-tables+=DSIG

# ---------------------------------------------------------------- Noto Emoji
echo "Noto Emoji(单色):下载 → 子集化…"
fetch 'https://github.com/google/fonts/raw/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf' "$WORK/em-var.ttf"
fetch 'https://github.com/google/fonts/raw/main/ofl/notoemoji/OFL.txt' "$OUT/NotoEmoji-Subset.LICENSE.txt"

# UI 里用到的:✊✋✌(猜拳手势) 🏆(胜者) 👑(房主)
# 顺手留几个常用备用,每个只几百字节:✅ ❌ ⭐ 🎉 ⚠
printf 'U+270A\nU+270B\nU+270C\nU+1F3C6\nU+1F451\nU+2705\nU+274C\nU+2B50\nU+1F389\nU+26A0\n' \
	> "$WORK/emoji.txt"
"$PY" -m fontTools.varLib.instancer "$WORK/em-var.ttf" wght=400 \
	--update-name-table -o "$WORK/em-400.ttf" >/dev/null
"$SUBSET" "$WORK/em-400.ttf" --unicodes-file="$WORK/emoji.txt" \
	--output-file="$OUT/NotoEmoji-Subset.ttf" --drop-tables+=DSIG

# ---------------------------------------------------------------- 汇报
echo
for f in "$OUT/NotoSansSC-Subset.ttf" "$OUT/NotoEmoji-Subset.ttf"; do
	raw=$(wc -c < "$f" | tr -d ' ')
	gz=$(gzip -9 -c "$f" | wc -c | tr -d ' ')
	printf "  %-40s %8s B   gzip %8s B\n" "$(basename "$f")" "$raw" "$gz"
done
echo
echo "接下来:"
echo "  godot --headless --path godot --import"
echo "  godot --headless --path godot --script res://tests/check_fonts.gd"
