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
