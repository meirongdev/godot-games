# 架构

一句话:**服务端说了算,客户端只负责显示,以及把玩家的动作发出去。**

胜负、谁淘汰、轮到谁、房间里有谁,全部由服务端算完广播下来。客户端改不了结果,
也不需要相信别的客户端 —— 家里人用手机开着页面互相打,这样最省心。

---

## 1. 三个进程

```
              浏览器 / 桌面客户端
                      │
                      │  一个域名,同源(为什么见 deployment-contract.md §3.3.1)
                      ▼
            ┌────────────────────┐
            │   网关 / 反向代理   │
            └────────────────────┘
              │              │
        /v2/* 和 /ws       其余全部
              │              │
              ▼              ▼
     ┌────────────────┐  ┌──────────────────┐
     │ Nakama  :7350  │  │  nginx    :8080  │
     │  + 我们的 Lua  │  │  静态页 + wasm    │
     └────────────────┘  └──────────────────┘
              │              ▲
              ▼              └── ghcr.io/…/godot-games-web 镜像
     ┌────────────────┐
     │   Postgres     │   账号、大厅聊天记录
     └────────────────┘
```

- **Nakama** 是现成的游戏服务器(3.40.x),我们只往它里面塞 Lua 模块。
  它同时提供 HTTP API 和 WebSocket,**同一个 7350 端口**。
- **nginx** 只发静态文件,没有任何状态。它挂了只是页面打不开,进行中的对局不受影响。
- **房间状态不进数据库**,活在 Nakama 进程内存里(见 §4)。Postgres 只存账号和聊天。
- `/v2/*` 和 `/ws` 这两个路径不是我们选的,是 Nakama SDK 写死的。

本地开发用 `nakama/docker-compose.yml`(Nakama + Postgres),
`tools/serve_web.py` 复现同一套路由,所以本地拓扑和线上一致。

---

## 2. 两条通道

客户端和服务端之间只有两条路,分工是固定的:

| | HTTP(`/v2/*`) | WebSocket(`/ws`) |
|---|---|---|
| 用来做什么 | 登录、改名、刷 token、大厅 RPC、拉聊天历史 | 进房、房间里的一切、大厅聊天与在线名单 |
| 谁发起 | 客户端问一句,服务端答一句 | 双向,服务端随时能推 |
| 具体内容 | `authenticate_device` / `update_account` / `session_refresh` / RPC `create_room` `list_rooms` `list_games` | `join_match` / `send_match_state` / 服务端广播 / 大厅频道消息 |

两个要点:

1. **房间列表没有推送**,只能 HTTP 轮询 —— 大厅每 3 秒拉一次 `list_rooms`。
2. **房间页一次 HTTP 都不发**,全靠 WebSocket。所以 socket 一断,房间页自己
   什么都不知道 —— 这就是为什么需要 §8 的巡检。

---

## 3. 客户端(Godot 4)

### 场景怎么走

```
Login.tscn ──进入大厅──▶ Lobby.tscn ──建房 / 点房间进去──▶ Room.tscn
                            ▲                                 │
                            └──── 退出 / 房间没了 ─────────────┘
                                                              │
                                          RoomController 按游戏 id 挂载
                                                              ▼
                                                      RpsGame.tscn
                                                     (继承 GameBase)
```

### 分层

```
     场景(Login / Lobby / RoomController / RpsGame)
          │  只用信号和 await,不碰 Nakama
          ▼
     ServerConnection.gd   ← autoload,全局唯一的网络门面
          │
          ▼
     addons/com.heroiclabs.nakama/   ← 官方 SDK,原样放着不改
```

**规矩:除了 `ServerConnection.gd`,没有任何文件可以 `require` 到 Nakama。**
游戏场景(`RpsGame`)连 `ServerConnection` 都不碰,只对着 `GameBase` 的
`send_to_server` 信号发消息,由 `RoomController` 转出去。

| 文件 | 管什么 |
|---|---|
| `src/autoload/ServerConnection.gd` | 连接、登录、大厅、房间、断线自愈。所有网络细节收敛在这里 |
| `src/autoload/NakamaConfig.gd` | 服务器地址从哪来:Web 版从页面地址推,源码运行读 `nakama.cfg` |
| `src/net/OpCodes.gd` | 消息号,**和服务端手工同步** |
| `src/net/JsonSafe.gd` | Lua 的空表 `{}` 解出来不是数组,读服务端数组一律走这里 |
| `src/net/Probe.gd` | 诊断记录通道 —— 客户端主动上报事实,给测试当断言和点击靶子(见 CONTEXT.md) |
| `src/room/RoomController.gd` | 房间通用部分:花名册、准备、开局、结算。加新游戏不改它的逻辑,只加一行场景路径 |
| `src/room/GameBase.gd` | 游戏场景基类。定义了游戏能做的全部事情:收消息、发消息 |

---

## 4. 服务端(Nakama Lua 模块)

