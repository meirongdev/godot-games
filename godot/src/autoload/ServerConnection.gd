extends Node
## Nakama 网络门面(Autoload)。游戏逻辑一律不直接碰 NakamaClient / NakamaSocket。

signal socket_connected
signal socket_closed
signal lobby_presence_changed(users: Array)  # [{id, name}],带 id 才能标出「我」
signal lobby_message(sender_id: String, name: String, text: String)
signal room_event(op_code: int, payload: Dictionary)
signal room_joined(match_id: String)
signal room_left

const LOBBY_ROOM := "lobby"

## 单个 HTTP 请求的超时(秒)。家里人用手机连,3 秒(SDK 默认)太紧。
const REQUEST_TIMEOUT_SEC := 10

var error_message := ""

var _client: NakamaClient
var _session: NakamaSession
var _socket: NakamaSocket
var _lobby_channel := ""
var _match_id := ""
var _lobby_users := {}   # user_id -> username
var _config: NakamaConfig
var _reconnecting := false
## 进房那一刻服务端广播的 ROOM_STATE。见 replay_room_state()。
var _last_room_state := {}


func _ready() -> void:
	_config = NakamaConfig.load_or_default()
	var cfg := _config
	if not cfg.error.is_empty():
		# 配置没确定就不建 client。宁可一进门就报错,也不要拿一个错地址
		# 去连然后给用户看「连接超时」—— 那是 2026-08-26 那个故障的形状。
		error_message = cfg.error
		push_error("[config] %s" % cfg.error)
		return
	# ⚠️ 超时必须在**构造时**传进去。上游 SDK 里 NakamaClient.timeout 是个普通字段,
	# 事后 `_client.timeout = 10` 只改了那个字段,不会传到 HTTP 适配器 ——
	# 日志里会照旧打 `Timeout: 3`(适配器默认值),排查时非常误导。
	_client = Nakama.create_client(
		cfg.server_key, cfg.host, cfg.port, cfg.scheme, REQUEST_TIMEOUT_SEC)
	_client.auto_refresh = true
	print("[config] %s://%s:%d" % [cfg.scheme, cfg.host, cfg.port])


## 配置是否可用。false 时 error_message 里是给用户看的原因。
func is_configured() -> bool:
	return _client != null


# ---------------------------------------------------------------- 认证

## 设备认证。家庭局不需要注册流程,一键进。
func login_async() -> int:
	if not is_configured():
		return ERR_UNCONFIGURED
	var device_id := Nakama.get_device_id()
	if not _config.device_suffix.is_empty():
		device_id += "-" + _config.device_suffix
	var session = await _client.authenticate_device_async(device_id)
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
	var err := _check(res)
	if err != OK:
		return err

	# ⚠️ 改名只落库,**不会**动已经签发的 session —— token 里的 usn 还是认证那一刻
	# 的随机用户名。而大厅「在线」列表读的是 presence 的 username,presence 又是
	# socket 连接时用的 token 里的那个。不刷新的话家里人在大厅看到的还是随机串,
	# 「输入名字,家里人就能在大厅看到你」这句话直接不成立。
	# 必须在 connect_to_server_async() 之前刷 —— socket 认的是连接那一刻的 token。
	var refreshed = await _client.session_refresh_async(_session)
	if refreshed != null and not refreshed.is_exception():
		_session = refreshed
	else:
		# 名字是门面,不是入场券:刷不动也让人进得去,只是列表里显示的是旧名。
		push_error("[Nakama] 改名后刷新 session 失败,大厅里会显示旧用户名")
	return OK


# ---------------------------------------------------------------- Socket

