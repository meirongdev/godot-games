extends Node
## Nakama 网络门面(Autoload)。游戏逻辑一律不直接碰 NakamaClient / NakamaSocket。

signal socket_connected
signal socket_closed
signal lobby_presence_changed(users: Array)  # [{id, name}],带 id 才能标出「我」
signal lobby_message(sender_id: String, name: String, text: String)
signal room_event(op_code: int, payload: Dictionary)
signal room_joined(match_id: String)
signal room_left
## 房间回不去了。两种原因,都不可逆:一个人的房间空置 60 秒被服务端关掉
## (room.lua 的自动关闭),或者对局已经开始不让重进。房间页收到就该回大厅。
signal room_lost(reason: String)

const LOBBY_ROOM := "lobby"

## 单个 HTTP 请求的超时(秒)。家里人用手机连,3 秒(SDK 默认)太紧。
const REQUEST_TIMEOUT_SEC := 10

## 断线巡检的间隔(秒)。大厅本来靠 3 秒一次的房间列表轮询顺带发现断线,
## **房间页一次 HTTP 都不发**,断了没人知道 —— 巡检收到这里,两个场景一起盖。
const HEALTH_CHECK_SEC := 3.0

## socket 静默多久之后开始怀疑它死了(秒)。对局中服务端每轮都有广播
## (rps 的节奏 ≤6 秒一条),大厅的聊天/上下线也算 —— 真到 12 秒一条都没有,
## 要么确实没人说话(探一下,2 帧的开销),要么连接已经半开。
const PROBE_IDLE_SEC := 12.0

## ping 发出去多久没回 pong 就判死(秒)。局域网/家用宽带的 RTT 远小于这个数;
## 判死的代价也只是重连一次(1~2 秒),判漏的代价才是「永远还在等待」。
const PROBE_TIMEOUT_SEC := 5.0

## 重连前刷 session 的余量(秒)。socket 的 token 是**连接那一刻**写进 URL 的,
## 过期了握手直接 401(实测),所以宁可多刷一次,也不拿快过期的 token 去连。
const SESSION_REFRESH_MARGIN_SEC := 30

## 大厅聊天一进门补多少条历史。家庭规模,几十条足够,再多也没人往上翻。
const LOBBY_HISTORY_LIMIT := 30

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
var _health_timer := 0.0
## 最后一次从 socket 收到任何东西的时刻(毫秒)。半开探测的依据。
var _last_rx_msec := 0
var _probing := false
## 切场景时捎给下一个场景显示的一句话。房间页被踢回大厅时,原因得跟着走,
## 否则用户只看到自己莫名回到了大厅。由下一个场景读完清空。
var notice := ""


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
	Probe.emit("config", {"scheme": cfg.scheme, "host": cfg.host, "port": cfg.port})


## 配置是否可用。false 时 error_message 里是给用户看的原因。
func is_configured() -> bool:
	return _client != null


## 断线巡检。**这是房间页唯一的自愈来源。**
##
## 手机上断线是常态而不是异常:锁屏、切到微信看一眼、Wi-Fi 切 4G,浏览器都会
## 把页面冻起来,而 Chrome 冻页面时会**直接关掉 WebSocket**(实测:控制台报
## "Page entered Back-Forward Cache" 紧跟一个 WS close)。页面被唤回来之后
## socket 已经是死的,以前没有任何东西会发现这件事 —— 房间页就那么一直空转。
##
## 放在 ServerConnection 而不是各个场景里:大厅碰巧有 3 秒一次的房间列表轮询
## 顺带查了一下,房间页一次 HTTP 都不发,靠场景自己查就一定会漏。
func _process(delta: float) -> void:
	# 还没登录、或者正在重连,都不用巡
	if _session == null or _socket == null or _reconnecting:
		return
	_health_timer += delta
	if _health_timer < HEALTH_CHECK_SEC:
		return
	_health_timer = 0.0
	if not is_socket_connected():
		await ensure_socket_async()
		return
	# ⚠️ 「连着」不等于「活着」。手机 Wi-Fi 切 4G、蜂窝网 NAT 超时都会把连接
	# 变成**半开**:客户端这边看一切正常,发出去的都进了黑洞,服务端早就把人
	# 从房间里移走了 —— 桌面打了 5 轮,手机还停在「等待」,就是这个。
	# 浏览器不暴露 WS 协议层的 ping/pong,Godot 也拿不到,只能自己在应用层探。
	if Time.get_ticks_msec() - _last_rx_msec > PROBE_IDLE_SEC * 1000.0:
		_probe_socket_async()


