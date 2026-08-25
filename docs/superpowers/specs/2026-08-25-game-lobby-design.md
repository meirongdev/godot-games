# 家庭游戏大厅 — 设计文档

日期:2026-08-25
状态:待评审
相关:[nakama-godot-guide.md](../../nakama-godot-guide.md)

---

## 1. 目标

一个 Godot 4 + Nakama 的家庭游戏大厅,首批带两个游戏(石头剪刀布、成语接龙)。

**首要约束:第三个游戏必须好加。** 用户明确说了「目前 2 个」,所以房间框架和游戏玩法之间要有干净的接口。加游戏 = 加一个服务端模块 + 一个客户端场景 + 注册两行,不改框架。

**次要目标:** 走完 Nakama 的完整能力(权威 match、presence、channel、storage、RPC、leaderboard),这是学习项目。

## 2. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | 权威服务端(Lua match handler) | 两个游戏都需要裁判;石头剪刀布在中继模式下**根本不成立**(第二个出拳的人的客户端已持有对方答案) |
| D2 | 在线大厅(presence + 聊天 + 房间列表) | 用户选择;顺带覆盖 Nakama 社交层 |
| D3 | 共享 `room.lua` 框架 + 游戏模块接口 | 见目标;房间生命周期不写两遍 |
| D4 | 石头剪刀布 = N 人混战淘汰赛 | 全家一起出拳,淘汰的人能围观起哄 |
| D5 | 成语接龙 = **抢麦制**(非抢答) | 见 §7.1。抢答 + 语音 = 输入方式决定胜负,是坏的 |
| D6 | **无让分机制** | 用户指定。抢麦制已把输入速度移出竞争维度,让分失去存在理由 |
| D7 | 语音走**系统输入法**,不集成 STT | 零代码、全平台、识别率是系统级的。Godot 的 STT 插件生态最高只有 41★,不可依赖 |
| D8 | 出题池 = 11,088 常用成语;接受池 = 29,497 全量 | 出题保证全家认识,接生僻词额外加分 |
| D9 | 默认同音宽松,严格同字为房主可选的硬核模式 | 数据决定,见 §7.2 |

### 被否决的方案

- **中继模式(NakamaMultiplayerBridge)** — D1 已述,石头剪刀布不成立。
- **常用词库 + 严格同字** — 实测 16.1% 死路率、后继数中位数仅 5,抢麦模式下会频繁卡壳。
- **Web Speech API / 自建 Whisper** — 不是不能做,是 D7 零成本就够了。接口留好(§9.4),以后想加不影响游戏逻辑。
- **让分机制** — D6。

## 3. 数据依据

对 `pwxcoo/chinese-xinhua`(MIT,11.6k★,30,895 条)的实测:

| 词库 | 条数 | 严格同字死路 | 同字均可接 | 同音死路 | 同音均可接 |
|---|---|---|---|---|---|
| 全部 | 29,497 | 10.8% | 24.2 | 0.1% | 177.2 |
| 常用(带例句) | 11,088 | **16.1%** | **10.1** | 0.3% | 64.6 |

同音接龙候选集:中位 **124**,P90 373,最大 1255。
候选集内拼音完全撞车:**19 条(0.1%)** — 只有这些需要弹二选一。

索引体积:

| 索引 | 内容 | 未压缩 | gzip |
|---|---|---|---|
| `idiom` | 成语 → [全 4 字无调拼音, 是否常用] | 1.05 MB | 0.36 MB |
| `char` | 单字 → 无调拼音集合(4,866 字,9.8% 多音) | 0.07 MB | 0.02 MB |
| 合计 | | **1.12 MB** | 0.38 MB |

## 4. 系统架构

```
┌─ Godot 客户端 ────────────┐     ┌─ Nakama (homelab) ──────────┐
│ ServerConnection (autoload)│     │  lobby_rpc.lua              │
│   ├─ Lobby.tscn            │◀───▶│    create_room / list_rooms │
│   │   presence / chat      │     │                             │
│   │   room list            │     │  room.lua  ← 通用房间框架    │
│   └─ Room.tscn             │     │    进房/准备/开局/断线/结算  │
│       RoomController.gd    │◀───▶│    label 更新               │
│       └─ GameSlot          │     │      │                      │
│           RpsGame.tscn     │     │      ├─ games/rps.lua       │
│           IdiomGame.tscn   │     │      └─ games/idiom.lua     │
└────────────────────────────┘     │           └─ data/idiom_index.lua
                                    └─────────────────────────────┘
```

### 目录结构

