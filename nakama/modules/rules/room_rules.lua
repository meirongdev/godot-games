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
