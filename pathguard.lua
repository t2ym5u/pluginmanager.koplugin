-- ---------------------------------------------------------------------------
-- pathguard.lua — decides what this plugin is allowed to delete.
--
-- Kept apart from main.lua, and free of any KOReader dependency, for one
-- reason: it is the only code in the collection that can destroy a user's
-- files, so it has to be testable on its own. See test_pathguard_spec.lua.
--
-- The guard it replaces was:
--
--     if not path:find(_plugins_dir, 1, true) then return end
--
-- find(..., 1, true) searches for a SUBSTRING, not a prefix, so it also let
-- through any sibling directory whose name merely starts with the plugins
-- directory -- "plugins-backup", "plugins_old" -- and any path that happened
-- to contain it further along. It also said nothing about "..", while the
-- paths it protects are built from manifest.json's `dir` field, which arrives
-- over the network.
-- ---------------------------------------------------------------------------

local PathGuard = {}

-- A plugin directory name must be one plain path segment. Anything with a
-- separator, a "..", or a leading dot is refused: those are the shapes that
-- walk out of the plugins directory or hide.
function PathGuard.isSafeName(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 255 then return false end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return false end
    if name == "." or name == ".." then return false end
    if name:sub(1, 1) == "." then return false end
    if name:find("%z") then return false end
    return true
end

-- True only when `path` sits strictly inside `root`. Both are compared with a
-- trailing separator, which is what stops "…/plugins-backup" from passing as
-- "…/plugins", and any ".." segment disqualifies the path outright.
function PathGuard.isWithin(root, path)
    if type(root) ~= "string" or type(path) ~= "string" then return false end
    if root == "" or path == "" then return false end
    if path:find("%z") then return false end

    -- Normalise to exactly one trailing separator on the root.
    local prefix = root:gsub("/+$", "") .. "/"

    if path:sub(1, #prefix) ~= prefix then return false end
    -- Strictly inside: the root itself is not a deletable target.
    if #path <= #prefix then return false end

    local rest = path:sub(#prefix + 1)
    if rest == ".." or rest:sub(1, 3) == "../" then return false end
    if rest:find("/%.%./") then return false end
    if rest:sub(-3) == "/.." then return false end
    return true
end

-- The full path of a plugin directory, or nil when the name cannot be trusted.
-- Call sites use this instead of concatenating root .. "/" .. name themselves,
-- so a bad name is refused before it ever reaches a delete.
function PathGuard.pluginPath(root, name)
    if not PathGuard.isSafeName(name) then return nil end
    local path = root:gsub("/+$", "") .. "/" .. name
    if not PathGuard.isWithin(root, path) then return nil end
    return path
end

-- The full path of a file that some outside source says belongs inside `root`
-- -- an entry in manifest.json's `files`, or a path inside a downloaded zip.
-- Returns nil when the entry cannot be trusted.
--
-- isSafeName is too strict here: these entries legitimately carry a
-- subdirectory ("common/i18n.lua"). What they must not do is leave `root`,
-- which is exactly what isWithin decides, so the check is: build the path,
-- then refuse it unless it landed inside.
--
-- Without this, an entry of "../../evil.lua" writes wherever it likes. For an
-- archive that is the Zip Slip vulnerability; for manifest.json it is the same
-- hole the `dir` field was already guarded against.
function PathGuard.filePath(root, rel)
    if type(root) ~= "string" or type(rel) ~= "string" then return nil end
    if rel == "" or #rel > 1024 then return nil end
    if rel:find("%z") then return nil end
    -- Must be relative, and must name a file rather than a directory.
    if rel:sub(1, 1) == "/" then return nil end
    if rel:sub(-1) == "/" then return nil end
    -- Backslashes would be a separator on some hosts and a literal character
    -- here, so the two readings could disagree about where the file lands.
    if rel:find("\\", 1, true) then return nil end

    local path = root:gsub("/+$", "") .. "/" .. rel
    if not PathGuard.isWithin(root, path) then return nil end
    return path
end

-- Single-quoted for the shell, with embedded quotes closed and reopened.
-- Only used on the no-lfs fallback path, where deletion goes through
-- `rm -rf`: an unquoted path containing a space would delete the wrong thing.
function PathGuard.shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return PathGuard
