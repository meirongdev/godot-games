# 家庭游戏大厅 · 地基 + 石头剪刀布 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个能登录、能看到家人在线、能建房进房、能玩完一局 N 人石头剪刀布的可运行系统。

**Architecture:** Nakama 权威服务端(Lua)持有全部游戏状态,Godot 客户端只发输入、只渲染服务端广播的结果。服务端分两层:`modules/rules/` 是零依赖纯函数(全部 TDD),`modules/` 下的 match handler 和 RPC 是薄适配层。房间生命周期由通用的 `room.lua` 独占,游戏只实现四个回调 —— 加第三个游戏不改框架。

**Tech Stack:** Godot 4.7.2 · Nakama 3.40 (Lua/GopherLua 5.1) · PostgreSQL 16 · Docker Compose · busted(跑在 `imega/busted` 容器里,Lua 5.1)

**范围:** 本计划覆盖 spec 的 M1–M3。成语接龙(M4)和断线/观战打磨(M5)是后续独立计划。

**Spec:** [2026-08-25-game-lobby-design.md](../specs/2026-08-25-game-lobby-design.md)

---

## 环境事实(已实测)

| | 状态 |
|---|---|
| Docker 29.4.0 / Compose v5.1.2 | ✅ 已装 |
| Python 3.12.14 | ✅ 已装(本计划用不到,M4 才用) |
| **Godot** | ❌ **未装,Task 0 装** |
| **本机 Lua / busted** | ❌ 未装,**不装** —— 走 Docker |

Godot 的解析检查**必须带 `--editor`**,否则在主场景就位前它是个空操作(见 Task 9 Step 8)。

Lua 测试跑在 `imega/busted` 容器里,实测 `_VERSION = Lua 5.1`,与 Nakama 的 GopherLua 语义一致。镜像是 amd64,在 Apple Silicon 上走模拟,会打印一行 platform warning —— **属正常,不是错误**,加 `--platform linux/amd64` 可让它闭嘴。实测单次跑 ~1.6ms。

---

## 文件结构

```
nakama/
├── docker-compose.yml
├── .busted                       # busted 配置:lpath 指向 modules/
├── modules/
│   ├── main.lua                  # 注册 RPC(Nakama 启动时执行)
│   ├── room.lua                  # ★ 通用房间 match handler(适配层)
│   ├── lobby_rpc.lua             # create_room / list_rooms
│   ├── games/
│   │   ├── init.lua              # 游戏注册表 ← 加游戏只改这里
│   │   └── rps.lua               # 猜拳适配层
│   └── rules/                    # ★ 纯函数,零 nk 依赖,100% 单测覆盖
│       ├── rps_rules.lua
│       └── room_rules.lua
└── spec/                         # busted 测试(在 modules/ 外,Nakama 不会加载)
    ├── rps_rules_spec.lua
    └── room_rules_spec.lua

godot/
├── addons/com.heroiclabs.nakama/ # 官方客户端(master 分支)
├── src/
│   ├── autoload/
│   │   ├── NakamaConfig.gd
│   │   └── ServerConnection.gd   # 唯一的网络出入口
│   ├── net/OpCodes.gd            # 与服务端手工同步
│   ├── lobby/
│   │   ├── Login.tscn / Login.gd
│   │   ├── Lobby.tscn / Lobby.gd
│   │   └── CreateRoomDialog.gd
│   ├── room/
│   │   ├── Room.tscn
│   │   ├── RoomController.gd     # ★ 通用
│   │   └── GameBase.gd           # ★ 游戏接口
│   └── games/rps/
│       ├── RpsGame.tscn
│       └── RpsGame.gd
├── nakama.cfg.example
└── project.godot
```

**分层铁律:** `modules/rules/` 里的文件**不许出现 `require("nakama")`**。所有游戏逻辑住在这一层,所以能纯函数单测。适配层只做三件事:解 JSON、调纯函数、广播结果。

---

## 任务依赖

```
Task 0 (环境)
  └─▶ Task 1 (仓库骨架 + Nakama 起来)
        ├─▶ Task 2,3,4 (纯规则 TDD,互相独立,可并行)
        │     └─▶ Task 5 (room.lua) ─▶ Task 6 (rps 适配) ─▶ Task 7 (lobby_rpc)
        └─▶ Task 8 (Godot 骨架) ─▶ Task 9 (登录) ─▶ Task 10 (大厅)
                                                      └─▶ Task 11 (房间列表)
Task 7 + Task 11 ─▶ Task 12 (Room 框架) ─▶ Task 13 (RpsGame + 端到端)
```

---

## Task 0: 环境准备

**Files:** 无(只装工具)

- [ ] **Step 1: 装 Godot 4.7.2**

```bash
brew install --cask godot
```

装完确认版本(必须是 4.7.x;4.4 以下不保证 `nakama-godot` master 兼容):

```bash
/Applications/Godot.app/Contents/MacOS/Godot --version
```

Expected: `4.7.2.stable.official.<hash>`

- [ ] **Step 2: 把 Godot CLI 加进 PATH**

```bash
echo 'alias godot="/Applications/Godot.app/Contents/MacOS/Godot"' >> ~/.zshrc
source ~/.zshrc
godot --version
```

Expected: 同上。后续所有 `godot ...` 命令都依赖这个 alias。

- [ ] **Step 3: 预拉 busted 镜像**

```bash
docker pull --platform linux/amd64 imega/busted
```

Expected: `Status: Downloaded newer image for imega/busted:latest`

- [ ] **Step 4: 确认容器里是 Lua 5.1**

```bash
mkdir -p /tmp/luacheck/spec && cd /tmp/luacheck
cat > spec/v_spec.lua <<'EOF'
describe("env", function()
  it("is Lua 5.1", function() assert.equal("Lua 5.1", _VERSION) end)
end)
EOF
docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `1 success / 0 failures / 0 errors / 0 pending`

如果这里报 `Lua 5.4`,**停下**——写出来的 Lua 可能在 Nakama 里跑不了。

---

## Task 1: 仓库骨架 + Nakama 跑起来

**Files:**
- Create: `nakama/docker-compose.yml`
- Create: `nakama/.busted`
- Create: `nakama/modules/main.lua`
- Create: `.gitignore`

- [ ] **Step 1: 开分支**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
git checkout -b feat/lobby-and-rps
```

- [ ] **Step 2: 写 .gitignore**

Create `.gitignore`:

```gitignore
# Godot
godot/.godot/
godot/.import/
godot/export.cfg
godot/export_presets.cfg
godot/android/

# 本机连接配置(含 homelab 地址与 server_key)
godot/nakama.cfg

# Nakama 数据卷
nakama/data/

.DS_Store
```

- [ ] **Step 3: 写 docker-compose.yml**

Create `nakama/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: nakama
      POSTGRES_PASSWORD: localdb
    volumes:
      - data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres", "-d", "nakama"]
      interval: 5s
      timeout: 3s
      retries: 10

  nakama:
    image: registry.heroiclabs.com/heroiclabs/nakama:3.40.0
    depends_on:
      postgres:
        condition: service_healthy
    entrypoint:
      - "/bin/sh"
      - "-ecx"
      - >
        /nakama/nakama migrate up --database.address postgres:localdb@postgres:5432/nakama &&
        exec /nakama/nakama
        --database.address postgres:localdb@postgres:5432/nakama
        --socket.server_key "family-lobby-2026"
        --session.token_expiry_sec 7200
        --runtime.lua_min_count 1
        --runtime.lua_max_count 4
        --logger.level DEBUG
    volumes:
      - ./modules:/nakama/data/modules
    ports:
      - "7350:7350"
      - "7351:7351"
    healthcheck:
      test: ["CMD", "/nakama/nakama", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  data:
```

`--runtime.lua_max_count 4` 是 spec §11 的要求:默认最多 48 个 Lua VM,M4 加载 1.12MB 词库后会吃掉 ~430MB。家用 4 个够。

> ⚠️ **`--runtime.lua_min_count 1` 必须一起给。** Nakama 的 `lua_min_count` 默认是 16,而它会校验 `min <= max`,只调 max 会让容器直接启动失败退出:
> `Minimum Lua runtime instance count must be less than or equal to maximum`
> 这是实施时踩出来的,别删这行。

- [ ] **Step 4: 写 busted 配置**

Create `nakama/.busted`:

```lua
return {
  _all    = { lpath = "./modules/?.lua;./modules/?/init.lua" },
  default = { ROOT = { "spec" }, verbose = true },
}
```

- [ ] **Step 5: 写一个最小 main.lua**

Create `nakama/modules/main.lua`:

```lua
-- Nakama 启动时执行一次。RPC 注册都放这里。
local nk = require("nakama")
nk.logger_info("family-lobby modules loaded")
```

- [ ] **Step 6: 起服务**

```bash
cd nakama && docker compose up -d
```

等 20 秒后:

```bash
docker compose logs nakama | grep -i "family-lobby modules loaded"
```

Expected: 能看到 `family-lobby modules loaded`。看不到就说明 modules 卷没挂上。

- [ ] **Step 7: 验证 server_key 三件套**

```bash
curl -s -X POST "http://127.0.0.1:7350/v2/account/authenticate/device?create=true" \
  -H "Content-Type: application/json" \
  -u "family-lobby-2026:" \
  -d '{"id":"0123456789abcdef0123456789abcdef"}' | head -c 120
```

Expected: `{"token":"eyJ...` 开头的 JSON。
返回 `401` → server_key 对不上。连不上 → 容器没起来。

- [ ] **Step 8: 提交**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
git add .gitignore nakama/
git commit -m "feat: bootstrap nakama server and lua test harness"
```

---

## Task 2: 纯规则 — 猜拳胜负判定(TDD)

**Files:**
- Create: `nakama/modules/rules/rps_rules.lua`
- Test: `nakama/spec/rps_rules_spec.lua`

手势编码固定为 `0=石头 1=布 2=剪刀`。相克关系:`布(1) 胜 石头(0)`、`剪刀(2) 胜 布(1)`、`石头(0) 胜 剪刀(2)` —— 即 `x` 胜 `(x+2)%3`。

- [ ] **Step 1: 写失败的测试**

Create `nakama/spec/rps_rules_spec.lua`:

```lua
local rules = require("rules.rps_rules")

describe("rps_rules.resolve", function()
  it("布胜石头", function()
    assert.equal(1, rules.resolve({ a = 1, b = 0 }))
  end)

  it("剪刀胜布", function()
    assert.equal(2, rules.resolve({ a = 2, b = 1, c = 1 }))
  end)

  it("石头胜剪刀", function()
    assert.equal(0, rules.resolve({ a = 0, b = 2, c = 0 }))
  end)

  it("三种手势都出现 = 平局", function()
    assert.is_nil(rules.resolve({ a = 0, b = 1, c = 2 }))
  end)

  it("全员同手势 = 平局", function()
    assert.is_nil(rules.resolve({ a = 1, b = 1, c = 1 }))
  end)

  it("单人 = 平局", function()
    assert.is_nil(rules.resolve({ a = 0 }))
  end)
end)

