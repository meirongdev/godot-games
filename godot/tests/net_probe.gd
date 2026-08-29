extends Node
## 联机时序探针,给 tools/e2e_client_reconnect.py 驱动。
##
## 跑的是**真的 ServerConnection**(登录 → socket → 建房),连的是 Python 侧
## 一个可「冻结」的 TCP 代理 —— 冻结 = 收发全黑洞但 TCP 不断,复刻手机
## Wi-Fi 切 4G 的半开连接。层 1–6 没有一层能跑到这条路(docs/testing.md 坑 ⑧),
## 桌面真玩也造不出半开 —— 拔网线是 close,不是黑洞。
##
## 只往 stdout 发记录,断言全在 Python 侧。记录走的是和产品代码同一条
## Probe 通道(godot/src/net/Probe.gd),所以解析也只有一份
## (tools/probe.py)—— 以前这里是另一套 `[probe] room_state 3` 的散装格式,
## Python 侧为它单独写了一组正则。
##
##   {"k":"net","event":"socket_connected"|"socket_closed"|"room_joined"}
##   {"k":"net","event":"room_state","players":N}
##   {"k":"net","event":"room_lost","reason":"…"}
##   {"k":"net","event":"tick","t":N,"connected":bool}
##   {"k":"fatal","at":"config|login|socket|create_room","error":"…"}
##
## 用法(由 e2e_client_reconnect.py 拼好):
##   godot --headless --path godot res://tests/NetProbe.tscn \
##     -- --nakama-port=<代理端口> --device-suffix=netprobe

func _ready() -> void:
	ServerConnection.socket_connected.connect(
		func(): Probe.emit("net", {"event": "socket_connected"}))
	ServerConnection.socket_closed.connect(
		func(): Probe.emit("net", {"event": "socket_closed"}))
	ServerConnection.room_joined.connect(
		func(_id): Probe.emit("net", {"event": "room_joined"}))
	ServerConnection.room_lost.connect(
		func(r): Probe.emit("net", {"event": "room_lost", "reason": r}))
	ServerConnection.room_event.connect(func(op, p):
		if op == OpCodes.ROOM_STATE:
			Probe.emit("net", {"event": "room_state",
				"players": JsonSafe.arr(p, "players").size()}))

	if not ServerConnection.is_configured():
		_fatal("config")
		return
	if await ServerConnection.login_async() != OK:
		_fatal("login")
		return
	if await ServerConnection.connect_to_server_async() != OK:
		_fatal("socket")
		return
	await ServerConnection.join_lobby_async()
	var id := await ServerConnection.create_room_async("rps", "探针房")
	if id.is_empty():
		_fatal("create_room")
		return
	# 之后就交给 ServerConnection 自己的巡检/探活,这里只等 Python 侧观察。
	# 心跳一条,证明引擎在转(冻结的是网络,不是引擎)。
	var t := 0
	while t < 120:
		await get_tree().create_timer(1.0).timeout
		t += 1
		if t % 5 == 0:
			Probe.emit("net", {"event": "tick", "t": t,
				"connected": ServerConnection.is_socket_connected()})


func _fatal(at: String) -> void:
	Probe.emit("fatal", {"at": at, "error": ServerConnection.error_message})
	get_tree().quit(1)
