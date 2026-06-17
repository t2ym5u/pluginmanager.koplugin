local _ = require("gettext")

-- ---------------------------------------------------------------------------
-- UndoStack — generic undo / redo stack
--
-- Each entry is a free-form table whose shape is defined by the caller.
-- The stack stores up to `max_size` entries (default: unlimited).
--
-- Usage:
--   local UndoStack = require("undo_stack")
--   local stack = UndoStack:new({ max_size = 200 })
--   stack:push({ type = "move", row = r, col = c, prev = old, next = new })
--   local entry = stack:pop()   -- nil when empty
-- ---------------------------------------------------------------------------

local UndoStack = {}
UndoStack.__index = UndoStack

function UndoStack:new(opts)
    opts = opts or {}
    return setmetatable({
        _stack    = {},
        _max_size = opts.max_size,
    }, self)
end

function UndoStack:push(entry)
    local stack = self._stack
    stack[#stack + 1] = entry
    if self._max_size and #stack > self._max_size then
        table.remove(stack, 1)
    end
end

-- Returns and removes the most recent entry, or nil if empty.
function UndoStack:pop()
    return table.remove(self._stack)
end

-- Returns the most recent entry without removing it.
function UndoStack:peek()
    return self._stack[#self._stack]
end

function UndoStack:canUndo()
    return self._stack[1] ~= nil
end

function UndoStack:size()
    return #self._stack
end

function UndoStack:clear()
    self._stack = {}
end

-- ---------------------------------------------------------------------------
-- Persistence — only serializable (non-function) entries are kept.
-- ---------------------------------------------------------------------------

function UndoStack:serialize()
    return self._stack
end

function UndoStack:load(data)
    if type(data) == "table" then
        self._stack = data
    else
        self._stack = {}
    end
end

-- ---------------------------------------------------------------------------
-- Convenience: standard error message when nothing can be undone.
-- ---------------------------------------------------------------------------

UndoStack.NOTHING_TO_UNDO = _("Nothing to undo.")

return UndoStack
