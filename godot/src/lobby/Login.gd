extends Control

const NAME_KEY := "user://display_name.cfg"

@onready var name_edit: LineEdit = $Center/Box/NameEdit
@onready var enter_button: Button = $Center/Box/EnterButton
@onready var status: Label = $Center/Box/Status


func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	# 手机上软键盘的「完成/换行」键要能直接进去,不用去够按钮。
	# 顺带让 tools/web_smoke.py 不再需要按钮的像素坐标。
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
