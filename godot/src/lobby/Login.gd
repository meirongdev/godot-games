extends Control

const NAME_KEY := "user://display_name.cfg"

@onready var name_edit: LineEdit = $Center/Box/NameEdit
@onready var enter_button: Button = $Center/Box/EnterButton
@onready var status: Label = $Center/Box/Status


func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	# 回车/软键盘「完成」键也能提交。这条路在 Web 上历史上不可靠:开了
	# html/experimental_virtual_keyboard 之后,LineEdit 把输入交给隐藏的
	# DOM <input>,那时 Enter 不触发 text_submitted(上游 issue
	# godotengine/godot#76215,报告于 3.5.1 和 4.0.2)。该 issue 由 PR
	# #113461 修复、合入 4.6 里程碑,早于本项目用的 4.7.2,所以大概率
	# 已经好了 —— 但**我们没在真机上复测过**。
	# 所以「进入大厅」按钮才是主路径,这里只是顺手多一条;
	# tools/web_smoke.py 靠它免掉像素坐标(那边不开触屏模拟,所以走得通)。
	name_edit.text_submitted.connect(func(_text: String): _on_enter_pressed())
	name_edit.text = _load_name()
	# 打开就能打字。手机上这会顺带唤起软键盘 —— 第一屏就是让你输名字,合理。
	name_edit.grab_focus()
	status.text = ""

	# 给排查用:这台设备上 UI 实际多大。web_smoke.py 的手机档位靠这一行断言
	# 逻辑视口宽度 —— 基准分辨率不对的话,手机上一切都会被缩到 30%。
	# 见 docs/superpowers/specs/2026-08-27-mobile-portrait-design.md §3。
	var win := get_window().size
	var vp := get_viewport_rect().size
	print("[layout] 窗口 %dx%d → 逻辑视口 %dx%d(缩放 %.2f)" % [
		win.x, win.y, int(vp.x), int(vp.y), float(win.x) / vp.x])

	# 配置坏了就别等用户填完名字再告诉他 —— 一进门就说,而且把按钮关掉。
	if not ServerConnection.is_configured():
		status.text = "连不上服务器:%s" % ServerConnection.error_message
		enter_button.disabled = true


func _on_enter_pressed() -> void:
	# ⚠️ 两个入口都会走到这里:按钮和名字框的回车。按钮按下后会 disabled,
	# 但名字框不会 —— 连点两次回车就会并发跑两遍登录(两次设备认证抢着写
	# _session、两次 connect_to_server_async 撞在 `if _socket == null` 上
	# 各建一个 socket、change_scene_to_file 还可能触发两次)。
	# 复用按钮的 disabled 当锁:它同时也挡住了「配置坏了」那种情况 ——
	# 那时按钮一进门就是 disabled,回车本来能绕过去。
	if enter_button.disabled:
		return
	var display_name := name_edit.text.strip_edges()
	if display_name.is_empty():
		status.text = "先起个名字"
		return
	if display_name.length() > 12:
		status.text = "名字太长啦(最多 12 个字)"
		return

	enter_button.disabled = true
	status.text = "连接中…"

	if await ServerConnection.login_async() != OK:
		_fail("登录失败:%s" % ServerConnection.error_message)
		return

	if await ServerConnection.set_display_name_async(display_name) != OK:
		# Nakama 的 username 全服唯一。中文名没问题(实测),撞名才会到这里。
		if "already in use" in ServerConnection.error_message:
			_fail("「%s」被家里人用了,换一个吧" % display_name)
		else:
			_fail("改名失败:%s" % ServerConnection.error_message)
		return

	if await ServerConnection.connect_to_server_async() != OK:
		_fail("实时连接失败:%s" % ServerConnection.error_message)
		return

	_save_name(display_name)
	get_tree().change_scene_to_file("res://src/lobby/Lobby.tscn")


func _fail(msg: String) -> void:
	status.text = msg
	enter_button.disabled = false


func _save_name(n: String) -> void:
	var f := ConfigFile.new()
	f.set_value("user", "name", n)
	f.save(NAME_KEY)


func _load_name() -> String:
	var f := ConfigFile.new()
	if f.load(NAME_KEY) == OK:
		return f.get_value("user", "name", "")
	return ""
