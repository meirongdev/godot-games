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
