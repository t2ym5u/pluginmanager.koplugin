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
L.CATEGORY_ORDER = { "logic", "sudoku", "words", "board", "cards", "classic", "party", "duo", "tools" }

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

-- ---------------------------------------------------------------------------
-- Discover: `user:NAME` (browse one GitHub account instead of searching)
-- ---------------------------------------------------------------------------

-- The account named by a Discover search text of the form `user:NAME`, or
-- nil for an ordinary search. Shared by Discover plugins and Discover
-- patches so both read the prefix the same way.
function L.ownerQuery(filter)
    if type(filter) ~= "string" then return nil end
    local owner = filter:match("^%s*user:%s*(.-)%s*$")
    if owner == nil or owner == "" then return nil end
    return owner
end

-- GitHub sends `null` for an absent description, which rapidjson turns into
-- a truthy sentinel: anything that is not a real string reads as "".
local function str(v) return type(v) == "string" and v or "" end

-- Whether a repository from an account listing (GET /users/NAME/repos) looks
-- like a collection of KOReader user patches. Stricter than the search
-- filter in main.lua (looks_like_koreader_patch_repo), which only has to
-- clean up results a "koreader patches" search already matched: an account
-- listing is everything the owner has, and "koreader" in a name alone would
-- let in a KOReader fork or a plugin index. So it takes the patch topic, or
-- "patch" in the name, or a description that names both KOReader and
-- patches. A .koplugin repository is a plugin, never a patch collection.
-- Whether the repository really holds patch files is only known when it is
-- opened (one more API call each, too many for a whole account): opening
-- one with none says so.
function L.isOwnerPatchRepo(repo)
    if type(repo) ~= "table" then return false end
    local name = str(repo.name):lower()
    local desc = str(repo.description):lower()
    if name == "" or name:match("%.koplugin$") then return false end
    if type(repo.topics) == "table" then
        for _i, t in ipairs(repo.topics) do
            if t == "koreader-user-patch" or t == "koreader-patch" or t == "koreader-patches" then
                return true
            end
        end
    end
    if name:find("patch", 1, true) then return true end
    return desc:find("patch", 1, true) ~= nil
        and (desc:find("koreader", 1, true) ~= nil or name:find("koreader", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
-- Install everything (plugins + the manifest's patch repositories)
-- ---------------------------------------------------------------------------

-- The manifest's optional top-level `patch_repos` ("owner/name" strings),
-- as {owner, name, full_name}. A manifest without the field, a field that
-- is not a list, and entries that are not a plain owner/name are all read
-- as "no patch repositories" rather than as an error: the field is
-- optional, and the names end up in API URLs.
function L.patchRepos(manifest)
    local out, seen = {}, {}
    local list = type(manifest) == "table" and manifest.patch_repos
    if type(list) ~= "table" then return out end
    for _i, s in ipairs(list) do
        local owner, name
        if type(s) == "string" then owner, name = s:match("^%s*(%w[%w%-]*)/([%w%-%_%.]+)%s*$") end
        if name == "." or name == ".." then owner = nil end
        if owner then
            local full = owner .. "/" .. name
            if not seen[full:lower()] then
                seen[full:lower()] = true
                out[#out + 1] = { owner = owner, name = name, full_name = full }
            end
        end
    end
    return out
end

-- Which listed patch files to install. `items` are listRepoPatchFiles
-- results ({name, sha, ...}) from every repository, in manifest order;
-- `installed` maps a patch filename to {disabled, sha}, sha being the git
-- blob sha of the file on the device (or the one recorded at install, or
-- nil when neither is known).
--  - same sha as the repository: already current, left alone;
--  - disabled on the device: left alone -- the user turned it off, and a
--    bulk run must not quietly turn it back on (a single Install still can);
--  - anything else (absent, different, unknown): installed.
-- Two repositories shipping the same filename would write the same file:
-- the first one listed wins, the others are reported as duplicates.
function L.planPatchInstalls(items, installed)
    installed = installed or {}
    local plan = { install = {}, current = {}, disabled = {}, duplicate = {} }
    local seen = {}
    for _i, it in ipairs(items or {}) do
        local name = type(it) == "table" and it.name
        if type(name) == "string" then
            local local_state = installed[name]
            if seen[name] then
                plan.duplicate[#plan.duplicate + 1] = it
            elseif local_state and local_state.sha and it.sha and local_state.sha == it.sha then
                plan.current[#plan.current + 1] = it
            elseif local_state and local_state.disabled then
                plan.disabled[#plan.disabled + 1] = it
            else
                plan.install[#plan.install + 1] = it
            end
            seen[name] = true
        end
    end
    return plan
end

-- The numbers "Install everything" confirms with. `n_update`/`n_new` come
-- from the Update plan; `repo_results` is one {full_name, items | err} per
-- manifest patch repository (err when it could not be listed); `patch_plan`
-- is planPatchInstalls over all listed items.
function L.everythingCounts(n_update, n_new, repo_results, patch_plan)
    local c = {
        plugins_update   = n_update or 0,
        plugins_new      = n_new or 0,
        repos            = 0,
        repos_failed     = 0,
        patches          = patch_plan and #patch_plan.install or 0,
        patches_current  = patch_plan and #patch_plan.current or 0,
        patches_disabled = patch_plan and #patch_plan.disabled or 0,
    }
    c.plugins = c.plugins_update + c.plugins_new
    for _i, r in ipairs(repo_results or {}) do
        c.repos = c.repos + 1
        if r.err or not r.items then c.repos_failed = c.repos_failed + 1 end
    end
    c.nothing_to_do = c.plugins == 0 and c.patches == 0
    return c
end

-- ---------------------------------------------------------------------------
-- Retired plugins and templates (plugins that must not stay installed)
-- ---------------------------------------------------------------------------

-- Plugins taken out of the catalogue. Once gone from manifest.json, an
-- installed copy is listed like any third-party plugin, never updated, and
-- left alone by "Remove all" -- while KOReader still loads it at every start.
-- Its common/ is an old game-common, and the shared modules it loads first
-- are the ones every other game then gets: an old arrowwords made every
-- game crash on open (screen_base without getGutter).
-- The manifest names them in its top-level `retired` list; this copy is for
-- a manifest from before that field, or none at all (offline, first run).
L.RETIRED_FALLBACK = { "arrowwords", "boggleparty", "doubleornothing", "kakuro", "startmenu" }

-- A directory name or id starting with "_" is a template (the fleet's
-- _skeleton.koplugin): a starting point for writing a plugin, never one to
-- install. KOReader would load it like any other plugin.
function L.isTemplate(name)
    return type(name) == "string" and name:sub(1, 1) == "_"
end

-- The set of retired ids: the manifest's `retired` list when it has one
-- (even an empty one: an id taken back into the catalogue must stop being
-- flagged), else RETIRED_FALLBACK. An id the manifest still lists as a
-- plugin is never retired, whatever either list says, and neither is
-- Plugin Manager itself.
function L.retiredIds(manifest)
    local list = type(manifest) == "table" and manifest.retired
    if type(list) ~= "table" then list = L.RETIRED_FALLBACK end
    local set = {}
    for _i, id in ipairs(list) do
        if type(id) == "string" and id ~= "" then set[id] = true end
    end
    if type(manifest) == "table" and type(manifest.plugins) == "table" then
        for _i, p in ipairs(manifest.plugins) do
            if type(p) == "table" and type(p.id) == "string" then set[p.id] = nil end
        end
    end
    set.pluginmanager = nil
    return set
end

-- Which installed plugin directories should be removed. `dirs` are the
-- names of the *.koplugin directories in the plugins folder -- all of them,
-- whether or not they have a _meta.lua: a half-deleted plugin without one is
-- invisible to the installed scan but KOReader still runs its main.lua.
-- Returns { {id, dir, reason = "retired"|"template"}, ... } sorted by id.
function L.unwantedPlugins(dirs, manifest)
    local retired = L.retiredIds(manifest)
    local out = {}
    for _i, dir in ipairs(dirs or {}) do
        local id = type(dir) == "string" and dir:match("^(.+)%.koplugin$")
        if id then
            if L.isTemplate(id) then
                out[#out + 1] = { id = id, dir = dir, reason = "template" }
            elseif retired[id] then
                out[#out + 1] = { id = id, dir = dir, reason = "retired" }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

return L