```
nakama/
├── docker-compose.yml
├── modules/
│   ├── main.lua                # 注册 RPC
│   ├── room.lua                # ★ 通用房间 match handler
│   ├── lobby_rpc.lua           # create_room / list_rooms
│   ├── games/
│   │   ├── init.lua            # 游戏注册表 ← 加游戏改这里
│   │   ├── rps.lua
│   │   └── idiom.lua
│   └── data/
│       ├── idiom_index.lua     # 生成物,勿手改
│       └── char_pinyin.lua     # 生成物,勿手改
└── tools/
    └── build_index.py          # 9.8MB JSON → 两个 Lua 索引

godot/
├── addons/com.heroiclabs.nakama/
├── src/
│   ├── autoload/
│   │   ├── ServerConnection.gd
│   │   └── NakamaConfig.gd
│   ├── lobby/
│   │   ├── Lobby.tscn / .gd
│   │   ├── RoomList.gd
│   │   ├── OnlineList.gd
│   │   └── CreateRoomDialog.gd
│   ├── room/
│   │   ├── Room.tscn
│   │   ├── RoomController.gd   # ★ 通用
│   │   └── GameBase.gd         # ★ 游戏接口
│   ├── games/
│   │   ├── rps/RpsGame.tscn / .gd
│   │   └── idiom/IdiomGame.tscn / .gd
│   └── net/OpCodes.gd
├── nakama.cfg.example
└── project.godot
```

## 5. 服务端:房间框架

### 5.1 游戏模块接口

`room.lua` 独占:presence 管理、准备状态、房主、开局判定、断线处理、`match_label_update`、结算回大厅。

游戏模块只实现:

```lua
return {
  id           = "rps",
  tickrate     = 10,              -- 1..60
  min_players  = 2,
  max_players  = 8,
  default_settings = { round_seconds = 3, afk_random = true, draw_accel = true },

  on_start = function(state, dispatcher) end,
  -- 开局。初始化 state.g(游戏私有状态),广播首个游戏事件。

  on_loop  = function(state, dispatcher, tick, messages) end,
  -- 每 tick。只会收到本游戏 OpCode 段内的消息(room.lua 已过滤)。

  on_leave = function(state, dispatcher, user_id) end,
  -- 游戏中有人掉线。

  is_over  = function(state) return over_bool, results_table end,
  -- room.lua 每 tick 调一次;返回 true 时 room.lua 负责广播结算并回到 waiting。
}
```

**`room.lua` 一个字都不用改**就能接第三个游戏。

### 5.2 房间状态机

```
waiting ──(房主 start,且人数 ≥ min_players)──▶ playing
   ▲                                              │
   └──────────(3 秒结算展示)──── finished ◀────────┘  (is_over 返回 true)
```

### 5.3 房间 label

Nakama label 上限 2048 字节,用 JSON,供 `match_list` 过滤:

```json
{"g":"rps","n":"客厅","p":3,"m":8,"s":"waiting","h":"爸爸"}
```

`p`(当前人数)或 `s`(阶段)变化时调 `dispatcher.match_label_update()`。

## 6. 石头剪刀布

### 6.1 规则

1. 每轮 3 秒倒计时,所有存活玩家出拳。
2. **服务端在收齐前绝不广播任何人的选择** — 客户端内存里没有对手数据,作弊无从谈起。这是权威模式白送的。
3. 倒计时到:
   - 未出拳者按 `afk_random` 处理。**默认随机代出,不淘汰**(小孩容易走神,没点按钮就出局会哭)。房主可关闭。
4. 统计本轮出现的不同手势数:
   - **2 种** → 胜方全部晋级,败方全部淘汰
   - **1 种或 3 种** → 平局,原班人马重来
5. 存活 1 人 → 该玩家获胜,局终。

### 6.2 平局节奏(设计期实测,必须处理)

N 人随机出拳时「三种手势都出现」= 平局,这个概率随人数爆炸:

| 人数 | 2 | 3 | 4 | 5 | 6 | 8 |
|---|---|---|---|---|---|---|
| 平局率 | 33% | 33% | 48% | 63% | **74%** | **88%** |

蒙特卡洛模拟(2 万局)打到剩 1 人所需时间:

| 人数 | 固定 3s 倒计时(中位 / P90 / 最坏) | **平局加速**(中位 / P90 / 最坏) |
|---|---|---|
| 4 | 14s / 26s / 66s | 13s / 20s / 49s |
| 6 | 23s / 48s / 148s | 20s / **33s** / 82s |
| 8 | 43s / 96s / **362s** | 30s / **57s** / 172s |

中位数本来就没问题(人多时一旦分出胜负会一次淘汰一大片),**问题全在尾部** — 8 人局有 10% 概率要连看 24 轮平局。

**解法:平局时倒计时递减。**

```
连续平局次数:  0     1     2     3+
倒计时:       3.0s  2.5s  2.0s  1.5s
平局揭晓:     0.4s(只闪一下,不做淘汰展示动画)
出现淘汰后倒计时重置回 3.0s
```

