-- ---------------------------------------------------------------------------
-- grid_utils — generic grid / table helpers
-- ---------------------------------------------------------------------------

local M = {}

-- 2D table of zeros (or any numeric default).
function M.emptyGrid(cols, rows, default)
    rows = rows or cols
    if default == nil then default = 0 end  -- preserve false as false
    local grid = {}
    for r = 1, rows do
        grid[r] = {}
        for c = 1, cols do
            grid[r][c] = default
        end
    end
    return grid
end

-- Deep copy of a 2D grid.
function M.copyGrid(src, cols, rows)
    rows = rows or cols
    local grid = {}
    for r = 1, rows do
        grid[r] = {}
        for c = 1, cols do
            grid[r][c] = src[r] and src[r][c] or 0
        end
    end
    return grid
end

-- 2D table of false (for marker / flag grids).
function M.emptyBoolGrid(cols, rows)
    return M.emptyGrid(cols, rows, false)
end

-- 1D array of a given length filled with a default value.
function M.emptyArray(n, default)
    default = default or 0
    local arr = {}
    for i = 1, n do arr[i] = default end
    return arr
end

-- Shallow copy of a 1D table (array or hash).
function M.cloneTable(t)
    if not t then return nil end
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
end

-- Deep copy of a 2D table of tables (e.g. notes grids).
function M.copyGrid2D(src, cols, rows)
    rows = rows or cols
    local dest = {}
    for r = 1, rows do
        dest[r] = {}
        for c = 1, cols do
            local cell = src and src[r] and src[r][c]
            dest[r][c] = type(cell) == "table" and M.cloneTable(cell) or cell
        end
    end
    return dest
end

-- Returns true if two flat arrays are equal.
function M.arrayEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Shuffle a 1D array in-place (Fisher–Yates).
function M.shuffle(arr)
    for i = #arr, 2, -1 do
        local j = math.random(i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end

-- Map over a flat array; returns a new array.
function M.map(arr, fn)
    local out = {}
    for i, v in ipairs(arr) do out[i] = fn(v, i) end
    return out
end

-- Filter a flat array; returns a new array.
function M.filter(arr, pred)
    local out = {}
    for _, v in ipairs(arr) do
        if pred(v) then out[#out + 1] = v end
    end
    return out
end

return M
