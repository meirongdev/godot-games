-- 把 require("nakama") 换成可断言的假货,让适配层也能单测。
local M = {}

--- 安装假 nk。返回一个 calls 表,测试里可断言调用记录。
function M.install()
  -- calls.now 是测试可写的时钟(毫秒)。默认 0,想推进窗口就直接赋值。
  local calls = { logs = {}, storage_writes = {},
                  match_creates = {}, match_lists = {}, now = 0 }
  package.loaded["nakama"] = {
    logger_info   = function(m) calls.logs[#calls.logs + 1] = m end,
    logger_error  = function(m) calls.logs[#calls.logs + 1] = m end,
    json_encode   = function(t) return require("dkjson").encode(t) end,
    json_decode   = function(s) return require("dkjson").decode(s) end,
    storage_write = function(o) calls.storage_writes[#calls.storage_writes + 1] = o end,
    uuid_v4       = function() return "00000000-0000-4000-8000-000000000000" end,
    -- Nakama 的 nk.time() 返回毫秒级 UTC 墙钟。测试里由 calls.now 驱动。
    time          = function() return calls.now end,
    match_create = function(module, params)
      calls.match_creates[#calls.match_creates + 1] =
        { module = module, params = params }
      return "match-" .. #calls.match_creates
    end,
    match_list = function(limit, authoritative, label, min, max, query)
      calls.match_lists[#calls.match_lists + 1] =
        { limit = limit, query = query }
      return calls.stub_matches or {}
    end,
  }
  return calls
end

--- 假 dispatcher。记录所有广播 / label 更新 / 踢人。
function M.dispatcher()
  local d = { broadcasts = {}, labels = {}, kicks = {} }
  d.broadcast_message = function(op, data, presences)
    d.broadcasts[#d.broadcasts + 1] = { op = op, data = data, presences = presences }
  end
  d.match_label_update = function(l) d.labels[#d.labels + 1] = l end
  d.match_kick = function(p) d.kicks[#d.kicks + 1] = p end
  return d
end

--- 造一个假 presence。
function M.presence(user_id, username)
  return { user_id = user_id, username = username or user_id,
           session_id = "sess-" .. user_id, node = "nakama1" }
end

--- 造一条假客户端消息。
function M.message(user_id, op_code, tbl)
  return { sender = M.presence(user_id), op_code = op_code,
           data = require("dkjson").encode(tbl or {}) }
end

--- 取出最后一条指定 op_code 的广播,已解码。
function M.last(d, op_code)
  for i = #d.broadcasts, 1, -1 do
    if d.broadcasts[i].op == op_code then
      return require("dkjson").decode(d.broadcasts[i].data)
    end
  end
  return nil
end

return M
