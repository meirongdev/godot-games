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