```
main.lua
  └─ 注册三个 RPC ──▶ lobby_rpc.lua
                        create_room  ─ 校验 + 限流 ─ nk.match_create("room") ─┐
                        list_rooms   ─ nk.match_list,读每个房间的 label      │
                        list_games   ─ 游戏注册表                            │
                                                                             ▼
                                                        room.lua(match handler)
                                                          房间的整个生命周期:
                                                          match_init / join / leave
                                                          match_loop(每秒 10 次)
                                                                    │
                                                          games/init.lua(注册表)
                                                                    │
                                                          games/rps.lua(适配层)
                                                            解 JSON、广播、管回合
                                                                    │
                                                          rules/rps_rules.lua
                                                            纯函数,谁胜谁负
```

三层的分界是刻意的:

| 层 | 能不能 `require("nakama")` | 为什么 |
|---|---|---|
| `lobby_rpc.lua` / `room.lua` / `games/rps.lua` | 能 | 它们要广播、要建房,离不开运行时 |
| `rules/*.lua` | **不能** | 纯函数才能在 busted 里直接跑,91 项单测全在这一层(见 testing.md 层 1) |

### 一个房间就是一个 authoritative match

`nk.match_create("room", …)` 建出来的东西:

- 状态(花名册、房主、准备、阶段、游戏私有状态)全在**进程内存**里,`state` 表;
- `match_loop` 按 tickrate 跑,石头剪刀布是 **10 次/秒**,回合超时靠数 tick;
- 房间对外只暴露一个 **label**(一个短 JSON),大厅的 `list_rooms` 就是读它 ——
  所以列表里能看到人数和阶段,而不用去问每个房间;
- **没人的房间空置 60 秒自动关掉**,否则每个建过又走光的房间都会永远空转。

客户端**不能**直接 `match_create`,必须走 `create_room` RPC —— 校验游戏 id、
截断房名、限流(5 次/分钟)都在那里。原因见 deployment-contract.md §5:
server key 是跟着 Web 制品公开发布的。

---

## 5. 一局是怎么跑起来的

```
客户端                                  通道        服务端
──────                                  ────        ──────

【登录】
 输名字,点「进入大厅」
 authenticate_device(设备 id)          HTTP  →   建账号或取回账号,签发 token
 update_account(显示名)                HTTP  →   存下来
 session_refresh                        HTTP  →   新 token 里才有新名字
 socket.connect                          WS   →   握手(token 写在 /ws 的 URL 里)

【大厅】
 join_chat("lobby")                      WS   →   进频道,回一份在线名单
 list_channel_messages                  HTTP  →   最近 30 条聊天
 list_games                             HTTP  →   有哪些游戏可玩
 list_rooms(此后每 3 秒一次)           HTTP  →   match_list,读各房间的 label

【建房 / 进房】
 create_room {game,name}                HTTP  →   校验 + 限流 → match_create
                                              ←   {match_id}
 join_match(match_id)                    WS   →   match_join_attempt 放不放行
                                              ←   ROOM_STATE(10)广播给全房
 切到 Room.tscn

【准备与开局】
 READY {ready:true}          (op 1)      WS   →   记下来,重新广播 ROOM_STATE
 START(只有房主发得动)     (op 2)      WS   →   校验:是房主?人够?全准备?
                                              ←   GAME_STARTED(11)
                                              ←   ROUND_BEGIN(30)第 1 轮

【回合循环】
 THROW {hand:0|1|2}         (op 20)      WS   →   记下来,不告诉任何人出了什么
                                              ←   THROW_PROGRESS(32)只报「谁出了」
                                                  收齐 或 倒计时到点 ↓
                                              ←   ROUND_RESULT(31)这时才亮牌
                                                  还剩 >1 人 → ROUND_BEGIN 下一轮

【结束】
                                              ←   GAME_OVER(12){results}
                                              ←   ROOM_STATE 阶段回 waiting,
                                                  所有人的准备清零
```

关键的一条:**倒计时结束前,服务端不会把任何人的手势发给任何人。**
`THROW_PROGRESS` 只带「谁已经出了」,不带出的是什么。这是权威模式的根基 ——
客户端就算改了也偷不到别人的选择。

---

## 6. 消息号(OpCode)

**两边手工同步**:`godot/src/net/OpCodes.gd` 和 `nakama/modules/room.lua`、
`nakama/modules/games/rps.lua` 顶部的 `OP` 表。分段规则:
1–19 房间通用,20–39 石头剪刀布,40–59 成语接龙,60+ 预留。

| 号 | 方向 | 名字 | 内容 |
|---|---|---|---|
| 1 | C→S | READY | `{ready}` |
| 2 | C→S | START | `{}`,仅房主 |
| 3 | C→S | SETTINGS | 仅房主 |
| 10 | S→C | ROOM_STATE | `{phase, players[], host, settings, name, game}` |
| 11 | S→C | GAME_STARTED | `{game, settings}` |
| 12 | S→C | GAME_OVER | `{results[]}` |
| 13 | S→C | ERROR | `{msg}` 错误码,客户端翻成人话 |
| 20 | C→S | THROW | `{hand}` 0=石头 1=布 2=剪刀 |
| 30 | S→C | ROUND_BEGIN | `{round, alive[], seconds, deadline_tick, draw_streak}` |
| 31 | S→C | ROUND_RESULT | `{hands{}, winner, draw, advanced[], eliminated[], afk[]}` |
| 32 | S→C | THROW_PROGRESS | `{thrown[], total}` —— **不含手势** |

