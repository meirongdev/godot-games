-- 滑动窗口限流,纯函数。状态由调用方持有,这里不碰 nk、不碰时钟。
--
-- 为什么需要它:create_room 是开放 RPC(契约 §5),拿到 server key 的人都能
-- 建 match。而 server key 跟着 Web 制品公开发布(见 NakamaConfig.SERVER_KEY),
-- 等于任何人 —— 所以限流是实际防线,server key 不是。

local M = {}

--- 判定一次调用是否放行,并返回修剪后的时间戳表。
--
-- @param stamps 该主体已记录的时间戳(毫秒),升序;nil 视作空
-- @param now    当前时间(毫秒)
-- @param window 窗口长度(毫秒)
-- @param max    窗口内允许的次数
-- @return allowed  boolean
-- @return kept     table   新的时间戳表,调用方存回去
-- @return retry_ms number  被拒时还要等多久才有额度;放行时为 0
function M.check(stamps, now, window, max)
  local kept = {}
  for _, t in ipairs(stamps or {}) do
    -- 边界:恰好等于 window 的算滚出窗口。
    if now - t < window then
      kept[#kept + 1] = t
    end
  end

  if #kept >= max then
    -- 最早那条滚出窗口,才腾出一个额度。
    -- max <= 0 时窗口里可能一条都没有,没有「最早那条」可等 —— 给一个整窗。
    local retry = (#kept > 0) and (kept[1] + window - now) or window
    return false, kept, retry
  end

  kept[#kept + 1] = now
  return true, kept, 0
end

return M
