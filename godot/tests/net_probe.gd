extends Node
## 联机时序探针,给 tools/e2e_client_reconnect.py 驱动。
##
## 跑的是**真的 ServerConnection**(登录 → socket → 建房),连的是 Python 侧
## 一个可「冻结」的 TCP 代理 —— 冻结 = 收发全黑洞但 TCP 不断,复刻手机
## Wi-Fi 切 4G 的半开连接。层 1–6 没有一层能跑到这条路(docs/testing.md 坑 ⑧),
## 桌面真玩也造不出半开 —— 拔网线是 close,不是黑洞。
##
## 只往 stdout 打标记,断言全在 Python 侧:
##   [probe] room_joined / socket_closed / socket_connected /
##   [probe] room_state <人数> / room_lost <原因>
##
## 用法(由 e2e_client_reconnect.py 拼好):
##   godot --headless --path godot res://tests/NetProbe.tscn \
##     -- --nakama-port=<代理端口> --device-suffix=netprobe

func _ready() -> void:
	ServerConnection.socket_connected.connect(func(): print("[probe] socket_connected"))
	ServerConnection.socket_closed.connect(func(): print("[probe] socket_closed"))
	ServerConnection.room_joined.connect(func(_id): print("[probe] room_joined"))
	ServerConnection.room_lost.connect(func(r): print("[probe] room_lost %s" % r))
	ServerConnection.room_event.connect(func(op, p):
		if op == OpCodes.ROOM_STATE:
			print("[probe] room_state %d" % JsonSafe.arr(p, "players").size()))

	if not ServerConnection.is_configured():
		print("[probe] FATAL config: %s" % ServerConnection.error_message)
		get_tree().quit(1)
		return
	if await ServerConnection.login_async() != OK:
		print("[probe] FATAL login: %s" % ServerConnection.error_message)
		get_tree().quit(1)
		return
	if await ServerConnection.connect_to_server_async() != OK:
		print("[probe] FATAL socket: %s" % ServerConnection.error_message)
		get_tree().quit(1)
		return
	await ServerConnection.join_lobby_async()
	var id := await ServerConnection.create_room_async("rps", "探针房")
	if id.is_empty():
		print("[probe] FATAL create_room: %s" % ServerConnection.error_message)
		get_tree().quit(1)
		return
	# 之后就交给 ServerConnection 自己的巡检/探活,这里只等 Python 侧观察。
	# 心跳一行,证明引擎在转(冻结的是网络,不是引擎)。
	var t := 0
	while t < 120:
		await get_tree().create_timer(1.0).timeout
		t += 1
		if t % 5 == 0:
			print("[probe] tick %d connected=%s" % [t, ServerConnection.is_socket_connected()])
