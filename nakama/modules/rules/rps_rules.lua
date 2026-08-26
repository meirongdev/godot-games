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

local COUNTDOWN_BASE  = 3.0
local COUNTDOWN_STEP  = 0.5
local COUNTDOWN_FLOOR = 1.5
local REVEAL_DRAW     = 0.4
local REVEAL_ELIMINATE = 2.0

--- 本轮倒计时秒数。连续平局时递减,制造加速感。
-- @param draw_streak number 已连续平局的次数(出现淘汰后重置为 0)
function M.countdown_for(draw_streak)
  local v = COUNTDOWN_BASE - COUNTDOWN_STEP * draw_streak
  if v < COUNTDOWN_FLOOR then return COUNTDOWN_FLOOR end
  return v
end

--- 揭晓阶段的展示秒数。平局只闪一下,不放淘汰动画。
function M.reveal_for(is_draw)
  if is_draw then return REVEAL_DRAW end
  return REVEAL_ELIMINATE
end

return M
