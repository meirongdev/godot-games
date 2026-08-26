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

describe("create_room 限流", function()
  -- 每个 case 换一个 user_id:lobby_rpc 的限流状态是模块级的,
  -- 跨 it 不会重置(线上也一样,VM 活着就一直记着)。
  local function ctx_for(uid) return { user_id = uid, username = "娃" } end
  local function create(uid)
    return nk.json_decode(lobby.create_room(ctx_for(uid),
      nk.json_encode({ game = "rps", name = "x" })))
  end

  it("一分钟内第 6 次建房被拒,并给出还要等多久", function()
    calls.now = 1000
    for _ = 1, 5 do assert.is_nil(create("rl-a").error) end
    local res = create("rl-a")
    assert.equal("rate_limited", res.error)
    assert.is_true(res.retry_after > 0)
  end)

  it("按 user_id 隔离,别人不受牵连", function()
    calls.now = 1000
    for _ = 1, 5 do create("rl-b") end
    assert.equal("rate_limited", create("rl-b").error)
    assert.is_nil(create("rl-c").error)
  end)

  it("窗口滚过去之后重新放行", function()
    calls.now = 1000
    for _ = 1, 5 do create("rl-d") end
    assert.equal("rate_limited", create("rl-d").error)
    calls.now = 1000 + 60000
    assert.is_nil(create("rl-d").error)
  end)

  it("被拒时没有真的建出 match", function()
    calls.now = 1000
    for _ = 1, 5 do create("rl-e") end
    local before = #calls.match_creates
    create("rl-e")
    assert.equal(before, #calls.match_creates)
  end)

  it("畸形 payload 不消耗额度", function()
    calls.now = 1000
    for _ = 1, 8 do lobby.create_room(ctx_for("rl-f"), "{{{") end
    assert.is_nil(create("rl-f").error)
  end)
end)
