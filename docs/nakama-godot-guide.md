# 用 Godot 4 做一个接入 Nakama 的游戏

> 面向对象:已经在 homelab 跑起 Nakama、想从零学 Godot 游戏开发的人。
> 参考项目:[heroiclabs/nakama-godot-demo](https://github.com/heroiclabs/nakama-godot-demo)
> 最后核对时间:2026-08(所有 API 签名都对照 `nakama-godot` master 分支源码验证过)

---

## 0. 先看这一段:最容易踩的坑

**官方 demo 是 Godot 3 的,不能直接抄。**

`nakama-godot-demo` 最后一次实质更新停在 Godot 3.x,里面全是 `yield(x, "completed")`、`setget`、`export var` 这类 Godot 3 语法。你在 Godot 4 里打开它会报几十个错。

它仍然值得读——**值得读的是架构,不是代码**。这份文档做的事就是:把 demo 的架构翻译成 Godot 4 能直接跑的写法。

| 组件 | 你应该用的版本 | 说明 |
|---|---|---|
| Godot | **4.7.x**(当前 4.7.2-stable) | 4.4+ 都行,本文按 4.x 写 |
| Nakama 服务端 | **3.40.x** | 你 homelab 上跑的那个 |
| `nakama-godot` 客户端 | **master 分支源码**,不是 v3.4.0 release | 见下方说明 |
| 官方 demo | 仅作架构参考 | Godot 3,语法不兼容 |

**为什么用 master 而不是 tag?** 最新 release `v3.4.0` 发布于 2024-03,之后 master 上合了不少重要修复:Godot 4.4 兼容性(2025-02)、`Nakama.get_device_id()`(2026-07)、请求总超时上限(2026-08)。这些都没进 tag。直接下 master 的 `addons/` 目录。

---

## 1. Step 0 — 摸清你 homelab 上的 Nakama

在写一行 Godot 代码之前,先把这 5 个值弄清楚并写下来。后面全靠它们。

| 要素 | 怎么查 | 典型值 |
|---|---|---|
| **host** | 你的 homelab 域名或内网 IP | `nakama.lan` / `192.168.1.50` |
| **port** | 客户端 API 端口 | `7350` |
| **scheme** | 有没有走 TLS 反代 | `http` 或 `https` |
| **server_key** | 启动参数 `--socket.server_key`,或配置文件 `socket.server_key` | 默认 `defaultkey` |
| **console** | 管理后台 | `http://<host>:7351`,默认 `admin` / `password` |

### 三个端口分别干什么

| 端口 | 用途 | 客户端要不要 |
|---|---|---|
| 7349 | gRPC API | 不需要(GDScript 客户端走 HTTP/WS) |
| **7350** | **REST API + WebSocket** | **必须** |
| 7351 | 管理后台 Console | 开发期你自己用 |

Godot 客户端**只需要 7350**。socket 复用同一个端口,scheme 自动从 `http`→`ws`、`https`→`wss`。

### 先用 curl 验证服务端活着

```bash
# 健康检查,应该返回 {}
curl http://<你的host>:7350/

# 用 server_key 做一次匿名认证,验证 key 对不对
curl -X POST "http://<你的host>:7350/v2/account/authenticate/device?create=true" \
  -H "Content-Type: application/json" \
  -u "<你的server_key>:" \
  -d '{"id":"0123456789abcdef0123456789abcdef"}'
```

第二条返回一段 JWT(`{"token":"eyJ..."}`)就说明 **host / port / server_key 三件套全对**。
返回 `401 Unauthorized` → server_key 错了。连不上 → 端口/防火墙问题。

> ⚠️ **device id 至少 10 个字符**,否则 Nakama 拒绝。

### homelab 特有的三件事

1. **不要把 7350 直接暴露公网**。要么只在内网/Tailscale/WireGuard 里访问,要么套一层带 TLS 的反代。
2. **换掉默认 `server_key`**。它是明文写在客户端二进制里的,不算秘密,但默认值等于门没关。用 `--socket.server_key "your-game-2026"`。
3. **反代必须支持 WebSocket upgrade**。Nakama 的实时功能全走 WS,反代配错的话 REST 能通、socket 却连不上——这是最常见的"看起来登录成功了但游戏进不去"。

<details>
<summary>Caddy / nginx 反代片段(点开)</summary>

Caddy(自动 TLS,推荐):
```
nakama.example.com {
    reverse_proxy 127.0.0.1:7350
}
```
Caddy 默认处理 WebSocket upgrade,不用额外配。

nginx:
```nginx
location / {
    proxy_pass http://127.0.0.1:7350;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # 这两行是关键
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;                    # 别让长连接被掐
}
```
</details>

---

## 2. Step 1 — 建 Godot 项目

```bash
cd /Users/matthew/projects/meirongdev/godot-games
mkdir -p games/first-nakama-game
```

在 Godot 里 New Project 指向这个目录,Renderer 选 **Compatibility**(想以后导 Web 版就必须选它)。

建议的目录结构(照抄 demo 的分层,这个分层是对的):

```
games/first-nakama-game/
├── addons/
│   └── com.heroiclabs.nakama/     # 官方客户端,原样放,不要改
├── src/
│   ├── autoload/
│   │   ├── ServerConnection.gd    # ★ 网络门面,全局唯一入口
│   │   └── NakamaConfig.gd        # 连接配置
│   ├── ui/                        # 登录、大厅、聊天、通知
│   ├── world/                     # 场景、角色、玩法
│   └── net/                       # OpCode 定义、数据包结构
├── nakama.cfg                     # 你的 homelab 地址(加 .gitignore)
├── nakama.cfg.example             # 提交这个
└── project.godot
```

**分层原则(demo 最值得学的一点):**
> 游戏逻辑**永远不直接碰** `NakamaClient` / `NakamaSocket`。
> 一切走 `ServerConnection` 这个 Autoload。

好处很实在:换服务器地址只改一处;想写单机模式或自动化测试时,能整个替换掉 `ServerConnection`;网络出问题时只有一个文件要看。

---

## 3. Step 2 — 装客户端 addon

```bash
cd /tmp
git clone --depth 1 https://github.com/heroiclabs/nakama-godot.git
cp -r nakama-godot/addons/com.heroiclabs.nakama \
      /Users/matthew/projects/meirongdev/godot-games/games/first-nakama-game/addons/
```

然后在 Godot 里:**Project → Project Settings → Globals(Autoload)**,添加

| Path | Node Name |
|---|---|
| `res://addons/com.heroiclabs.nakama/Nakama.gd` | `Nakama` |
| `res://src/autoload/ServerConnection.gd` | `ServerConnection` |

**顺序很重要**:`Nakama` 必须排在 `ServerConnection` 前面,否则 `ServerConnection._ready()` 里调 `Nakama.create_client()` 会拿到 null。

> `addons/com.heroiclabs.nakama/Satori/` 是 Heroic Labs 的 LiveOps 商业产品(A/B 测试、远程配置),自建 homelab 用不到,可以整个删掉减小体积。

### 3.1 本地改动(重新拷 addon 后必须重新打上)

vendor 进来的 SDK 有**一处**本地修改。它不是优化,是 Web 版能不能用的开关 ——
重新从 master 拷 `addons/` 会把它冲掉,而桌面运行和 Python e2e 都测不出来。

| 文件 | 改动 | 为什么 |
|---|---|---|
| `client/NakamaHTTPAdapter.gd` · `send_async()` | Web 平台上 `req.accept_gzip = false` | 见下 |

Web 上 Godot 的 `HTTPRequest` 底层走浏览器的 `fetch`,响应体**已经被浏览器解过
gzip**,但 Chrome 仍然在 `Response.headers` 里保留 `Content-Encoding: gzip`。
`accept_gzip` 默认 `true`,Godot 看见这个头就再解一次 —— 解一段没压缩的字节,
必然失败:

```
ERROR: Condition "err != 0 && err != 1" is true. Returning: FAILED
   at: _process (core/io/stream_peer_gzip.cpp:117)
=== Nakama : DEBUG === Request 1 failed with result: 8, response code: 200
```

`result=8` 是 `RESULT_BODY_DECOMPRESS_FAILED`,body 长度 0,而 **response code 是
200** —— 服务端明明成功了,客户端就是拿不到响应,登录永远卡在「连接中…」。
Nakama 默认对 `/v2/*` 开 gzip,所以每一个请求都踩。

桌面版自己收发 HTTP,拿到的是真 gzip 字节,解得开;`tools/e2e_match.py` 根本
不经过 Godot。**只有 Web 版会炸**,这就是 2026-08-27 上线时两层测试全绿、
页面一开就废的原因。

关掉只是让 Godot 别重复解压,压缩仍由浏览器与服务器协商,不损失带宽。

两道门禁盯着它,不靠人记:

- `tools/build_web.sh` 构建前 grep 这一行,没有就拒绝出包;
- `tools/web_smoke.py` 在真浏览器里把制品跑进大厅,是最后一道。

---

## 4. Step 3 — 配置不要写死

demo 把 IP 硬编码在 `ServerConnection.gd` 里。你在 homelab 场景下会频繁在「本机 docker」「内网 IP」「域名」之间切,硬编码会很烦。

**`nakama.cfg.example`**(提交到 git):
```ini
[nakama]
host="127.0.0.1"
port=7350
scheme="http"
server_key="defaultkey"
```

**`nakama.cfg`**(写进 `.gitignore`,填你 homelab 的真实值):
```ini
[nakama]
host="nakama.lan"
port=7350
scheme="https"
server_key="your-game-2026"
```

**`src/autoload/NakamaConfig.gd`**:
```gdscript
class_name NakamaConfig
extends RefCounted

const PATH := "res://nakama.cfg"

var host := "127.0.0.1"
var port := 7350
var scheme := "http"
var server_key := "defaultkey"

static func load_or_default() -> NakamaConfig:
	var cfg := NakamaConfig.new()
	var file := ConfigFile.new()
	if file.load(PATH) == OK:
		cfg.host       = file.get_value("nakama", "host", cfg.host)
		cfg.port       = file.get_value("nakama", "port", cfg.port)
		cfg.scheme     = file.get_value("nakama", "scheme", cfg.scheme)
		cfg.server_key = file.get_value("nakama", "server_key", cfg.server_key)

	# 命令行覆盖:同一台机器开两个客户端联调时很好用
	#   godot --path . -- --nakama-host=192.168.1.50
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nakama-host="):
			cfg.host = arg.split("=", true, 1)[1]
	return cfg
```

---

## 5. Step 4 — `ServerConnection`:全局网络门面

这是整个项目的核心文件。下面是**可直接运行的 Godot 4 版本**,对应 demo 里那个 478 行的 Godot 3 `ServerConnection.gd`。

```gdscript
extends Node
## Nakama 网络门面(Autoload)。所有和服务器的通信都从这里进出。
##
## 用法:
##     var err := await ServerConnection.login_async(email, password)
##     if err != OK:
##         push_error(ServerConnection.error_message)

const SESSION_PATH := "user://session.cfg"

## 自定义 OpCode。Nakama 内置码全部 <= 0,自定义的从 1 开始。
enum OpCodes {
	UPDATE_POSITION = 1,
	UPDATE_INPUT    = 2,
	UPDATE_STATE    = 3,
	DO_SPAWN        = 4,
	INITIAL_STATE   = 5,
}

signal socket_connected
signal socket_closed
signal presences_changed
signal state_updated(positions: Dictionary, inputs: Dictionary)
signal player_spawned(user_id: String, data: Dictionary)
signal chat_message_received(sender_id: String, message: String)

## 最近一次失败的错误信息。所有 *_async 返回 != OK 时读这里。
var error_message := ""
## user_id -> NakamaRTAPI.UserPresence
var presences := {}

var _client: NakamaClient
var _session: NakamaSession
var _socket: NakamaSocket
var _match_id := ""
var _channel_id := ""


func _ready() -> void:
	var cfg := NakamaConfig.load_or_default()
	_client = Nakama.create_client(cfg.server_key, cfg.host, cfg.port, cfg.scheme)
	_client.timeout = 10
	_client.auto_refresh = true          # 快过期时自动用 refresh_token 续期
	_client.auto_refresh_seconds = 300


# ------------------------------------------------------------------ 认证

## 邮箱注册。返回 OK 或错误码。
func register_async(email: String, password: String) -> int:
	return await _authenticate(email, password, true)


## 邮箱登录(不自动建号)。
func login_async(email: String, password: String) -> int:
	return await _authenticate(email, password, false)


## 设备认证:免注册,一键开玩。做家庭 / 本地多人游戏时这个最省事。
func login_device_async() -> int:
	# Nakama.get_device_id() 生成并持久化一个稳定 id 到 user://nakama_device_id
	# (master 分支才有;v3.4.0 请用 OS.get_unique_id())
	var session = await _client.authenticate_device_async(Nakama.get_device_id())
	var err := _check(session)
	if err == OK:
		_session = session
		_save_session()
	return err


func _authenticate(email: String, password: String, create: bool) -> int:
	var session = await _client.authenticate_email_async(email, password, null, create)
	var err := _check(session)
	if err == OK:
		_session = session
		_save_session()
	return err


## 尝试用磁盘上缓存的 token 恢复会话,免去每次启动都登录。
func try_restore_session_async() -> int:
	var file := ConfigFile.new()
	if file.load(SESSION_PATH) != OK:
		return ERR_FILE_NOT_FOUND

	var token: String = file.get_value("session", "token", "")
	if token.is_empty():
		return ERR_FILE_NOT_FOUND

	var session := NakamaClient.restore_session(token)
	if session.expired:
		# restore_session 只吃 auth_token,拿不回 refresh_token,
		# 所以要自己存一份,过期时手动 refresh。
		var refresh: String = file.get_value("session", "refresh_token", "")
		if refresh.is_empty():
			return ERR_INVALID_DATA
		session = await _client.session_refresh_async(NakamaClient.restore_session(refresh))
		var err := _check(session)
		if err != OK:
			return err

	_session = session
	_save_session()
	return OK


func _save_session() -> void:
	var file := ConfigFile.new()
	file.set_value("session", "token", _session.token)
	file.set_value("session", "refresh_token", _session.refresh_token)
	file.save(SESSION_PATH)


func get_user_id() -> String:
	return _session.user_id if _session else ""


func get_username() -> String:
	return _session.username if _session else ""


# ------------------------------------------------------------------ Socket

## 建立实时连接。必须先登录。
func connect_to_server_async() -> int:
	_socket = Nakama.create_socket_from(_client)
	_socket.connected.connect(func(): socket_connected.emit())
	_socket.closed.connect(_on_socket_closed)
	_socket.received_error.connect(func(e): push_error("[socket] %s" % e))
	_socket.received_match_state.connect(_on_match_state)
	_socket.received_match_presence.connect(_on_match_presence)
	_socket.received_channel_message.connect(_on_channel_message)

	var result = await _socket.connect_async(_session)
	return _check(result)


func disconnect_from_server_async() -> void:
	if _socket and _socket.is_connected_to_host():
		if not _channel_id.is_empty():
			await _socket.leave_chat_async(_channel_id)
		if not _match_id.is_empty():
			await _socket.leave_match_async(_match_id)
		_socket.close()
	_match_id = ""
	_channel_id = ""
	presences.clear()


func _on_socket_closed() -> void:
	presences.clear()
	socket_closed.emit()


# ------------------------------------------------------------------ 对局

## 加入世界。match id 由服务端 RPC 决定(见第 8 节的 world_rpc.lua)。
func join_world_async() -> int:
	var rpc_result = await _client.rpc_async(_session, "get_world_id", "")
	var err := _check(rpc_result)
	if err != OK:
		return err

	var world_id: String = rpc_result.payload
	var m = await _socket.join_match_async(world_id)
	err = _check(m)
	if err != OK:
		return err

	_match_id = m.match_id
	for p in m.presences:
		presences[p.user_id] = p
	presences_changed.emit()
	return OK


## 发送一条对局消息。data 会被 JSON 序列化。
func send_state(op_code: int, data: Dictionary) -> void:
	if _socket and not _match_id.is_empty():
		# 注意:send_match_state_async 的第三个参数是 String,不是 PackedByteArray。
		# 要发二进制请用 send_match_state_raw_async。
		_socket.send_match_state_async(_match_id, op_code, JSON.stringify(data))


func _on_match_state(state: NakamaRTAPI.MatchData) -> void:
	var payload = JSON.parse_string(state.data)
	if payload == null:
		return
	match state.op_code:
		OpCodes.UPDATE_STATE:
			state_updated.emit(payload.get("pos", {}), payload.get("inp", {}))
		OpCodes.INITIAL_STATE:
			state_updated.emit(payload.get("pos", {}), payload.get("inp", {}))
		OpCodes.DO_SPAWN:
			player_spawned.emit(payload.get("id", ""), payload)


func _on_match_presence(event: NakamaRTAPI.MatchPresenceEvent) -> void:
	for p in event.joins:
		presences[p.user_id] = p
	for p in event.leaves:
		presences.erase(p.user_id)
	presences_changed.emit()


# ------------------------------------------------------------------ 聊天

func join_chat_async(room := "world") -> int:
	var channel = await _socket.join_chat_async(room, NakamaSocket.ChannelType.Room, true, false)
	var err := _check(channel)
	if err == OK:
		_channel_id = channel.id
	return err


func send_chat_async(text: String) -> void:
	if not _channel_id.is_empty():
		await _socket.write_chat_message_async(_channel_id, {"msg": text})


func _on_channel_message(msg: NakamaAPI.ApiChannelMessage) -> void:
	if msg.code != 0:      # 0 = 普通聊天;其他是加入/离开等系统消息
		return
	var content = JSON.parse_string(msg.content)
	if content and content.has("msg"):
		chat_message_received.emit(msg.sender_id, content["msg"])


# ------------------------------------------------------------------ 存档

## 存一份玩家数据。value 必须是能 JSON 化的 Dictionary。
func save_async(collection: String, key: String, value: Dictionary) -> int:
	var obj := NakamaWriteStorageObject.new(
		collection, key,
		1,                      # permission_read: 1=仅自己 2=公开可读
		1,                      # permission_write: 0=只有服务端能写 1=owner 可写
		JSON.stringify(value),
		""                      # version:传上次读到的 version 可做乐观锁
	)
	var acks = await _client.write_storage_objects_async(_session, [obj])
	return _check(acks)


## 读回玩家数据。找不到返回空 Dictionary。
func load_async(collection: String, key: String) -> Dictionary:
	var id := NakamaStorageObjectId.new(collection, key, _session.user_id)
	var result = await _client.read_storage_objects_async(_session, [id])
	if _check(result) != OK or result.objects.is_empty():
		return {}
	var parsed = JSON.parse_string(result.objects[0].value)
	return parsed if parsed is Dictionary else {}


# ------------------------------------------------------------------ 错误处理

## Nakama 没有异常机制,所有返回值都要 is_exception() 检查一遍。
## 把它收敛到这一个函数里,别在业务代码里到处写。
func _check(result) -> int:
	if result == null:
		error_message = "no response"
		return ERR_CANT_CONNECT

	if result.is_exception():
		var e: NakamaException = result.get_exception()
		error_message = e.message
		push_error("[Nakama] status=%d grpc=%d %s" % [e.status_code, e.grpc_status_code, e.message])
		match e.status_code:
			-1:  return ERR_CANT_CONNECT      # 网络层根本没通
			401: return ERR_UNAUTHORIZED      # server_key 错 / session 过期
			404: return ERR_DOES_NOT_EXIST
			_:   return FAILED

	error_message = ""
	return OK
```

### 关于 `_check()` —— 这是 Godot 版 Nakama 最容易写错的地方

GDScript **没有异常**。Nakama 客户端的做法是:所有 `*_async` 都返回一个对象,失败时该对象的 `is_exception()` 为 `true`。

```gdscript
# ❌ 错:失败时 session.user_id 是空串,后面所有调用静默出错
var session = await client.authenticate_email_async(email, password)
print(session.user_id)

# ✅ 对:每一次都检查
var session = await client.authenticate_email_async(email, password)
if session.is_exception():
    push_error(session.get_exception().message)
    return
```

demo 里专门为此做了个 `ExceptionHandler` 委托类,思路完全正确——上面的 `_check()` 就是它的简化版。

---

## 6. Step 5 — 选架构:两条路线

这是接下来最重要的决定。**先选路线,再写玩法代码**,选错了要重写。

### 路线 A:`NakamaMultiplayerBridge`(中继模式)

Nakama 当纯粹的**消息中继 + 打洞替代品**。服务器不理解你的游戏,只负责把 A 的包转给 B。客户端用 Godot 原生的高层多人 API(`@rpc`、`MultiplayerSynchronizer`)。

```gdscript
var bridge := NakamaMultiplayerBridge.new(_socket)
bridge.match_joined.connect(_on_match_joined)
bridge.match_join_error.connect(func(e): push_error(e.message))

multiplayer.multiplayer_peer = bridge.multiplayer_peer

# 三选一:
await bridge.create_match()                  # 建私有房,拿到 bridge.match_id 分享给别人
await bridge.join_match("<match_id>")        # 用房间码加入
await bridge.join_named_match("family-room") # 具名房:同名自动进同一间 ← 家庭局神器
```

之后就是**纯 Godot 多人开发**:

```gdscript
@rpc("any_peer", "call_local", "reliable")
func place_piece(row: int, col: int) -> void:
	board[row][col] = multiplayer.get_remote_sender_id()
	_refresh_board()
```

**优点**
- 上手最快。Godot 的多人教程能 100% 直接用。
- 服务端零代码。
- `join_named_match("family-room")` 让"全家都进同一间"变成一行代码。

**缺点**
- 服务器不校验任何东西 → 谁都能改包作弊。
- 房主(peer 1)掉线,整局就没了。
- 状态不落服务端,断线重连接不回去。

### 路线 B:权威 match handler(demo 走的路)

在 Nakama 里写一个服务端 match handler(Lua / TypeScript / Go),它**持有游戏状态、跑固定 tick 循环、广播权威状态**。客户端只发输入,只渲染服务器发回来的状态。

```
客户端 ──输入(OpCode 2)──▶ match_loop() ──▶ 更新 state
客户端 ◀──权威状态(OpCode 3)── 每秒 10 次广播
```

**优点**
- 服务器说了算,作弊基本堵死。
- 玩家全掉线,世界照样在;重连能接回来。
- 状态可以直接存 Nakama storage(demo 就是在 `match_leave` 里把位置存下来的)。

**缺点**
- 得写服务端代码,还要学 Nakama 的 runtime API。
- 必须自己设计并维护 OpCode 协议(demo 专门写了 `docs/packets.md`)。
- 天然有一个 tick 的延迟,操作手感要额外做客户端预测/插值。

### 怎么选

| 你的情况 | 选 |
|---|---|
| 第一个 Godot 游戏,想两周内能玩上 | **A** |
| 回合制(棋牌、猜词、答题) | **A**,回合制作弊空间本来就小 |
| 家里人一起玩,信任度 100% | **A** |
| 想要持久世界 / 排行榜 / 断线重连 | **B** |
| 实时动作、需要防作弊 | **B** |
| 想学 Nakama 的完整能力 | 先 A 跑通,再把同一个游戏改成 B |

**我的建议:先做路线 A。** 第一个游戏的目标是"跑起来、玩得开心",不是"架构完美"。等你对 Nakama 的 session/socket/storage 有肌肉记忆了,再拿同一个游戏练路线 B——这时对比会非常直观。

---

## 7. 路线 A 完整最小例子

用具名房间做一个「全家共享白板」,能验证整条链路。

**`src/main/Lobby.gd`**
```gdscript
extends Control

@onready var status: Label = $VBox/Status
@onready var room_edit: LineEdit = $VBox/RoomEdit

var _bridge: NakamaMultiplayerBridge


func _ready() -> void:
	status.text = "连接中…"

	# 1) 认证:设备认证,家庭局不需要注册流程
	if await ServerConnection.login_device_async() != OK:
		status.text = "登录失败:%s" % ServerConnection.error_message
		return

	# 2) 建立实时连接
	if await ServerConnection.connect_to_server_async() != OK:
		status.text = "socket 失败:%s" % ServerConnection.error_message
		return

	status.text = "已连接,用户名 %s" % ServerConnection.get_username()


func _on_join_pressed() -> void:
	# 3) 把 socket 接到 Godot 的高层多人 API 上
	_bridge = NakamaMultiplayerBridge.new(ServerConnection.get_socket())
	_bridge.match_joined.connect(_on_match_joined)
	_bridge.match_join_error.connect(func(e): status.text = "加入失败:%s" % e.message)

	multiplayer.multiplayer_peer = _bridge.multiplayer_peer
	multiplayer.peer_connected.connect(func(id): print("玩家 %d 进来了" % id))

	# 具名房:输一样的名字就进同一间,不用交换房间码
	await _bridge.join_named_match(room_edit.text)


func _on_match_joined() -> void:
	status.text = "已进入房间 %s(我的 peer id=%d)" % [
		_bridge.match_id, multiplayer.get_unique_id()
	]
	get_tree().change_scene_to_file("res://src/world/Whiteboard.tscn")
```

给 `ServerConnection` 补一个 getter:
```gdscript
func get_socket() -> NakamaSocket:
	return _socket
```

**`src/world/Whiteboard.gd`**
```gdscript
extends Node2D

var _lines := {}   # peer_id -> Line2D


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		draw_point.rpc(event.position)


@rpc("any_peer", "call_local", "unreliable_ordered")
func draw_point(pos: Vector2) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not _lines.has(peer):
		var line := Line2D.new()
		line.width = 4
		line.default_color = Color.from_hsv(hash(peer) % 360 / 360.0, 0.7, 0.9)
		add_child(line)
		_lines[peer] = line
	_lines[peer].add_point(pos)
```

**验证方式:** 在 Godot 里 `Debug → Run Multiple Instances → 2`,两个窗口输同一个房间名,一边画另一边应该同步出现。

---

## 8. 路线 B:权威服务端

### 8.1 OpCode 协议

先定协议,再写代码。**两端各维护一份,必须手工保持同步**——这是路线 B 最大的维护成本。demo 专门写了 `docs/packets.md` 记录每个 OpCode 的收发结构,你也应该这么做。

| OpCode | 名字 | 方向 | 载荷 |
|---|---|---|---|
| 1 | UPDATE_POSITION | C→S | `{id, pos:{x,y}}` |
| 2 | UPDATE_INPUT | C→S | `{id, inp}` |
| 3 | UPDATE_STATE | S→C | `{pos:{...}, inp:{...}}` |
| 4 | DO_SPAWN | C↔S | `{id, nm, col}` |
| 5 | INITIAL_STATE | S→C | 全量快照 |

规则:
- **Nakama 内置 OpCode 全部 ≤ 0**,你的自定义码从 1 开始。
- 键名用缩写(`pos` 而不是 `position`)。10 tick/s × N 个玩家,JSON 的键名开销是实打实的。
- 想更省带宽就上 `send_match_state_raw_async` + `var_to_bytes()`,但调试难度陡增。**先用 JSON 跑通**。

### 8.2 Lua match handler 骨架

放在服务端的 `modules/` 目录(Nakama 启动时自动加载):

```lua
-- modules/world_control.lua
local nk = require("nakama")
local M = {}

local OpCodes = {
    update_input  = 2,
    update_state  = 3,
    do_spawn      = 4,
    initial_state = 5,
}

-- 对局创建时调用一次。返回 (初始状态, tickrate, label)
function M.match_init(_, _)
    local state = { presences = {}, positions = {}, inputs = {} }
    return state, 10, "family-world"     -- 10 tick/s
end

-- 有人想进来。返回 (state, 是否允许, 拒绝理由)
function M.match_join_attempt(_, _, _, state, presence, _)
    if state.presences[presence.user_id] ~= nil then
        return state, false, "已在别处登录"
    end
    return state, true
end

function M.match_join(_, _, _, state, presences)
    for _, p in ipairs(presences) do
        state.presences[p.user_id] = p
        state.positions[p.user_id] = { x = 0, y = 0 }
        state.inputs[p.user_id]    = { dir = 0 }
    end
    return state
end

-- 有人离开:趁机把进度存进 storage,下次回来能接上
function M.match_leave(_, _, _, state, presences)
    for _, p in ipairs(presences) do
        nk.storage_write({{
            collection = "player_data",
            key        = "position",
            user_id    = p.user_id,
            value      = state.positions[p.user_id],
            permission_read  = 1,
            permission_write = 0,   -- 只有服务端能写 = 客户端改不了存档
        }})
        state.presences[p.user_id] = nil
        state.positions[p.user_id] = nil
        state.inputs[p.user_id]    = nil
    end
    return state
end

-- 每秒被调用 tickrate 次。整个游戏的心脏。
function M.match_loop(_, dispatcher, _, state, messages)
    -- 1) 消费这一 tick 收到的所有客户端消息
    for _, message in ipairs(messages) do
        local data = nk.json_decode(message.data)
        local uid  = message.sender.user_id

        if message.op_code == OpCodes.update_input then
            if state.inputs[uid] then
                state.inputs[uid].dir = data.inp
            end
        elseif message.op_code == OpCodes.do_spawn then
            -- 只给刚进来的这个人发全量快照
            dispatcher.broadcast_message(
                OpCodes.initial_state,
                nk.json_encode({ pos = state.positions, inp = state.inputs }),
                { message.sender }
            )
        end
    end

    -- 2) 推进模拟
    for uid, input in pairs(state.inputs) do
        state.positions[uid].x = state.positions[uid].x + input.dir * 10
    end

    -- 3) 向所有人广播权威状态
    dispatcher.broadcast_message(
        OpCodes.update_state,
        nk.json_encode({ pos = state.positions, inp = state.inputs })
    )

    return state
end

function M.match_terminate(_, _, _, state, _)  return state end
function M.match_signal(_, _, _, state, data)  return state, data end

return M
```

> ⚠️ 这 **7 个回调一个都不能少**(`match_init`、`match_join_attempt`、`match_join`、`match_leave`、`match_loop`、`match_terminate`、`match_signal`),缺一个 Nakama 启动时就报错。

### 8.3 让客户端找到这个对局

客户端不知道 match id,得问服务端要。这就是 demo 里 `world_rpc.lua` 的作用:

```lua
-- modules/world_rpc.lua
local nk = require("nakama")

-- 有就返回,没有就建一个。保证全服只有一个"世界"。
local function get_world_id(_, _)
    local matches = nk.match_list(1, true, "family-world")
    if matches[1] ~= nil then
        return matches[1].match_id
    end
    return nk.match_create("world_control", {})
end

nk.register_rpc(get_world_id, "get_world_id")
```

客户端侧就是上面 `ServerConnection.join_world_async()` 里那两步:先 `rpc_async(session, "get_world_id", "")` 拿 id,再 `join_match_async(id)`。

### 8.4 把模块挂上去

```yaml
# docker-compose.yml 里给 nakama 服务加卷挂载
services:
  nakama:
    volumes:
      - ./modules:/nakama/data/modules
```

改完 Lua 要重启 Nakama 容器。看加载有没有成功:

```bash
docker compose logs -f nakama | grep -i -E "module|lua|error"
```

> **Lua vs TypeScript vs Go?** Lua 零构建步骤,改完重启就生效,学习期最合适。TypeScript 有类型检查但要 esbuild 打包。Go 性能最好但要编译成 `.so` 插件。**先用 Lua。**

---

## 9. 其他你迟早会用到的能力

`ServerConnection` 里已经有 storage 和 chat 了,补几个常用的:

### 排行榜
```gdscript
# 排行榜本身要在服务端先建(Lua: nk.leaderboard_create),或在 Console 里建
func submit_score_async(board_id: String, score: int) -> int:
	var r = await _client.write_leaderboard_record_async(_session, board_id, score)
	return _check(r)

func top_scores_async(board_id: String, limit := 10) -> Array:
	var r = await _client.list_leaderboard_records_async(_session, board_id, [], null, limit)
	return r.records if _check(r) == OK else []
```

### 通知(服务端推给客户端的弹窗)
```gdscript
_socket.received_notification.connect(func(n: NakamaAPI.ApiNotification):
	print("[%s] %s" % [n.subject, n.content])
)
```

### 好友 / 群组
`add_friends_async`、`list_friends_async`、`join_group_async` —— 做家庭游戏时,「群组」正好对应「一家人」。

### 权限速查(存档最容易配错的地方)

| | `permission_read` | `permission_write` |
|---|---|---|
| 0 | 无人可读(仅服务端) | **仅服务端可写** ← 存分数用这个 |
| 1 | 仅 owner 可读 | owner 可写 |
| 2 | 所有人可读 ← 排行榜展示用 | — |

**存和分数/进度相关的数据一律用 `permission_write = 0`**,然后通过 RPC 让服务端来写。否则玩家可以直接改自己的存档。

---

## 10. 部署与网络实操(homelab 专属)

### Web 导出(想让家里人点个链接就玩)

这是家庭游戏最好的分发方式——不用装任何东西。但有三个硬约束:

1. **Renderer 必须是 Compatibility**。Forward+ 导不了 Web。
2. **https 页面只能连 wss**。如果游戏页面走 https,`nakama.cfg` 里 `scheme` 必须是 `https`(客户端会自动把 socket 升级成 `wss`)。混用会被浏览器直接拦掉,控制台报 mixed content。
3. **CORS**。Nakama 默认允许所有来源,一般不用管;如果你在反代里加了 CORS 头,别把它弄拧了。

托管:Godot Web 导出就是一堆静态文件,homelab 上随便一个 nginx/Caddy 静态站点就够。

### 同一台机器开多个客户端联调

```bash
# Godot 编辑器:Debug → Run Multiple Instances → 2
# 或者命令行:
godot --path games/first-nakama-game -- --nakama-host=192.168.1.50 &
godot --path games/first-nakama-game -- --nakama-host=192.168.1.50 &
```

⚠️ 用**设备认证**时,同一台机器两个实例会拿到同一个 device id → 同一个账号 → 权威模式下 `match_join_attempt` 会拒掉第二个("已在别处登录")。联调时改用邮箱认证,或给 `Nakama.get_device_id()` 的结果拼个实例后缀。

### 手机/平板加入

homelab 的内网 IP 在同一个 WiFi 下直接能用。出了家门要么上 Tailscale/WireGuard(推荐,省掉端口转发和 TLS 证书的所有麻烦),要么公网域名 + Caddy 自动 TLS。

---

## 11. 排错速查表

| 症状 | 大概率原因 | 怎么查 |
|---|---|---|
| `is_exception()` 为 true,`status_code = -1` | 网络根本没通:host/port 错、防火墙、容器没起 | 先跑第 1 节那两条 curl |
| `status_code = 401` | server_key 不匹配,或 session 过期 | 比对客户端 `server_key` 和服务端 `--socket.server_key` |
| REST 能通,socket 连不上 | 反代没配 WebSocket upgrade | nginx 加 `Upgrade`/`Connection` 头;或直连 7350 试试 |
| Web 版报 mixed content | https 页面连了 ws:// | `nakama.cfg` 的 `scheme` 改 `https` |
| `Nakama` 是 null | Autoload 顺序错了 | Project Settings 里把 `Nakama` 拖到 `ServerConnection` 上面 |
| 存进去的数据读出来是空 | 存的不是 JSON Dictionary | `value` 必须是 `JSON.stringify(dict)`;`Color` 直接 stringify 会变成一串数字而不是对象 |
| Lua 模块没生效 | 挂载路径错 / 语法错误 | `docker compose logs nakama \| grep -i error` |
| 权威模式下第二个客户端进不去 | 两个实例同一个 device id | 换邮箱认证联调 |
| 状态更新一卡一卡 | tickrate 10 但客户端没插值 | 客户端对收到的位置做 `lerp`,别直接赋值 |
| 编译报几十个语法错 | 抄了 Godot 3 的 demo 代码 | 见第 0 节 |

**万能调试开关:**
```gdscript
_client.logger.set_level(NakamaLogger.LOG_LEVEL.DEBUG)  # 打印每一个请求/响应
```

---

## 12. 建议的学习路线

不要一上来就做多人游戏。按这个顺序,每一步都有能跑的东西:

| 阶段 | 目标 | 大概 |
|---|---|---|
| **1. 纯单机** | 不碰 Nakama。做个能玩的单机小游戏,熟悉节点、场景、信号、输入 | 1–2 周 |
| **2. 只做认证** | 加一个登录界面。跑通 `create_client` → `authenticate` → 显示用户名 | 1 天 |
| **3. 加存档** | 用 storage 存单机游戏的进度/最高分。理解 collection/key/permission | 2 天 |
| **4. 通实时** | 连 socket,做一个只有聊天框的场景。看到别人发的消息 = 实时链路通了 | 2 天 |
| **5. 路线 A 多人** | 用 `NakamaMultiplayerBridge` 把第 1 步的游戏改成多人 | 1 周 |
| **6. 排行榜** | 加 leaderboard,家里人比分数 | 2 天 |
| **7. 路线 B** | 写第一个 Lua match handler,把同一个游戏改成权威模式 | 1–2 周 |

**每个阶段结束都 commit 一次。** 第 5 步做砸了想回到第 4 步的可运行状态,这个习惯能救你。

---

## 13. 参考资料

- [Nakama 官方文档](https://heroiclabs.com/docs/nakama/) — 服务端配置、runtime API
- [Godot 客户端指南](https://heroiclabs.com/docs/nakama/client-libraries/godot/) — ⚠️ 有个错:storage 示例里 `NakamaWriteStorageObject.new("hats","favorite_hats",1,1)` 少传参数,实际构造函数要 **6 个参数全传**(collection, key, read, write, value, version)
- [nakama-godot 源码](https://github.com/heroiclabs/nakama-godot) — API 有疑问时直接读 `addons/com.heroiclabs.nakama/` 下的源码,比文档准
- [nakama-godot-demo](https://github.com/heroiclabs/nakama-godot-demo) — 架构参考,**Godot 3 语法**
  - `godot/src/Autoload/ServerConnection.gd` — 门面模式,本文第 5 节的原型
  - `nakama/modules/world_control.lua` — 权威 match handler 完整实现
  - `docs/packets.md` — 协议文档该怎么写
- [Godot 高层多人 API](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html) — 路线 A 必读
- [Nakama Lua Runtime 参考](https://heroiclabs.com/docs/nakama/server-framework/lua-runtime/) — 写 match handler 时查这个
