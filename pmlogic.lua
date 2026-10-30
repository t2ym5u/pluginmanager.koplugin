-- ---------------------------------------------------------------------------
-- pmlogic.lua — the decisions behind Plugin Manager's screens, kept free of
-- any KOReader dependency so they can be specced on their own (see
-- test_pmlogic_spec.lua), the same reason pathguard.lua is split out.
--
-- Nothing in here touches the network, the filesystem or the UI: callers
-- hand in plain data (manifest entries, the installed scan, file bodies) and
-- get plain data back.
-- ---------------------------------------------------------------------------

local L = {}

-- ---------------------------------------------------------------------------
-- Versions
-- ---------------------------------------------------------------------------

local function version_parts(v)
    local t = {}
    for n in tostring(v or "0"):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- True when `b` is strictly newer than `a` -- the same argument order main.lua
-- has always used (is_newer(installed, manifest)).
function L.isNewer(a, b)
    local ap, bp = version_parts(a), version_parts(b)
    for i = 1, math.max(#ap, #bp) do
        local ai, bi = ap[i] or 0, bp[i] or 0
        if bi > ai then return true end
        if bi < ai then return false end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- What's new: CHANGELOG.md slicing
-- ---------------------------------------------------------------------------

-- The fleet's changelogs follow Keep a Changelog: `## [1.2.0] - 2026-10-30`,
-- sometimes `## [1.2.0]` with no date, and `## [Unreleased]` at the top while
-- work is in progress. A bare `## 1.2.0` or `## v1.2.0` is accepted too, for
-- the odd third-party style. Only level-2 headings open a section: `###
-- Added` belongs to the version above it.
local function heading_version(line)
    if not line:match("^##%s") then return nil end
    return line:match("^##%s+%[v?(%d+[%.%d]*)%]")
        or line:match("^##%s+v?(%d+%.%d+[%.%d]*)")
end

-- Returns the sections strictly newer than `from_v` and no newer than `to_v`,
-- in file order (newest first, as written), plus how many versioned
-- sections the file has at all. `[Unreleased]` -- or any level-2 heading
-- without a version -- closes the previous section and is never included:
-- it describes code nobody has been shipped yet.
--
-- (nil, 0) means nothing parsed, and the caller shows the whole file rather
-- than nothing. ("", n) means the file parsed but holds no entry in that
-- range -- the version was bumped without a changelog line.
function L.changelogSlice(text, from_v, to_v)
    if type(text) ~= "string" then return nil, 0 end
    local out, versioned, keep = {}, 0, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^##%s") then
            local v = heading_version(line)
            if v then
                versioned = versioned + 1
                keep = (from_v == nil or L.isNewer(from_v, v))
                    and (to_v == nil or not L.isNewer(to_v, v))
            else
                keep = false
            end
        elseif line:match("^#%s") then
            keep = false   -- the document title
        end
        if keep then out[#out + 1] = line end
    end
    if versioned == 0 then return nil, 0 end
    return (table.concat(out, "\n"):gsub("%s+$", "")), versioned
end

-- ---------------------------------------------------------------------------
-- Minimum KOReader version
-- ---------------------------------------------------------------------------

-- Same scale as KOReader's own Version:getNormalizedVersion() (frontend/
-- version.lua): ((year * 100 + month) * 1e6) + point * 1e4 + commits. A
-- manifest's `min_koreader` is a release name -- "2026.03", "v2026.03.1" --
-- so it carries no commit count, and "2026.03" compares as "2026.03 or any
-- build after it".
function L.normalizeKoreaderVersion(s)
    if type(s) ~= "string" then return nil end
    local y, m, p = s:match("(%d%d%d%d)%.(%d%d?)%.?(%d*)")
    if not y then return nil end
    return (tonumber(y) * 100 + tonumber(m)) * 1000000 + (tonumber(p) or 0) * 10000
end

-- Never blocks on what it cannot read: no requirement, an unparsable one, or
-- a build that does not know its own version (a dev build reports 0) all
-- count as compatible. The field exists to warn, not to lock people out.
function L.koreaderCompatible(min_koreader, current_normalized)
    if min_koreader == nil or min_koreader == "" then return true end
    local need = L.normalizeKoreaderVersion(min_koreader)
    if not need then return true end
    if type(current_normalized) ~= "number" or current_normalized <= 0 then return true end
    return current_normalized >= need
end

-- ---------------------------------------------------------------------------
-- Pending updates (shared by the home screen badge, the silent check and
-- the Update button, which must never disagree about the count)
-- ---------------------------------------------------------------------------

-- `is_ignored(id, version)` and `is_compatible(entry)` are supplied by the
-- caller (settings and KOReader's version live outside this module).
-- Returns the manifest entries with an update to apply, and separately the
-- ones whose update needs a newer KOReader -- those are reported, never
-- installed by a bulk run.
function L.pendingUpdates(manifest_plugins, installed, is_ignored, is_compatible)
    local updates, blocked = {}, {}
    for _i, p in ipairs(manifest_plugins or {}) do
        local inst = installed[p.id]
        if inst and L.isNewer(inst.version, p.version)
           and not (is_ignored and is_ignored(p.id, p.version)) then
            if is_compatible and not is_compatible(p) then
                blocked[#blocked + 1] = p
            else
                updates[#updates + 1] = p
            end
        end
    end
    return updates, blocked
end

-- ---------------------------------------------------------------------------
-- Integrity
-- ---------------------------------------------------------------------------

-- "unverified" when there is nothing to compare against: a manifest written
-- before sha256 existed, a file missing from its map, or no SHA-256 at hand.
-- Those files still go through the compile check; they are simply not
-- hash-checked, so an older manifest keeps working exactly as before.
function L.hashVerdict(expected, actual)
    if type(expected) ~= "string" or expected == "" or type(actual) ~= "string" then
        return "unverified"
    end
    return expected:lower() == actual:lower() and "ok" or "mismatch"
end

-- Files come from raw.githubusercontent at the branch head; the hashes come
-- from the monorepo's checked-out submodule commit when manifest.json was
-- last regenerated. Between a plugin push and the next regeneration the two
-- legitimately differ. A mismatch that survives a re-download is therefore
-- accepted only when the plugin's own _meta.lua, as just downloaded, is at
-- least the manifest's version -- upstream moved on, the manifest has not
-- caught up. An *older* _meta.lua is the opposite: a stale copy (a wrong
-- branch in raw_base_url serves frozen content with a 200), and is refused.
function L.driftAcceptable(downloaded_meta_version, manifest_version)
    if type(downloaded_meta_version) ~= "string" then return false end
    return not L.isNewer(downloaded_meta_version, manifest_version)
end

function L.isLuaFile(name)
    return type(name) == "string" and name:match("%.lua$") ~= nil
end

-- Compiles without running. A truncated download -- the failure that used to
-- leave a plugin that crashed KOReader at startup -- fails here whatever the
-- manifest says.
function L.compiles(body, name)
    local compile = loadstring or load  -- luacheck: ignore (LuaJIT / 5.2+)
    local fn, err = compile(body, "=" .. tostring(name))
    return fn ~= nil, err
end

-- ---------------------------------------------------------------------------
-- Screenshot
-- ---------------------------------------------------------------------------

local function norm(s) return (s:lower():gsub("[^%w]", "")) end

-- The README screenshot lives in images/ next to whatever the game itself
-- loads from there (fifteen ships twenty puzzle pictures), so pick the one
-- named after the plugin: images/sudoku.png, images/arrow-sudoku.png for
-- arrowsudoku, images/fifteen-puzzle.png for fifteen. A lone image is taken
-- as is (killer-sudoku.png for sudokukiller); several unrelated ones give no
-- screenshot rather than a random game asset.
function L.pickScreenshot(id, files)
    if type(id) ~= "string" then return nil end
    local imgs = {}
    for _i, f in ipairs(files or {}) do
        if type(f) == "string" and f:match("^images/[^/]+%.png$") then imgs[#imgs + 1] = f end
    end
    if #imgs == 0 then return nil end
    local nid = norm(id)
    for _i, f in ipairs(imgs) do
        if norm(f:match("^images/(.+)%.png$")) == nid then return f end
    end
    for _i, f in ipairs(imgs) do
        if norm(f:match("^images/(.+)%.png$")):find(nid, 1, true) then return f end
    end
    if #imgs == 1 then return imgs[1] end
    return nil
end

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------

-- Ids are stable (see .github/scripts/categories.json); labels live in
-- main.lua so they go through the translation table.
L.CATEGORY_ORDER = { "logic", "sudoku", "words", "board", "cards", "classic", "party", "tools" }

-- Splits `items` (each with an optional `category`) into sections in
-- CATEGORY_ORDER, then "other" for anything without a category or with one
-- this version does not know yet. Empty sections are dropped. Items keep
-- their relative order, so sort before grouping.
function L.groupByCategory(items)
    local known, buckets = {}, {}
    for _i, id in ipairs(L.CATEGORY_ORDER) do known[id] = true end
    for _i, item in ipairs(items) do
        local cat = known[item.category] and item.category or "other"
        buckets[cat] = buckets[cat] or {}
        table.insert(buckets[cat], item)
    end
    local groups = {}
    for _i, id in ipairs(L.CATEGORY_ORDER) do
        if buckets[id] then groups[#groups + 1] = { id = id, items = buckets[id] } end
    end
    if buckets.other then groups[#groups + 1] = { id = "other", items = buckets.other } end
    return groups
end

-- ---------------------------------------------------------------------------
-- Export / import of the installed list
-- ---------------------------------------------------------------------------

L.EXPORT_FORMAT = "pluginmanager-export"

-- Only plugins the manifest knows are exported -- scanInstalled() also sees
-- KOReader's own plugins, which an import must never try to "install" --
-- plus Discover-linked third-party plugins (`links`: id -> {owner, name}),
-- which an import reinstalls from their repo.
function L.buildExport(installed, manifest_plugins, links, date)
    local in_manifest = {}
    for _i, p in ipairs(manifest_plugins or {}) do in_manifest[p.id] = true end
    local plugins, github = {}, {}
    for id, inst in pairs(installed or {}) do
        if in_manifest[id] then
            plugins[#plugins + 1] = { id = id, version = inst.version }
        elseif links and links[id] and links[id].owner and links[id].name then
            github[#github + 1] = { id = id, repo = links[id].owner .. "/" .. links[id].name }
        end
    end
    table.sort(plugins, function(a, b) return a.id < b.id end)
    table.sort(github,  function(a, b) return a.id < b.id end)
    return {
        format         = L.EXPORT_FORMAT,
        format_version = 1,
        exported       = date,
        plugins        = plugins,
        github         = github,
    }
end

-- What an import would do on this device. Installs the manifest's *current*
-- version of each listed plugin (old versions are not kept anywhere to pin
-- to), leaves anything already installed alone, and reports ids the
-- repository no longer has. Returns nil plus a reason for a file that is not
-- an export.
function L.planImport(data, manifest_plugins, installed)
    if type(data) ~= "table" or data.format ~= L.EXPORT_FORMAT then
        return nil, "format"
    end
    local by_id = {}
    for _i, p in ipairs(manifest_plugins or {}) do by_id[p.id] = p end
    local plan = { install = {}, present = {}, unknown = {}, github = {} }
    local seen = {}
    for _i, e in ipairs(type(data.plugins) == "table" and data.plugins or {}) do
        local id = type(e) == "table" and e.id
        if type(id) == "string" and not seen[id] then
            seen[id] = true
            if installed[id] then
                plan.present[#plan.present + 1] = id
            elseif by_id[id] then
                plan.install[#plan.install + 1] = by_id[id]
            else
                plan.unknown[#plan.unknown + 1] = id
            end
        end
    end
    for _i, e in ipairs(type(data.github) == "table" and data.github or {}) do
        local id   = type(e) == "table" and e.id
        local repo = type(e) == "table" and e.repo
        local owner, name
        -- GitHub's own rules: an owner is letters, digits and hyphens; a
        -- repo name may hold dots but is never "." or "..". The file is
        -- user-supplied, and owner/name end up in a URL and a folder name.
        if type(repo) == "string" then owner, name = repo:match("^(%w[%w%-]*)/([%w%-%_%.]+)$") end
        if name == "." or name == ".." then owner, name = nil, nil end
        if type(id) == "string" and owner and not seen[id] then
            seen[id] = true
            if installed[id] then
                plan.present[#plan.present + 1] = id
            else
                plan.github[#plan.github + 1] = {
                    id = id, owner = owner, name = name, full_name = owner .. "/" .. name,
                }
            end
        end
    end
    return plan
end

-- A small, deterministic JSON writer (sorted keys, two-space indent) for the
-- export file: something a person can read and diff, which rapidjson's
-- encoder does not promise across versions. Arrays are tables with a [1];
-- an empty table is written as [] since every list in the export may be
-- empty and no object in it ever is.
local function json_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

function L.encodeJson(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return json_string(v) end
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return tostring(v)
    end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" then return "null" end
    local inner = indent .. "  "
    if v[1] ~= nil or next(v) == nil then
        if next(v) == nil then return "[]" end
        local parts = {}
        for _i, x in ipairs(v) do parts[#parts + 1] = inner .. L.encodeJson(x, inner) end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _i, k in ipairs(keys) do
        parts[#parts + 1] = inner .. json_string(k) .. ": " .. L.encodeJson(v[k], inner)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

return L
