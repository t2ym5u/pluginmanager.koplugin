-- ---------------------------------------------------------------------------
-- ScoreTracker — current score + per-key best score (persisted via plugin)
--
-- Usage:
--   local ScoreTracker = require("score_tracker")
--
--   -- One tracker per scoring context (e.g. per grid-size + difficulty).
--   local score = ScoreTracker:new()
--   score:reset()
--   score:add(10)
--   print(score:get())    -- 10
--
--   -- Best score (needs the plugin for persistence):
--   score:updateBest(plugin, "best_score_easy_9x9")
--   print(score:getBest(plugin, "best_score_easy_9x9"))
-- ---------------------------------------------------------------------------

local ScoreTracker = {}
ScoreTracker.__index = ScoreTracker

function ScoreTracker:new()
    return setmetatable({ _score = 0 }, self)
end

function ScoreTracker:reset()
    self._score = 0
end

function ScoreTracker:set(value)
    self._score = value or 0
end

function ScoreTracker:add(delta)
    self._score = self._score + (delta or 0)
end

function ScoreTracker:get()
    return self._score
end

-- Reads the best score stored under `key` via `plugin:getSetting`.
function ScoreTracker:getBest(plugin, key)
    return plugin:getSetting(key, nil)
end

-- Writes a new best if current score is better.
-- `higher_is_better`: true (default) for points-based scores,
--                      false for fewest-moves / fastest-time scores.
function ScoreTracker:updateBest(plugin, key, higher_is_better)
    if higher_is_better == nil then higher_is_better = true end
    local current = self._score
    local best    = plugin:getSetting(key, nil)
    local is_better
    if best == nil then
        is_better = true
    elseif higher_is_better then
        is_better = current > best
    else
        is_better = current < best
    end
    if is_better then
        plugin:saveSetting(key, current)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Persistence (inline score only — best is kept in plugin settings)
-- ---------------------------------------------------------------------------

function ScoreTracker:serialize()
    return { score = self._score }
end

function ScoreTracker:load(data)
    if type(data) == "table" then
        self._score = tonumber(data.score) or 0
    end
end

return ScoreTracker