`room.lua` 分发消息的规则很简单:`op_code >= game.op_base`(rps 是 20)的
交给游戏模块,其余自己处理。所以加新游戏不用改分发逻辑。

---

## 7. 状态归谁

| 状态 | 在哪 | 说明 |
|---|---|---|
| 账号、显示名 | Postgres | 设备认证,一台设备一个号 |
| 大厅聊天记录 | Postgres | 频道带 persistence,进大厅补最近 30 条 |
| 谁在线 | Nakama 内存(presence) | socket 断了就自动没了 |
| 房间花名册 / 房主 / 准备 / 阶段 | Nakama 内存(match state) | 进程重启就没了 —— 家庭规模,不值得持久化 |
| 本局的存活名单、手势、回合、倒计时 | Nakama 内存(`state.g`) | 游戏模块私有,`room.lua` 不看里面 |
| 客户端上显示的一切 | 客户端内存,**纯派生** | 收到广播就重画。客户端不做任何判定 |

推论:**客户端可以随时丢掉全部状态重来一遍**(重连之后就是这么干的)——
服务端重播一次 `ROOM_STATE`,画面就回来了。

---

## 8. 断线自愈

手机上断线是常态不是异常:锁屏、切到微信看一眼、Wi-Fi 切 4G。
浏览器冻结页面时会**直接关掉 WebSocket**;更麻烦的是**半开连接** —— socket
看着还连着,收发全进黑洞(蜂窝 NAT 超时的典型结果)。

自愈全部在 `ServerConnection` 里,场景不参与:

```
每 3 秒巡检一次(_process)
      │
      ├── socket 已经断了 ─────────────────────────┐
      │                                            │
      └── socket 连着,但已经 12 秒没收到任何东西    │
                │                                  │
             主动 ping                              │
                │                                  │
          5 秒内没回 pong ──▶ 判死,强制 close ────┤
                │                                  │
             回了 pong                              │
                │                                  │
              没事,继续                            ▼
                                        ┌──────────────────────┐
                                        │ 1. 刷 session        │ token 快过期就换
                                        │ 2. 重连 socket       │ 复用同一个对象
                                        │ 3. 重进 lobby 频道   │ 否则聊天/在线是死的
                                        │ 4. 重新 join_match   │ 否则你以为你在房里
                                        └──────────────────────┘
                                                  │
                                 ┌────────────────┴────────────────┐
                                进去了                           进不去
                                 │                                 │
                    服务端重播 ROOM_STATE,               room_lost → 回大厅,
                    画面自己回来                          并说清楚为什么
```

进不去只有两种原因,都不可逆,所以直接送回大厅,不让人对着假房间干等:

- 一个人的房间空置 60 秒被服务端关了(锁屏一分钟就够);
- 这局已经开始,而你**没进过**这个房间。

反过来,**进过这个房间的人掉线后是能回来的** —— 但回来是进观战席,
下一局自动加入(掉线的那一刻服务端已经按离场处理了)。

手机切回前台时不等下一个巡检周期,`NOTIFICATION_APPLICATION_FOCUS_IN`
会立刻触发一次检查。

> 这一段的每个决策点都会发一条 `net` 诊断记录(`probe_start` / `probe_timeout` /
> `reconnect_start` / `session_refresh` / `rejoin_attempt` / `rejoin_ok`),
> `tools/e2e_client_reconnect.py` 按这些记录断言机制本身,而不是只看结果。

---

## 9. 加一个新游戏要改什么

服务端两个文件 + 客户端两个文件,房间逻辑一行不动:

| 改哪 | 干什么 |
|---|---|
| `nakama/modules/rules/<游戏>_rules.lua` | 纯规则,先写单测 |
| `nakama/modules/games/<游戏>.lua` | 适配层:`min_players` / `max_players` / `tickrate` / `op_base` / `on_start` / `on_loop` / `is_over` |
| `nakama/modules/games/init.lua` | 注册表里加一行 |
| `godot/src/net/OpCodes.gd` | 分配一段消息号 + 在 `GAME_LABELS` 加中文名 |
| `godot/src/games/<游戏>/` | 继承 `GameBase` 的场景 |
| `godot/src/room/RoomController.gd` | `GAME_SCENES` 加一行 |

`room.lua` 和 `RoomController` 的房间逻辑、大厅、建房、断线自愈全部复用。

---

## 相关文档

- [nakama-godot-guide.md](nakama-godot-guide.md) —— Godot 接 Nakama 的完整教程
- [deployment-contract.md](deployment-contract.md) —— 部署侧要提供什么(§3.3.1 是路由硬要求)
- [testing.md](testing.md) —— 7 层测试各自抓什么
- [../CONTEXT.md](../CONTEXT.md) —— 术语表:半开连接、巡检、探活、判死、诊断记录
