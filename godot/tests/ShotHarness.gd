extends Control
## 截图固定装置:给场景喂真实格式的服务端 payload,渲染出有内容的画面。
## 只用于生成文档截图,不参与游戏运行。
##
## 用法(movie 模式,由 tools/take_screenshots.py 驱动):
##   SHOT=rps godot --path godot --write-movie /tmp/x.png --quit-after 40
## SHOT ∈ login | lobby | room | rps
##
## room/rps 需要真实 user_id(界面按「我是谁」渲染),所以会先对本地
## Nakama 登录一次 —— 跑之前确保 docker compose up。

func _ready() -> void:
	var which := OS.get_environment("SHOT")
	match which:
		"login": _login()
		"lobby": await _lobby()
		"room":  await _room()
		"rps":   await _rps()
		_: push_error("SHOT 环境变量必须是 login|lobby|room|rps")


func _login() -> void:
	var s: Control = load("res://src/lobby/Login.tscn").instantiate()
	add_child(s)
	s.get_node("Margin/Row/Col/NameEdit").text = "爸爸"


func _me() -> String:
	await ServerConnection.login_async()
	return ServerConnection.get_user_id()


func _lobby() -> void:
	var me := await _me()
	await ServerConnection.connect_to_server_async()
	var s: Control = load("res://src/lobby/Lobby.tscn").instantiate()
	add_child(s)
	# Lobby._ready 的 await 走墙钟、movie 的帧走渲染速度,固定帧数等不齐。
	# 改成事件驱动:等它自己的首次刷新真正落地(列表出现条目)再注入。
	var room_list: ItemList = s.get_node("Margin/Row/Col/Rooms/RoomList")
	for _i in range(600):
		if room_list.item_count > 0:
			break
		await get_tree().process_frame
	s._timer = -1.0e9   # 冻结 3 秒轮询,注入的内容不会被下一次刷新盖掉
	# 在线与聊天:直接喂渲染入口
	s._on_presence_changed([
		{"id": me, "name": "爸爸"}, {"id": "g1", "name": "奶奶"},
		{"id": "g2", "name": "爷爷"}, {"id": "g3", "name": "小明"},
	])
	s._on_message("g1", "奶奶", "吃完饭来一局?")
	s._on_message("g3", "小明", "我先进客厅等你们!")
	# 房间列表:按 _refresh_rooms 的渲染格式手工填(截图在 3 秒轮询前完成)
	room_list.clear()
	room_list.add_item("石头剪刀布 · 客厅  (2/8)  房主 小明")
	room_list.add_item("石头剪刀布 · 书房  (1/8)  房主 爷爷")


func _room() -> void:
	var me := await _me()
	var s: Control = load("res://src/room/Room.tscn").instantiate()
	add_child(s)
	await get_tree().process_frame
	s._apply_room_state({
		"phase": "waiting", "host": me, "name": "客厅", "game": "rps",
		"settings": {},
		"players": [
			{"id": me, "name": "爸爸", "ready": true},
			{"id": "b", "name": "妈妈", "ready": true},
			{"id": "c", "name": "小明", "ready": false},
		],
	})


func _rps() -> void:
	var me := await _me()
	var g = load("res://src/games/rps/RpsGame.tscn").instantiate()
	g.my_id = me
	g.players = [
		{"id": me, "name": "爸爸", "ready": true},
		{"id": "b", "name": "妈妈", "ready": true},
		{"id": "c", "name": "小明", "ready": true},
	]
	add_child(g)
	g.game_started({}, g.players)
	# 第 1 轮平局 → 第 2 轮加速中,妈妈已出拳
	g.handle_server(OpCodes.ROUND_RESULT, {
		"hands": {me: 0, "b": 0, "c": 0}, "draw": true,
		"advanced": [me, "b", "c"], "eliminated": [], "afk": [], "draw_streak": 1,
	})
	g.handle_server(OpCodes.ROUND_BEGIN, {
		"round": 2, "alive": [me, "b", "c"], "seconds": 2.5, "draw_streak": 1,
	})
	g.handle_server(OpCodes.THROW_PROGRESS, {"thrown": ["b"], "total": 3})
