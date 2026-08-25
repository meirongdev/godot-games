extends Control

const NAME_KEY := "user://display_name.cfg"

@onready var name_edit: LineEdit = $Center/Box/NameEdit
@onready var enter_button: Button = $Center/Box/EnterButton
@onready var status: Label = $Center/Box/Status


func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	name_edit.text = _load_name()
	status.text = ""


func _on_enter_pressed() -> void:
	var display_name := name_edit.text.strip_edges()
	if display_name.is_empty():
		status.text = "先起个名字"
		return

	enter_button.disabled = true
	status.text = "连接中…"

	if await ServerConnection.login_async() != OK:
		_fail("登录失败:%s" % ServerConnection.error_message)
		return

	if await ServerConnection.set_display_name_async(display_name) != OK:
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