func connect_to_server_async() -> int:
	# ⚠️ socket 只建**一次**,重连复用同一个对象。
	# Nakama.create_socket_from() 每次都会 add_child 一个新的适配器节点,
	# 断线时每 3 秒重连一次的话,一次断网就能堆出几百个还在 _process 里
	# 空转的节点。适配器内部本来就复用同一个 WebSocketPeer,连都能重连。
	if _socket == null:
		_socket = Nakama.create_socket_from(_client)
		_socket.connected.connect(func(): socket_connected.emit())
		_socket.closed.connect(func(): socket_closed.emit())
		_socket.received_error.connect(func(e): push_error("[socket] %s" % e))
		_socket.received_match_state.connect(_on_match_state)
		_socket.received_channel_message.connect(_on_channel_message)
		_socket.received_channel_presence.connect(_on_channel_presence)

	# SDK 默认的连接超时是 3 秒,和 HTTP 那边一样对手机网络太紧。
	var res = await _socket.connect_async(_session, false, REQUEST_TIMEOUT_SEC)
	return _check(res)


## socket 还活着吗。只报告,不修 —— 要修用 ensure_socket_async()。
func is_socket_connected() -> bool:
	return _socket != null and _socket.is_connected_to_host()


## 断线自愈。**每个用到 socket 的操作都要先过这一关。**
##
## socket 是家用场景里最脆的一环:手机锁屏、切后台、Wi-Fi 抖动、服务端重启
## 都会断。麻烦在于断了之后 **HTTP 还是通的** —— 大厅的房间列表照常 3 秒一刷,
## 页面看上去一切正常,其实 socket 那一半(聊天、在线列表、进房、建房)全废,
## 而且只报一句英文的 "Request cancelled.",没人看得懂。
func ensure_socket_async() -> int:
	if is_socket_connected():
		return OK

	# 同一时刻只能有一次重连在飞。大厅每 3 秒自己试一次,用户又可能正好点了
	# 建房 —— 两次 connect_async 撞上会把 SDK 内部那个 _conn 换掉,先来的
	# await 就永远回不来,表现成「点了建房没反应」。
	if _reconnecting:
		while _reconnecting:
			await get_tree().process_frame
		return OK if is_socket_connected() else ERR_CANT_CONNECT

	_reconnecting = true
	var err := await connect_to_server_async()
	if err == OK:
		# 重连之后大厅频道要重新加入,否则聊天和在线列表还是死的。
		await join_lobby_async()
	_reconnecting = false

	if err != OK:
		error_message = "和服务器断开了,检查一下网络"
	return err


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
	# ⚠️ channel.presences 里**没有自己**(实测:join 响应的 presences 是空数组,
	# 自己在 channel.self_presence 里)。自己是靠一条单独的 presence 事件送来的,
	# 而那条事件常常在上面那个 await 期间就到了 —— 然后被这里的 clear() 抹掉,
	# 于是「在线」列表里看不见自己,还时灵时不灵(取决于事件和 await 谁先)。
	# 所以自己从 self_presence 补,不赌那条事件的到达时机。
	if channel.self_presence != null:
		_lobby_users[channel.self_presence.user_id] = channel.self_presence.username
	for p in channel.presences:
		_lobby_users[p.user_id] = p.username
	lobby_presence_changed.emit(_lobby_users_list())
	return OK


func _lobby_users_list() -> Array:
	var out := []
	for id in _lobby_users:
		out.append({"id": id, "name": _lobby_users[id]})
	return out


func send_lobby_message_async(text: String) -> void:
	if not _lobby_channel.is_empty():
		await _socket.write_chat_message_async(_lobby_channel, {"msg": text})


func _on_channel_presence(evt: NakamaRTAPI.ChannelPresenceEvent) -> void:
	for p in evt.joins:
		_lobby_users[p.user_id] = p.username
	for p in evt.leaves:
		_lobby_users.erase(p.user_id)
	lobby_presence_changed.emit(_lobby_users_list())


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
	if not (payload is Dictionary):
		return []
	return JsonSafe.arr(payload, "rooms")


func list_games_async() -> Array:
	var res = await _client.rpc_async(_session, "list_games", "")
	if _check(res) != OK:
		return []
	var payload = JSON.parse_string(res.payload)
	if not (payload is Dictionary):
		return []
	return JsonSafe.arr(payload, "games")


