-- 房间生命周期的纯规则,与具体游戏无关。禁止 require("nakama")。
local M = {}

local LABEL_MAX     = 2048   -- Nakama 对 match label 的硬上限
local HOST_NAME_MAX = 64

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

-- 房名是玩家输入,直接拼进 JSON 会被引号打断。必须转义。
local function esc(s)
  return (tostring(s):gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
  end))
end

-- 按字节截断会把多字节字符劈开,产出非法 UTF-8。退回到字符边界。
local function utf8_trim(s, max_bytes)
  if #s <= max_bytes then return s end
  local i = max_bytes
  while i > 0 do
    local b = string.byte(s, i + 1)
    -- 0x80..0xBF 是延续字节,落在这里说明劈到了字符中间
    if b == nil or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return string.sub(s, 1, i)
end

--- 能否开局。
-- @param order       table  user_id 数组,进房顺序
-- @param ready       table  user_id -> bool
-- @param host        string 当前房主
-- @param requester   string 发起 start 的人
-- @param min_players number
-- @return boolean ok, string|nil reason
function M.can_start(order, ready, host, requester, min_players)
  if requester ~= host then return false, "not_host" end
  if #order < min_players then return false, "need_more_players" end
  for _, uid in ipairs(order) do
    if not ready[uid] then return false, "not_all_ready" end
  end
  return true, nil
end

--- 能否进房。
-- 「对局进行中」不等于「门焊死了」:**这一局的人**掉线后回来要能进 ——
-- 手机上锁屏、切微信、Wi-Fi 切 4G 都会断线,断线即除名(Nakama 的
-- match_leave),不放行的话掉线的人只能在大厅干等到局终(2026-08-28
-- 实测:重连后 match_join 恒被拒「游戏已开始」,这就是「桌面打了 5 轮,
-- 手机还在等待」)。回来的人**不回到对局里**(掉线时已按离场处理),
-- 进的是观战席,下一局自动参加 —— 和「出局了留在观战席看完」同一条路。
-- @param phase     string  "waiting" | "playing"
-- @param is_member boolean 这个 user_id 是否进过这个房间(掉线不清除)
-- @param count     number  当前在房人数
-- @param max       number  上限
-- @return boolean ok, string|nil reason
function M.can_join(phase, is_member, count, max)
  if count >= max then return false, "房间已满" end
  if phase ~= "waiting" and not is_member then
    return false, "游戏已开始"
  end
  return true, nil
end

--- 房主离开后谁接手。
-- @param order table  玩家顺序数组,**调用方须先移除离开者**
-- @param host  string 离开前的房主
-- @return string|nil  房主仍在则原样返回;否则队首;房间空了 nil
function M.next_host(order, host)
  for _, uid in ipairs(order) do
    if uid == host then return host end
  end
  return order[1]
end

--- 生成 match_list 用的 label。键名用单字母压体积。
function M.encode_label(info)
  local host_name = utf8_trim(tostring(info.host_name), HOST_NAME_MAX)
  local function build(name)
    return string.format(
      '{"g":"%s","n":"%s","p":%d,"m":%d,"s":"%s","h":"%s"}',
      esc(info.game), esc(name), info.count, info.max,
      esc(info.phase), esc(host_name))
  end
  local name  = tostring(info.name)
  local label = build(name)
  while #label > LABEL_MAX and #name > 0 do
    name  = utf8_trim(name, math.max(0, #name - (#label - LABEL_MAX)))
    label = build(name)
  end
  return label
end

return M
