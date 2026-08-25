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
