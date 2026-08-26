-- 大厅 RPC。客户端不直接 match_create,一律走这里,服务端校验。
local nk    = require("nakama")
local games = require("games.init")
local rate  = require("rules.rate_limit")

local M = {}

local NAME_MAX = 32

-- 建房限流。create_room 是开放 RPC(契约 §5),而 server key 跟着 Web 制品
-- 公开发布 —— 所以「拿到 key 的人」就是「任何人」,这里才是实际防线。
local CREATE_WINDOW_MS = 60000
local CREATE_MAX       = 5
-- ⚠️ 状态在 Lua VM 内存里,每个 VM 一份。契约 §3.2 建议 lua_max_count=4,
-- 最坏情况实际上限是 4 × CREATE_MAX。家庭规模够用;要精确就得挪到
-- nk.storage,代价是每次建房多一次读 + 一次写。
local create_stamps = {}   -- user_id -> {毫秒时间戳}

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

  -- 限流放在校验之后:畸形请求不该消耗额度,每次真的建房才算一次。
  local uid = ctx.user_id
  local allowed, kept, retry_ms = rate.check(
    create_stamps[uid], nk.time(), CREATE_WINDOW_MS, CREATE_MAX)
  create_stamps[uid] = (#kept > 0) and kept or nil
  if not allowed then
    return nk.json_encode({
      error = "rate_limited",
      retry_after = math.ceil(retry_ms / 1000),
    })
  end

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
