-- 通用房间 match handler。独占房间生命周期,与具体游戏无关。
-- ★ 加新游戏不改这个文件,只在 games/init.lua 注册。
local nk         = require("nakama")
local room_rules = require("rules.room_rules")
local games      = require("games.init")

local OP = {
  READY = 1, START = 2, SETTINGS = 3,
  ROOM_STATE = 10, GAME_STARTED = 11, GAME_OVER = 12, ERROR = 13,
}

local M = {}

local function label_info(state)
  local game = games.get(state.game_id)
  return {
    game      = state.game_id,
    name      = state.name,
    count     = #state.order,
    max       = game.max_players,
    phase     = state.phase,
    host_name = state.host_name or "",
  }
end

local function update_label(dispatcher, state)
  dispatcher.match_label_update(room_rules.encode_label(label_info(state)))
end

local function sync(dispatcher, state)
  local players = {}
  for i, uid in ipairs(state.order) do
    players[i] = {
      id    = uid,
      name  = state.names[uid],
      ready = state.ready[uid] or false,
    }
  end
  dispatcher.broadcast_message(OP.ROOM_STATE, nk.json_encode({
    phase    = state.phase,
    players  = players,
    host     = state.host,
    settings = state.settings,
    -- 客户端标题栏用:没有这两个字段,房间页只能显示一个写死的「房间」
    name     = state.name,
    game     = state.game_id,
  }))
  update_label(dispatcher, state)
end

function M.match_init(_, params)
  local game = games.get(params.game)
  -- 复制一份 default_settings,否则多个房间会共享同一张表
  local settings = {}
  for k, v in pairs(game.default_settings) do settings[k] = v end

  local state = {
    game_id   = params.game,
    name      = params.name or "房间",
    host      = params.host,
    host_name = params.host_name or "",
    phase     = "waiting",
    presences = {},   -- uid -> presence
    order     = {},   -- uid 数组,进房顺序
    names     = {},   -- uid -> username
    ready     = {},   -- uid -> bool
    settings  = settings,
    g         = nil,  -- 游戏私有状态,由游戏模块拥有
    empty_ticks = 0,  -- 房间空置计时,见 match_loop 里的自动关闭
  }
  return state, game.tickrate, room_rules.encode_label(label_info(state))
end