## 手机锁屏/切后台回来的那一刻,别等下一个巡检周期 —— 立刻查。
## (页面冻结期间 _process 完全不跑,巡检的计时器也是死的;这里是唤醒后
## 最早能做事的时机。ticks_msec 是系统单调钟,冻结期间照走,所以上面的
## 静默判断在唤醒后的第一次巡检就会成立。)
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_health_timer = HEALTH_CHECK_SEC


## 半开探测:ping 一下,PROBE_TIMEOUT_SEC 秒内没有 pong 就强制断开重连。
## SDK 的请求没有超时,所以不能 await ping 本身 —— 半开连接上它永远不返回;
## 用旁边的计时器当裁判,close() 会把挂着的 ping 一并 cancel 掉。
func _probe_socket_async() -> void:
	if _probing:
		return
	_probing = true
	var got_pong := [false]
	_ping_and_flag(got_pong)
	await get_tree().create_timer(PROBE_TIMEOUT_SEC).timeout
	_probing = false
	if got_pong[0] or _socket == null or not is_socket_connected():
		return   # 活着;或者别的路径已经在处理断线了
	push_warning("[socket] ping %.0f 秒没回 —— 连接是半开的,强制重连" % PROBE_TIMEOUT_SEC)
	_socket.close()
	await ensure_socket_async()


func _ping_and_flag(got_pong: Array) -> void:
	var res = await _socket.ping_async()
	if res != null and not res.is_exception():
		got_pong[0] = true
		_mark_rx()


func _mark_rx() -> void:
	_last_rx_msec = Time.get_ticks_msec()


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
		_socket.connected.connect(func(): _mark_rx(); socket_connected.emit())
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
	# 顺序是刻意的:先换新 token,再连 socket,连上了才谈恢复现场。
	var err := await _refresh_session_async()
	if err == OK:
		err = await connect_to_server_async()
	if err == OK:
		# 重连之后大厅频道要重新加入,否则聊天和在线列表还是死的。
		await join_lobby_async()
		# 房间也要重新进 —— 光把 socket 连回来是不够的,见 _rejoin_room_async。
		await _rejoin_room_async()
	_reconnecting = false

	if err != OK and error_message.is_empty():
		error_message = "和服务器断开了,检查一下网络"
	return err


## 重连之前把 session 刷新到能用。
##
## ⚠️ Nakama 的 `session.token_expiry_sec` **默认只有 60 秒**(实测:不带这个
## 参数起一个 3.40.0,签出来的 token exp - iat = 60),而 SDK 的 auto_refresh
## 只在**发 HTTP 请求时**顺带刷 —— 房间页一次 HTTP 都不发,坐在房间里一分钟
## token 就废了。已经建立的 socket 不受影响(实测:token 过期不会被关),
## 但重连时 token 是写在 /ws 的 URL 里的,过期就直接 401,于是「断了以后
## 永远连不回来」。这一步就是补上 auto_refresh 在房间里没机会跑的那一次。
func _refresh_session_async() -> int:
	if _session == null:
		return ERR_UNCONFIGURED
	if not _session.would_expire_in(SESSION_REFRESH_MARGIN_SEC):
		return OK
	# refresh token 默认 1 小时(实测),过了它谁也救不了 —— 只能重新登录。
	if _session.is_refresh_expired():
		error_message = "登录太久失效了,刷新一下页面重新进来"
		return ERR_UNAUTHORIZED
	var refreshed = await _client.session_refresh_async(_session)
	if _check(refreshed) != OK:
		error_message = "登录太久失效了,刷新一下页面重新进来"
		return ERR_UNAUTHORIZED
	_session = refreshed
	return OK


