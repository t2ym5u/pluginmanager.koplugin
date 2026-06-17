-- ---------------------------------------------------------------------------
-- Timer — elapsed-time tracker for game sessions
--
-- Usage:
--   local Timer = require("timer")
--   local t = Timer:new()
--   t:start()
--   ...
--   print(t:format())   -- "04:37"
--   t:stop()
--   local data = t:serialize()
--   -- later:
--   t:load(data)
-- ---------------------------------------------------------------------------

local Timer = {}
Timer.__index = Timer

function Timer:new()
    return setmetatable({
        _elapsed  = 0,    -- accumulated seconds (before last start)
        _start_at = nil,  -- os.time() when last started, or nil if stopped
    }, self)
end

function Timer:start()
    if not self._start_at then
        self._start_at = os.time()
    end
end

function Timer:stop()
    if self._start_at then
        self._elapsed  = self._elapsed + (os.time() - self._start_at)
        self._start_at = nil
    end
end

function Timer:reset()
    self._elapsed  = 0
    self._start_at = nil
end

function Timer:isRunning()
    return self._start_at ~= nil
end

-- Returns total elapsed seconds (float).
function Timer:getElapsed()
    local total = self._elapsed
    if self._start_at then
        total = total + (os.time() - self._start_at)
    end
    return total
end

-- Returns "MM:SS" string.
function Timer:format()
    local secs  = math.floor(self:getElapsed())
    local m     = math.floor(secs / 60)
    local s     = secs % 60
    return string.format("%02d:%02d", m, s)
end

-- Returns "HH:MM:SS" for elapsed >= 1 hour, "MM:SS" otherwise.
function Timer:formatLong()
    local secs = math.floor(self:getElapsed())
    local h    = math.floor(secs / 3600)
    local m    = math.floor((secs % 3600) / 60)
    local s    = secs % 60
    if h > 0 then
        return string.format("%02d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function Timer:serialize()
    -- Always stop before serialising so elapsed is fully accumulated.
    local was_running = self._start_at ~= nil
    self:stop()
    return {
        elapsed     = self._elapsed,
        was_running = was_running,
    }
end

function Timer:load(data)
    if type(data) ~= "table" then return end
    self._elapsed  = tonumber(data.elapsed) or 0
    self._start_at = nil
    if data.was_running then
        self:start()
    end
end

return Timer