function M.match_join_attempt(_, _, _, state, presence, _)
  local game = games.get(state.game_id)
  -- 同一 user_id 还挂着旧 session(半开连接没被服务端判死)的重连:直接放行。
  if state.presences[presence.user_id] ~= nil then
    return state, true
  end
  -- names 只进不出(match_leave 不清它),所以它就是「这个房间的人」的名单 ——
  -- 掉线的人凭它回来,见 room_rules.can_join 的注释。
  local ok, why = room_rules.can_join(
    state.phase, state.names[presence.user_id] ~= nil,
    #state.order, game.max_players)
  if not ok then
    return state, false, why
  end
  return state, true
end

function M.match_join(_, dispatcher, tick, state, presences)
  local game = games.get(state.game_id)
  for _, p in ipairs(presences) do
    if state.presences[p.user_id] == nil then
      state.order[#state.order + 1] = p.user_id
      state.ready[p.user_id] = false
    end
    state.presences[p.user_id] = p
    state.names[p.user_id]     = p.username
    if state.host == nil then
      state.host      = p.user_id
      state.host_name = p.username
    end
  end
  sync(dispatcher, state)

  -- 对局进行中进来的(= 掉线重连的,见 match_join_attempt),要给**这一个人**
  -- 补一份现场,不然他的房间页只有花名册,游戏区永远空着「还在等待」:
  --   1. GAME_STARTED(定向)—— 客户端靠它挂载游戏场景;
  --   2. game.on_join —— 游戏自己补当前回合(轮数、剩余秒数等)。
  -- 广播顺序刻意和正常开局一致:ROOM_STATE(上面的 sync)→ GAME_STARTED →
  -- 回合快照,客户端不需要为重连写任何特殊时序。
  if state.phase == "playing" then
    for _, p in ipairs(presences) do
      dispatcher.broadcast_message(OP.GAME_STARTED, nk.json_encode({
        game = state.game_id, settings = state.settings }), { p })
      if game.on_join then
        game.on_join(state, dispatcher, tick, p)
      end
    end
  end
  return state
end

function M.match_leave(_, dispatcher, _, state, presences)
  local game = games.get(state.game_id)
  for _, p in ipairs(presences) do
    -- ⚠️ 只清「当前这个 session」。掉线重连比旧 session 的 leave 先到时
    -- (半开连接:新 join 进来了,服务端稍后才判死旧连接),这条迟到的
    -- leave 带的是**旧** session_id —— 不比对就会把刚回来的人又踢出去。
    local cur = state.presences[p.user_id]
    if cur ~= nil and cur.session_id == p.session_id then
      state.presences[p.user_id] = nil
      state.ready[p.user_id]     = nil
      for i, uid in ipairs(state.order) do
        if uid == p.user_id then table.remove(state.order, i); break end
      end
      if state.phase == "playing" and game.on_leave then
        game.on_leave(state, dispatcher, p.user_id)
      end
    end
  end
  -- next_host 要的是「已移除离开者」之后的 order
  state.host      = room_rules.next_host(state.order, state.host)
  state.host_name = state.host and state.names[state.host] or ""
  sync(dispatcher, state)
  return state
end

local function handle_lobby(dispatcher, state, m, game, tick)
  local uid = m.sender.user_id

  if m.op_code == OP.READY then
    local ok, d = pcall(nk.json_decode, m.data)
    if ok then
      state.ready[uid] = d and d.ready and true or false
      sync(dispatcher, state)
    end

  elseif m.op_code == OP.SETTINGS then
    if uid == state.host then
      local ok, d = pcall(nk.json_decode, m.data)
      if ok and d then
        for k, v in pairs(d) do state.settings[k] = v end
        sync(dispatcher, state)
      end
    end

  elseif m.op_code == OP.START then
    local ok, why = room_rules.can_start(
      state.order, state.ready, state.host, uid, game.min_players)
    if not ok then
      dispatcher.broadcast_message(
        OP.ERROR, nk.json_encode({ msg = why }), { m.sender })
    else
      state.phase = "playing"
      state.g     = nil
      dispatcher.broadcast_message(OP.GAME_STARTED, nk.json_encode({
        game = state.game_id, settings = state.settings }))
      game.on_start(state, dispatcher, tick)
      update_label(dispatcher, state)
    end
  end

  return state
end

function M.match_loop(_, dispatcher, tick, state, messages)
  local game = games.get(state.game_id)

  -- 空房自动关闭:match handler 不返回 nil 的话,每个被建出来又被离开的
  -- 房间都会以 tickrate 永远空转 —— 服务器上的僵尸。空置 60 秒即结束。
  if next(state.presences) == nil then
    state.empty_ticks = state.empty_ticks + 1
    if state.empty_ticks > game.tickrate * 60 then
      return nil
    end
  else
    state.empty_ticks = 0
  end

  if state.phase == "waiting" then
    for _, m in ipairs(messages) do
      state = handle_lobby(dispatcher, state, m, game, tick)
    end
    return state
  end

  -- playing:只把本游戏 OpCode 段的消息交给游戏模块
  local own = {}
  for _, m in ipairs(messages) do
    if m.op_code >= game.op_base then own[#own + 1] = m end
  end
  game.on_loop(state, dispatcher, tick, own)

  local over, results = game.is_over(state)
  if over then
    dispatcher.broadcast_message(
      OP.GAME_OVER, nk.json_encode({ results = results or {} }))
    state.phase = "waiting"
    state.g     = nil
    for uid in pairs(state.ready) do state.ready[uid] = false end
    sync(dispatcher, state)
  end
  return state
end

function M.match_terminate(_, _, _, state, _) return state end
function M.match_signal(_, _, _, state, data) return state, data end

return M
