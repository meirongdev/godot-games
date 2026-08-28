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

describe("room_rules.can_join", function()
  it("waiting 未满放行", function()
    assert.is_true(rules.can_join("waiting", false, 3, 8))
  end)
  it("满员拒绝 —— 成员重连也不例外(他的位置已经被顶掉了)", function()
    local ok, why = rules.can_join("waiting", true, 8, 8)
    assert.is_false(ok)
    assert.equal("房间已满", why)
  end)
  it("对局中拒绝陌生人", function()
    local ok, why = rules.can_join("playing", false, 2, 8)
    assert.is_false(ok)
    assert.equal("游戏已开始", why)
  end)
  it("对局中放行掉线回来的成员 —— 手机断线不该被锁在门外", function()
    assert.is_true(rules.can_join("playing", true, 2, 8))
  end)
end)