## 重连之后重新进房。
##
## ⚠️ socket 一断,服务端立刻给这个房间派一次 match_leave —— 人从花名册里移走,
## 房主也传给了下一个人(实测:两人房里 A 掉线,B 立刻看到「1 人」并接过房主)。
## 所以只把 socket 连回来是不够的:客户端还以为自己在房里,准备/开局发出去
## 没人收,房间页停在断线前的画面,而其他人早就看不见你了。
##
## 进不去的两种情况都不可逆,直接把人送回大厅,别让他对着一个假房间干等:
##   - 一个人的房间空置 60 秒被 room.lua 关掉 → "Match not found"(实测)
##   - 对局已经开始 → match_join_attempt 拒绝「游戏已开始」
func _rejoin_room_async() -> void:
	if _match_id.is_empty():
		return
	# 服务端会在 match_join 里重新广播 ROOM_STATE,房间页据此自己刷新,
	# 这里不用手动补 —— _match_id 已经是目标房间,那条状态收得到。
	var m = await _socket.join_match_async(_match_id)
	if _check(m) == OK:
		return
	var why := error_message
	_match_id = ""
	_last_room_state = {}
	room_lost.emit(why)


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
	_mark_rx()
	for p in evt.joins:
		_lobby_users[p.user_id] = p.username
	for p in evt.leaves:
		_lobby_users.erase(p.user_id)
	lobby_presence_changed.emit(_lobby_users_list())


func _on_channel_message(msg: NakamaAPI.ApiChannelMessage) -> void:
	_mark_rx()
	if msg.code != 0:     # 非 0 是加入/离开等系统消息
		return
	var content = JSON.parse_string(msg.content)
	if content is Dictionary and content.has("msg"):
		lobby_message.emit(msg.sender_id, _sender_name(msg), content["msg"])


## 一条聊天该显示谁发的。
##
## 帧里自带 username(实测:实时推来的 channel_message 和 REST 拉的历史都有
## 这个字段),优先用它 —— 历史消息的发送者常常已经不在线了,只查 presence 表
## 的话那些人会显示成一串 id。presence 表只当兜底。
func _sender_name(msg: NakamaAPI.ApiChannelMessage) -> String:
	if not msg.username.is_empty():
		return msg.username
	return _lobby_users.get(msg.sender_id, msg.sender_id.substr(0, 6))


## 拉大厅聊天的最近记录,按时间正序返回 [{sender_id, name, text}]。
##
## 频道是带 persistence 加入的(join_lobby_async),消息一直存在服务端 ——
## 只是以前没人去取。于是每次从房间回到大厅、或者手机刷新一下页面,
## 聊天记录就是空的,看着像「消息全丢了」。
func lobby_history_async() -> Array:
	if _lobby_channel.is_empty():
		return []
	# forward=false = 从最新往回取,拿到的是倒序,显示前要翻回来。
	var res = await _client.list_channel_messages_async(
		_session, _lobby_channel, LOBBY_HISTORY_LIMIT, false)
	if _check(res) != OK:
		return []
	var out := []
	for msg in res.messages:
		if msg.code != 0:
			continue
		var content = JSON.parse_string(msg.content)
		if content is Dictionary and content.has("msg"):
			out.push_front({
				"sender_id": msg.sender_id,
				"name": _sender_name(msg),
				"text": content["msg"],
			})
	return out


# ---------------------------------------------------------------- 房间