describe("rps_rules.split", function()
  it("按胜出手势分晋级与淘汰", function()
    local adv, elim = rules.split({ a = 0, b = 2, c = 0 }, 0)
    table.sort(adv); table.sort(elim)
    assert.same({ "a", "c" }, adv)
    assert.same({ "b" }, elim)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: FAIL,报 `module 'rules.rps_rules' not found`

- [ ] **Step 3: 写最小实现**

Create `nakama/modules/rules/rps_rules.lua`:

```lua
-- 石头剪刀布的纯规则。禁止 require("nakama")。
-- 手势编码:0=石头 1=布 2=剪刀。x 胜 (x+2)%3。
local M = {}

--- 判定本轮胜出手势。
-- @param hands table  user_id -> hand(0/1/2)
-- @return number|nil  胜出手势;平局返回 nil
function M.resolve(hands)
  local seen, distinct = {}, 0
  for _, h in pairs(hands) do
    if not seen[h] then seen[h] = true; distinct = distinct + 1 end
  end
  if distinct ~= 2 then return nil end

  local a, b
  for h in pairs(seen) do
    if a == nil then a = h else b = h end
  end
  -- a 胜 b 当且仅当 b == (a+2)%3,等价于 (a-b)%3 == 1
  if (a - b) % 3 == 1 then return a else return b end
end

--- 按胜出手势把玩家分成晋级与淘汰两组。
-- @return table advanced, table eliminated  两个 user_id 数组
function M.split(hands, winner)
  local advanced, eliminated = {}, {}
  for uid, h in pairs(hands) do
    if h == winner then
      advanced[#advanced + 1] = uid
    else
      eliminated[#eliminated + 1] = uid
    end
  end
  return advanced, eliminated
end

return M
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `7 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 5: 提交**

```bash
git add nakama/modules/rules/rps_rules.lua nakama/spec/rps_rules_spec.lua
git commit -m "feat(rps): pure win/loss resolution rules with tests"
```

---

## Task 3: 纯规则 — 平局加速倒计时(TDD)

**Files:**
- Modify: `nakama/modules/rules/rps_rules.lua`
- Modify: `nakama/spec/rps_rules_spec.lua`

Spec §6.2 的实测结论:8 人局平局率 88%,不加速时 P90 要 96 秒、最坏 6 分钟。倒计时随连续平局递减,P90 降 41%。

- [ ] **Step 1: 写失败的测试**

追加到 `nakama/spec/rps_rules_spec.lua` 末尾:

```lua
describe("rps_rules.countdown_for", function()
  it("首轮 3.0 秒", function()
    assert.equal(3.0, rules.countdown_for(0))
  end)

  it("连续平局逐档递减", function()
    assert.equal(2.5, rules.countdown_for(1))
    assert.equal(2.0, rules.countdown_for(2))
  end)

  it("下限锁死在 1.5 秒", function()
    assert.equal(1.5, rules.countdown_for(3))
    assert.equal(1.5, rules.countdown_for(99))
  end)
end)

describe("rps_rules.reveal_for", function()
  it("平局只闪 0.4 秒", function()
    assert.equal(0.4, rules.reveal_for(true))
  end)

  it("有淘汰时展示 2 秒", function()
    assert.equal(2.0, rules.reveal_for(false))
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: FAIL,`attempt to call field 'countdown_for' (a nil value)`

- [ ] **Step 3: 写实现**

在 `nakama/modules/rules/rps_rules.lua` 的 `return M` **之前**插入:

```lua
local COUNTDOWN_BASE  = 3.0
local COUNTDOWN_STEP  = 0.5
local COUNTDOWN_FLOOR = 1.5
local REVEAL_DRAW     = 0.4
local REVEAL_ELIMINATE = 2.0

--- 本轮倒计时秒数。连续平局时递减,制造加速感。
-- @param draw_streak number 已连续平局的次数(出现淘汰后重置为 0)
function M.countdown_for(draw_streak)
  local v = COUNTDOWN_BASE - COUNTDOWN_STEP * draw_streak
  if v < COUNTDOWN_FLOOR then return COUNTDOWN_FLOOR end
  return v
end

--- 揭晓阶段的展示秒数。平局只闪一下,不放淘汰动画。
function M.reveal_for(is_draw)
  if is_draw then return REVEAL_DRAW end
  return REVEAL_ELIMINATE
end
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `12 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 5: 提交**

```bash
git add nakama/modules/rules/rps_rules.lua nakama/spec/rps_rules_spec.lua
git commit -m "feat(rps): accelerating countdown on consecutive draws"
```

---

## Task 4: 纯规则 — 房间生命周期(TDD)

**Files:**
- Create: `nakama/modules/rules/room_rules.lua`
- Test: `nakama/spec/room_rules_spec.lua`

这一层被 `room.lua` 复用,**与具体游戏无关** —— 第三个游戏也吃这套。

> ⚠️ 三个坑,写之前先知道(都是设计期实测撞出来的):
> 1. **`next_host(order, host)` 的 `order` 是「已移除离开者」之后的数组。** 调用方负责先删人。
> 2. **房间名是玩家输入,直接拼进 JSON 会被引号打断。** `他说"开局"` 会产出非法 JSON,客户端解析房间列表直接炸。必须转义。
> 3. **按字节截断会把汉字劈成两半**,产出非法 UTF-8。必须退回字符边界。

- [ ] **Step 1: 写失败的测试**

Create `nakama/spec/room_rules_spec.lua`:

```lua
local rules = require("rules.room_rules")

describe("can_start", function()
  it("全员准备且人数达标", function()
    local ok, why = rules.can_start({"a","b"}, {a=true,b=true}, "a", "a", 2)
    assert.is_true(ok); assert.is_nil(why)
  end)
  it("人数不足", function()
    local ok, why = rules.can_start({"a"}, {a=true}, "a", "a", 2)
    assert.is_false(ok); assert.equal("need_more_players", why)
  end)
  it("有人没准备", function()
    local ok, why = rules.can_start({"a","b"}, {a=true}, "a", "a", 2)
    assert.is_false(ok); assert.equal("not_all_ready", why)
  end)
  it("非房主发起", function()
    local ok, why = rules.can_start({"a","b"}, {a=true,b=true}, "a", "b", 2)
    assert.is_false(ok); assert.equal("not_host", why)
  end)
end)

describe("next_host (order 已移除离开者)", function()
  it("房主离开 -> 顺延队首", function()
    assert.equal("b", rules.next_host({"b","c"}, "a"))
  end)
  it("非房主离开 -> 房主不变", function()
    assert.equal("a", rules.next_host({"a","c"}, "a"))
  end)
  it("房间空 -> nil", function()
    assert.is_nil(rules.next_host({}, "a"))
  end)
end)

describe("encode_label", function()
  it("常规输出", function()
    assert.equal(
      '{"g":"rps","n":"客厅","p":3,"m":8,"s":"waiting","h":"爸爸"}',
      rules.encode_label{game="rps", name="客厅", count=3, max=8,
                         phase="waiting", host_name="爸爸"})
  end)
  it("房名里的引号被转义,JSON 仍合法", function()
    local l = rules.encode_label{game="rps", name='他说"开局"', count=1,
                                 max=8, phase="waiting", host_name="爸爸"}
    assert.equal(
      '{"g":"rps","n":"他说\\"开局\\"","p":1,"m":8,"s":"waiting","h":"爸爸"}', l)
  end)
  it("反斜杠被转义", function()
    local l = rules.encode_label{game="rps", name='a\\b', count=1, max=8,
                                 phase="waiting", host_name="x"}
    assert.equal('{"g":"rps","n":"a\\\\b","p":1,"m":8,"s":"waiting","h":"x"}', l)
  end)
  it("换行等控制字符被转义", function()
    local l = rules.encode_label{game="rps", name="a\nb", count=1, max=8,
                                 phase="waiting", host_name="x"}
    assert.equal('{"g":"rps","n":"a\\nb","p":1,"m":8,"s":"waiting","h":"x"}', l)
  end)
  it("超长中文房名:不超上限且截断在字符边界", function()
    local l = rules.encode_label{game="rps", name=string.rep("长",1000),
                                 count=1, max=8, phase="waiting", host_name="x"}
    assert.is_true(#l <= 2048)
    local name = l:match('"n":"(.-)","p"')
    assert.equal(0, #name % 3)  -- 三字节字符,合法截断必为 3 的倍数
  end)
  it("超长房主名也被夹住", function()
    local l = rules.encode_label{game="rps", name="x", count=1, max=8,
                                 phase="waiting", host_name=string.rep("长",500)}
    assert.is_true(#l <= 2048)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: FAIL,`module 'rules.room_rules' not found`

- [ ] **Step 3: 写实现**

Create `nakama/modules/rules/room_rules.lua`:

```lua
-- 房间生命周期的纯规则,与具体游戏无关。禁止 require("nakama")。
local M = {}

local LABEL_MAX     = 2048   -- Nakama 对 match label 的硬上限
local HOST_NAME_MAX = 64

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

-- 房名是玩家输入,直接拼进 JSON 会被引号打断。必须转义。
local function esc(s)
  return (tostring(s):gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
  end))
end

-- 按字节截断会把多字节字符劈开,产出非法 UTF-8。退回到字符边界。
local function utf8_trim(s, max_bytes)
  if #s <= max_bytes then return s end
  local i = max_bytes
  while i > 0 do
    local b = string.byte(s, i + 1)
    -- 0x80..0xBF 是延续字节,落在这里说明劈到了字符中间
    if b == nil or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return string.sub(s, 1, i)
end

--- 能否开局。
-- @param order       table  user_id 数组,进房顺序
-- @param ready       table  user_id -> bool
-- @param host        string 当前房主
-- @param requester   string 发起 start 的人
-- @param min_players number
-- @return boolean ok, string|nil reason
function M.can_start(order, ready, host, requester, min_players)
  if requester ~= host then return false, "not_host" end
  if #order < min_players then return false, "need_more_players" end
  for _, uid in ipairs(order) do
    if not ready[uid] then return false, "not_all_ready" end
  end
  return true, nil
end

--- 房主离开后谁接手。
-- @param order table  玩家顺序数组,**调用方须先移除离开者**
-- @param host  string 离开前的房主
-- @return string|nil  房主仍在则原样返回;否则队首;房间空了 nil
function M.next_host(order, host)
  for _, uid in ipairs(order) do
    if uid == host then return host end
  end
  return order[1]
end

--- 生成 match_list 用的 label。键名用单字母压体积。
function M.encode_label(info)
  local host_name = utf8_trim(tostring(info.host_name), HOST_NAME_MAX)
  local function build(name)
    return string.format(
      '{"g":"%s","n":"%s","p":%d,"m":%d,"s":"%s","h":"%s"}',
      esc(info.game), esc(name), info.count, info.max,
      esc(info.phase), esc(host_name))
  end
  local name  = tostring(info.name)
  local label = build(name)
  while #label > LABEL_MAX and #name > 0 do
    name  = utf8_trim(name, math.max(0, #name - (#label - LABEL_MAX)))
    label = build(name)
  end
  return label
end

return M
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `25 successes / 0 failures / 0 errors / 0 pending`
(Task 2 的 7 项 + Task 3 的 5 项 + 本任务的 13 项)

- [ ] **Step 5: 提交**

```bash
git add nakama/modules/rules/room_rules.lua nakama/spec/room_rules_spec.lua
git commit -m "feat(room): pure room lifecycle rules with JSON-safe labels"
```

---

---

## Task 5: 测试脚手架 + 游戏注册表

**Files:**
- Create: `nakama/spec/support/mock_nk.lua`
- Create: `nakama/modules/games/init.lua`
- Test: `nakama/spec/mock_nk_spec.lua`

适配层依赖 `require("nakama")`,默认没法单测。把 `nk` 和 `dispatcher` 换成可断言的假货,`room.lua` 的状态机就能测了 —— 这是本计划质量的关键一环,别跳过。

`imega/busted` 镜像自带 `dkjson`,mock 直接拿它做 JSON 往返。

- [ ] **Step 1: 写 mock 脚手架**

Create `nakama/spec/support/mock_nk.lua`:

```lua
-- 把 require("nakama") 换成可断言的假货,让适配层也能单测。
local M = {}

--- 安装假 nk。返回一个 calls 表,测试里可断言调用记录。
function M.install()
  local calls = { logs = {}, storage_writes = {} }
  package.loaded["nakama"] = {
    logger_info   = function(m) calls.logs[#calls.logs + 1] = m end,
    logger_error  = function(m) calls.logs[#calls.logs + 1] = m end,
    json_encode   = function(t) return require("dkjson").encode(t) end,
    json_decode   = function(s) return require("dkjson").decode(s) end,
    storage_write = function(o) calls.storage_writes[#calls.storage_writes + 1] = o end,
    uuid_v4       = function() return "00000000-0000-4000-8000-000000000000" end,
  }
  return calls
end

--- 假 dispatcher。记录所有广播 / label 更新 / 踢人。
function M.dispatcher()
  local d = { broadcasts = {}, labels = {}, kicks = {} }
  d.broadcast_message = function(op, data, presences)
    d.broadcasts[#d.broadcasts + 1] = { op = op, data = data, presences = presences }
  end
  d.match_label_update = function(l) d.labels[#d.labels + 1] = l end
  d.match_kick = function(p) d.kicks[#d.kicks + 1] = p end
  return d
end

--- 造一个假 presence。
function M.presence(user_id, username)
  return { user_id = user_id, username = username or user_id,
           session_id = "sess-" .. user_id, node = "nakama1" }
end

--- 造一条假客户端消息。
function M.message(user_id, op_code, tbl)
  return { sender = M.presence(user_id), op_code = op_code,
           data = require("dkjson").encode(tbl or {}) }
end

--- 取出最后一条指定 op_code 的广播,已解码。
function M.last(d, op_code)
  for i = #d.broadcasts, 1, -1 do
    if d.broadcasts[i].op == op_code then
      return require("dkjson").decode(d.broadcasts[i].data)
    end
  end
  return nil
end

return M
```

- [ ] **Step 2: 写 mock 自身的测试**

Create `nakama/spec/mock_nk_spec.lua`:

```lua
local mock = require("spec.support.mock_nk")

describe("mock_nk", function()
  it("拦截 require('nakama')", function()
    local calls = mock.install()
    require("nakama").logger_info("hi")
    assert.same({ "hi" }, calls.logs)
  end)

  it("json 往返", function()
    mock.install()
    local nk = require("nakama")
    assert.equal(1, nk.json_decode(nk.json_encode({ a = 1 })).a)
  end)

  it("dispatcher 记录广播与 label", function()
    local d = mock.dispatcher()
    d.broadcast_message(30, '{"x":1}')
    d.match_label_update('{"g":"rps"}')
    assert.equal(30, d.broadcasts[1].op)
    assert.equal('{"g":"rps"}', d.labels[1])
  end)

  it("last() 取回最后一条指定 op 的广播", function()
    local d = mock.dispatcher()
    d.broadcast_message(10, '{"n":1}')
    d.broadcast_message(10, '{"n":2}')
    assert.equal(2, mock.last(d, 10).n)
  end)
end)
```

- [ ] **Step 3: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `29 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 4: 写游戏注册表**

Create `nakama/modules/games/init.lua`:

```lua
-- 游戏注册表。★ 加第三个游戏只改这个文件。
local M = {}

local REGISTRY = {
  rps = require("games.rps"),
}

function M.get(id)    return REGISTRY[id] end
function M.exists(id) return REGISTRY[id] ~= nil end

--- 给大厅列出可玩的游戏。
function M.list()
  local out = {}
  for id, g in pairs(REGISTRY) do
    out[#out + 1] = { id = id, min = g.min_players, max = g.max_players }
  end
  return out
end

return M
```

> ⚠️ `games/rps.lua` 还不存在,所以这一步之后 busted 会报 `module 'games.rps' not found`。**这是预期的** —— Task 6 建完就好。先别提交这个文件,和 Task 6 一起提交。

---

## Task 6: 猜拳适配层

**Files:**
- Create: `nakama/modules/games/rps.lua`
- Test: `nakama/spec/rps_game_spec.lua`

适配层只做三件事:解 JSON、调 `rules/` 里的纯函数、广播结果。**任何判定逻辑都不许写在这里**。

游戏模块契约(第三个游戏照抄这个形状):

| 字段 | 含义 |
|---|---|
| `op_base` | 本游戏 OpCode 段起点。`room.lua` 靠它过滤消息 |
| `tickrate` | 1..60 |
| `min_players` / `max_players` | |
| `default_settings` | 房主可改的项 |
| `on_start(state, dispatcher, tick)` | 开局,初始化 `state.g` |
| `on_loop(state, dispatcher, tick, messages)` | 每 tick,只收到本段消息 |
| `on_leave(state, dispatcher, user_id)` | 游戏中有人掉线 |
| `is_over(state)` | 返回 `over, results` |

- [ ] **Step 1: 写失败的测试**

Create `nakama/spec/rps_game_spec.lua`:

```lua
local mock = require("spec.support.mock_nk")
mock.install()
local rps = require("games.rps")

local OP_THROW, OP_ROUND_BEGIN, OP_ROUND_RESULT = 20, 30, 31

-- 造一个已开局的房间状态
local function new_state(uids, settings)
  local s = {
    order = uids, names = {}, settings = settings or
      { afk_random = true, draw_accel = true },
  }
  for _, u in ipairs(uids) do s.names[u] = u end
  return s
end

describe("rps 适配层", function()
  it("on_start 广播首轮并把所有人算作存活", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b", "c" })
    rps.on_start(s, d, 0)
    local begin = mock.last(d, OP_ROUND_BEGIN)
    assert.equal(1, begin.round)
    assert.equal(3, #begin.alive)
    assert.equal(3.0, begin.seconds)
  end)

  it("全员出拳后立即揭晓,不等倒计时", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b" })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, {
      mock.message("a", OP_THROW, { hand = 1 }),   -- 布
      mock.message("b", OP_THROW, { hand = 0 }),   -- 石头
    })
    local r = mock.last(d, OP_ROUND_RESULT)
    assert.is_false(r.draw)
    assert.same({ "a" }, r.advanced)
    assert.same({ "b" }, r.eliminated)
  end)

  it("三种手势 = 平局,无人淘汰且 draw_streak 递增", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b", "c" })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, {
      mock.message("a", OP_THROW, { hand = 0 }),
      mock.message("b", OP_THROW, { hand = 1 }),
      mock.message("c", OP_THROW, { hand = 2 }),
    })
    local r = mock.last(d, OP_ROUND_RESULT)
    assert.is_true(r.draw)
    assert.equal(0, #r.eliminated)
    assert.equal(1, r.draw_streak)
  end)

  it("ROUND_BEGIN 带上 draw_streak,客户端才能显示加速提示", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b", "c" })
    rps.on_start(s, d, 0)
    assert.equal(0, mock.last(d, OP_ROUND_BEGIN).draw_streak)
    rps.on_loop(s, d, 1, {                      -- 制造一次平局
      mock.message("a", OP_THROW, { hand = 0 }),
      mock.message("b", OP_THROW, { hand = 1 }),
      mock.message("c", OP_THROW, { hand = 2 }),
    })
    rps.on_loop(s, d, 1000, {})                 -- 开下一轮
    assert.equal(1, mock.last(d, OP_ROUND_BEGIN).draw_streak)
  end)

  it("连续平局时下一轮倒计时缩短", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b", "c" })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, {                      -- 第 1 次平局
      mock.message("a", OP_THROW, { hand = 0 }),
      mock.message("b", OP_THROW, { hand = 1 }),
      mock.message("c", OP_THROW, { hand = 2 }),
    })
    rps.on_loop(s, d, 1000, {})                 -- 揭晓展示结束,开下一轮
    assert.equal(2.5, mock.last(d, OP_ROUND_BEGIN).seconds)
  end)

  it("倒计时到点且 afk_random=false 时,没出拳的直接淘汰", function()
    local d = mock.dispatcher()
    local s = new_state({ "a", "b" }, { afk_random = false, draw_accel = true })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, { mock.message("a", OP_THROW, { hand = 1 }) })
    rps.on_loop(s, d, 9999, {})                 -- 超过 deadline
    local r = mock.last(d, OP_ROUND_RESULT)
    assert.same({ "b" }, r.eliminated)
    assert.same({ "b" }, r.afk)
  end)

  it("非法手势被丢弃", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b" })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, {
      mock.message("a", OP_THROW, { hand = 7 }),
      mock.message("b", OP_THROW, { hand = 0 }),
    })
    assert.is_nil(mock.last(d, OP_ROUND_RESULT))  -- 只有 b 出了,没到齐也没到点
  end)

  it("同一玩家重复出拳只认第一次", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b" })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, {
      mock.message("a", OP_THROW, { hand = 1 }),
      mock.message("a", OP_THROW, { hand = 2 }),
      mock.message("b", OP_THROW, { hand = 0 }),
    })
    assert.equal(1, mock.last(d, OP_ROUND_RESULT).hands.a)
  end)

  it("打到剩 1 人时 is_over 返回胜者", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b" })
    rps.on_start(s, d, 0)
    rps.on_loop(s, d, 1, {
      mock.message("a", OP_THROW, { hand = 1 }),
      mock.message("b", OP_THROW, { hand = 0 }),
    })
    assert.is_false((rps.is_over(s)))            -- 还在揭晓展示中
    rps.on_loop(s, d, 9999, {})                  -- 展示结束
    local over, results = rps.is_over(s)
    assert.is_true(over)
    assert.equal("a", results[1].id)
  end)

  it("玩家中途掉线后不再计入存活", function()
    local d, s = mock.dispatcher(), new_state({ "a", "b", "c" })
    rps.on_start(s, d, 0)
    rps.on_leave(s, d, "c")
    rps.on_loop(s, d, 1, {
      mock.message("a", OP_THROW, { hand = 1 }),
      mock.message("b", OP_THROW, { hand = 0 }),
    })
    assert.is_not_nil(mock.last(d, OP_ROUND_RESULT))  -- 只等 a b 就够
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: FAIL,`module 'games.rps' not found`

- [ ] **Step 3: 写实现**

Create `nakama/modules/games/rps.lua`:

```lua
-- 石头剪刀布适配层。只解 JSON、调 rules、广播。判定逻辑一律在 rules/rps_rules.lua。
local nk    = require("nakama")
local rules = require("rules.rps_rules")

local OP = { THROW = 20, ROUND_BEGIN = 30, ROUND_RESULT = 31 }

local M = {
  id          = "rps",
  op_base     = 20,
  tickrate    = 10,
  min_players = 2,
  max_players = 8,
  default_settings = { afk_random = true, draw_accel = true },
}

local function secs_to_ticks(s) return math.floor(s * M.tickrate) end

local function is_alive(g, uid)
  for _, u in ipairs(g.alive) do if u == uid then return true end end
  return false
end

local function all_thrown(g)
  for _, uid in ipairs(g.alive) do
    if g.hands[uid] == nil then return false end
  end
  return #g.alive > 0
end

local function begin_round(state, dispatcher, tick)
  local g = state.g
  g.round = g.round + 1
  g.hands = {}
  g.phase = "countdown"
  local secs = state.settings.draw_accel
    and rules.countdown_for(g.draw_streak) or 3.0
  g.deadline = tick + secs_to_ticks(secs)
  dispatcher.broadcast_message(OP.ROUND_BEGIN, nk.json_encode({
    round = g.round, alive = g.alive,
    seconds = secs, deadline_tick = g.deadline,
    -- 客户端要在回合开始时就显示「连续平局 ×N,加速」,
    -- 所以 draw_streak 必须跟着 ROUND_BEGIN 走,不能只在 ROUND_RESULT 里发。
    draw_streak = g.draw_streak,
  }))
end

local function reveal(state, dispatcher, tick)
  local g = state.g

  -- 没出拳的:随机代出(默认,对小孩友好)或按弃权淘汰
  local afk = {}
  for _, uid in ipairs(g.alive) do
    if g.hands[uid] == nil then
      afk[#afk + 1] = uid
      if state.settings.afk_random then
        g.hands[uid] = math.random(0, 2)
      end
    end
  end

  local winner = rules.resolve(g.hands)
  local advanced, eliminated = {}, {}

  if winner == nil then
    g.draw_streak = g.draw_streak + 1
    for _, uid in ipairs(g.alive) do
      if g.hands[uid] ~= nil then advanced[#advanced + 1] = uid end
    end
  else
    g.draw_streak = 0
    advanced, eliminated = rules.split(g.hands, winner)
  end

  -- afk_random 关掉时,没出拳的一律淘汰
  if not state.settings.afk_random then
    for _, uid in ipairs(afk) do eliminated[#eliminated + 1] = uid end
  end

  g.alive = advanced
  local is_draw = (winner == nil)
  local reveal_secs = state.settings.draw_accel and rules.reveal_for(is_draw) or 2.0
  g.phase    = "reveal"
  g.deadline = tick + secs_to_ticks(reveal_secs)

  dispatcher.broadcast_message(OP.ROUND_RESULT, nk.json_encode({
    hands = g.hands, winner = winner, draw = is_draw,
    advanced = advanced, eliminated = eliminated,
    afk = afk, draw_streak = g.draw_streak,
  }))
end

function M.on_start(state, dispatcher, tick)
  state.g = {
    alive = {}, hands = {}, draw_streak = 0,
    round = 0, phase = "countdown", deadline = 0,
    winner = nil, over = false,
  }
  for _, uid in ipairs(state.order) do
    state.g.alive[#state.g.alive + 1] = uid
  end
  begin_round(state, dispatcher, tick or 0)
end

function M.on_loop(state, dispatcher, tick, messages)
  local g = state.g
  if g == nil or g.over then return end

  if g.phase == "countdown" then
    for _, m in ipairs(messages) do
      if m.op_code == OP.THROW then
        local uid = m.sender.user_id
        if is_alive(g, uid) and g.hands[uid] == nil then
          local ok, d = pcall(nk.json_decode, m.data)
          local h = ok and tonumber(d and d.hand) or nil
          if h == 0 or h == 1 or h == 2 then g.hands[uid] = h end
        end
      end
    end
    if all_thrown(g) or tick >= g.deadline then
      reveal(state, dispatcher, tick)
    end

  elseif g.phase == "reveal" then
    if tick >= g.deadline then
      if #g.alive <= 1 then
        g.winner = g.alive[1]
        g.over   = true
      else
        begin_round(state, dispatcher, tick)
      end
    end
  end
end

function M.on_leave(state, dispatcher, uid)
  local g = state.g
  if g == nil then return end
  for i, a in ipairs(g.alive) do
    if a == uid then table.remove(g.alive, i); break end
  end
  g.hands[uid] = nil
end

function M.is_over(state)
  local g = state.g
  if g == nil or not g.over then return false, nil end
  if g.winner == nil then return true, {} end   -- 全员掉线
  return true, { { id = g.winner, name = state.names[g.winner], rank = 1 } }
end

return M
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `38 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 5: 提交**

```bash
git add nakama/modules/games/ nakama/spec/
git commit -m "feat(rps): game module adapter with mock-nk test harness"
```

---

## Task 7: 通用房间 match handler

**Files:**
- Create: `nakama/modules/room.lua`
- Test: `nakama/spec/room_spec.lua`

★ 本计划的核心文件。它独占房间生命周期,**加第三个游戏时一个字都不用改**。

Nakama 要求 match handler 导出 7 个回调,少一个启动就报错:`match_init`、`match_join_attempt`、`match_join`、`match_leave`、`match_loop`、`match_terminate`、`match_signal`。

- [ ] **Step 1: 写失败的测试**

Create `nakama/spec/room_spec.lua`:

```lua
local mock = require("spec.support.mock_nk")
mock.install()
local room = require("room")

local OP_READY, OP_START      = 1, 2
local OP_ROOM_STATE, OP_STARTED, OP_OVER, OP_ERROR = 10, 11, 12, 13

local function fresh(host)
  local state = room.match_init(nil, {
    game = "rps", name = "客厅", host = host, host_name = host })
  return state
end

local function join(state, d, uids)
  local ps = {}
  for i, u in ipairs(uids) do ps[i] = mock.presence(u) end
  return room.match_join(nil, d, 0, state, ps)
end

describe("room.match_init", function()
  it("返回 state / tickrate / label 三件套", function()
    local state, tickrate, label = room.match_init(nil, {
      game = "rps", name = "客厅", host = "a", host_name = "爸爸" })
    assert.equal("waiting", state.phase)
    assert.equal(10, tickrate)
    assert.equal(
      '{"g":"rps","n":"客厅","p":0,"m":8,"s":"waiting","h":"爸爸"}', label)
  end)

  it("settings 是 default_settings 的副本,不共享引用", function()
    local s1 = fresh("a")
    local s2 = fresh("b")
    s1.settings.afk_random = false
    assert.is_true(s2.settings.afk_random)
  end)
end)

describe("room.match_join_attempt", function()
  it("waiting 阶段放行", function()
    local _, ok = room.match_join_attempt(
      nil, nil, 0, fresh("a"), mock.presence("b"), nil)
    assert.is_true(ok)
  end)

  it("游戏进行中拒绝新玩家", function()
    local s = fresh("a"); s.phase = "playing"
    local _, ok, why = room.match_join_attempt(
      nil, nil, 0, s, mock.presence("z"), nil)
    assert.is_false(ok)
    assert.equal("游戏已开始", why)
  end)

  it("满员拒绝", function()
    local s, d = fresh("a"), mock.dispatcher()
    join(s, d, { "u1","u2","u3","u4","u5","u6","u7","u8" })
    local _, ok, why = room.match_join_attempt(
      nil, nil, 0, s, mock.presence("u9"), nil)
    assert.is_false(ok)
    assert.equal("房间已满", why)
  end)

  it("已在房间的人重连放行,即使游戏已开始", function()
    local s, d = fresh("a"), mock.dispatcher()
    join(s, d, { "a" })
    s.phase = "playing"
    local _, ok = room.match_join_attempt(
      nil, nil, 0, s, mock.presence("a"), nil)
    assert.is_true(ok)
  end)
end)

describe("room.match_join", function()
  it("记录进房顺序并广播房间状态", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    assert.same({ "a", "b" }, s.order)
    local st = mock.last(d, OP_ROOM_STATE)
    assert.equal(2, #st.players)
    assert.is_false(st.players[1].ready)
  end)

  it("label 随人数更新", function()
    local s, d = fresh("a"), mock.dispatcher()
    join(s, d, { "a", "b" })
    assert.is_truthy(d.labels[#d.labels]:match('"p":2'))
  end)

  it("host 为空时第一个进来的人当房主", function()
    local s, d = fresh(nil), mock.dispatcher()
    s = join(s, d, { "x", "y" })
    assert.equal("x", s.host)
  end)
end)

describe("room 准备与开局", function()
  it("ready 消息更新状态并广播", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_loop(nil, d, 1, s, { mock.message("a", OP_READY, { ready = true }) })
    local st = mock.last(d, OP_ROOM_STATE)
    assert.is_true(st.players[1].ready)
  end)

  it("非房主开局被拒并收到 error", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_loop(nil, d, 1, s, { mock.message("b", OP_START, {}) })
    assert.equal("not_host", mock.last(d, OP_ERROR).msg)
    assert.equal("waiting", s.phase)
  end)

  it("有人没准备时开局被拒", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_loop(nil, d, 1, s, { mock.message("a", OP_READY, { ready = true }) })
    s = room.match_loop(nil, d, 2, s, { mock.message("a", OP_START, {}) })
    assert.equal("not_all_ready", mock.last(d, OP_ERROR).msg)
  end)

  it("全员准备后开局,广播 game_started 并进入 playing", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_loop(nil, d, 1, s, {
      mock.message("a", OP_READY, { ready = true }),
      mock.message("b", OP_READY, { ready = true }),
    })
    s = room.match_loop(nil, d, 2, s, { mock.message("a", OP_START, {}) })
    assert.equal("playing", s.phase)
    assert.equal("rps", mock.last(d, OP_STARTED).game)
    assert.is_not_nil(mock.last(d, 30))         -- 游戏模块的 round_begin
    assert.is_truthy(d.labels[#d.labels]:match('"s":"playing"'))
  end)

  it("只有房主能改设置", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_loop(nil, d, 1, s, {
      mock.message("b", 3, { afk_random = false }) })
    assert.is_true(s.settings.afk_random)
    s = room.match_loop(nil, d, 2, s, {
      mock.message("a", 3, { afk_random = false }) })
    assert.is_false(s.settings.afk_random)
  end)
end)

describe("room.match_leave", function()
  it("移出 order 并把房主顺延", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b", "c" })
    s = room.match_leave(nil, d, 0, s, { mock.presence("a") })
    assert.same({ "b", "c" }, s.order)
    assert.equal("b", s.host)
  end)

  it("非房主离开时房主不变", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_leave(nil, d, 0, s, { mock.presence("b") })
    assert.equal("a", s.host)
  end)
end)

describe("room 结算", function()
  it("游戏结束后广播 game_over 并回到 waiting,ready 全部清空", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a", "b" })
    s = room.match_loop(nil, d, 1, s, {
      mock.message("a", OP_READY, { ready = true }),
      mock.message("b", OP_READY, { ready = true }),
    })
    s = room.match_loop(nil, d, 2, s, { mock.message("a", OP_START, {}) })
    -- 让 a 赢:布 vs 石头
    s = room.match_loop(nil, d, 3, s, {
      mock.message("a", 20, { hand = 1 }),
      mock.message("b", 20, { hand = 0 }),
    })
    s = room.match_loop(nil, d, 9999, s, {})     -- 揭晓展示结束 -> 分胜负
    s = room.match_loop(nil, d, 10000, s, {})    -- room 检出 is_over
    assert.equal("waiting", s.phase)
    assert.equal("a", mock.last(d, OP_OVER).results[1].id)
    assert.is_false(s.ready.a)
    assert.is_nil(s.g)
  end)
end)

describe("room 必需回调齐全", function()
  it("Nakama 要求的 7 个回调一个不少", function()
    for _, name in ipairs({ "match_init", "match_join_attempt", "match_join",
                            "match_leave", "match_loop", "match_terminate",
                            "match_signal" }) do
      assert.equal("function", type(room[name]), name .. " 缺失")
    end
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: FAIL,`module 'room' not found`

- [ ] **Step 3: 写实现**

Create `nakama/modules/room.lua`:

```lua
-- 通用房间 match handler。独占房间生命周期,与具体游戏无关。
-- ★ 加新游戏不改这个文件,只在 games/init.lua 注册。
local nk         = require("nakama")
local room_rules = require("rules.room_rules")
local games      = require("games.init")

local OP = {
  READY = 1, START = 2, SETTINGS = 3,
  ROOM_STATE = 10, GAME_STARTED = 11, GAME_OVER = 12, ERROR = 13,
}

local M = {}

local function label_info(state)
  local game = games.get(state.game_id)
  return {
    game      = state.game_id,
    name      = state.name,
    count     = #state.order,
    max       = game.max_players,
    phase     = state.phase,
    host_name = state.host_name or "",
  }
end

local function update_label(dispatcher, state)
  dispatcher.match_label_update(room_rules.encode_label(label_info(state)))
end

local function sync(dispatcher, state)
  local players = {}
  for i, uid in ipairs(state.order) do
    players[i] = {
      id    = uid,
      name  = state.names[uid],
      ready = state.ready[uid] or false,
    }
  end
  dispatcher.broadcast_message(OP.ROOM_STATE, nk.json_encode({
    phase    = state.phase,
    players  = players,
    host     = state.host,
    settings = state.settings,
  }))
  update_label(dispatcher, state)
end

function M.match_init(_, params)
  local game = games.get(params.game)
  -- 复制一份 default_settings,否则多个房间会共享同一张表
  local settings = {}
  for k, v in pairs(game.default_settings) do settings[k] = v end

  local state = {
    game_id   = params.game,
    name      = params.name or "房间",
    host      = params.host,
    host_name = params.host_name or "",
    phase     = "waiting",
    presences = {},   -- uid -> presence
    order     = {},   -- uid 数组,进房顺序
    names     = {},   -- uid -> username
    ready     = {},   -- uid -> bool
    settings  = settings,
    g         = nil,  -- 游戏私有状态,由游戏模块拥有
  }
  return state, game.tickrate, room_rules.encode_label(label_info(state))
end

function M.match_join_attempt(_, _, _, state, presence, _)
  local game = games.get(state.game_id)
  -- 重连:已在房间的 user_id 一律放行,即使游戏已开始
  if state.presences[presence.user_id] ~= nil then
    return state, true
  end
  if state.phase ~= "waiting" then
    return state, false, "游戏已开始"
  end
  if #state.order >= game.max_players then
    return state, false, "房间已满"
  end
  return state, true
end

function M.match_join(_, dispatcher, _, state, presences)
  for _, p in ipairs(presences) do
    if state.presences[p.user_id] == nil then
      state.order[#state.order + 1] = p.user_id
      state.ready[p.user_id] = false
    end
    state.presences[p.user_id] = p
    state.names[p.user_id]     = p.username
    if state.host == nil then
      state.host      = p.user_id
      state.host_name = p.username
    end
  end
  sync(dispatcher, state)
  return state
end

function M.match_leave(_, dispatcher, _, state, presences)
  local game = games.get(state.game_id)
  for _, p in ipairs(presences) do
    state.presences[p.user_id] = nil
    state.ready[p.user_id]     = nil
    for i, uid in ipairs(state.order) do
      if uid == p.user_id then table.remove(state.order, i); break end
    end
    if state.phase == "playing" and game.on_leave then
      game.on_leave(state, dispatcher, p.user_id)
    end
  end
  -- next_host 要的是「已移除离开者」之后的 order
  state.host      = room_rules.next_host(state.order, state.host)
  state.host_name = state.host and state.names[state.host] or ""
  sync(dispatcher, state)
  return state
end

local function handle_lobby(dispatcher, state, m, game, tick)
  local uid = m.sender.user_id

  if m.op_code == OP.READY then
    local ok, d = pcall(nk.json_decode, m.data)
    if ok then
      state.ready[uid] = d and d.ready and true or false
      sync(dispatcher, state)
    end

  elseif m.op_code == OP.SETTINGS then
    if uid == state.host then
      local ok, d = pcall(nk.json_decode, m.data)
      if ok and d then
        for k, v in pairs(d) do state.settings[k] = v end
        sync(dispatcher, state)
      end
    end

  elseif m.op_code == OP.START then
    local ok, why = room_rules.can_start(
      state.order, state.ready, state.host, uid, game.min_players)
    if not ok then
      dispatcher.broadcast_message(
        OP.ERROR, nk.json_encode({ msg = why }), { m.sender })
    else
      state.phase = "playing"
      state.g     = nil
      dispatcher.broadcast_message(OP.GAME_STARTED, nk.json_encode({
        game = state.game_id, settings = state.settings }))
      game.on_start(state, dispatcher, tick)
      update_label(dispatcher, state)
    end
  end

  return state
end

function M.match_loop(_, dispatcher, tick, state, messages)
  local game = games.get(state.game_id)

  if state.phase == "waiting" then
    for _, m in ipairs(messages) do
      state = handle_lobby(dispatcher, state, m, game, tick)
    end
    return state
  end

  -- playing:只把本游戏 OpCode 段的消息交给游戏模块
  local own = {}
  for _, m in ipairs(messages) do
    if m.op_code >= game.op_base then own[#own + 1] = m end
  end
  game.on_loop(state, dispatcher, tick, own)

  local over, results = game.is_over(state)
  if over then
    dispatcher.broadcast_message(
      OP.GAME_OVER, nk.json_encode({ results = results or {} }))
    state.phase = "waiting"
    state.g     = nil
    for uid in pairs(state.ready) do state.ready[uid] = false end
    sync(dispatcher, state)
  end
  return state
end

function M.match_terminate(_, _, _, state, _) return state end
function M.match_signal(_, _, _, state, data) return state, data end

return M
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `56 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 5: 提交**

```bash
git add nakama/modules/room.lua nakama/spec/room_spec.lua
git commit -m "feat(room): generic room match handler with lifecycle tests"
```

---

## Task 8: 大厅 RPC(建房 / 列房)

**Files:**
- Create: `nakama/modules/lobby_rpc.lua`
- Modify: `nakama/modules/main.lua`
- Test: `nakama/spec/lobby_rpc_spec.lua`

客户端不能直接 `match_create`(那样谁都能建任意 module 的 match)。所有建房走 RPC,服务端校验游戏 id 与房名。

- [ ] **Step 1: 给 mock 补上 match 相关函数**

在 `nakama/spec/support/mock_nk.lua` 的 `M.install()` 里,`uuid_v4` 那行后面追加:

```lua
    match_create = function(module, params)
      calls.match_creates[#calls.match_creates + 1] =
        { module = module, params = params }
      return "match-" .. #calls.match_creates
    end,
    match_list = function(limit, authoritative, label, min, max, query)
      calls.match_lists[#calls.match_lists + 1] =
        { limit = limit, query = query }
      return calls.stub_matches or {}
    end,
```

同时把 `local calls = { logs = {}, storage_writes = {} }` 改成:

```lua
  local calls = { logs = {}, storage_writes = {},
                  match_creates = {}, match_lists = {} }
```

- [ ] **Step 2: 写失败的测试**

Create `nakama/spec/lobby_rpc_spec.lua`:

```lua
local mock = require("spec.support.mock_nk")
local calls = mock.install()
local lobby = require("lobby_rpc")

local nk = require("nakama")
local ctx = { user_id = "u1", username = "爸爸" }

describe("create_room", function()
  it("建出 room module 的 match 并回传 match_id", function()
    local out = lobby.create_room(ctx, nk.json_encode({
      game = "rps", name = "客厅" }))
    local res = nk.json_decode(out)
    assert.equal("match-1", res.match_id)
    assert.equal("room", calls.match_creates[1].module)
    assert.equal("rps",  calls.match_creates[1].params.game)
    assert.equal("u1",   calls.match_creates[1].params.host)
  end)

  it("未知游戏 id 被拒", function()
    local out = lobby.create_room(ctx, nk.json_encode({
      game = "mahjong", name = "x" }))
    assert.equal("unknown_game", nk.json_decode(out).error)
  end)

  it("空房名回退成用户名的房间", function()
    local out = lobby.create_room(ctx, nk.json_encode({ game = "rps" }))
    assert.equal("爸爸的房间", nk.json_decode(out).name)
  end)

  it("超长房名被截断到 32 字节", function()
    lobby.create_room(ctx, nk.json_encode({
      game = "rps", name = string.rep("长", 50) }))
    local n = calls.match_creates[#calls.match_creates].params.name
    assert.is_true(#n <= 32)
    assert.equal(0, #n % 3)          -- 截在 UTF-8 边界上
  end)

  it("payload 不是合法 JSON 时返回错误而不是崩", function()
    assert.equal("bad_payload",
      nk.json_decode(lobby.create_room(ctx, "{{{")).error)
  end)
end)

describe("list_rooms", function()
  it("把 match_list 结果转成客户端要的形状", function()
    calls.stub_matches = { {
      match_id = "m1", size = 2,
      label = '{"g":"rps","n":"客厅","p":2,"m":8,"s":"waiting","h":"爸爸"}',
    } }
    local res = nk.json_decode(lobby.list_rooms(ctx, ""))
    assert.equal(1, #res.rooms)
    assert.equal("m1",   res.rooms[1].match_id)
    assert.equal("rps",  res.rooms[1].game)
    assert.equal("客厅", res.rooms[1].name)
    assert.equal(2,      res.rooms[1].count)
    assert.equal("waiting", res.rooms[1].phase)
  end)

  it("label 坏掉的房间被跳过而不是让整个列表失败", function()
    calls.stub_matches = {
      { match_id = "bad", size = 1, label = "not json" },
      { match_id = "ok",  size = 1,
        label = '{"g":"rps","n":"x","p":1,"m":8,"s":"waiting","h":"a"}' },
    }
    local res = nk.json_decode(lobby.list_rooms(ctx, ""))
    assert.equal(1, #res.rooms)
    assert.equal("ok", res.rooms[1].match_id)
  end)

  it("没有房间时返回空数组", function()
    calls.stub_matches = {}
    assert.equal(0, #nk.json_decode(lobby.list_rooms(ctx, "")).rooms)
  end)
end)

describe("list_games", function()
  it("列出注册表里的游戏", function()
    local res = nk.json_decode(lobby.list_games(ctx, ""))
    local ids = {}
    for _, g in ipairs(res.games) do ids[g.id] = true end
    assert.is_true(ids.rps)
  end)
end)
```

- [ ] **Step 3: 跑测试确认失败**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: FAIL,`module 'lobby_rpc' not found`

- [ ] **Step 4: 写实现**

Create `nakama/modules/lobby_rpc.lua`:

```lua
-- 大厅 RPC。客户端不直接 match_create,一律走这里,服务端校验。
local nk    = require("nakama")
local games = require("games.init")

local M = {}

local NAME_MAX = 32

local function utf8_trim(s, max_bytes)
  if #s <= max_bytes then return s end
  local i = max_bytes
  while i > 0 do
    local b = string.byte(s, i + 1)
    if b == nil or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return string.sub(s, 1, i)
end

local function err(code) return nk.json_encode({ error = code }) end

--- 建房。payload: {game, name}
function M.create_room(ctx, payload)
  local ok, req = pcall(nk.json_decode, payload)
  if not ok or type(req) ~= "table" then return err("bad_payload") end
  if not games.exists(req.game) then return err("unknown_game") end

  local name = req.name
  if name == nil or name == "" then
    name = (ctx.username or "某人") .. "的房间"
  end
  name = utf8_trim(tostring(name), NAME_MAX)

  local match_id = nk.match_create("room", {
    game      = req.game,
    name      = name,
    host      = ctx.user_id,
    host_name = ctx.username,
  })
  return nk.json_encode({ match_id = match_id, name = name })
end

--- 列房。只列 authoritative match,坏 label 跳过。
function M.list_rooms(_, _)
  local matches = nk.match_list(50, true, nil, 0, 100, nil) or {}
  local rooms = {}
  for _, m in ipairs(matches) do
    local ok, l = pcall(nk.json_decode, m.label or "")
    if ok and type(l) == "table" and l.g ~= nil then
      rooms[#rooms + 1] = {
        match_id = m.match_id,
        game     = l.g,
        name     = l.n,
        count    = l.p,
        max      = l.m,
        phase    = l.s,
        -- 注意:这里是显示名。ROOM_STATE 里的 host 是 user_id,别混。
        host_name = l.h,
      }
    end
  end
  return nk.json_encode({ rooms = rooms })
end

--- 列出可玩的游戏,供建房界面用。
function M.list_games(_, _)
  return nk.json_encode({ games = games.list() })
end

return M
```

- [ ] **Step 5: 在 main.lua 注册 RPC**

Replace `nakama/modules/main.lua` 全文:

```lua
-- Nakama 启动时执行一次。所有 RPC 注册都放这里。
local nk    = require("nakama")
local lobby = require("lobby_rpc")

nk.register_rpc(lobby.create_room, "create_room")
nk.register_rpc(lobby.list_rooms,  "list_rooms")
nk.register_rpc(lobby.list_games,  "list_games")

nk.logger_info("family-lobby modules loaded")
```

- [ ] **Step 6: 跑测试确认通过**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `65 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 7: 重启 Nakama,确认模块真的加载了**

```bash
cd nakama && docker compose restart nakama && sleep 15
docker compose logs --tail=50 nakama | grep -iE "family-lobby|error|lua"
```

Expected: 看到 `family-lobby modules loaded`,**且没有任何 Lua 错误**。
若报 `match_signal not found` 之类,说明 `room.lua` 少了必需回调。

- [ ] **Step 8: 用 curl 打通建房 → 列房**

```bash
TOKEN=$(curl -s -X POST \
  "http://127.0.0.1:7350/v2/account/authenticate/device?create=true" \
  -H "Content-Type: application/json" -u "family-lobby-2026:" \
  -d '{"id":"0123456789abcdef0123456789abcdef"}' | jq -r .token)

curl -s -X POST "http://127.0.0.1:7350/v2/rpc/create_room" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '"{\"game\":\"rps\",\"name\":\"客厅\"}"' | jq -r .payload

curl -s -X POST "http://127.0.0.1:7350/v2/rpc/list_rooms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '""' | jq -r .payload
```

Expected:
第一条返回 `{"match_id":"<uuid>.nakama","name":"客厅"}`(后缀是节点名;compose 没设 `--name`,所以是 `nakama`)
第二条返回含该房间的 `{"rooms":[{"match_id":"...","game":"rps","name":"客厅","count":0,...}]}`

> ⚠️ **`match_create` 到 `match_list` 可见有约 0.9–1.5 秒索引延迟**(实测,Nakama match registry 的固有行为,不是代码问题)。紧接着 `create_room` 查 `list_rooms` 很可能看不到自己刚建的房。等 1.5 秒再查,或重试几次。
> 另外**空列表会返回 `{"rooms":{}}` 而不是 `{"rooms":[]}`** —— Lua 空表编码歧义,客户端必须归一化。

**这一步通过 = 整个服务端跑通了。**

- [ ] **Step 9: 提交**

```bash
git add nakama/modules/lobby_rpc.lua nakama/modules/main.lua nakama/spec/
git commit -m "feat(lobby): create_room / list_rooms / list_games RPCs"
```

---

## Task 9: Godot 项目骨架 + ServerConnection

**Files:**
- Create: `godot/project.godot`(用编辑器建)
- Create: `godot/addons/com.heroiclabs.nakama/`(拷贝)
- Create: `godot/nakama.cfg.example`, `godot/nakama.cfg`
- Create: `godot/src/autoload/NakamaConfig.gd`
- Create: `godot/src/net/OpCodes.gd`
- Create: `godot/src/net/JsonSafe.gd`
- Create: `godot/src/autoload/ServerConnection.gd`

> Godot 端没有单测(装 GUT 属于本计划范围外)。验证方式是 `--headless --quit` 做解析检查 + 手工观察。每个任务都给了确切的预期现象。

- [ ] **Step 1: 建 Godot 项目**

打开 Godot → New Project:
- Project Path: `/Users/matthew/projects/meirongdev/godot-games/godot`
- Renderer: **Compatibility**(以后要导 Web 版就必须选它,Forward+ 导不了)
- 建完先关掉编辑器

- [ ] **Step 2: 装 Nakama 客户端 addon**

```bash
cd /tmp && rm -rf nakama-godot
git clone --depth 1 https://github.com/heroiclabs/nakama-godot.git
mkdir -p /Users/matthew/projects/meirongdev/godot-games/godot/addons
cp -r nakama-godot/addons/com.heroiclabs.nakama \
      /Users/matthew/projects/meirongdev/godot-games/godot/addons/
rm -rf /Users/matthew/projects/meirongdev/godot-games/godot/addons/com.heroiclabs.nakama/Satori
```

用 master 不用 v3.4.0 release:后者停在 2024-03,master 上有 Godot 4.4 兼容修复和 `Nakama.get_device_id()`。Satori 是商业 LiveOps 产品,自建用不到,删掉减体积。

- [ ] **Step 3: 写连接配置**

Create `godot/nakama.cfg.example`:

```ini
[nakama]
host="127.0.0.1"
port=7350
scheme="http"
server_key="family-lobby-2026"
```

```bash
cp godot/nakama.cfg.example godot/nakama.cfg
```

`nakama.cfg` 已在 `.gitignore` 里。以后连 homelab 只改这一份。

- [ ] **Step 4: 写配置加载器**

Create `godot/src/autoload/NakamaConfig.gd`:

```gdscript
class_name NakamaConfig
extends RefCounted

const PATH := "res://nakama.cfg"

var host := "127.0.0.1"
var port := 7350
var scheme := "http"
var server_key := "family-lobby-2026"
## 同机联调用:附加到设备 ID 后面,让多个实例登进不同账号
var device_suffix := ""

static func load_or_default() -> NakamaConfig:
	var cfg := NakamaConfig.new()
	var file := ConfigFile.new()
	if file.load(PATH) == OK:
		cfg.host       = file.get_value("nakama", "host", cfg.host)
		cfg.port       = file.get_value("nakama", "port", cfg.port)
		cfg.scheme     = file.get_value("nakama", "scheme", cfg.scheme)
		cfg.server_key = file.get_value("nakama", "server_key", cfg.server_key)

	# 同机开多个客户端联调时用:
	#   godot --path godot -- --nakama-host=192.168.1.50
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nakama-host="):
			cfg.host = arg.split("=", true, 1)[1]
		# 设备认证按机器 ID,同机多实例会撞成同一个账号。
		#   godot --path godot -- --device-suffix=2
		elif arg.begins_with("--device-suffix="):
			cfg.device_suffix = arg.split("=", true, 1)[1]
	return cfg
```

- [ ] **Step 5: 写 OpCode 表**

Create `godot/src/net/OpCodes.gd`:

```gdscript
class_name OpCodes
extends RefCounted

## 与服务端手工同步。分段规则见 spec §8。
## 1-19 房间通用 / 20-39 石头剪刀布 / 40-59 成语接龙 / 60+ 预留

# --- 房间通用 ---
const READY        := 1    # C→S {ready: bool}
const START        := 2    # C→S {}          仅房主
const SETTINGS     := 3    # C→S {...}       仅房主
const ROOM_STATE   := 10   # S→C {phase, players[], host, settings}
const GAME_STARTED := 11   # S→C {game, settings}
const GAME_OVER    := 12   # S→C {results[]}
const ERROR        := 13   # S→C {msg}

# --- 石头剪刀布 ---
const THROW        := 20   # C→S {hand: 0|1|2}
const ROUND_BEGIN  := 30   # S→C {round, alive[], seconds, deadline_tick}
const ROUND_RESULT := 31   # S→C {hands{}, winner, draw, advanced[], eliminated[], afk[], draw_streak}

# 手势
const ROCK    := 0
const PAPER   := 1
const SCISSOR := 2
```

- [ ] **Step 5b: 写 JSON 防御助手**

服务端是 Lua,而 Lua 分不清「空表」和「空数组」—— `nk.json_encode({})` 产出 `{}` 不是 `[]`。
客户端把它赋给静态 `Array` 类型的变量会直接抛运行时错误。这个坑在本项目里踩过三次
(`list_rooms` / `list_games` / `ROUND_RESULT.afk`),所以统一收敛到一个助手里。

Create `godot/src/net/JsonSafe.gd`:

```gdscript
class_name JsonSafe
extends RefCounted
## 服务端 JSON 的防御性读取。
##
## Lua 分不清「空表」和「空数组」,`nk.json_encode({})` 产出的是 `{}` 而不是 `[]`。
## 于是服务端一个本该是数组的空字段,到客户端会解析成 Dictionary;直接赋给
## 静态 Array 类型的变量会抛:
##     Trying to assign value of type 'Dictionary' to a variable of type 'Array'
## 这个坑在本项目里已经踩过三次(list_rooms / list_games / ROUND_RESULT.afk),
## 所以统一收敛到这里。凡是从服务端读数组,一律走 arr()。


## 取出一个必定是 Array 的值。缺失、类型不对、或是 Lua 的空表 `{}`,都返回 []。
static func arr(source: Dictionary, key: String) -> Array:
	var value = source.get(key, [])
	return value if value is Array else []


## 同上,但用于取字典字段(Lua 空表在这里反而是对的)。
static func dict(source: Dictionary, key: String) -> Dictionary:
	var value = source.get(key, {})
	return value if value is Dictionary else {}
```

**规矩:凡是从服务端 payload 里读数组,一律走 `JsonSafe.arr()`,不要直接 `payload.get(k, [])`。**

- [ ] **Step 6: 写 ServerConnection**

Create `godot/src/autoload/ServerConnection.gd`:

```gdscript
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
var _config: NakamaConfig


func _ready() -> void:
	_config = NakamaConfig.load_or_default()
	var cfg := _config
	_client = Nakama.create_client(cfg.server_key, cfg.host, cfg.port, cfg.scheme)
	_client.timeout = 10
	_client.auto_refresh = true


# ---------------------------------------------------------------- 认证

## 设备认证。家庭局不需要注册流程,一键进。
func login_async() -> int:
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
```

- [ ] **Step 7: 注册 Autoload**

打开 Godot → Project → Project Settings → Globals(Autoload),**按这个顺序**加两条:

| # | Path | Node Name |
|---|---|---|
| 1 | `res://addons/com.heroiclabs.nakama/Nakama.gd` | `Nakama` |
| 2 | `res://src/autoload/ServerConnection.gd` | `ServerConnection` |

> ⚠️ **顺序不能反。** `ServerConnection._ready()` 里要调 `Nakama.create_client()`,`Nakama` 排在后面的话会拿到 null。

- [ ] **Step 8: 解析检查**

> ⚠️ **`--editor` 不能省。** 不加它的话,Godot 在加载任何脚本**之前**就因为「没有主场景」退出了 —— 正确代码和语法错误代码的输出**逐字节相同**,这条检查等于没做。已用故障注入验证:
> ```
> 无 --editor,正确代码:  Error: Can't run project: no main scene defined
> 无 --editor,注入语法错误:Error: Can't run project: no main scene defined   ← 一样
> 加 --editor,注入语法错误:SCRIPT ERROR: Parse Error: Expected parameter name.
> ```
> Task 10 设了 `run/main_scene` 之后不加也能用,但 `--editor` 一直是更彻底的检查(它会完整扫描项目、注册全局类、编译所有 autoload)。

```bash
cd /Users/matthew/projects/meirongdev/godot-games
godot --headless --editor --path godot --quit 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" || echo "无脚本错误"
```

Expected: `无脚本错误`

- [ ] **Step 9: 提交**

```bash
git add godot/
git commit -m "feat(client): godot project skeleton with ServerConnection facade"
```

---

## Task 10: 登录 → 大厅

**Files:**
- Create: `godot/src/lobby/Login.tscn` / `Login.gd`
- Create: `godot/src/lobby/Lobby.tscn` / `Lobby.gd`

- [ ] **Step 1: 建 Login 场景**

在 Godot 里新建场景,节点树:

```
Login (Control)                    ← 挂 Login.gd,Layout 设 Full Rect
└── Center (CenterContainer)       ← Full Rect
    └── Box (VBoxContainer)
        ├── Title (Label)          ← text "家庭游戏大厅"
        ├── NameEdit (LineEdit)    ← placeholder "你的名字"
        ├── EnterButton (Button)   ← text "进入大厅"
        └── Status (Label)
```

存为 `res://src/lobby/Login.tscn`。

- [ ] **Step 2: 写 Login.gd**

Create `godot/src/lobby/Login.gd`:

```gdscript
extends Control

const NAME_KEY := "user://display_name.cfg"

@onready var name_edit: LineEdit = $Center/Box/NameEdit
@onready var enter_button: Button = $Center/Box/EnterButton
@onready var status: Label = $Center/Box/Status


func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	name_edit.text = _load_name()
	status.text = ""


func _on_enter_pressed() -> void:
	var display_name := name_edit.text.strip_edges()
	if display_name.is_empty():
		status.text = "先起个名字"
		return

	enter_button.disabled = true
	status.text = "连接中…"

	if await ServerConnection.login_async() != OK:
		_fail("登录失败:%s" % ServerConnection.error_message)
		return

	if await ServerConnection.set_display_name_async(display_name) != OK:
		_fail("改名失败:%s" % ServerConnection.error_message)
		return

	if await ServerConnection.connect_to_server_async() != OK:
		_fail("实时连接失败:%s" % ServerConnection.error_message)
		return

	_save_name(display_name)
	get_tree().change_scene_to_file("res://src/lobby/Lobby.tscn")


func _fail(msg: String) -> void:
	status.text = msg
	enter_button.disabled = false


func _save_name(n: String) -> void:
	var f := ConfigFile.new()
	f.set_value("user", "name", n)
	f.save(NAME_KEY)


func _load_name() -> String:
	var f := ConfigFile.new()
	if f.load(NAME_KEY) == OK:
		return f.get_value("user", "name", "")
	return ""
```

- [ ] **Step 3: 设为主场景并跑**

Project → Project Settings → Application → Run → Main Scene = `res://src/lobby/Login.tscn`

先确认 Nakama 在跑(`cd nakama && docker compose ps`),然后 F5。

Expected:
1. 输名字点「进入大厅」→ 状态变「连接中…」
2. 因为 `Lobby.tscn` 还没建,会报 `change_scene_to_file` 失败 —— **这一步预期如此**
3. **关键**:Godot 控制台**不应该**出现任何 `[Nakama] status=...` 报错

若报 `status=401` → `nakama.cfg` 的 `server_key` 和 docker-compose 里的 `--socket.server_key` 对不上。
若报 `status=-1` → Nakama 没起来,或 host/port 错。

- [ ] **Step 4: 建 Lobby 场景**

节点树:

```
Lobby (Control)                        ← 挂 Lobby.gd,Full Rect
└── HBox (HBoxContainer)               ← Full Rect
    ├── Left (VBoxContainer)           ← custom_minimum_size.x = 200
    │   ├── OnlineTitle (Label)        ← text "在线"
    │   ├── OnlineList (ItemList)      ← size_flags_vertical = Expand+Fill
    │   ├── ChatLog (RichTextLabel)    ← scroll_following = on
    │   └── ChatEdit (LineEdit)        ← placeholder "说点什么…"
    └── Right (VBoxContainer)          ← size_flags_horizontal = Expand+Fill
        ├── RoomTitle (Label)          ← text "房间"
        ├── RoomList (ItemList)        ← Expand+Fill
        ├── RefreshButton (Button)     ← text "刷新"
        └── CreateBox (HBoxContainer)
            ├── GameOption (OptionButton)
            ├── RoomNameEdit (LineEdit) ← placeholder "房间名"
            └── CreateButton (Button)   ← text "建房"
```

存为 `res://src/lobby/Lobby.tscn`。

- [ ] **Step 5: 写 Lobby.gd**

Create `godot/src/lobby/Lobby.gd`:

```gdscript
extends Control

const REFRESH_INTERVAL := 3.0   # Nakama 没有房间列表推送,只能轮询

@onready var online_list: ItemList = $HBox/Left/OnlineList
@onready var chat_log: RichTextLabel = $HBox/Left/ChatLog
@onready var chat_edit: LineEdit = $HBox/Left/ChatEdit
@onready var room_list: ItemList = $HBox/Right/RoomList
@onready var refresh_button: Button = $HBox/Right/RefreshButton
@onready var game_option: OptionButton = $HBox/Right/CreateBox/GameOption
@onready var room_name_edit: LineEdit = $HBox/Right/CreateBox/RoomNameEdit
@onready var create_button: Button = $HBox/Right/CreateBox/CreateButton

var _rooms: Array = []
var _timer := 0.0
var _busy := false

const GAME_LABELS := { "rps": "石头剪刀布", "idiom": "成语接龙" }


func _ready() -> void:
	ServerConnection.lobby_presence_changed.connect(_on_presence_changed)
	ServerConnection.lobby_message.connect(_on_message)
	refresh_button.pressed.connect(_refresh_rooms)
	create_button.pressed.connect(_on_create_pressed)
	chat_edit.text_submitted.connect(_on_chat_submitted)
	room_list.item_activated.connect(_on_room_activated)

	await ServerConnection.join_lobby_async()
	await _load_games()
	_refresh_rooms()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_INTERVAL:
		_timer = 0.0
		_refresh_rooms()


func _on_presence_changed(users: Array) -> void:
	online_list.clear()
	for name in users:
		online_list.add_item(str(name))


func _on_message(_sender_id: String, name: String, text: String) -> void:
	chat_log.append_text("[b]%s[/b]: %s\n" % [name, text])


func _on_chat_submitted(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	chat_edit.clear()
	await ServerConnection.send_lobby_message_async(t)


func _load_games() -> void:
	game_option.clear()
	for g in await ServerConnection.list_games_async():
		var id: String = g["id"]
		game_option.add_item(GAME_LABELS.get(id, id))
		game_option.set_item_metadata(game_option.item_count - 1, id)


func _refresh_rooms() -> void:
	if _busy:
		return
	_busy = true
	_rooms = await ServerConnection.list_rooms_async()
	_busy = false

	room_list.clear()
	for r in _rooms:
		var label := "%s · %s  (%d/%d)  房主 %s" % [
			GAME_LABELS.get(r["game"], r["game"]), r["name"],
			r["count"], r["max"], r["host_name"]]
		if r["phase"] != "waiting":
			label += "  [进行中]"
		room_list.add_item(label)
		# 进行中的房间不能加入,置灰
		room_list.set_item_disabled(room_list.item_count - 1, r["phase"] != "waiting")


func _on_room_activated(index: int) -> void:
	if index < 0 or index >= _rooms.size():
		return
	if await ServerConnection.join_room_async(_rooms[index]["match_id"]) == OK:
		get_tree().change_scene_to_file("res://src/room/Room.tscn")


func _on_create_pressed() -> void:
	if game_option.selected < 0:
		return
	create_button.disabled = true
	var game_id: String = game_option.get_item_metadata(game_option.selected)
	var id := await ServerConnection.create_room_async(
		game_id, room_name_edit.text.strip_edges())
	create_button.disabled = false
	if not id.is_empty():
		get_tree().change_scene_to_file("res://src/room/Room.tscn")
```

- [ ] **Step 6: 解析检查 + 手工验证**

```bash
godot --headless --editor --path godot --quit 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" || echo "无脚本错误"
```

然后开两个实例(要加 `--device-suffix`,见 Task 13),各输一个名字进大厅。

Expected:
1. 两边的「在线」列表都显示两个名字
2. 一边发聊天,另一边立刻看到
3. 一边建房,**约 5 秒内**另一边的房间列表出现该房间(3 秒轮询间隔 + 最多 1.5 秒服务端索引延迟)
4. 建房的那边会因为 `Room.tscn` 不存在而报错 —— 下个任务建

- [ ] **Step 7: 提交**

```bash
git add godot/src/lobby/
git commit -m "feat(lobby): online list, chat, room list and room creation"
```

---

## Task 11: 房间框架(GameBase + RoomController)

**Files:**
- Create: `godot/src/room/GameBase.gd`
- Create: `godot/src/room/Room.tscn`
- Create: `godot/src/room/RoomController.gd`

★ 客户端侧的框架层,和服务端 `room.lua` 对称。**加第三个游戏不改这两个文件**,只在 `GAME_SCENES` 加一行。

- [ ] **Step 1: 写游戏接口**

Create `godot/src/room/GameBase.gd`:

```gdscript
class_name GameBase
extends Control
## 所有游戏场景的基类。游戏场景不碰 Nakama,只通过 send_to_server 发消息。

## 由 RoomController 接到 ServerConnection.send()
signal send_to_server(op_code: int, data: Dictionary)

## 我的 user_id,由 RoomController 注入
var my_id := ""
## [{id, name, ready}] 的玩家数组
var players: Array = []


## 开局。settings 是房主定的那份。
func game_started(_settings: Dictionary, _players: Array) -> void:
	pass


## 收到本游戏 OpCode 段内的服务端消息。
func handle_server(_op_code: int, _payload: Dictionary) -> void:
	pass


## 局终。results 是 [{id, name, rank}]。
func game_ended(_results: Array) -> void:
	pass


## 便捷方法,给子类用。
func send(op_code: int, data: Dictionary = {}) -> void:
	send_to_server.emit(op_code, data)


## user_id -> 显示名。找不到就回退成 id 前 6 位。
func name_of(uid: String) -> String:
	for p in players:
		if p["id"] == uid:
			return p["name"]
	return uid.substr(0, 6)
```

- [ ] **Step 2: 建 Room 场景**

节点树:

```
Room (Control)                           ← 挂 RoomController.gd,Full Rect
└── VBox (VBoxContainer)                 ← Full Rect
    ├── Header (HBoxContainer)
    │   ├── RoomTitle (Label)            ← size_flags_horizontal = Expand+Fill
    │   └── LeaveButton (Button)         ← text "离开"
    ├── Body (HBoxContainer)             ← size_flags_vertical = Expand+Fill
    │   ├── PlayerPanel (VBoxContainer)  ← custom_minimum_size.x = 200
    │   │   ├── PlayerList (ItemList)    ← Expand+Fill
    │   │   ├── ReadyButton (CheckButton)← text "准备"
    │   │   └── StartButton (Button)     ← text "开始游戏"
    │   └── GameSlot (Control)           ← Expand+Fill,游戏场景挂这里
    └── Status (Label)
```

存为 `res://src/room/Room.tscn`。

- [ ] **Step 3: 写 RoomController**

Create `godot/src/room/RoomController.gd`:

```gdscript
extends Control
## 通用房间控制器。独占准备/开局/结算,把游戏段消息转发给挂载的 GameBase。
## ★ 加新游戏只需在 GAME_SCENES 加一行。

const GAME_SCENES := {
	"rps": "res://src/games/rps/RpsGame.tscn",
}

@onready var room_title: Label = $VBox/Header/RoomTitle
@onready var leave_button: Button = $VBox/Header/LeaveButton
@onready var player_list: ItemList = $VBox/Body/PlayerPanel/PlayerList
@onready var ready_button: CheckButton = $VBox/Body/PlayerPanel/ReadyButton
@onready var start_button: Button = $VBox/Body/PlayerPanel/StartButton
@onready var game_slot: Control = $VBox/Body/GameSlot
@onready var status: Label = $VBox/Status

var _game: GameBase = null
var _players: Array = []
var _host := ""
var _phase := "waiting"


func _ready() -> void:
	ServerConnection.room_event.connect(_on_room_event)
	leave_button.pressed.connect(_on_leave)
	ready_button.toggled.connect(_on_ready_toggled)
	start_button.pressed.connect(func(): ServerConnection.send(OpCodes.START))
	start_button.disabled = true
	status.text = "等待其他人…"


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

	player_list.clear()
	for p in _players:
		var line: String = p["name"]
		if p["id"] == _host:
			line += "  (房主)"
		line += "  ✓" if p["ready"] else "  …"
		player_list.add_item(line)

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
		status.text = "本局结束"
	else:
		status.text = "🏆 %s 获胜!" % results[0]["name"]
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
```

- [ ] **Step 4: 解析检查**

```bash
godot --headless --editor --path godot --quit 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" || echo "无脚本错误"
```

Expected: `无脚本错误`(`RpsGame.tscn` 还不存在,但 `load()` 是运行时才解析,不影响)

- [ ] **Step 5: 手工验证房间流程**

开两个实例(同样要加 `--device-suffix`,见 Task 13),两边进大厅,一边建房、另一边双击加入。

Expected:
1. 两边都进 Room 场景,玩家列表显示两个人
2. 房主那边有「开始游戏」按钮,另一边没有
3. 勾「准备」→ 两边列表里该玩家后面变 ✓
4. 只有一人准备时点开始 → 状态栏显示「还有人没准备」
5. 非房主点开始(按钮本来就隐藏,可临时改代码测)→「只有房主能开始」
6. 两人都准备后点开始 → 状态栏显示「不认识的游戏:rps」 —— **这一步预期如此**,下个任务建 RpsGame

- [ ] **Step 6: 提交**

```bash
git add godot/src/room/
git commit -m "feat(room): generic room controller and GameBase interface"
```

---

## Task 12: 石头剪刀布客户端

**Files:**
- Create: `godot/src/games/rps/RpsGame.tscn`
- Create: `godot/src/games/rps/RpsGame.gd`

- [ ] **Step 1: 建 RpsGame 场景**

节点树(根节点 Control,**脚本继承 GameBase**):

```
RpsGame (Control)                     ← 挂 RpsGame.gd,Full Rect
└── VBox (VBoxContainer)              ← Full Rect
    ├── RoundLabel (Label)            ← 居中
    ├── Countdown (ProgressBar)       ← show_percentage = off
    ├── Hands (HBoxContainer)         ← alignment = Center
    │   ├── RockButton (Button)       ← text "✊"  custom_minimum_size 80x80
    │   ├── PaperButton (Button)      ← text "✋"
    │   └── ScissorButton (Button)    ← text "✌"
    ├── Result (RichTextLabel)        ← Expand+Fill,bbcode_enabled = on
    └── Spectator (Label)             ← text "你已出局,观战中",visible = off
```

存为 `res://src/games/rps/RpsGame.tscn`。

- [ ] **Step 2: 写 RpsGame.gd**

Create `godot/src/games/rps/RpsGame.gd`:

```gdscript
extends GameBase
## 石头剪刀布客户端。只负责显示和发送出拳,胜负一律由服务端裁定。

const HAND_ICON := { 0: "✊", 1: "✋", 2: "✌️" }
const HAND_NAME := { 0: "石头", 1: "布", 2: "剪刀" }

@onready var round_label: Label = $VBox/RoundLabel
@onready var countdown: ProgressBar = $VBox/Countdown
@onready var hands_box: HBoxContainer = $VBox/Hands
@onready var result: RichTextLabel = $VBox/Result
@onready var spectator: Label = $VBox/Spectator

var _alive: Array = []
var _thrown := false
var _time_left := 0.0
var _round_seconds := 3.0


func _ready() -> void:
	$VBox/Hands/RockButton.pressed.connect(_throw.bind(OpCodes.ROCK))
	$VBox/Hands/PaperButton.pressed.connect(_throw.bind(OpCodes.PAPER))
	$VBox/Hands/ScissorButton.pressed.connect(_throw.bind(OpCodes.SCISSOR))
	countdown.min_value = 0.0
	countdown.max_value = 1.0


func game_started(_settings: Dictionary, _players: Array) -> void:
	result.clear()
	result.append_text("[i]准备…[/i]\n")


func handle_server(op_code: int, payload: Dictionary) -> void:
	match op_code:
		OpCodes.ROUND_BEGIN:  _on_round_begin(payload)
		OpCodes.ROUND_RESULT: _on_round_result(payload)


func game_ended(results: Array) -> void:
	_set_input_enabled(false)
	countdown.value = 0.0
	round_label.text = "本局结束"
	if not results.is_empty():
		result.append_text("\n[b]🏆 %s 获胜![/b]\n" % results[0]["name"])


# ---------------------------------------------------------------- 回合

func _on_round_begin(p: Dictionary) -> void:
	_alive = JsonSafe.arr(p, "alive")
	_thrown = false
	_round_seconds = float(p.get("seconds", 3.0))
	_time_left = _round_seconds

	var streak := int(p.get("draw_streak", 0))
	round_label.text = "第 %d 轮 · 剩 %d 人" % [int(p.get("round", 0)), _alive.size()]
	if streak > 0:
		round_label.text += "  (连续平局 ×%d,加速!)" % streak

	var i_am_alive := _alive.has(my_id)
	spectator.visible = not i_am_alive
	hands_box.visible = i_am_alive
	_set_input_enabled(i_am_alive)


func _on_round_result(p: Dictionary) -> void:
	_set_input_enabled(false)
	_time_left = 0.0
	countdown.value = 0.0

	var hands := JsonSafe.dict(p, "hands")
	var line := ""
	for uid in hands.keys():
		line += "%s %s   " % [name_of(str(uid)), HAND_ICON.get(int(hands[uid]), "?")]
	result.append_text(line.strip_edges() + "\n")

	if p.get("draw", false):
		result.append_text("[color=gray]平局,重来[/color]\n\n")
		return

	var winner := int(p.get("winner", 0))
	result.append_text("[b]%s %s 胜[/b]\n" % [HAND_ICON[winner], HAND_NAME[winner]])

	var eliminated := JsonSafe.arr(p, "eliminated")
	if not eliminated.is_empty():
		var names := PackedStringArray()
		for uid in eliminated:
			names.append(name_of(str(uid)))
		result.append_text("[color=red]淘汰:%s[/color]\n" % ", ".join(names))

	var afk := JsonSafe.arr(p, "afk")
	if not afk.is_empty():
		var names := PackedStringArray()
		for uid in afk:
			names.append(name_of(str(uid)))
		result.append_text("[color=gray](%s 没出拳,系统代出)[/color]\n" % ", ".join(names))

	result.append_text("\n")


# ---------------------------------------------------------------- 输入

func _throw(hand: int) -> void:
	if _thrown:
		return
	_thrown = true
	_set_input_enabled(false)
	round_label.text += "  你出了 %s" % HAND_ICON[hand]
	send(OpCodes.THROW, {"hand": hand})


func _set_input_enabled(on: bool) -> void:
	for b in hands_box.get_children():
		if b is Button:
			b.disabled = not on


func _process(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left = max(0.0, _time_left - delta)
	countdown.value = _time_left / _round_seconds
```

- [ ] **Step 3: 解析检查**

```bash
godot --headless --editor --path godot --quit 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" || echo "无脚本错误"
```

Expected: `无脚本错误`

- [ ] **Step 4: 两人对局验证**

开两个实例(同样要加 `--device-suffix`,见 Task 13),进同一房间,都准备,房主开始。

Expected:
1. 两边同时看到「第 1 轮 · 剩 2 人」和倒计时条
2. **一边出拳后,另一边看不到任何提示** —— 服务端在收齐前不广播,这是权威模式的核心
3. 两边都出拳后立刻揭晓(不等满 3 秒)
4. 出现淘汰后,输的那边 `Spectator` 显示「你已出局,观战中」,出拳按钮消失
5. 状态栏显示「🏆 xxx 获胜!」,准备勾选自动取消,可以再来一局

- [ ] **Step 5: 提交**

```bash
git add godot/src/games/
git commit -m "feat(rps): rock-paper-scissors client scene"
```

---

## Task 13: 端到端验收

**Files:** 无新文件,只验证

- [ ] **Step 1: 全量单测**

```bash
cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted
```

Expected: `65 successes / 0 failures / 0 errors / 0 pending`

- [ ] **Step 2: 服务端零错误**

```bash
cd nakama && docker compose restart nakama && sleep 15
docker compose logs --tail=100 nakama | grep -iE "error|panic" || echo "服务端无错误"
```

Expected: `服务端无错误`

- [ ] **Step 3: 三人局验证平局加速**

开三个实例。**不能直接用 `Run Multiple Instances`** —— 设备认证按机器 ID,三个窗口会登进同一个账号,服务端当成同一个人重连,多人测不了。用命令行加设备后缀:

```bash
cd /Users/matthew/projects/meirongdev/godot-games
godot --path godot -- --device-suffix=a &
godot --path godot -- --device-suffix=b &
godot --path godot -- --device-suffix=c &
```

三人进同一房间开局。

三人局的平局率是 33%,多打几轮一定能撞上连续平局。

Expected:
1. 撞上平局时,标题出现「(连续平局 ×1,加速!)」
2. **下一轮的倒计时条明显更短**(3.0s → 2.5s → 2.0s → 1.5s 触底)
3. 出现淘汰后,再下一轮倒计时**恢复到 3.0s**
4. 一次淘汰可能同时淘汰两个人(比如 ✊✊✌ → 剪刀那个出局)

- [ ] **Step 4: 走神代出验证**

三人局,开局后**故意让一个人不点**,等倒计时走完。

Expected:
1. 该玩家被系统随机代出一个手势
2. 结果区显示「(xxx 没出拳,系统代出)」
3. 该玩家**没有因为走神直接出局**(除非随机代出的手势正好是输的那个)

- [ ] **Step 5: 断线不炸验证**

对局进行中,直接关掉其中一个窗口。

Expected:
1. 剩下的窗口继续正常推进,不卡死
2. 玩家列表里少一个人
3. 如果关掉的是房主,**房主自动转移**给下一位(该玩家出现「开始游戏」按钮)
4. 打到剩 1 人时正常结算

- [ ] **Step 6: 房间列表状态验证**

一边在房间里玩,另一边留在大厅。

Expected:
1. 大厅那边的房间列表约 5 秒内把该房间标成 `[进行中]` 且置灰不可点
2. 局终回到 waiting 后,约 5 秒内恢复成可加入

- [ ] **Step 7: 合并**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
git checkout main
git merge --no-ff feat/lobby-and-rps -m "feat: game lobby with rock-paper-scissors"
```

---

## 验收标准

全部勾完即视为 M1–M3 完成:

- [ ] `busted` 65 项全绿
- [ ] Nakama 启动日志无 Lua 错误
- [ ] 三人能在同一房间打完一整局猜拳
- [ ] 一边出拳时另一边看不到(权威性成立)
- [ ] 连续平局时倒计时可见地缩短
- [ ] 中途关窗口不影响其他人
- [ ] 房间列表在大厅侧 3 秒内反映房间状态

## 布局教训(M4 做成语接龙时照这个来)

第一版所有 `.tscn` 只写了节点树,没写任何尺寸属性。结果是所有控件都取 Godot 的默认最小尺寸——
表单只有 90px 宽,几个小方块飘在大片空白里,完全没法用。而这一点**解析检查和节点路径检查都发现不了**,
因为语法和结构都是对的。

必须显式设定的东西:

| 项目 | 做法 |
|---|---|
| 全局字号 | `godot/src/ui/family.tres` 一个 Theme 管所有,别逐节点覆盖 |
| 窗口缩放 | `project.godot` 的 `stretch/mode="canvas_items"` + `aspect="expand"`,不设的话窗口放大只是留白变多 |
| 页面留白 | 根容器用 anchor `offset_*` 内缩(**不要插 MarginContainer** —— `.gd` 里的 `$Path` 是硬编码的,加节点会全断) |
| 触摸目标 | 按钮/输入框 `custom_minimum_size` 至少 48–56px 高,手机上才点得中 |
| 该扩展的区域 | `size_flags_vertical = 3`,否则 ItemList / RichTextLabel 会被压成 0 高 |
| RichTextLabel | 默认**没有背景**,不给 `theme_override_styles/normal` 就是隐形的 |
| emoji | `✌` (U+270C) 默认是文字呈现会渲染成线框,要加变体选择符 `✌️` (U+FE0F) |

验证手段:`Godot --path godot --write-movie /tmp/shot.png --quit-after 10` 能直接出截图,
配合临时改 `run/main_scene` 可以拍任意场景。这是唯一能发现视觉问题的办法。

## 本计划刻意不做(与 spec 的已知偏差)

| spec 条目 | 本计划的做法 | 为什么 |
|---|---|---|
| §10「游戏中掉线保留 30 秒」 | `match_leave` 立即移除玩家 | 30 秒宽限期属于 M5。本计划只保证**掉线不炸**(Task 13 Step 5 验证),不保证能接回来 |
| §10「重连替换 presence」 | `match_join_attempt` 已放行同 user_id 重入 | 服务端放行逻辑做了,但客户端没有自动重连 UI,得手动重进 |
| §6.3 观战席 | 只有一个「你已出局,观战中」标签 | 完整观战席属 M5 |
| §7 成语接龙 | 不做 | M4 独立计划 |
| §9.3/9.4 语音输入 | 不做 | M4 |

## 下一步

- **M4 成语接龙** —— 独立计划。需要:词库工具链(`tools/build_index.py`)、`rules/idiom_rules.lua`(接龙判定 + 拼音容错匹配)、`games/idiom.lua`(抢麦状态机)、`IdiomGame.tscn`。
  **框架层(`room.lua` / `RoomController.gd`)一个字都不用改** —— 这是本计划最该被验证的设计假设。
- **M5 打磨** —— 断线重连、观战席、排行榜。
