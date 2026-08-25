-- 石头剪刀布的纯规则。禁止 require("nakama")。
-- 手势编码:0=石头 1=布 2=剪刀。x 胜 (x+2)%3。
local M = {}

--- 判定本轮胜出手势。
-- @param hands table  user_id -> hand(0/1/2)
-- @return number|nil  胜出手势;平局返回 nil
function M.resolve(hands)
  local seen, distinct = {}, 0
  for _, h in pairs(hands) do
    if not seen[h] then seen[h] = true; distinct = distinct + 1 end
  end
  if distinct ~= 2 then return nil end

  local a, b
  for h in pairs(seen) do
    if a == nil then a = h else b = h end
  end
  -- a 胜 b 当且仅当 b == (a+2)%3,等价于 (a-b)%3 == 1
  if (a - b) % 3 == 1 then return a else return b end
end

--- 按胜出手势把玩家分成晋级与淘汰两组。
-- @return table advanced, table eliminated  两个 user_id 数组
function M.split(hands, winner)
  local advanced, eliminated = {}, {}
  for uid, h in pairs(hands) do
    if h == winner then
      advanced[#advanced + 1] = uid
    else
      eliminated[#eliminated + 1] = uid
    end
  end
  return advanced, eliminated
end

return M
