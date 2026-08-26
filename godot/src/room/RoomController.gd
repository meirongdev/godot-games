extends Control
## 通用房间控制器。独占准备/开局/结算,把游戏段消息转发给挂载的 GameBase。
## ★ 加新游戏只需在 GAME_SCENES 加一行。

const GAME_SCENES := {
	"rps": "res://src/games/rps/RpsGame.tscn",
}

@onready var room_title: Label = $VBox/Header/RoomTitle
@onready var leave_button: Button = $VBox/Header/LeaveButton
@onready var player_list: ItemList = $VBox/Body/PlayerPanel/PlayerList
@onready var ready_button: CheckButton = $VBox/Body/PlayerPanel/ReadyButton
@onready var start_button: Button = $VBox/Body/PlayerPanel/StartButton
@onready var game_slot: Control = $VBox/Body/GameSlot
@onready var status: Label = $VBox/Status

var _game: GameBase = null
var _players: Array = []
var _host := ""
var _phase := "waiting"


func _ready() -> void:
	ServerConnection.room_event.connect(_on_room_event)
	leave_button.pressed.connect(_on_leave)
	ready_button.toggled.connect(_on_ready_toggled)
	start_button.pressed.connect(func(): ServerConnection.send(OpCodes.START))
	start_button.disabled = true
	status.text = "等待其他人…"


func _on_room_event(op_code: int, payload: Dictionary) -> void:
	match op_code:
		OpCodes.ROOM_STATE:
			_apply_room_state(payload)
		OpCodes.GAME_STARTED:
			_start_game(payload)
		OpCodes.GAME_OVER:
			_end_game(payload)
		OpCodes.ERROR:
			status.text = _error_text(payload.get("msg", ""))
		_:
			# 游戏段的消息,转给挂载的游戏
			if _game != null:
				_game.handle_server(op_code, payload)


func _apply_room_state(payload: Dictionary) -> void:
	_players = JsonSafe.arr(payload, "players")
	_host    = str(payload.get("host", ""))
	_phase   = str(payload.get("phase", "waiting"))

	# 标题:房名 · 游戏名(服务端 ROOM_STATE 带了 name/game)
	var game_id := str(payload.get("game", ""))
	var room_name := str(payload.get("name", "房间"))
	room_title.text = "%s · %s" % [room_name, OpCodes.GAME_LABELS.get(game_id, game_id)]

	var me := ServerConnection.get_user_id()
	player_list.clear()
	for p in _players:
		var line: String = p["name"]
		if p["id"] == me:
			line += "(我)"
		if p["id"] == _host:
			line += "  👑"
		line += "  ✓ 已准备" if p["ready"] else "  …"
		player_list.add_item(line)

	var is_host := ServerConnection.get_user_id() == _host
	start_button.visible = is_host
	start_button.disabled = not (is_host and _phase == "waiting")
	ready_button.disabled = _phase != "waiting"

	if _phase == "waiting":
		status.text = "%d 人在房间" % _players.size()


func _start_game(payload: Dictionary) -> void:
	var game_id: String = payload.get("game", "")
	var path: String = GAME_SCENES.get(game_id, "")
	if path.is_empty():
		status.text = "不认识的游戏:%s" % game_id
		return

	_clear_game()
	var scene: PackedScene = load(path)
	_game = scene.instantiate()
	_game.my_id = ServerConnection.get_user_id()
	_game.players = _players
	_game.send_to_server.connect(
		func(op, data): ServerConnection.send(op, data))
	game_slot.add_child(_game)
	_game.game_started(payload.get("settings", {}), _players)
	status.text = ""


func _end_game(payload: Dictionary) -> void:
	var results := JsonSafe.arr(payload, "results")
	if _game != null:
		_game.game_ended(results)
	if results.is_empty():
		status.text = "本局结束 · 再来一局请重新准备"
	else:
		status.text = "🏆 %s 获胜! · 再来一局请重新准备" % results[0]["name"]
	ready_button.button_pressed = false


func _clear_game() -> void:
	if _game != null:
		_game.queue_free()
		_game = null


func _on_ready_toggled(on: bool) -> void:
	ServerConnection.send(OpCodes.READY, {"ready": on})


func _on_leave() -> void:
	_clear_game()
	await ServerConnection.leave_room_async()
	get_tree().change_scene_to_file("res://src/lobby/Lobby.tscn")


## 服务端返回的是错误码,这里翻成人话。
func _error_text(code: String) -> String:
	match code:
		"not_host":          return "只有房主能开始"
		"not_all_ready":     return "还有人没准备"
		"need_more_players": return "人不够,再叫一个"
		_:                   return "出错了:%s" % code