P90 下降 22–41%,最坏情况砍掉一半以上。而且节奏上更好 —— 连续平局时越来越急促,紧张感是往上走的。

`max_players` 上限设 8,但 UI 在建房时对 >6 人给出提示。

### 6.3 观战

被淘汰的玩家留在房间,进入观战席,能看到后续每轮的完整揭晓 + 聊天。

## 7. 成语接龙

### 7.1 抢麦制(核心设计)

**问题:** 抢答模式下谁先提交谁赢。语音有 0.3–3s 识别延迟,键盘没有 → 输入方式决定胜负,而非玩家能力。

**方案:** 把「抢」和「答」拆开。

```
出题(从 11k 常用池挑) ──▶ 抢麦按钮亮起
                            │
        谁先按下 ───────────┤  ← 竞争在这里。毫秒级,与输入方式无关
                            │
              持麦者 5 秒内提交(说 or 打)  ← 识别延迟在这里,不计入竞争
                            │
              ┌─────────────┴─────────────┐
           判定通过                    判定失败/超时
              │                            │
        +分,新成语成为下一环        释放麦,该玩家冷却 3 秒
              │                            │
        是死路成语? ──是──▶ 绝杀 +30,本链结束换新题
              └──否──▶ 继续抢麦
```

**结果:语音和键盘可以在同一局里混用,完全公平。** 这正是 D6(无让分)成立的前提。

### 7.2 判定规则

房主开局前二选一:

- **同音宽松(默认)** — 上一环末字拼音(无调)== 下一环首字拼音。0.1% 死路,候选中位 124。
- **严格同字(硬核)** — 上一环末字 == 下一环首字本字。10.8% 死路,均可接 24.2。

出题只从**后继数 ≥ 5** 的常用成语里挑,避免开局即卡死。

### 7.3 容错匹配

**这不是语音专属功能** — 系统输入法的语音会输出同音错字(「兔死**胡**悲」),小孩打字也会打错同音字。同一套逻辑服务两者。

```
提交文本
  │
  ├─ 精确命中接受池(29,497) ──▶ 接受
  │
  ├─ 未命中 ──▶ 转无调拼音(用 char_pinyin 索引,多音字取全部读音)
  │              └─▶ 在当前合法候选集内算编辑距离
  │                    ├─ 唯一最近且距离 ≤ 1 ──▶ 接受,回包带 corrected_from
  │                    ├─ 多个并列(实测 0.1%) ──▶ 发 disambiguate,持麦者 3 秒内选
  │                    └─ 无匹配 ──▶ 拒绝,释放麦
```

### 7.4 计分与局制

| 事件 | 分 |
|---|---|
| 接上一环 | +10 |
| 绝杀(接到死路成语) | +30 |
| 用了非常用成语 | +5 |
| 接错 / 超时 | 0(不扣分) |

一局 = **5 条链**,每条链最多 **15 环**。链结束条件:绝杀 / 满 15 环 / 全员冷却中无人能抢。

### 7.5 冷却

接错或超时 → 该玩家 3 秒内不能抢麦。防止无脑狂点抢麦。

### 7.6 已知限制(诚实记录)

Nakama 的 `match_loop` 收到的消息只有 `sender / op_code / data`,**没有到达时间戳**(已对照官方 Lua Match Handler API 文档确认)。因此抢麦裁定只能用 tick 号作时间基准,tickrate 上限 60 → 精度 ≈ 16.7ms。

真正的瓶颈是家庭 WiFi 抖动(5–30ms),比 tick 精度粗一个量级。

**结论:抢麦是公平的**(服务端裁定,客户端无法伪造)**,但不是毫秒级精确的**。家庭场景完全够用。不要在 UI 上显示「快 0.03 秒」这种暗示精度的文案。

## 8. OpCode 协议

分段留空,加游戏不撞号。

| 段 | 归属 |
|---|---|
| 1–19 | 房间通用 |
| 20–39 | 石头剪刀布 |
| 40–59 | 成语接龙 |
| 60+ | 预留 |

### 房间通用

| Code | 向 | 名 | 载荷 |
|---|---|---|---|
| 1 | C→S | ready | `{ready: bool}` |
| 2 | C→S | start | `{}`(仅房主) |
| 3 | C→S | settings | `{...}`(仅房主) |
| 10 | S→C | room_state | `{phase, players[], settings, host}` |
| 11 | S→C | game_started | `{game, settings}` |
| 12 | S→C | game_over | `{results[]}` |
| 13 | S→C | error | `{msg}` |

### 石头剪刀布

