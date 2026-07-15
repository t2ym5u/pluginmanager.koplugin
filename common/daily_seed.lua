-- daily_seed.lua — deterministic daily seed for puzzle-of-the-day modes
--
-- Usage:
--   local DailySeed = require("daily_seed")
--   local seed = DailySeed.today()       -- integer, constant within a day
--   local rng  = DailySeed.rng(seed)     -- function() → [0, 1)
--   local n    = math.floor(rng() * 10)  -- random 0–9

local DailySeed = {}

-- Returns an integer that is constant within a calendar day (year * 1000 + day_of_year).
function DailySeed.today()
    local d = os.date("*t")
    return d.year * 1000 + d.yday
end

-- Park-Miller LCG seeded with `seed`.  Works in plain Lua 5.1 / LuaJIT.
-- Returns a stateful closure: call it repeatedly for the next value in [0, 1).
function DailySeed.rng(seed)
    local M = 2147483647  -- 2^31 − 1 (Mersenne prime)
    local A = 16807
    local state = seed % M
    if state == 0 then state = 1 end
    return function()
        state = (A * state) % M
        return (state - 1) / (M - 1)
    end
end

return DailySeed
