extends Control

const REFRESH_INTERVAL := 3.0   # Nakama 没有房间列表推送,只能轮询

@onready var online_list: ItemList = $HBox/Left/OnlineList
@onready var chat_log: RichTextLabel = $HBox/Left/ChatLog
@onready var chat_edit: LineEdit = $HBox/Left/ChatEdit
@onready var room_list: ItemList = $HBox/Right/RoomList
@onready var refresh_button: Button = $HBox/Right/RefreshButton
@onready var game_option: OptionButton = $HBox/Right/CreateBox/GameOption
@onready var room_name_edit: LineEdit = $HBox/Right/CreateBox/RoomNameEdit
@onready var create_button: Button = $HBox/Right/CreateBox/CreateButton

var _rooms: Array = []
var _timer := 0.0
var _busy := false



func _ready() -> void:
	ServerConnection.lobby_presence_changed.connect(_on_presence_changed)
	ServerConnection.lobby_message.connect(_on_message)
	refresh_button.pressed.connect(_refresh_rooms)
	create_button.pressed.connect(_on_create_pressed)
	chat_edit.text_submitted.connect(_on_chat_submitted)
	room_list.item_activated.connect(_on_room_activated)

	await ServerConnection.join_lobby_async()
	await _load_games()
	_refresh_rooms()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_INTERVAL:
		_timer = 0.0
		_refresh_rooms()


func _on_presence_changed(users: Array) -> void:
	online_list.clear()
	var me := ServerConnection.get_user_id()
	users.sort_custom(func(a, b): return a["id"] == me)   # 自己排最前
	for u in users:
		var label: String = u["name"]
		if u["id"] == me:
			label += "(我)"
		online_list.add_item(label)


func _on_message(_sender_id: String, name: String, text: String) -> void:
	chat_log.append_text("[b]%s[/b]: %s\n" % [name, text])


func _on_chat_submitted(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	chat_edit.clear()
	await ServerConnection.send_lobby_message_async(t)


func _load_games() -> void:
	game_option.clear()
	for g in await ServerConnection.list_games_async():
		var id: String = g["id"]
		game_option.add_item(OpCodes.GAME_LABELS.get(id, id))
		game_option.set_item_metadata(game_option.item_count - 1, id)


func _refresh_rooms() -> void:
	if _busy:
		return
	_busy = true
	_rooms = await ServerConnection.list_rooms_async()
	_busy = false

	room_list.clear()
	if _rooms.is_empty():
		room_list.add_item("还没有房间 —— 建一个吧")
		room_list.set_item_disabled(0, true)
		room_list.set_item_selectable(0, false)
		return
	for r in _rooms:
		var label := "%s · %s  (%d/%d)  房主 %s" % [
			OpCodes.GAME_LABELS.get(r["game"], r["game"]), r["name"],
			r["count"], r["max"], r["host_name"]]
		if r["phase"] != "waiting":
			label += "  [进行中]"
		room_list.add_item(label)
		# 进行中的房间不能加入,置灰
		room_list.set_item_disabled(room_list.item_count - 1, r["phase"] != "waiting")


func _on_room_activated(index: int) -> void:
	if index < 0 or index >= _rooms.size():
		return
	if await ServerConnection.join_room_async(_rooms[index]["match_id"]) == OK:
		get_tree().change_scene_to_file("res://src/room/Room.tscn")


func _on_create_pressed() -> void:
	if game_option.selected < 0:
		return
	create_button.disabled = true
	var game_id: String = game_option.get_item_metadata(game_option.selected)
	var id := await ServerConnection.create_room_async(
		game_id, room_name_edit.text.strip_edges())
	create_button.disabled = false
	if not id.is_empty():
		get_tree().change_scene_to_file("res://src/room/Room.tscn")
