-- 石头剪刀布适配层。只解 JSON、调 rules、广播。判定逻辑一律在 rules/rps_rules.lua。
local nk    = require("nakama")
local rules = require("rules.rps_rules")

local OP = { THROW = 20, ROUND_BEGIN = 30, ROUND_RESULT = 31, THROW_PROGRESS = 32 }

local M = {
  id          = "rps",
  op_base     = 20,
  tickrate    = 10,
  min_players = 2,
  max_players = 8,
  default_settings = { afk_random = true, draw_accel = true },
}

local function secs_to_ticks(s) return math.floor(s * M.tickrate) end

local function is_alive(g, uid)
  for _, u in ipairs(g.alive) do if u == uid then return true end end
  return false
end

local function all_thrown(g)
  for _, uid in ipairs(g.alive) do
    if g.hands[uid] == nil then return false end
  end
  return #g.alive > 0
end

local function begin_round(state, dispatcher, tick)
  local g = state.g
  g.round = g.round + 1
  g.hands = {}
  g.phase = "countdown"
  local secs = state.settings.draw_accel
    and rules.countdown_for(g.draw_streak) or 3.0
  g.deadline = tick + secs_to_ticks(secs)
  dispatcher.broadcast_message(OP.ROUND_BEGIN, nk.json_encode({
    round = g.round, alive = g.alive,
    seconds = secs, deadline_tick = g.deadline,
    -- 客户端要在回合开始时就显示「连续平局 ×N,加速」,
    -- 所以 draw_streak 必须跟着 ROUND_BEGIN 走,不能只在 ROUND_RESULT 里发。
    draw_streak = g.draw_streak,
  }))
end

local function reveal(state, dispatcher, tick)
  local g = state.g

  -- 没出拳的:随机代出(默认,对小孩友好)或按弃权淘汰
  local afk = {}
  for _, uid in ipairs(g.alive) do
    if g.hands[uid] == nil then
      afk[#afk + 1] = uid
      if state.settings.afk_random then
        g.hands[uid] = math.random(0, 2)
      end
    end
  end

  local winner = rules.resolve(g.hands)
  local advanced, eliminated = {}, {}

  if winner == nil then
    g.draw_streak = g.draw_streak + 1
    for _, uid in ipairs(g.alive) do
      if g.hands[uid] ~= nil then advanced[#advanced + 1] = uid end
    end
  else
    g.draw_streak = 0
    advanced, eliminated = rules.split(g.hands, winner)
  end

  -- afk_random 关掉时,没出拳的一律淘汰
  if not state.settings.afk_random then
    for _, uid in ipairs(afk) do eliminated[#eliminated + 1] = uid end
  end

  g.alive = advanced
  local is_draw = (winner == nil)
  local reveal_secs = state.settings.draw_accel and rules.reveal_for(is_draw) or 2.0
  g.phase    = "reveal"
  g.deadline = tick + secs_to_ticks(reveal_secs)

  dispatcher.broadcast_message(OP.ROUND_RESULT, nk.json_encode({
    hands = g.hands, winner = winner, draw = is_draw,
    advanced = advanced, eliminated = eliminated,
    afk = afk, draw_streak = g.draw_streak,
  }))
end

function M.on_start(state, dispatcher, tick)
  state.g = {
    alive = {}, hands = {}, draw_streak = 0,
    round = 0, phase = "countdown", deadline = 0,
    winner = nil, over = false,
  }
  for _, uid in ipairs(state.order) do
    state.g.alive[#state.g.alive + 1] = uid
  end
  begin_round(state, dispatcher, tick or 0)
end

function M.on_loop(state, dispatcher, tick, messages)
  local g = state.g
  if g == nil or g.over then return end

  if g.phase == "countdown" then
    for _, m in ipairs(messages) do
      if m.op_code == OP.THROW then
        local uid = m.sender.user_id
        if is_alive(g, uid) and g.hands[uid] == nil then
          local ok, d = pcall(nk.json_decode, m.data)
          local h = ok and tonumber(d and d.hand) or nil
          if h == 0 or h == 1 or h == 2 then
            g.hands[uid] = h
            -- 出拳进度:只广播「谁出了」,让大家知道在等谁。
            -- ☠️ 绝不能把手势放进来 —— 收齐前不泄露任何选择是权威模式的根基。
            local thrown = {}
            for _, a in ipairs(g.alive) do
              if g.hands[a] ~= nil then thrown[#thrown + 1] = a end
            end
            dispatcher.broadcast_message(OP.THROW_PROGRESS, nk.json_encode({
              thrown = thrown, total = #g.alive,
            }))
          end
        end
      end
    end
    if all_thrown(g) or tick >= g.deadline then
      reveal(state, dispatcher, tick)
    end

  elseif g.phase == "reveal" then
    if tick >= g.deadline then
      if #g.alive <= 1 then
        g.winner = g.alive[1]
        g.over   = true
      else
        begin_round(state, dispatcher, tick)
      end
    end
  end
end

--- 掉线重连的人进来,给他一个人补当前回合的现场(定向,不打扰别人)。
-- 他不在 g.alive 里(掉线时已按离场淘汰),客户端会自动进观战席 ——
-- 和被淘汰的人走的是同一条显示路径。seconds 给**剩余**秒数:
-- 正在倒计时就是还剩几秒;正在亮牌就是 0,下一轮的 ROUND_BEGIN
-- 反正 2 秒内就到,不值得为它单独发一份亮牌结果。
function M.on_join(state, dispatcher, tick, presence)
  local g = state.g
  if g == nil then return end
  local remaining = 0
  if g.phase == "countdown" and g.deadline > tick then
    remaining = (g.deadline - tick) / M.tickrate
  end
  dispatcher.broadcast_message(OP.ROUND_BEGIN, nk.json_encode({
    round = g.round, alive = g.alive,
    seconds = remaining, deadline_tick = g.deadline,
    draw_streak = g.draw_streak,
  }), { presence })
end

function M.on_leave(state, dispatcher, uid)
  local g = state.g
  if g == nil then return end
  for i, a in ipairs(g.alive) do
    if a == uid then table.remove(g.alive, i); break end
  end
  g.hands[uid] = nil
end

function M.is_over(state)
  local g = state.g
  if g == nil or not g.over then return false, nil end
  if g.winner == nil then return true, {} end   -- 全员掉线
  return true, { { id = g.winner, name = state.names[g.winner], rank = 1 } }
end

return M
