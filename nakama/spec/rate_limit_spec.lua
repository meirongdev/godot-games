local rate = require("rules.rate_limit")

local WINDOW = 60000
local MAX    = 3

describe("rate_limit.check", function()
  it("空历史直接放行,并记下这一次", function()
    local ok, kept, retry = rate.check(nil, 1000, WINDOW, MAX)
    assert.is_true(ok)
    assert.same({ 1000 }, kept)
    assert.equal(0, retry)
  end)

  it("窗口内到达上限后被拒", function()
    local stamps = nil
    local ok
    for i = 1, MAX do
      ok, stamps = rate.check(stamps, 1000 + i, WINDOW, MAX)
      assert.is_true(ok)
    end
    ok = rate.check(stamps, 1000 + MAX + 1, WINDOW, MAX)
    assert.is_false(ok)
  end)

  it("被拒时不把这一次记进去 —— 否则永远等不出额度", function()
    local stamps = { 100, 200, 300 }
    local ok, kept = rate.check(stamps, 400, WINDOW, MAX)
    assert.is_false(ok)
    assert.equal(3, #kept)
  end)

  it("retry_ms 是最早那条滚出窗口还需要的时间", function()
    local _, _, retry = rate.check({ 1000, 2000, 3000 }, 5000, WINDOW, MAX)
    -- 最早的 1000 要到 61000 才出窗口,此刻 5000
    assert.equal(56000, retry)
  end)

  it("过期的时间戳被修掉,额度重新放出来", function()
    local stamps = { 1000, 2000, 3000 }
    local now = 1000 + WINDOW          -- 1000 正好滚出窗口
    local ok, kept = rate.check(stamps, now, WINDOW, MAX)
    assert.is_true(ok)
    assert.same({ 2000, 3000, now }, kept)
  end)

  it("整窗静默之后完全复位", function()
    local ok, kept = rate.check({ 1, 2, 3 }, 10 * WINDOW, WINDOW, MAX)
    assert.is_true(ok)
    assert.equal(1, #kept)
  end)

  it("max=0 时谁都不放行", function()
    assert.is_false((rate.check(nil, 0, WINDOW, 0)))
  end)
end)
