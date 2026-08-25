extends Node
## Nakama 网络门面(Autoload)。游戏逻辑一律不直接碰 NakamaClient / NakamaSocket。

signal socket_connected
signal socket_closed
signal lobby_presence_changed(users: Array)
signal lobby_message(sender_id: String, name: String, text: String)
signal room_event(op_code: int, payload: Dictionary)
signal room_joined(match_id: String)
signal room_left

const LOBBY_ROOM := "lobby"

var error_message := ""

var _client: NakamaClient
var _session: NakamaSession
var _socket: NakamaSocket
var _lobby_channel := ""
var _match_id := ""
var _lobby_users := {}   # user_id -> username


func _ready() -> void:
	var cfg := NakamaConfig.load_or_default()
	_client = Nakama.create_client(cfg.server_key, cfg.host, cfg.port, cfg.scheme)
	_client.timeout = 10
	_client.auto_refresh = true


# ---------------------------------------------------------------- 认证

## 设备认证。家庭局不需要注册流程,一键进。
func login_async() -> int:
	var session = await _client.authenticate_device_async(Nakama.get_device_id())
	var err := _check(session)
	if err == OK:
		_session = session
	return err


func get_user_id() -> String:
	return _session.user_id if _session else ""


func get_username() -> String:
	return _session.username if _session else ""


## 改显示名。设备认证给的默认用户名是一串随机字符,家里人认不出。
func set_display_name_async(name: String) -> int:
	var res = await _client.update_account_async(_session, name, name)
	return _check(res)


# ---------------------------------------------------------------- Socket

func connect_to_server_async() -> int:
	_socket = Nakama.create_socket_from(_client)
	_socket.connected.connect(func(): socket_connected.emit())
	_socket.closed.connect(func(): socket_closed.emit())
	_socket.received_error.connect(func(e): push_error("[socket] %s" % e))
	_socket.received_match_state.connect(_on_match_state)
	_socket.received_channel_message.connect(_on_channel_message)
	_socket.received_channel_presence.connect(_on_channel_presence)

	var res = await _socket.connect_async(_session)
	return _check(res)


# ---------------------------------------------------------------- 大厅

## 加入大厅频道。这一个频道同时提供「谁在线」和「聊天」两件事。
func join_lobby_async() -> int:
	var channel = await _socket.join_chat_async(
		LOBBY_ROOM, NakamaSocket.ChannelType.Room, true, false)
	var err := _check(channel)
	if err != OK:
		return err
	_lobby_channel = channel.id
	_lobby_users.clear()
	for p in channel.presences:
		_lobby_users[p.user_id] = p.username
	lobby_presence_changed.emit(_lobby_users.values())
	return OK


func send_lobby_message_async(text: String) -> void:
	if not _lobby_channel.is_empty():
		await _socket.write_chat_message_async(_lobby_channel, {"msg": text})


func _on_channel_presence(evt: NakamaRTAPI.ChannelPresenceEvent) -> void:
	for p in evt.joins:
		_lobby_users[p.user_id] = p.username
	for p in evt.leaves:
		_lobby_users.erase(p.user_id)
	lobby_presence_changed.emit(_lobby_users.values())


func _on_channel_message(msg: NakamaAPI.ApiChannelMessage) -> void:
	if msg.code != 0:     # 非 0 是加入/离开等系统消息
		return
	var content = JSON.parse_string(msg.content)
	if content is Dictionary and content.has("msg"):
		# ⚠️ ApiChannelMessage 没有 username 字段(只有 sender_id)。
		# 显示名从大厅 presence 表里查,查不到就退化成 id 前 6 位。
		var who: String = _lobby_users.get(msg.sender_id, msg.sender_id.substr(0, 6))
		lobby_message.emit(msg.sender_id, who, content["msg"])


# ---------------------------------------------------------------- 房间

func list_rooms_async() -> Array:
	var res = await _client.rpc_async(_session, "list_rooms", "")
	if _check(res) != OK:
		return []
	var payload = JSON.parse_string(res.payload)
	return payload.get("rooms", []) if payload is Dictionary else []


func list_games_async() -> Array:
	var res = await _client.rpc_async(_session, "list_games", "")
	if _check(res) != OK:
		return []
	var payload = JSON.parse_string(res.payload)
	return payload.get("games", []) if payload is Dictionary else []


## 建房并直接进去。返回 match_id,失败返回空串。
func create_room_async(game: String, name: String) -> String:
	var res = await _client.rpc_async(_session, "create_room",
		JSON.stringify({"game": game, "name": name}))
	if _check(res) != OK:
		return ""
	var payload = JSON.parse_string(res.payload)
	if not (payload is Dictionary) or payload.has("error"):
		error_message = str(payload.get("error", "unknown")) if payload is Dictionary else "bad payload"
		return ""
	var id: String = payload["match_id"]
	return id if await join_room_async(id) == OK else ""


func join_room_async(match_id: String) -> int:
	var m = await _socket.join_match_async(match_id)
	var err := _check(m)
	if err != OK:
		return err
	_match_id = m.match_id
	room_joined.emit(_match_id)
	return OK


func leave_room_async() -> void:
	if not _match_id.is_empty():
		await _socket.leave_match_async(_match_id)
		_match_id = ""
		room_left.emit()


## 往当前房间发一条消息。
func send(op_code: int, data: Dictionary = {}) -> void:
	if _socket and not _match_id.is_empty():
		# 第三个参数是 String,不是 PackedByteArray。
		# 要发二进制得用 send_match_state_raw_async。
		_socket.send_match_state_async(_match_id, op_code, JSON.stringify(data))


func _on_match_state(state: NakamaRTAPI.MatchData) -> void:
	var payload = JSON.parse_string(state.data)
	room_event.emit(state.op_code, payload if payload is Dictionary else {})


# ---------------------------------------------------------------- 错误处理

## GDScript 没有异常,Nakama 用返回值携带错误。全部收敛到这一个函数。
func _check(result) -> int:
	if result == null:
		error_message = "no response"
		return ERR_CANT_CONNECT
	if result.is_exception():
		var e: NakamaException = result.get_exception()
		error_message = e.message
		push_error("[Nakama] status=%d %s" % [e.status_code, e.message])
		match e.status_code:
			-1:  return ERR_CANT_CONNECT
			401: return ERR_UNAUTHORIZED
			404: return ERR_DOES_NOT_EXIST
			_:   return FAILED
	error_message = ""
	return OK