## 发一个 RPC。**所有 RPC 都必须走这里。**
##
## ⚠️ SDK 的 auto_refresh **管不到 RPC。** 它挂在「接收 session 对象」的那些
## 方法上(`_refresh_session(p_session)`),而 NakamaClient.rpc_async 是把
## `p_session.token` 当一个裸 bearer 串传下去的(NakamaClient.gd:789-790,
## 全 SDK 只有这两处这么干)。于是 token 一过期,list_rooms / list_games /
## create_room 全部 401,而且**永远不会自己好** —— 大厅这时 socket 还连得好好的
## (token 过期不会关已建立的 socket,实测),所以连 ensure_socket_async 都不会
## 被触发,没有任何一条路径会去刷 session。
##
## 实测(Nakama `session.token_expiry_sec` 默认 **60 秒**):登录后第 60 秒起,
## list_rooms 恒定返回空列表(现有房间在大厅里全部消失,显示「还没有房间」),
## 建房报英文的 "Auth token invalid",从此再也建不出房、也进不了房 ——
## **这就是「手机无法进入房间」**:手机上从登录走到点建房本来就容易超过一分钟。
## 本地 compose 把 token 设成了 7200 秒,把这件事盖得严严实实(契约 §3.2 已补上
## 这个参数的要求)。
func _rpc_async(rpc_name: String, payload: String):
	# 刷不动也照发:让服务端说话,比在这里自己编一个错误更好排查。
	await _refresh_session_async()
	return await _client.rpc_async(_session, rpc_name, payload)


func list_rooms_async() -> Array:
	var res = await _rpc_async("list_rooms", "")
	if _check(res) != OK:
		return []
	var payload = JSON.parse_string(res.payload)
	if not (payload is Dictionary):
		return []
	return JsonSafe.arr(payload, "rooms")


func list_games_async() -> Array:
	var res = await _rpc_async("list_games", "")
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
	var res = await _rpc_async("create_room",
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
	# ⚠️ _match_id 必须在 await **之前**就认领目标房间,不能等 join 返回。
	# 服务端在 match_join 里广播的第一条 ROOM_STATE 和 join 的应答是两条独立的
	# 帧,而广播**恒定先到**(实测 12/12):等到 join 返回再写 _match_id,
	# 那条状态到达时 _match_id 还是空的,_on_match_state 的房间校验会把它
	# 当成「上一个房间的迟到帧」丢掉 —— 缓存空的,replay_room_state() 无事可做,
	# 房间页就永远停在写死的「房间」+ 空花名册 + 「等待其他人…」。
	# 桌面版实测 3/3 必现,而它长得和「进房失败」一模一样。
	_match_id = match_id
	var m = await _socket.join_match_async(match_id)
	var err := _check(m)
	if err != OK:
		_match_id = ""
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
##
## 尽力而为:socket 死着的时候发不出去,巡检会在几秒内把它连回来,但**这一条
## 丢了**(玩家得再点一次)。以前这里是完全静默的 —— 点「准备」没反应也不报错。
func send(op_code: int, data: Dictionary = {}) -> void:
	if _match_id.is_empty():
		return
	if not is_socket_connected():
		push_warning("[socket] 断线中,op_code=%d 这条没发出去" % op_code)
		return
	# 第三个参数是 String,不是 PackedByteArray。
	# 要发二进制得用 send_match_state_raw_async。
	_socket.send_match_state_async(_match_id, op_code, JSON.stringify(data))


func _on_match_state(state: NakamaRTAPI.MatchData) -> void:
	_mark_rx()
	var payload = JSON.parse_string(state.data)
	var data: Dictionary = payload if payload is Dictionary else {}
	# 只缓存**当前房间**的状态。刚离开的房间可能还有一帧在路上,不校验的话
	# 它会被缓存下来、再被 replay_room_state() 主动补发到下一个房间去 ——
	# 而在加缓存之前,这种迟到帧顶多是一次无害的 emit,不会留下来。
	# ⚠️ 这个校验成立的前提是 join_room_async 在 await 之前就认领了 _match_id
	# (那边有详细理由)。别把那一行挪回 await 后面,否则进房第一条状态
	# 每次都会被这里判成迟到帧丢掉。
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
			401:
				# 401 只有一个意思:这个 token 服务端不认了。原文是英文的
				# "Auth token invalid",给家里人看没有任何用 —— 原文仍然在上面
				# 那行 push_error 里,排查不受影响。
				error_message = "登录失效了 —— 刷新一下页面重新进来"
				return ERR_UNAUTHORIZED
			404: return ERR_DOES_NOT_EXIST
			_:   return FAILED
	error_message = ""
	return OK
