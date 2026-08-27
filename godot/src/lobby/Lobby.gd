extends Control

const REFRESH_INTERVAL := 3.0   # Nakama 没有房间列表推送,只能轮询

@onready var online_list: ItemList = $Margin/Row/Col/Online/OnlineList
@onready var chat_log: RichTextLabel = $Margin/Row/Col/Chat/ChatLog
@onready var chat_edit: LineEdit = $Margin/Row/Col/Chat/ChatEdit
@onready var room_list: ItemList = $Margin/Row/Col/Rooms/RoomList
@onready var game_option: OptionButton = $Margin/Row/Col/CreateBox/GameOption
@onready var room_name_edit: LineEdit = $Margin/Row/Col/CreateBox/RoomNameEdit
@onready var create_button: Button = $Margin/Row/Col/CreateBox/CreateButton
@onready var status: Label = $Margin/Row/Col/Status

@onready var _panels := {
	"rooms":  $Margin/Row/Col/Rooms,
	"online": $Margin/Row/Col/Online,
	"chat":   $Margin/Row/Col/Chat,
}

var _rooms: Array = []
var _timer := 0.0
var _busy := false


func _ready() -> void:
	ServerConnection.lobby_presence_changed.connect(_on_presence_changed)
	ServerConnection.lobby_message.connect(_on_message)
	create_button.pressed.connect(_on_create_pressed)
	chat_edit.text_submitted.connect(_on_chat_submitted)
	room_list.item_activated.connect(_on_room_activated)

	# 竖屏一屏放不下「房间/在线/聊天」三块,用分段切换。
	# 用三个 toggle Button 而不是 TabContainer:页签是手机上的主导航,
	# 必须够大(≥44),而 TabContainer 的页签高度由主题 StyleBox 的内边距
	# 决定,想做到 44 得自己写一套 StyleBox。Button 一个 custom_minimum_size
	# 就够了。互斥由 .tscn 里的 ButtonGroup 保证。
	$Margin/Row/Col/Segments/RoomsTab.pressed.connect(_show_segment.bind("rooms"))
	$Margin/Row/Col/Segments/OnlineTab.pressed.connect(_show_segment.bind("online"))
	$Margin/Row/Col/Segments/ChatTab.pressed.connect(_show_segment.bind("chat"))

	status.text = ""

	await ServerConnection.join_lobby_async()
	await _load_games()
	_refresh_rooms()


func _show_segment(which: String) -> void:
	for key in _panels:
		_panels[key].visible = key == which


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_INTERVAL:
		_timer = 0.0
		_refresh_rooms()


func _on_presence_changed(users: Array) -> void:
	# 打一行给排查用:「在线」是空的还是没刷新,光看截图分不出来。
	# tools/web_smoke.py 也靠这一行断言自己进了在线列表。
	print("[lobby] 在线 %d 人" % users.size())
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
	# ⚠️ 房间列表是 HTTP 轮询,socket 死了它照样刷新 —— 页面看着一切正常,
	# 其实聊天、在线列表、进房、建房全废。所以断线要在这里主动修,
	# 不能等用户点了建房才发现。_busy 顺便保证了 3 秒最多试一次,不会打炮。
	if not ServerConnection.is_socket_connected():
		status.text = "和服务器断开了,正在重连…"
		status.text = "" if await ServerConnection.ensure_socket_async() == OK \
			else ServerConnection.error_message
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
	else:
		status.text = "进房失败:%s" % ServerConnection.error_message


func _on_create_pressed() -> void:
	if game_option.selected < 0:
		return
	create_button.disabled = true
	status.text = ""
	var game_id: String = game_option.get_item_metadata(game_option.selected)
	var id := await ServerConnection.create_room_async(
		game_id, room_name_edit.text.strip_edges())
	create_button.disabled = false
	if not id.is_empty():
		get_tree().change_scene_to_file("res://src/room/Room.tscn")
	else:
		# 以前这里是完全静默的 —— 点「建房」没反应,用户不知道发生了什么。
		# 服务端的拒绝(限流、未知游戏)必须有出口。
		status.text = ServerConnection.error_message
