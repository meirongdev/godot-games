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
    assert.equal("客厅", st.name)     -- 客户端标题依赖
    assert.equal("rps", st.game)
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

describe("room 空置自动关闭", function()
  it("空置超过 60 秒后 match_loop 返回 nil 结束 match", function()
    local s, d = fresh("a"), mock.dispatcher()
    -- 没人进来,空转 601 个 tick(tickrate 10 × 60s = 600)
    for _ = 1, 600 do
      s = room.match_loop(nil, d, 0, s, {})
      assert.is_not_nil(s)
    end
    assert.is_nil(room.match_loop(nil, d, 0, s, {}))
  end)

  it("有人在房间时不计空置", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a" })
    for _ = 1, 700 do
      s = room.match_loop(nil, d, 0, s, {})
    end
    assert.is_not_nil(s)
  end)

  it("人走光后重新计时,再来人则清零", function()
    local s, d = fresh("a"), mock.dispatcher()
    s = join(s, d, { "a" })
    s = room.match_leave(nil, d, 0, s, { mock.presence("a") })
    for _ = 1, 500 do s = room.match_loop(nil, d, 0, s, {}) end
    s = join(s, d, { "b" })                    -- 又有人来
    for _ = 1, 500 do s = room.match_loop(nil, d, 0, s, {}) end
    assert.is_not_nil(s)                        -- 没被关掉
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
