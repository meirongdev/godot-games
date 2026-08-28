extends Control
## 通用房间控制器。独占准备/开局/结算,把游戏段消息转发给挂载的 GameBase。
## ★ 加新游戏只需在 GAME_SCENES 加一行。

const GAME_SCENES := {
	"rps": "res://src/games/rps/RpsGame.tscn",
}

@onready var room_title: Label = $Margin/Row/Col/Header/RoomTitle
@onready var leave_button: Button = $Margin/Row/Col/Header/LeaveButton
@onready var player_strip: Label = $Margin/Row/Col/PlayerStrip
@onready var ready_button: CheckButton = $Margin/Row/Col/Actions/ReadyButton
@onready var start_button: Button = $Margin/Row/Col/Actions/StartButton
@onready var game_slot: Control = $Margin/Row/Col/GameSlot
@onready var status: Label = $Margin/Row/Col/Status

var _game: GameBase = null
var _players: Array = []
var _host := ""
var _phase := "waiting"


func _ready() -> void:
	ServerConnection.room_event.connect(_on_room_event)
	# 房间页以前对连线状态一无所知。手机锁屏、切个应用回来 socket 就断了
	# (Chrome 冻页面时直接关 WebSocket),而这里既不提示也不自愈,
	# 表现就是「房间突然不动了」—— 用户报的「连线突然中断」就是这一段。
	ServerConnection.socket_closed.connect(_on_socket_closed)
	ServerConnection.room_lost.connect(_on_room_lost)
	leave_button.pressed.connect(_on_leave)
	ready_button.toggled.connect(_on_ready_toggled)
	start_button.pressed.connect(func(): ServerConnection.send(OpCodes.START))
	start_button.disabled = true
	status.text = "等待其他人…"
	# 进房那一刻的 ROOM_STATE 是在本场景被切出来之前广播的,那时还没订阅 ——
	# 补发一次。不补的话房名、花名册、人数会一直空着,直到下一次 sync。
	ServerConnection.replay_room_state()


## 断了。ServerConnection 的巡检会在几秒内重连并重新进房,重连成功后服务端
## 会重播 ROOM_STATE,_apply_room_state 顺手把这行字盖掉 —— 所以这里只报状态,
## 不自己修。真的回不去会走 _on_room_lost。
func _on_socket_closed() -> void:
	status.text = "和服务器断开了,正在重连…"


## 回不去了(房间被关掉 / 对局已开始)。别让人对着一个假房间干等,回大厅。
func _on_room_lost(reason: String) -> void:
	_clear_game()
	ServerConnection.notice = _lost_text(reason)
	get_tree().change_scene_to_file("res://src/lobby/Lobby.tscn")


## 回不去的原因翻成人话。服务端这一路给的是 Nakama 的英文原文,
## 家里人看不懂;认不出的原样透出,好排查。
func _lost_text(reason: String) -> String:
	if "not found" in reason.to_lower():
		# 一个人的房间空置 60 秒会被 room.lua 自动关掉 —— 锁屏一分钟就够了
		return "房间已经关了 —— 没人的房间会自动关闭,重新建一个吧"
	if "游戏已开始" in reason:
		return "这局已经开始了,进不回去 —— 等他们打完再来"
	if reason.is_empty():
		return "掉线太久,回不到房间了"
	return "回不到房间了:%s" % reason


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

	# 打一行给排查用。tools/web_smoke.py 靠它断言「真的进到房间里了」——
	# 以前进房第一条 ROOM_STATE 会被丢掉,房间页停在写死的「房间」+ 空花名册,
	# 而所有测试层都看不到这件事(见 docs/testing.md)。
	print("[room] %s · %d 人 · phase=%s" % [room_name, _players.size(), _phase])

	var me := ServerConnection.get_user_id()
	# 竖屏里竖直空间全给游戏区,名单压成一行(最多 8 人,一两行写完)。
	# 房主的 👑 放在名字前面 —— 后面跟着 ✓,放后面会挤成一团认不出。
	var parts := PackedStringArray()
	for p in _players:
		var line: String = p["name"]
		if p["id"] == _host:
			line = "👑" + line
		if p["id"] == me:
			line += "(我)"
		# 准备好打 ✓,没准备打 … —— 不能留空:空白读起来像「还在加载」,
		# 而房主需要一眼看出是谁在拖着不开局。
		line += " ✓" if p["ready"] else " …"
		parts.append(line)
	player_strip.text = "   ".join(parts)

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