## 建房并直接进去。返回 match_id,失败返回空串。
func create_room_async(game: String, name: String) -> String:
	# ⚠️ socket 必须在**发 RPC 之前**确认。create_room 走的是 HTTP,socket 死了
	# 它照样成功 —— 于是服务端多一个没人进的空房(要空置 60 秒才自动关),
	# 客户端却因为 join_match 失败而返回空串。用户看到的是「建不出房间」,
	# 再点几次,5 次/分钟的建房额度就被这些空房吃光,变成「建房太频繁了」,
	# 从此彻底建不出来 —— 这就是「玩一局退出后就无法再创建房间」的形状。
	if await ensure_socket_async() != OK:
		return ""
	var res = await _client.rpc_async(_session, "create_room",
		JSON.stringify({"game": game, "name": name}))
	if _check(res) != OK:
		return ""
	var payload = JSON.parse_string(res.payload)
	if not (payload is Dictionary):
		error_message = "服务器回了看不懂的东西"
		return ""
	if payload.has("error"):
		error_message = _rpc_error(payload)
		return ""
	var id: String = payload["match_id"]
	return id if await join_room_async(id) == OK else ""


## 服务端错误码翻成给家里人看的话。认不出的码原样透出,好排查。
func _rpc_error(payload: Dictionary) -> String:
	var code := str(payload.get("error", "unknown"))
	match code:
		"rate_limited":
			return "建房太频繁了,%d 秒后再试" % int(payload.get("retry_after", 60))
		"unknown_game":
			return "这个游戏认不出来"
		"bad_payload":
			return "请求格式不对"
	return code


func join_room_async(match_id: String) -> int:
	if await ensure_socket_async() != OK:
		return ERR_CANT_CONNECT
	# 上一个房间的状态不能漏到下一个房间去。清在 join 之前:
	# 服务端的 ROOM_STATE 是在下面这个 await 期间到的,清晚了会把它抹掉。
	_last_room_state = {}
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
		_last_room_state = {}
		room_left.emit()


## 往当前房间发一条消息。
func send(op_code: int, data: Dictionary = {}) -> void:
	if _socket and not _match_id.is_empty():
		# 第三个参数是 String,不是 PackedByteArray。
		# 要发二进制得用 send_match_state_raw_async。
		_socket.send_match_state_async(_match_id, op_code, JSON.stringify(data))


func _on_match_state(state: NakamaRTAPI.MatchData) -> void:
	var payload = JSON.parse_string(state.data)
	var data: Dictionary = payload if payload is Dictionary else {}
	# 只缓存**当前房间**的状态。刚离开的房间可能还有一帧在路上,不校验的话
	# 它会被缓存下来、再被 replay_room_state() 主动补发到下一个房间去 ——
	# 而在加缓存之前,这种迟到帧顶多是一次无害的 emit,不会留下来。
	if state.op_code == OpCodes.ROOM_STATE and state.match_id == _match_id:
		_last_room_state = data
	room_event.emit(state.op_code, data)


## 补发进房那一刻错过的 ROOM_STATE。房间场景在 _ready() 里订阅完 room_event
## 之后调用。
##
## ⚠️ 为什么需要它:服务端在 match_join 里就广播了第一条 ROOM_STATE,而那一刻
## 房间场景**还没被切出来** —— join_room_async 要先 return,大厅才
## change_scene_to_file,RoomController._ready() 才订阅 room_event。
## 所以第一条状态是发给「没有听众的信号」,直接丢掉:房名显示写死的「房间」、
## 花名册空着、状态卡在「等待其他人…」,一直到有人进来或有人点准备触发
## 下一次 sync 才恢复。自己一个人建的房就一直是空的。
##
## 补发是安全的:如果那条状态到得比 _ready() 晚,场景已经订阅上了会正常收到,
## 这里的缓存还是空的,什么都不做。两种时序都对。
func replay_room_state() -> void:
	if not _last_room_state.is_empty():
		room_event.emit(OpCodes.ROOM_STATE, _last_room_state)


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