| Code | 向 | 名 | 载荷 |
|---|---|---|---|
| 20 | C→S | throw | `{hand: 0\|1\|2}` |
| 30 | S→C | round_begin | `{round, alive[], deadline_tick}` |
| 31 | S→C | round_result | `{hands{}, advanced[], eliminated[], draw}` |

### 成语接龙

| Code | 向 | 名 | 载荷 |
|---|---|---|---|
| 40 | C→S | grab_mic | `{}` |
| 41 | C→S | submit | `{text}` |
| 42 | C→S | disambiguate_pick | `{index}` |
| 50 | S→C | chain_begin | `{seed, seed_py, rule, chain_no, deadline_tick}` |
| 51 | S→C | mic_granted | `{uid, expire_tick}` |
| 52 | S→C | mic_released | `{uid, reason}` |
| 53 | S→C | accepted | `{uid, idiom, score, is_kill, corrected_from}` |
| 54 | S→C | rejected | `{uid, reason}`(仅发持麦者) |
| 55 | S→C | scores | `{uid: score}` |
| 56 | S→C | disambiguate | `{options[]}`(仅发持麦者) |

## 9. 客户端

### 9.1 GameBase 接口

```gdscript
class_name GameBase extends Control

signal send_to_server(op_code: int, data: Dictionary)

func game_started(settings: Dictionary, players: Array) -> void: pass
func handle_server(op_code: int, payload: Dictionary) -> void: pass
func game_ended(results: Array) -> void: pass
```

`RoomController` 动态实例化对应场景挂到 `GameSlot`,把 `send_to_server` 接到 `ServerConnection.send_state()`。游戏场景不碰 Nakama。

### 9.2 大厅

- 在线列表:socket presence(`follow_users_async` + `received_status_presence`)
- 聊天:persistent room channel
- 房间列表:`list_matches_async` **3 秒轮询一次**(Nakama 没有房间列表推送)
- 建房:`rpc_async("create_room", {game, name, settings})`

### 9.3 语音输入(D7)

不集成 STT。抢到麦后 UI 聚焦输入框,玩家用系统输入法的麦克风按钮。识别出的同音错字由 §7.3 的容错匹配兜住。

### 9.4 未来的 STT 扩展点

若以后要做游戏内「按住说话」,新增:

```gdscript
class_name SpeechInput extends Node
signal recognized(text: String)
func start_listening() -> void: pass
func stop_listening() -> void: pass
```

Web Speech API(`JavaScriptBridge`,仅 Web 导出)或 homelab Whisper 各实现一份。**游戏逻辑不受影响** — 它只关心最终提交的文本。

## 10. 断线处理

| 场景 | 行为 |
|---|---|
| 玩家重连 | `match_join_attempt` 允许同 `user_id` 重入,替换 presence |
| 游戏中掉线 | 标记 offline,保留 30 秒;石头剪刀布按 AFK 处理,接龙持麦则立即释放麦 |
| 房主掉线 | 房主自动转移给下一位,房间不解散 |
| 全员掉线 | match 自然 terminate |

## 11. 部署注意

Nakama 的 Lua VM 是池化的(默认最多 48 个),每个 VM 都会加载全部 module。1.12 MB 索引在 Lua 表里约 8–10 MB/VM:

```
48 VM × ~9 MB ≈ 430 MB   ← 默认配置,家用服务器吃不消
 4 VM × ~9 MB ≈  36 MB   ← 加 --runtime.lua_min_count 1 --runtime.lua_max_count 4
```

家庭规模用 4 个 VM 绰绰有余。写进部署文档。

⚠️ **两个参数必须成对给。** `lua_min_count` 默认 16,Nakama 会校验 `min <= max`,只设 max 会让服务启动失败。

## 12. 里程碑

| | 内容 | 估时 | 产出 |
|---|---|---|---|
| M1 | 登录 → 在线大厅(presence + 聊天) | 2 天 | 看得到谁在线 |
| M2 | 建房 / 房间列表 / 进房 / 准备 / 开局 | 3 天 | **框架完成** |
| M3 | 石头剪刀布 | 4 天 | 第一个能玩的游戏 |
| M4 | 成语接龙(含索引工具链 + 抢麦 + 容错) | 5 天 | 第二个游戏 |
| M5 | 断线重连 / 观战 / 打磨 | 3 天 | 能给家人用 |

M2 结束时第三个游戏的地基已经好了;M3/M4 只是往框架里填模块。

## 13. 明确不做(YAGNI)

- 游戏内 STT 集成(D7,留 §9.4 扩展点)
- 让分机制(D6)
- 排行榜 / 好友 / 群组 — M5 之后再说
- 观众语音 / 视频
- 匹配系统 — 家庭场景用不上,房间列表够了
- 移动端原生导出 — 先 Web
