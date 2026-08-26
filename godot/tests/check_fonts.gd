extends SceneTree
## 字体覆盖检查。
##
## 为什么需要它:Godot 内置字体是 Open Sans,**不含任何汉字**。桌面和编辑器里
## 中文能正常显示,是因为绘制时回退到操作系统字体(`.import` 里的
## `allow_system_fallback`)。**Web 导出拿不到系统字体** —— 靠它就是满屏豆腐块。
##
## 这个坑之所以能活到发版前:`tools/take_screenshots.py` 跑的是桌面 Godot,
## 文档截图全都有系统字体回退,看起来一切正常;真玩也是桌面多开。
## 2026-08-27 实测:`ThemeDB.fallback_font` = Open Sans SemiBold,
## `has_char("客")` = false。
##
## 所以这个检查**刻意只看仓库里的字体资产,不看系统字体** —— 覆盖必须自带。
##
## 用法:
##   godot --headless --path godot --script res://tests/check_fonts.gd
##
## 加了新的符号 / emoji 到 UI 文案里,把它补进 MUST。

const THEME := "res://src/ui/family.tres"

## 必须能渲染的字符:UI 里出现过的全部非汉字符号 + 汉字抽样。
## 汉字只抽样 —— 全量覆盖由 tools/subset_fonts.sh 的字表保证。
const MUST := "客厅爸爸妈妈的房间石头剪刀布建准备开局胜平淘汰观战聊天名太长啦连不上服务器频繁再试进失败等秒后重来某人娃—…✊✋✌✓、「」🏆👑"


func _init() -> void:
	var th := load(THEME) as Theme
	if th == null:
		print("LOAD FAIL: ", THEME)
		quit(1)
		return

	var root := th.default_font
	if root == null:
		print("MISSING: %s 没有设 default_font —— Web 版会满屏豆腐块" % THEME)
		quit(1)
		return

	var fonts := _leaves(root)
	print("字体链(仓库自带,不含系统字体):")
	for leaf in fonts:
		print("  - %s" % leaf.get_font_name())

	var failed := 0
	for ch in MUST:
		var cp := ch.unicode_at(0)
		var covered := false
		for leaf in fonts:
			if leaf.has_char(cp):
				covered = true
				break
		if not covered:
			print("MISSING GLYPH: U+%04X %s" % [cp, ch])
			failed += 1

	print("checked %d chars across %d fonts, FAILURES: %d"
		% [MUST.length(), fonts.size(), failed])
	quit(1 if failed > 0 else 0)


## 把字体链摊平成真正带字形的叶子:FontVariation 只是包装,取它的 base_font,
## 每一级的 fallbacks 也都要算进来。
func _leaves(f: Font) -> Array[Font]:
	var out: Array[Font] = []
	var stack: Array[Font] = [f]
	while not stack.is_empty():
		var cur: Font = stack.pop_back()
		if cur == null:
			continue
		if cur is FontVariation and cur.base_font != null:
			stack.push_back(cur.base_font)
		else:
			out.append(cur)
		for fb in cur.fallbacks:
			stack.push_back(fb)
	return out
