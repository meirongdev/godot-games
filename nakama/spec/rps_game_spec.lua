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
