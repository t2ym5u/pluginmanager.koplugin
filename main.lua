local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local _plugins_dir = _dir:match("^(.*)/[^/]+/$") or (_dir .. "..")
package.path = _dir .. "?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonDialog    = require("ui/widget/buttondialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))

local MANIFEST_URL   = "https://raw.githubusercontent.com/t2ym5u/koreader-plugins/master/manifest.json"
local AUTO_CHECK_TTL = 86400  -- re-check automatically at most once every 24 h
local _patches_dir   = DataStorage:getPatchesDir()  -- koreader/patches, see frontend/userpatch.lua

-- Runs fn(...) shielded from Lua errors (a bad manifest entry, an
-- unexpected nil, a third-party source with malformed data...). Any escape
-- is logged to crash.log and turned into a normal (false, message) result,
-- so one broken plugin can never abort the rest of a bulk update.
local function safe_call(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then
        logger.warn("PluginManager:", a)
        return false, tostring(a)
    end
    return a, b
end

-- ---------------------------------------------------------------------------
-- Disable / enable installed plugins without deleting them
-- ---------------------------------------------------------------------------

-- Same mechanism KOReader's own plugin management screen and other plugin
-- managers (e.g. appstore.koplugin) use: a plugin id -> true map in the
-- global reader settings. PluginLoader consults this at startup to decide
-- which plugins to actually load, so toggling it only takes effect after a
-- restart -- there is no live enable/disable of an already-loaded plugin.
local function is_plugin_disabled(id)
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    return disabled[id] == true
end

local function set_plugin_disabled(id, disabled)
    local list = G_reader_settings:readSetting("plugins_disabled") or {}
    if disabled then
        list[id] = true
    else
        list[id] = nil
    end
    G_reader_settings:saveSetting("plugins_disabled", list)
end

-- ---------------------------------------------------------------------------
-- PluginManager
-- ---------------------------------------------------------------------------

local PluginManager = WidgetContainer:extend{
    name        = "pluginmanager",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Settings / manifest cache
-- ---------------------------------------------------------------------------

function PluginManager:ensureSettings()
    if not self.settings then
        self.settings = LuaSettings:open(
            DataStorage:getSettingsDir() .. "/pluginmanager.lua"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Ignored updates
-- ---------------------------------------------------------------------------

-- A plugin id can have at most one ignored version at a time: the one the
-- user last chose to skip. If the manifest later advances past it, is_newer()
-- against the *new* manifest version stops matching this stale entry on its
-- own, so the update reappears without needing any active cleanup.
function PluginManager:isVersionIgnored(id, version)
    self:ensureSettings()
    local ignored = self.settings:readSetting("ignored_versions") or {}
    return ignored[id] == version
end

function PluginManager:setIgnoredVersion(id, version)
    self:ensureSettings()
    local ignored = self.settings:readSetting("ignored_versions") or {}
    ignored[id] = version
    self.settings:saveSetting("ignored_versions", ignored)
    self.settings:flush()
end

-- ---------------------------------------------------------------------------
-- Discover installs (plugin id -> source GitHub repo)
-- ---------------------------------------------------------------------------

-- manifest.json plugins carry their own raw_base_url, so the repo link is
-- already right there in the data pluginmanager already caches. A plugin
-- installed via "Discover plugins…" has no manifest entry at all, so
-- without this it would become indistinguishable from any other
-- third-party-installed plugin the moment it lands in plugins/ -- no way to
-- check it for updates ever again. This is the minimal fix: remember which
-- repo it came from, keyed by the same id scanInstalled() already uses.
function PluginManager:getDiscoverInstall(id)
    self:ensureSettings()
    local all = self.settings:readSetting("discover_installs") or {}
    return all[id]
end

function PluginManager:recordDiscoverInstall(id, repo)
    self:ensureSettings()
    local all = self.settings:readSetting("discover_installs") or {}
    all[id] = { owner = repo.owner, name = repo.name, full_name = repo.full_name }
    self.settings:saveSetting("discover_installs", all)
    self.settings:flush()
end

function PluginManager:forgetDiscoverInstall(id)
    self:ensureSettings()
    local all = self.settings:readSetting("discover_installs") or {}
    if all[id] == nil then return end
    all[id] = nil
    self.settings:saveSetting("discover_installs", all)
    self:setDiscoverUpdateCache(id, nil)
    self.settings:flush()
end

-- Last remote version seen for a Discover-linked plugin, refreshed by
-- _refreshDiscoverLinkedVersions (piggybacked on the "Update" button) so
-- showPluginList can flag an available update for it without a network call
-- on every list open, the same way the manifest section's badge is driven
-- by the already-cached manifest rather than a live check per open.
function PluginManager:getDiscoverUpdateCache(id)
    self:ensureSettings()
    local all = self.settings:readSetting("discover_update_cache") or {}
    return all[id]
end

function PluginManager:setDiscoverUpdateCache(id, version)
    self:ensureSettings()
    local all = self.settings:readSetting("discover_update_cache") or {}
    all[id] = version
    self.settings:saveSetting("discover_update_cache", all)
    self.settings:flush()
end

function PluginManager:saveManifestCache(manifest)
    self:ensureSettings()
    local ok, json = pcall(require, "rapidjson")
    local json_str = ok and json.encode(manifest) or "{}"
    self.settings:saveSetting("manifest_json", json_str)
    self.settings:saveSetting("last_check",    os.time())
    self.settings:flush()
    self._last_check = os.time()
end

function PluginManager:loadCachedManifest()
    self:ensureSettings()
    local json_str   = self.settings:readSetting("manifest_json")
    local last_check = self.settings:readSetting("last_check")
    if not json_str then return end
    local manifest = parse_json(json_str)
    if manifest and manifest.plugins then
        self._manifest   = manifest
        self._last_check = last_check or 0
    end
end

-- ---------------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------------

-- raw.githubusercontent.com rate-limits bursts of requests from the same IP
-- with HTTP 429. A bulk update/reinstall can fire a few hundred requests
-- (every file of every plugin, back to back) in well under a minute, which
-- reliably tripped it and aborted the whole run. Two mitigations: pace every
-- request a little (avoids tripping the limit in the first place) and, if a
-- 429 slips through anyway, back off and retry rather than treating it as a
-- hard failure.
local FETCH_PACE_DELAY   = 0.2  -- seconds between any two requests
local FETCH_MAX_RETRIES  = 5
local FETCH_RETRY_DELAY  = 2    -- seconds, doubles each retry; overridden by Retry-After

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket.sleep then socket.sleep(seconds) end
end

local function fetch_url(url)
    local ok1, https = pcall(require, "ssl.https")
    if not ok1 then return nil, _("ssl.https not available") end
    local ok2, ltn12 = pcall(require, "ltn12")
    if not ok2 then return nil, _("ltn12 not available") end

    local delay = FETCH_RETRY_DELAY
    for attempt = 1, FETCH_MAX_RETRIES do
        sleep(FETCH_PACE_DELAY)
        local chunks = {}
        local result, status, headers = https.request{
            url      = url,
            sink     = ltn12.sink.table(chunks),
            verify   = "none",
            protocol = "tlsv1_2",
        }
        if result and status == 200 then
            return table.concat(chunks)
        end
        if status == 429 and attempt < FETCH_MAX_RETRIES then
            local retry_after = headers and tonumber(headers["retry-after"])
            sleep(retry_after or delay)
            delay = delay * 2
        else
            return nil, string.format(_("HTTP %s"), tostring(status or "?"))
        end
    end
    return nil, string.format(_("HTTP %s"), tostring(429))
end

-- Streams a response straight to a file instead of building it up as one Lua
-- string in memory -- used for zip downloads, which can run to a few
-- hundred KB and would otherwise sit fully in RAM twice (once as the ltn12
-- chunk table, once as table.concat's result) on memory-constrained e-ink
-- hardware. ltn12.sink.file closes the handle itself once done, on both
-- success and failure.
local function fetch_to_file(url, path, extra_headers)
    local ok1, https = pcall(require, "ssl.https")
    if not ok1 then return false, _("ssl.https not available") end
    local ok2, ltn12 = pcall(require, "ltn12")
    if not ok2 then return false, _("ltn12 not available") end
    local file, ferr = io.open(path, "wb")
    if not file then return false, ferr end

    local headers = { ["User-Agent"] = "pluginmanager.koplugin" }
    for k, v in pairs(extra_headers or {}) do headers[k] = v end

    local result, status = https.request{
        url      = url,
        sink     = ltn12.sink.file(file),
        headers  = headers,
        verify   = "none",
        protocol = "tlsv1_2",
    }
    if result and status == 200 then return true end
    os.remove(path)
    return false, string.format(_("HTTP %s"), tostring(status or "?"))
end

-- ---------------------------------------------------------------------------
-- GitHub API (repository discovery)
-- ---------------------------------------------------------------------------

-- Optional local config file (never committed -- see .gitignore) letting a
-- user supply a classic GitHub PAT to raise the search API's very low
-- unauthenticated rate limit (10 requests/minute). Mirrors the same pattern
-- appstore.koplugin uses, so anyone already familiar with that plugin's
-- config file recognises this one.
local function github_config()
    local ok, cfg = pcall(require, "pluginmanager_configuration")
    return ok and cfg or {}
end

local function github_headers()
    local headers = {
        ["User-Agent"] = "pluginmanager.koplugin",
        ["Accept"]     = "application/vnd.github+json",
    }
    local token = github_config().github_token
    if token and token ~= "" and token ~= "ghp_your_token_here" then
        headers["Authorization"] = "token " .. token
    end
    return headers
end

-- GET path (e.g. "/search/repositories") against api.github.com with query
-- already URL-encoded by the caller. Returns (parsed_json, nil) on success or
-- (nil, message) on failure -- a 403/429 is reported distinctly since it
-- almost always means the (usually unauthenticated) rate limit was hit.
local function github_api_get(path, query)
    local ok1, https = pcall(require, "ssl.https")
    if not ok1 then return nil, _("ssl.https not available") end
    local ok2, ltn12 = pcall(require, "ltn12")
    if not ok2 then return nil, _("ltn12 not available") end

    local url = "https://api.github.com" .. path
    if query and query ~= "" then url = url .. "?" .. query end

    local chunks = {}
    local result, status = https.request{
        url      = url,
        sink     = ltn12.sink.table(chunks),
        headers  = github_headers(),
        verify   = "none",
        protocol = "tlsv1_2",
    }
    local body = table.concat(chunks)
    if not result or status ~= 200 then
        if status == 403 or status == 429 then
            return nil, _("GitHub API rate limit reached. Try again later, or set a GitHub token in pluginmanager_configuration.lua.")
        end
        return nil, string.format(_("HTTP %s"), tostring(status or "?"))
    end
    local data, jerr = parse_json(body)
    if not data then return nil, jerr end
    return data
end

local function url_encode(s)
    local ok, url = pcall(require, "socket.url")
    if ok and url.escape then return url.escape(s) end
    return (s:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function github_raw_base_url(owner, name)
    return string.format("https://raw.githubusercontent.com/%s/%s/HEAD/", owner, name)
end

-- GitHub's topic tagging is self-reported and not curated: `topic:koreader-plugin`
-- reliably includes some completely unrelated repos that happen to carry the
-- tag (e.g. an ebook reader app whose maintainer tagged it once, with no
-- other mention of KOReader anywhere). A fake positive here is harmless --
-- Install still refuses it cleanly for lacking a _meta.lua -- but it's
-- confusing noise in a browsing list, so filter out anything that gives no
-- other sign of actually being a KOReader plugin.
-- rapidjson decodes a JSON `null` into a special sentinel value -- not Lua
-- nil, and not a string -- specifically so a table can still tell "key
-- absent" apart from "key present but null". A bare `x or ""` doesn't catch
-- it (the sentinel is truthy), so reading it as a string later (e.g.
-- `:lower()`) crashes with "attempt to index a userdata value". GitHub
-- routinely sends `description: null` for repos that don't have one, which
-- is exactly what triggered this in practice -- every nullable string field
-- read from a GitHub API response needs to go through this instead.
local function json_str(v)
    return type(v) == "string" and v or ""
end

local function json_num(v)
    return type(v) == "number" and v or 0
end

local function looks_like_koreader_plugin(repo)
    local name = json_str(repo.name):lower()
    local desc = json_str(repo.description):lower()
    return name:match("%.koplugin$") ~= nil
        or desc:find("koreader", 1, true) ~= nil
        or desc:find("koplugin", 1, true) ~= nil
end

-- Searches GitHub for repositories tagged with the koreader-plugin topic
-- (the convention already used by appstore.koplugin, so third-party plugin
-- authors are likely to already have it set). `opts.text` narrows further
-- by name/description, `opts.sort` is "stars" or "updated", `opts.page` is
-- 1-based. Returns (items, nil, total_count) on success -- total_count is
-- GitHub's count *before* this function's own noise filtering, so callers
-- can tell "genuinely zero matches" apart from "everything on this page got
-- filtered out".
local function repo_to_item(repo, fallback_owner)
    local owner = (repo.owner and repo.owner.login) or fallback_owner
    return {
        owner        = owner,
        name         = json_str(repo.name),
        full_name    = json_str(repo.full_name),
        description  = json_str(repo.description),
        stars        = json_num(repo.stargazers_count),
        updated_at   = json_str(repo.updated_at),
        raw_base_url = github_raw_base_url(owner, repo.name),
    }
end

-- The koreader-plugin topic is self-tagged and plenty of real plugins never
-- set it -- every repo in this very fleet included (verified: none of them
-- carry it). Topic search alone would never surface those. appstore.koplugin
-- works around exactly this by running a *second*, independent search for
-- repo names containing ".koplugin" and merging both result sets; this does
-- the same, just fetched live per search rather than into a local cache.
local function build_search_query(q, sort, page)
    return string.format(
        "q=%s&sort=%s&order=desc&page=%d&per_page=30",
        url_encode(q), sort, page
    )
end

function PluginManager:searchGithubPlugins(opts)
    opts = opts or {}
    local text = opts.text
    local sort = opts.sort or "stars"
    local page = opts.page or 1

    local topic_q = "topic:koreader-plugin"
    if text and text ~= "" then topic_q = topic_q .. " " .. text .. " in:name,description" end

    local name_q = '".koplugin" in:name'
    if text and text ~= "" then name_q = text .. " " .. name_q end

    local by_topic, topic_err = github_api_get("/search/repositories", build_search_query(topic_q, sort, page))
    local by_name,  name_err  = github_api_get("/search/repositories", build_search_query(name_q, sort, page))
    if not by_topic and not by_name then
        return nil, topic_err or name_err
    end

    local seen, items = {}, {}
    local function add_all(data)
        if not data then return end
        for _, repo in ipairs(data.items or {}) do
            -- Noise reduction: a fork with zero stars is very unlikely to be
            -- a maintained, independent plugin worth surfacing.
            local looks_like_fork_spam = repo.fork and json_num(repo.stargazers_count) == 0
            if not looks_like_fork_spam and not seen[repo.full_name] and looks_like_koreader_plugin(repo) then
                seen[repo.full_name] = true
                items[#items + 1] = repo_to_item(repo)
            end
        end
    end
    add_all(by_topic)
    add_all(by_name)

    -- Merging two independently-sorted result sets breaks any single global
    -- order, so re-sort the combined list locally.
    if sort == "updated" then
        table.sort(items, function(a, b) return (a.updated_at or "") > (b.updated_at or "") end)
    else
        table.sort(items, function(a, b) return a.stars > b.stars end)
    end

    local total_count = json_num(by_topic and by_topic.total_count) + json_num(by_name and by_name.total_count)
    local has_more     = (by_topic and #(by_topic.items or {}) == 30) or (by_name and #(by_name.items or {}) == 30)
    return items, nil, total_count, has_more
end

-- Lists every public repo owned by `owner` whose name looks like a plugin
-- (".koplugin" suffix -- the convention this whole fleet, and most
-- third-party authors, follow). This is deliberately independent of the
-- koreader-plugin GitHub topic used by searchGithubPlugins above: many
-- authors -- including every repo in this very fleet -- never set that
-- topic at all, so browsing "everything user X made" needs a path that
-- doesn't depend on it. Paginates up to 500 repos (5 pages), which comfortably
-- covers even a very prolific account.
function PluginManager:listGithubOwnerPlugins(owner)
    local items = {}
    for page = 1, 5 do
        local query = string.format("type=owner&per_page=100&page=%d", page)
        local data, err = github_api_get("/users/" .. url_encode(owner) .. "/repos", query)
        if not data then
            if #items == 0 then return nil, err end
            break
        end
        if type(data) ~= "table" or #data == 0 then break end
        for _, repo in ipairs(data) do
            if json_str(repo.name):match("%.koplugin$") then
                items[#items + 1] = repo_to_item(repo, owner)
            end
        end
        if #data < 100 then break end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- JSON  (rapidjson is bundled with KOReader)
-- ---------------------------------------------------------------------------

-- NOTE: parse_json is referenced in loadCachedManifest above, so define it
-- as a module-level upvalue before PluginManager:loadCachedManifest is called.
-- We declare it here and assign below to keep the forward reference working.
parse_json = nil  -- luacheck: ignore (intentional forward declaration)

local function _parse_json(str)
    local ok, json = pcall(require, "rapidjson")
    if not ok then return nil, _("rapidjson not available") end
    local ok2, data = pcall(json.decode, str)
    if ok2 then return data end
    return nil, _("JSON parse error")
end
parse_json = _parse_json

-- ---------------------------------------------------------------------------
-- Version comparison
-- ---------------------------------------------------------------------------

local function is_newer(a, b)
    local function parts(v)
        local t = {}
        for n in (v or "0"):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local ap, bp = parts(a), parts(b)
    for i = 1, math.max(#ap, #bp) do
        local ai, bi = ap[i] or 0, bp[i] or 0
        if bi > ai then return true end
        if bi < ai then return false end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

local function get_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    return ok and lfs or nil
end

local function mkdir_p(path)
    local lfs = get_lfs()
    if lfs then
        local parts = {}
        local p = path:gsub("/$", "")
        while p and p ~= "" and p ~= "/" do
            table.insert(parts, 1, p)
            p = p:match("^(.*)/[^/]+$")
        end
        for _, seg in ipairs(parts) do
            if lfs.attributes(seg, "mode") ~= "directory" then
                lfs.mkdir(seg)
            end
        end
    else
        os.execute("mkdir -p " .. path)
    end
end

-- Top-level regular files directly inside `path` (directories, such as a
-- symlinked/copied `common`, are left untouched).
local function list_top_level_files(path)
    local lfs = get_lfs()
    if not lfs then return {} end
    local files = {}
    pcall(function()
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".."
               and lfs.attributes(path .. "/" .. entry, "mode") == "file" then
                files[#files + 1] = entry
            end
        end
    end)
    return files
end

local function write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end

local function rm_rf(path)
    if not path:find(_plugins_dir, 1, true) then return end
    local lfs = get_lfs()
    if lfs then
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            for f in lfs.dir(path) do
                if f ~= "." and f ~= ".." then rm_rf(path .. "/" .. f) end
            end
            lfs.rmdir(path)
        elseif mode then
            os.remove(path)
        end
    else
        os.execute("rm -rf " .. path)
    end
end

-- Isolates a field's value to its own line before extracting the string out
-- of it. A previous version matched fullname's string directly against the
-- rest of the file with a pattern like '[^"]*"([^"]*)"' -- fine for
-- fullname = "Plain" or fullname = _("Plain"), but for
-- fullname = _([[Bracket]]) (no quote anywhere near it), that pattern
-- skipped straight past to the next field's quotes (e.g. version = "1.2.3")
-- and silently captured the version string as the fullname instead.
-- Bounding the search to one line first makes that impossible. Shared by
-- read_meta (a local _meta.lua on disk) and any caller parsing one fetched
-- over the network (e.g. checking a Discover-installed plugin for updates).
local function parse_meta(src)
    local function field(name_pat)
        local line = src:match(name_pat .. '%s*=%s*([^\n]+)')
        if not line then return nil end
        return line:match('%[%[(.-)%]%]') or line:match('"([^"]*)"')
    end
    return {
        fullname = field('fullname'),
        version  = field('version'),
    }
end

local function read_meta(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return parse_meta(src)
end

-- ---------------------------------------------------------------------------
-- Installed-plugin scan
-- ---------------------------------------------------------------------------

function PluginManager:scanInstalled()
    local lfs = get_lfs()
    if not lfs then return {} end
    local installed = {}
    local ok = pcall(function()
        for entry in lfs.dir(_plugins_dir) do
            -- KOReader's own PluginLoader derives a plugin's id from its
            -- directory name (stripping ".koplugin") and ignores/warns on
            -- any "name" field in _meta.lua -- match that here instead of
            -- trusting _meta.lua's own (now-removed) name field.
            local id = entry:match("^(.*)%.koplugin$")
            if id then
                local meta = read_meta(_plugins_dir .. "/" .. entry .. "/_meta.lua")
                if meta then
                    installed[id] = {
                        id       = id,
                        version  = meta.version or "?",
                        fullname = meta.fullname or id,
                        dir      = entry,
                        disabled = is_plugin_disabled(id),
                    }
                end
            end
        end
    end)
    if not ok then return {} end
    return installed
end

-- ---------------------------------------------------------------------------
-- Silent background check  (auto, called from init)
-- ---------------------------------------------------------------------------

function PluginManager:_silentCheck()
    -- Only run if already connected; never prompt the user.
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and not NetworkMgr:isConnected() then return end

    local body = fetch_url(MANIFEST_URL)
    if not body then return end
    local manifest = parse_json(body)
    if not manifest or not manifest.plugins then return end
    self._manifest = manifest
    self:saveManifestCache(manifest)

    local installed = self:scanInstalled()
    local n_update  = 0
    for _, p in ipairs(manifest.plugins) do
        local inst = installed[p.id]
        if inst and is_newer(inst.version, p.version) and not self:isVersionIgnored(p.id, p.version) then
            n_update = n_update + 1
        end
    end
    if n_update > 0 then
        UIManager:show(InfoMessage:new{
            text    = string.format(_("Plugin Manager: %d update(s) available."), n_update),
            timeout = 5,
        })
    end
end

function PluginManager:showIgnoredDialog()
    self:ensureSettings()
    local ignored = self.settings:readSetting("ignored_versions") or {}
    local ids = {}
    for id, version in pairs(ignored) do
        if version then ids[#ids + 1] = id end
    end
    table.sort(ids)

    local dlg
    local buttons = {}

    if #ids == 0 then
        buttons[#buttons + 1] = {{ text = _("No ignored updates."), enabled = false }}
    else
        for _i, id in ipairs(ids) do
            local pid = id
            buttons[#buttons + 1] = {
                { text = pid .. "  v" .. ignored[id], enabled = false },
                {
                    text     = _("Un-ignore"),
                    callback = function()
                        UIManager:close(dlg)
                        self:setIgnoredVersion(pid, nil)
                        self:showIgnoredDialog()
                    end,
                },
            }
        end
    end

    buttons[#buttons + 1] = {{
        text     = _("Close"),
        callback = function() UIManager:close(dlg) end,
    }}

    dlg = ButtonDialog:new{ title = _("Ignored updates"), buttons = buttons }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Install helpers
-- ---------------------------------------------------------------------------

-- `lib_key` is a manifest.json top-level key naming a downloadable common/
-- bundle -- "common" (game-common, ScreenBase-based games) or
-- "sudoku_common" (sudoku-common, BaseScreen-based sudoku variants); see the
-- project-sudoku-common-architecture memory for why the two are NOT
-- interchangeable. Each plugin_info names the one it needs via its own
-- common_lib field, which indexes straight into manifest[lib_key] here.
function PluginManager:ensureCommon(manifest, lib_key)
    local spec = manifest[lib_key]
    local lib_dir = _plugins_dir .. "/" .. spec.dir
    local lfs     = get_lfs()
    if lfs and lfs.attributes(lib_dir, "mode") == "directory" then
        local vf = io.open(lib_dir .. "/.version", "r")
        if vf then
            local v = vf:read("*l"); vf:close()
            if not is_newer(v or "0", spec.version) then return true end
        end
    end
    mkdir_p(lib_dir)
    local base = spec.raw_base_url or ((manifest.raw_base_url or "") .. spec.dir .. "/")
    for _, fname in ipairs(spec.files) do
        local body, err = fetch_url(base .. fname)
        if not body then
            return false, string.format("%s/%s: %s", spec.dir, fname, err)
        end
        local subdir = fname:match("^(.*)/[^/]+$")
        if subdir then
            mkdir_p(lib_dir .. "/" .. subdir)
        end
        write_file(lib_dir .. "/" .. fname, body)
    end
    write_file(lib_dir .. "/.version", spec.version)
    return true
end

function PluginManager:installPlugin(plugin_info, manifest)
    local plugin_dir = _plugins_dir .. "/" .. plugin_info.dir
    mkdir_p(plugin_dir)
    local base = plugin_info.raw_base_url or ((manifest.raw_base_url or "") .. plugin_info.dir .. "/")
    for idx, fname in ipairs(plugin_info.files) do
        local body, err = fetch_url(base .. fname)
        if not body then
            return false, string.format(_("Download failed: %s \u{2014} %s"), fname, err)
        end
        local subdir = fname:match("^(.*)/[^/]+$")
        if subdir then
            mkdir_p(plugin_dir .. "/" .. subdir)
        end
        local ok, werr = write_file(plugin_dir .. "/" .. fname, body)
        if not ok then
            return false, string.format(_("Write failed: %s \u{2014} %s"), fname, werr)
        end
    end

    -- Remove stale files left over from a previous version (renamed/removed
    -- source files) that are no longer listed for this version. Only
    -- top-level regular files are considered; `common` and any other
    -- subdirectory are never touched here.
    local expected = {}
    for _, fname in ipairs(plugin_info.files) do expected[fname] = true end
    for _, fname in ipairs(list_top_level_files(plugin_dir)) do
        if not expected[fname] then
            os.remove(plugin_dir .. "/" .. fname)
        end
    end

    if plugin_info.common_lib then
        -- Always copy real files into common/ on the device -- never a
        -- symlink here. Symlinks are a local-dev-only shortcut (see the
        -- feedback-user-local-symlinks memory); on a real reader they're
        -- one more thing that can dangle or dead-end, and previously this
        -- was also a one-time-only copy (skipped whenever common/ already
        -- existed in any form), so a shared-lib fix could silently never
        -- reach an already-installed plugin no matter how many times it
        -- got reinstalled. Re-copying every install/update is cheap (a
        -- handful of .lua files) and guarantees common/ is never stale.
        local spec = manifest[plugin_info.common_lib]
        local common_path = plugin_dir .. "/common"
        local lib_dir = _plugins_dir .. "/" .. spec.dir
        local lfs = get_lfs()
        mkdir_p(common_path)
        if lfs and lfs.attributes(lib_dir, "mode") == "directory" then
            for fname in lfs.dir(lib_dir) do
                if fname:match("%.lua$") then
                    local src = io.open(lib_dir .. "/" .. fname, "rb")
                    if src then
                        local data = src:read("*a"); src:close()
                        write_file(common_path .. "/" .. fname, data)
                    end
                end
            end
        end
    end
    return true
end

-- Install / update a single plugin with UI feedback.
function PluginManager:_doInstall(plugin_info, manifest)
    local msg = InfoMessage:new{
        text = string.format(_("Installing %s\u{2026}"), plugin_info.fullname),
    }
    UIManager:show(msg)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(msg)
        if plugin_info.common_lib and manifest[plugin_info.common_lib] then
            local ok, err = safe_call(function() return self:ensureCommon(manifest, plugin_info.common_lib) end)
            if not ok then
                logger.warn("PluginManager: " .. plugin_info.common_lib .. " error:", err)
                UIManager:show(InfoMessage:new{
                    text    = _("Shared library error:") .. "\n" .. (err or "?"),
                    timeout = 5,
                })
                return
            end
        end
        local ok, err = safe_call(function() return self:installPlugin(plugin_info, manifest) end)
        if ok then
            local is_self = plugin_info.id == "pluginmanager"
            UIManager:show(InfoMessage:new{
                text    = is_self
                    and string.format(
                        _("%s v%s installed.\nPlease restart KOReader to apply the update."),
                        plugin_info.fullname, plugin_info.version
                    )
                    or  string.format(
                        _("%s v%s installed."),
                        plugin_info.fullname, plugin_info.version
                    ),
                timeout = is_self and 8 or 6,
            })
        else
            logger.warn("PluginManager: install failed for", plugin_info.id, ":", err)
            UIManager:show(InfoMessage:new{
                text    = _("Install failed:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Discover: install a plugin from an arbitrary GitHub repo (zip archive)
-- ---------------------------------------------------------------------------

-- GitHub zipballs always wrap their contents in a single top folder named
-- "<owner>-<repo>-<sha>/", so a repo that IS a plugin (the convention used
-- across this whole fleet: a repo named e.g. "foo.koplugin" with _meta.lua
-- at its root) never actually has a path segment ending in ".koplugin" --
-- that only happens for a monorepo nesting a plugin in a subfolder. Handle
-- both: prefer a ".koplugin"-suffixed path segment when present, otherwise
-- fall back to deriving the name from the repo itself.
local function detect_plugin_layout(reader, repo_name)
    local plugin_root, meta_path
    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path:match("/_meta%.lua$") then
            local candidate_root = entry.path:match("^(.*)/_meta%.lua$")
            -- Prefer the shallowest match, in case a monorepo nests more
            -- than one .koplugin folder.
            if not meta_path or #candidate_root < #plugin_root then
                plugin_root, meta_path = candidate_root, entry.path
            end
        end
    end
    if not plugin_root then
        return nil, _("No _meta.lua found in this repository's archive.")
    end
    local dirname = plugin_root:match("([^/]+%.koplugin)$")
    if not dirname then
        dirname = repo_name:match("%.koplugin$") and repo_name or (repo_name .. ".koplugin")
    end
    return { plugin_root = plugin_root, dirname = dirname }
end

-- Extracts every file entry under `plugin_root` into `dest_dir`, preserving
-- its relative path. Iterating fresh here (rather than reusing whatever
-- position detect_plugin_layout's own iterate() loop left the reader at)
-- matters: ffi/archiver's iterate() resets to the start of the archive on
-- every call unless told to keep position, so this is a clean second pass,
-- not a continuation.
local function extract_archive(reader, plugin_root, dest_dir)
    mkdir_p(dest_dir)
    local prefix = plugin_root .. "/"
    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path:sub(1, #prefix) == prefix then
            local relative = entry.path:sub(#prefix + 1)
            local dest_path = dest_dir .. "/" .. relative
            local subdir = relative:match("^(.*)/[^/]+$")
            if subdir then mkdir_p(dest_dir .. "/" .. subdir) end
            if not reader:extractToPath(entry.path, dest_path) then
                return false, string.format(_("Failed to extract %s"), relative)
            end
        end
    end
    return true
end

-- Returns a human-readable description of whatever is already installed at
-- `dirname` (or nil if nothing is there, or if it's already tracked to this
-- exact `repo` -- that's just a normal reinstall/update, not a conflict).
-- The plugin's install directory is derived purely from the repo's own
-- name, so a same-named repo from a *different* owner -- or one of this
-- fleet's own manifest.json plugins -- can collide with an entirely
-- unrelated plugin already occupying that same plugins/<name>.koplugin
-- folder; without this check, installFromGithubRepo would silently
-- overwrite it.
function PluginManager:describeExistingInstall(dirname, repo)
    local lfs = get_lfs()
    if not lfs or lfs.attributes(_plugins_dir .. "/" .. dirname, "mode") ~= "directory" then
        return nil
    end
    local id            = dirname:match("^(.*)%.koplugin$") or dirname
    local existing_repo = self:getDiscoverInstall(id)
    if existing_repo and repo and existing_repo.owner == repo.owner and existing_repo.name == repo.name then
        return nil
    end

    local meta     = read_meta(_plugins_dir .. "/" .. dirname .. "/_meta.lua")
    local fullname = (meta and meta.fullname) or id
    local version  = (meta and meta.version) or "?"
    local source
    if existing_repo then
        source = existing_repo.full_name
    else
        local in_manifest = false
        if self._manifest then
            for _, p in ipairs(self._manifest.plugins) do
                if p.id == id then in_manifest = true break end
            end
        end
        source = in_manifest and _("the koreader-plugins repository") or _("an untracked local install")
    end
    return string.format(_("%s v%s (from %s)"), fullname, version, source)
end

-- `on_done(ok, err)`, if given, is called exactly once at the very end of
-- the attempt (success or failure) -- lets installAllFromGithub chain
-- installs one at a time without duplicating any of this logic.
function PluginManager:installFromGithubRepo(repo, on_done)
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if not ok_arc then
        UIManager:show(InfoMessage:new{ text = _("Archive support not available."), timeout = 4 })
        if on_done then on_done(false, _("Archive support not available.")) end
        return
    end

    local zip_url  = string.format("https://api.github.com/repos/%s/%s/zipball", repo.owner, repo.name)
    local zip_dir  = DataStorage:getDataDir() .. "/cache/pluginmanager"
    mkdir_p(zip_dir)
    local zip_path = string.format("%s/%s-%d.zip", zip_dir, repo.name, os.time())

    local progress = InfoMessage:new{ text = string.format(_("Downloading %s\u{2026}"), repo.full_name or repo.name) }
    UIManager:show(progress)
    UIManager:scheduleIn(0.2, function()
        local ok_dl, dl_err = safe_call(function() return fetch_to_file(zip_url, zip_path, github_headers()) end)
        UIManager:close(progress)
        if not ok_dl then
            UIManager:show(InfoMessage:new{
                text    = _("Download failed:") .. "\n" .. (dl_err or "?"),
                timeout = 5,
            })
            if on_done then on_done(false, dl_err) end
            return
        end

        local reader = Archiver.Reader:new()
        if not safe_call(function() return reader:open(zip_path) end) then
            os.remove(zip_path)
            UIManager:show(InfoMessage:new{ text = _("Failed to open downloaded archive."), timeout = 5 })
            if on_done then on_done(false, _("Failed to open downloaded archive.")) end
            return
        end

        local layout, derr = safe_call(function() return detect_plugin_layout(reader, repo.name) end)
        if not layout then
            reader:close()
            os.remove(zip_path)
            UIManager:show(InfoMessage:new{
                text    = derr or _("Could not detect a plugin inside this repository."),
                timeout = 5,
            })
            if on_done then on_done(false, derr) end
            return
        end

        local dest_dir = _plugins_dir .. "/" .. layout.dirname

        local function proceed()
            local eok, eerr = safe_call(function() return extract_archive(reader, layout.plugin_root, dest_dir) end)
            reader:close()
            os.remove(zip_path)

            if not eok then
                -- Don't leave a half-written plugin directory behind:
                -- KOReader would try to load it at next startup and fail on
                -- missing files.
                rm_rf(dest_dir)
                UIManager:show(InfoMessage:new{
                    text    = _("Installation failed:") .. "\n" .. (eerr or "?"),
                    timeout = 5,
                })
                if on_done then on_done(false, eerr) end
                return
            end

            local meta = read_meta(dest_dir .. "/_meta.lua")
            local id   = layout.dirname:match("^(.*)%.koplugin$") or layout.dirname
            self:recordDiscoverInstall(id, repo)
            UIManager:show(InfoMessage:new{
                text    = string.format(
                    _("%s installed.\nPlease restart KOReader to load it."),
                    (meta and meta.fullname) or repo.name
                ),
                timeout = 8,
            })
            if on_done then on_done(true) end
        end

        local conflict = self:describeExistingInstall(layout.dirname, repo)
        if conflict then
            UIManager:show(ConfirmBox:new{
                text        = string.format(
                    _("%s\nis already installed at %s.\nInstalling %s here will overwrite it. Continue?"),
                    conflict, layout.dirname, repo.full_name
                ),
                ok_text     = _("Overwrite"),
                ok_callback = proceed,
                cancel_callback = function()
                    reader:close()
                    os.remove(zip_path)
                    if on_done then on_done(false, _("Cancelled: a different plugin already occupies this folder.")) end
                end,
            })
            return
        end

        proceed()
    end)
end

-- Installs every repo in `repos` one at a time (never in parallel -- keeps
-- memory pressure and GitHub API usage predictable, same reasoning as the
-- manifest-driven bulk install in _runBulkInstall), then shows one summary.
function PluginManager:installAllFromGithub(repos)
    local total  = #repos
    local failed = {}
    local function step(i)
        if i > total then
            local parts = {}
            if #failed > 0 then
                parts[#parts + 1] = string.format(_("%d/%d installed. Failures:"), total - #failed, total)
                for _, f in ipairs(failed) do parts[#parts + 1] = f end
            else
                parts[#parts + 1] = string.format(
                    _("%d plugin(s) installed.\nPlease restart KOReader to load them."), total
                )
            end
            UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 10 })
            return
        end
        local repo = repos[i]
        self:installFromGithubRepo(repo, function(ok, err)
            if not ok then
                failed[#failed + 1] = repo.full_name .. ": " .. (err or "?")
            end
            step(i + 1)
        end)
    end
    step(1)
end

function PluginManager:getDiscoverSort()
    self:ensureSettings()
    return self.settings:readSetting("discover_sort_mode") or "stars"
end

function PluginManager:cycleDiscoverSort()
    local next_mode = self:getDiscoverSort() == "stars" and "updated" or "stars"
    self:ensureSettings()
    self.settings:saveSetting("discover_sort_mode", next_mode)
    self.settings:flush()
    return next_mode
end

function PluginManager:showDiscoverFilterDialog(link_target)
    local input
    input = InputDialog:new{
        title       = _("Search GitHub plugins"),
        description = _("Type user:NAME to browse every .koplugin repo from one GitHub account."),
        input       = self._discover_filter or "",
        input_hint  = _("Search text (optional)\u{2026}"),
        buttons    = {{
            {
                text     = _("Clear"),
                callback = function()
                    UIManager:close(input)
                    self._discover_filter = nil
                    self:showDiscoverDialog(link_target)
                end,
            },
            {
                text     = _("Cancel"),
                callback = function()
                    UIManager:close(input)
                    self:showDiscoverDialog(link_target)
                end,
            },
            {
                text             = _("Search"),
                is_enter_default = true,
                callback         = function()
                    local text = input:getInputText():match("^%s*(.-)%s*$")
                    UIManager:close(input)
                    self._discover_filter = text ~= "" and text or nil
                    self:showDiscoverDialog(link_target)
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function PluginManager:showDiscoveredRepoDialog(repo)
    local dlg
    local title = repo.full_name .. string.format("  \u{2605}%d", repo.stars)
    if repo._installed then
        if repo._remote_version and is_newer(repo._installed.version, repo._remote_version) then
            title = title .. "\n" .. string.format(_("Installed v%s \u{2014} update to v%s available"), repo._installed.version, repo._remote_version)
        else
            title = title .. "\n" .. string.format(_("Already installed (v%s)"), repo._installed.version)
        end
    end
    if repo.description and repo.description ~= "" then
        title = title .. "\n" .. repo.description
    end
    dlg = ButtonDialog:new{
        title   = title,
        buttons = {
            {{
                text     = _("Install"),
                callback = function()
                    UIManager:close(dlg)
                    UIManager:show(ConfirmBox:new{
                        text    = string.format(
                            _("Install %s from GitHub?\nThis downloads and runs third-party code \u{2014} only install plugins you trust."),
                            repo.full_name
                        ),
                        ok_text     = _("Install"),
                        ok_callback = function() self:installFromGithubRepo(repo) end,
                    })
                end,
            }},
            {{
                text     = _("README\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showReadme(
                        repo.raw_base_url .. "README.md",
                        string.format(_("README: %s"), repo.full_name),
                        repo.owner .. "_" .. repo.name
                    )
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

-- `link_target`, when given, switches the whole Discover flow from "browse
-- to install" into "browse to link" mode: tapping a result links it to
-- `link_target` (an installed-but-untracked plugin's inst_info, from
-- showLinkRepoDialog's "Search GitHub…") instead of opening the normal
-- install/README dialog. This is threaded through every function in this
-- flow (filter dialog, sort toggle, "Load more") so the mode survives
-- filtering/paging within the same browsing session.
function PluginManager:showDiscoverDialog(link_target)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        NetworkMgr:runWhenOnline(function() self:_showDiscoverDialog(1, {}, link_target) end)
    else
        self:_showDiscoverDialog(1, {}, link_target)
    end
end

-- Confirms, then installs every repo currently shown, one at a time. Warns
-- about GitHub's unauthenticated rate limit up front for a large batch --
-- each install is a separate zipball download against the *core* API
-- (60 requests/hour unauthenticated, shared with everything else this
-- plugin does against api.github.com), easy to exceed with more than a
-- couple dozen repos in one go.
function PluginManager:confirmInstallAll(repos)
    local text = string.format(_("Install all %d plugins shown?"), #repos)
    if #repos > 20 and not github_config().github_token then
        text = text .. "\n" .. _("GitHub's unauthenticated rate limit is low (60 requests/hour) and this many installs may hit it partway through; see Configuration in the README to set a token first.")
    end
    UIManager:show(ConfirmBox:new{
        text        = text,
        ok_text     = _("Install all"),
        ok_callback = function() self:installAllFromGithub(repos) end,
    })
end

function PluginManager:confirmLinkRepo(link_target, repo)
    UIManager:show(ConfirmBox:new{
        text        = string.format(_("Link %s to %s?"), link_target.fullname, repo.full_name),
        ok_text     = _("Link"),
        ok_callback = function() self:verifyAndLinkRepo(link_target, repo.owner, repo.name) end,
    })
end

-- `accumulated` carries results from previous pages across "Load more" taps,
-- so paging in doesn't lose what was already fetched. `page`/`accumulated`
-- are meaningless in owner-browse mode (listGithubOwnerPlugins already
-- returns everything in one call), but are threaded through regardless to
-- keep this a single entry point for both modes.
function PluginManager:_showDiscoverDialog(page, accumulated, link_target)
    local owner_query = self._discover_filter and self._discover_filter:match("^user:%s*(.+)$")

    local notice = InfoMessage:new{ text = _("Searching GitHub\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local results, err, total_count, has_more
        if owner_query then
            results, err = self:listGithubOwnerPlugins(owner_query)
        else
            results, err, total_count, has_more = self:searchGithubPlugins{
                text = self._discover_filter,
                sort = self:getDiscoverSort(),
                page = page,
            }
        end
        if not results then
            UIManager:show(InfoMessage:new{
                text    = _("Search failed:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
            return
        end
        for _, r in ipairs(results) do accumulated[#accumulated + 1] = r end

        if #accumulated == 0 then
            if owner_query then
                UIManager:show(InfoMessage:new{
                    text    = string.format(_("No .koplugin repositories found for \u{201c}%s\u{201d}."), owner_query),
                    timeout = 4,
                })
            elseif self._discover_filter then
                -- A filter that's still set from a previous search is the
                -- most likely reason this comes back empty on a later
                -- attempt (the text must still match somewhere), so surface
                -- it and offer the fix directly rather than leaving the
                -- dialog looking like Discover has simply stopped working.
                UIManager:show(ConfirmBox:new{
                    text        = string.format(
                        _("No results for \u{201c}%s\u{201d} (%d repositories are candidates in total, before that filter).\nClear the filter and search again?"),
                        self._discover_filter, total_count or 0
                    ),
                    ok_text     = _("Clear filter"),
                    ok_callback = function()
                        self._discover_filter = nil
                        self:showDiscoverDialog(link_target)
                    end,
                    cancel_text = _("Close"),
                })
            else
                UIManager:show(InfoMessage:new{ text = _("No results."), timeout = 3 })
            end
            return
        end

        local Menu   = require("ui/widget/menu")
        local Screen = require("device").screen

        -- Cross-reference each result against what's on disk under the
        -- folder name a plain single-repo install would use (same fallback
        -- detect_plugin_layout uses), so already-installed repos are marked
        -- in the list instead of only surfacing a warning at Install time.
        -- Cached on the repo table itself so paging in more results or
        -- re-sorting doesn't re-fetch remote versions already checked.
        -- Skipped in link_target mode: that flow picks a repo to *link* an
        -- existing untracked install to, so "already installed" isn't a
        -- meaningful signal there.
        local to_check = {}
        if not link_target then
            local scanned = self:scanInstalled()
            for _, repo in ipairs(accumulated) do
                if repo._installed == nil then
                    local dirname = repo.name:match("%.koplugin$") and repo.name or (repo.name .. ".koplugin")
                    local id = dirname:match("^(.*)%.koplugin$")
                    repo._installed = scanned[id] or false
                    if repo._installed and repo._update_checked == nil then
                        to_check[#to_check + 1] = repo
                    end
                end
            end
        end

        local function build_menu()
            local items = {}
            if not link_target and #accumulated >= 2 then
                items[#items + 1] = {
                    text     = string.format(_("Install all %d shown\u{2026}"), #accumulated),
                    bold     = true,
                    callback = function() self:confirmInstallAll(accumulated) end,
                }
            end
            for _i, repo in ipairs(accumulated) do
                local pref = repo
                local status, bold
                if repo._installed then
                    if repo._remote_version and is_newer(repo._installed.version, repo._remote_version) then
                        status = string.format(_("v%s\u{2192}v%s"), repo._installed.version, repo._remote_version)
                        bold   = true
                    else
                        status = string.format(_("Installed v%s"), repo._installed.version)
                    end
                end
                items[#items + 1] = {
                    text      = repo.full_name,
                    mandatory = status
                        and string.format("%s  \u{2605}%d", status, repo.stars)
                        or  string.format("\u{2605}%d", repo.stars),
                    bold      = bold,
                    callback  = function()
                        if link_target then
                            self:confirmLinkRepo(link_target, pref)
                        else
                            self:showDiscoveredRepoDialog(pref)
                        end
                    end,
                }
            end
            if not owner_query and has_more then
                -- At least one of the two merged queries had a full page: there
                -- may well be more.
                items[#items + 1] = {
                    text     = _("Load more\u{2026}"),
                    callback = function() self:_showDiscoverDialog(page + 1, accumulated, link_target) end,
                }
            end

            local menu_instance
            menu_instance = Menu:new{
                title               = link_target
                    and string.format(_("Select repo for %s"), link_target.fullname)
                    or  _("Discover plugins"),
                subtitle            = self._discover_filter and string.format(_("Search: %s"), self._discover_filter) or nil,
                item_table          = items,
                width               = Screen:getWidth(),
                height              = Screen:getHeight(),
                title_bar_left_icon = "appbar.search",
                onLeftButtonTap     = function()
                    UIManager:close(menu_instance)
                    self:showDiscoverFilterDialog(link_target)
                end,
                onLeftButtonHold    = function()
                    local mode = self:cycleDiscoverSort()
                    UIManager:close(menu_instance)
                    UIManager:show(InfoMessage:new{
                        text    = mode == "updated" and _("Sorted by last updated.") or _("Sorted by stars."),
                        timeout = 2,
                    })
                    self:showDiscoverDialog(link_target)
                end,
            }
            function menu_instance:onMenuChoice(item)
                UIManager:close(self)
                if item.callback then item.callback() end
            end
            UIManager:show(menu_instance)
        end

        if #to_check == 0 then
            build_menu()
        else
            local check_notice = InfoMessage:new{ text = _("Checking installed plugins for updates\u{2026}") }
            UIManager:show(check_notice)
            local function check_step(i)
                if i > #to_check then
                    UIManager:close(check_notice)
                    build_menu()
                    return
                end
                local repo = to_check[i]
                local body = fetch_url(github_raw_base_url(repo.owner, repo.name) .. "_meta.lua")
                repo._remote_version = body and parse_meta(body).version or nil
                repo._update_checked = true
                UIManager:scheduleIn(0, function() check_step(i + 1) end)
            end
            check_step(1)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Remove
-- ---------------------------------------------------------------------------

function PluginManager:_doRemove(fullname, plugin_dir)
    rm_rf(_plugins_dir .. "/" .. plugin_dir)
    local id = plugin_dir:match("^(.*)%.koplugin$")
    if id then self:forgetDiscoverInstall(id) end
    UIManager:show(InfoMessage:new{
        text    = string.format(_("%s removed."), fullname),
        timeout = 5,
    })
end

-- ---------------------------------------------------------------------------
-- Renamed-plugin cleanup
-- ---------------------------------------------------------------------------

-- When a plugin is renamed upstream (both its id and its dir change, e.g.
-- tabou.koplugin -> taboo.koplugin), scanInstalled() keys the old install by
-- its old id, which no longer matches anything in the manifest: installPlugin
-- happily creates the new dir alongside it, but nothing ever removes the old
-- one, so both show up as separate active plugins on the reader. A manifest
-- entry can declare `renamed_from = {"old_id", ...}` to mark this; once the
-- new plugin is confirmed present on disk under a different dir, the old
-- directory is deleted.
function PluginManager:_cleanupRenamed(manifest)
    local installed = self:scanInstalled()
    local removed = {}
    for _, p in ipairs(manifest.plugins) do
        if p.renamed_from and installed[p.id] then
            for _, old_id in ipairs(p.renamed_from) do
                local old = installed[old_id]
                if old and old.dir ~= installed[p.id].dir then
                    rm_rf(_plugins_dir .. "/" .. old.dir)
                    removed[#removed + 1] = old.fullname
                end
            end
        end
    end
    return removed
end

-- ---------------------------------------------------------------------------
-- README viewer
-- ---------------------------------------------------------------------------

-- TextViewer only gained Markdown rendering (text_format = "md") in KOReader
-- v2026.07 -- older versions still show the raw README fine, just unstyled.
local function textviewer_supports_md()
    local ok, Version = pcall(require, "version")
    if not ok then return false end
    local current = Version:getNormalizedCurrentVersion()
    local min     = Version:getNormalizedVersion("v2026.07")
    return current and min and current >= min
end

local function readme_cache_path(cache_key)
    return DataStorage:getDataDir() .. "/cache/pluginmanager/readme_" .. cache_key:gsub("[^%w%-%.]", "_") .. ".md"
end

local function load_readme_cache(cache_key)
    local f = io.open(readme_cache_path(cache_key), "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body ~= "" and body or nil
end

function PluginManager:_displayReadme(body, url, title, cache_key)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title                = title,
        text                 = body,
        text_format          = textviewer_supports_md() and "md" or nil,
        add_default_buttons  = true,
        buttons_table        = {{
            {
                text     = _("Refresh"),
                callback = function() self:_fetchAndShowReadme(url, title, cache_key) end,
            },
        }},
    })
end

function PluginManager:_fetchAndShowReadme(url, title, cache_key)
    local notice = InfoMessage:new{ text = _("Fetching README\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local body, err = fetch_url(url)
        if not body then
            UIManager:show(InfoMessage:new{
                text    = _("README download failed:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
            return
        end
        local cache_path = readme_cache_path(cache_key)
        mkdir_p(cache_path:match("^(.*)/"))
        write_file(cache_path, body)
        self:_displayReadme(body, url, title, cache_key)
    end)
end

-- Shows `url`'s README, caching the result to disk so reopening the same
-- README later (or offline) is instant instead of re-downloading every
-- time. `cache_key` identifies the cache file (plugin id, or "owner_repo"
-- for a Discover result) and is sanitised for filesystem safety. A
-- "Refresh" button on the viewer lets the user force a re-download when
-- they actually want the latest copy.
function PluginManager:showReadme(url, title, cache_key)
    if not url then
        UIManager:show(InfoMessage:new{
            text    = _("No README available for this source."),
            timeout = 4,
        })
        return
    end

    local cached = load_readme_cache(cache_key)
    if cached then
        self:_displayReadme(cached, url, title, cache_key)
        return
    end
    self:_fetchAndShowReadme(url, title, cache_key)
end

-- ---------------------------------------------------------------------------
-- Per-plugin dialogs
-- ---------------------------------------------------------------------------

function PluginManager:showInstalledDialog(plugin_info, inst_info, has_update)
    local dlg
    local buttons = {}

    buttons[#buttons + 1] = {{
        text     = _("README\u{2026}"),
        callback = function()
            UIManager:close(dlg)
            self:showReadme(
                plugin_info.raw_base_url and (plugin_info.raw_base_url .. "README.md") or nil,
                string.format(_("README: %s"), plugin_info.fullname),
                plugin_info.id
            )
        end,
    }}

    if has_update then
        local pref = plugin_info
        buttons[#buttons + 1] = {{
            text     = string.format(_("Update to v%s"), plugin_info.version),
            callback = function()
                UIManager:close(dlg)
                self:_doInstall(pref, self._manifest)
            end,
        }}
        buttons[#buttons + 1] = {{
            text     = string.format(_("Ignore v%s"), plugin_info.version),
            callback = function()
                UIManager:close(dlg)
                self:setIgnoredVersion(pref.id, pref.version)
                UIManager:show(InfoMessage:new{
                    text    = string.format(
                        _("v%s will be hidden from updates until a newer version is released.\nSee \u{201c}Ignored updates\u{2026}\u{201d} in the main menu to undo."),
                        pref.version
                    ),
                    timeout = 5,
                })
            end,
        }}
    end

    -- Reinstall (force, even when up to date)
    local pref = plugin_info
    buttons[#buttons + 1] = {{
        text     = has_update and _("Reinstall current") or _("Reinstall"),
        callback = function()
            UIManager:close(dlg)
            -- install with the installed version, not the manifest version
            local current = {
                id           = pref.id,
                dir          = pref.dir,
                fullname     = inst_info.fullname,
                version      = inst_info.version,
                files        = pref.files,
                common_lib   = pref.common_lib,
                raw_base_url = pref.raw_base_url,
            }
            self:_doInstall(current, self._manifest)
        end,
    }}

    local iref = inst_info
    local pid  = plugin_info.id
    if pid ~= "pluginmanager" then
        -- Disabling Plugin Manager itself would lock the user out of the
        -- only UI that could re-enable it.
        buttons[#buttons + 1] = {{
            text     = iref.disabled and _("Enable") or _("Disable"),
            callback = function()
                UIManager:close(dlg)
                set_plugin_disabled(pid, not iref.disabled)
                UIManager:show(InfoMessage:new{
                    text    = iref.disabled
                        and string.format(_("%s enabled.\nRestart KOReader to apply."), iref.fullname)
                        or  string.format(_("%s disabled.\nRestart KOReader to apply."), iref.fullname),
                    timeout = 5,
                })
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text     = _("Remove"),
        callback = function()
            UIManager:close(dlg)
            UIManager:show(ConfirmBox:new{
                text        = string.format(
                    _("Remove %s?\nAll plugin files will be deleted."),
                    iref.fullname
                ),
                ok_text     = _("Remove"),
                ok_callback = function()
                    self:_doRemove(iref.fullname, iref.dir)
                end,
            })
        end,
    }}

    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(dlg) end,
    }}

    -- Title: name + version arrow + description
    local title = inst_info.fullname .. "  v" .. inst_info.version
    if iref.disabled then title = title .. "  " .. _("[DISABLED]") end
    if has_update then
        title = title .. "  \u{2192}  v" .. plugin_info.version
    end
    if json_str(plugin_info.description) ~= "" then
        title = title .. "\n" .. json_str(plugin_info.description)
    end

    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

function PluginManager:showAvailableDialog(plugin_info)
    local dlg
    local title = plugin_info.fullname .. "  v" .. plugin_info.version
    if json_str(plugin_info.description) ~= "" then
        title = title .. "\n" .. json_str(plugin_info.description)
    end
    dlg = ButtonDialog:new{
        title   = title,
        buttons = {
            {{
                text     = _("Install"),
                callback = function()
                    UIManager:close(dlg)
                    self:_doInstall(plugin_info, self._manifest)
                end,
            }},
            {{
                text     = _("README\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showReadme(
                        plugin_info.raw_base_url and (plugin_info.raw_base_url .. "README.md") or nil,
                        string.format(_("README: %s"), plugin_info.fullname),
                        plugin_info.id
                    )
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

-- Dialog for a plugin installed locally but absent from the manifest.
-- Fetches the current _meta.lua from `repo`'s default branch and offers to
-- update if its version is newer than `iref`'s installed one. Reuses the
-- exact same install path as a first install (installFromGithubRepo just
-- re-downloads and re-extracts over the existing directory).
function PluginManager:checkDiscoverUpdate(iref, repo)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    local function run()
        local notice = InfoMessage:new{ text = _("Checking for updates\u{2026}") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(notice)
            local url = github_raw_base_url(repo.owner, repo.name) .. "_meta.lua"
            local body, err = fetch_url(url)
            if not body then
                UIManager:show(InfoMessage:new{
                    text    = _("Update check failed:") .. "\n" .. (err or "?"),
                    timeout = 5,
                })
                return
            end
            local remote_version = parse_meta(body).version
            if not remote_version then
                UIManager:show(InfoMessage:new{ text = _("Could not read the remote version."), timeout = 4 })
                return
            end
            if not is_newer(iref.version, remote_version) then
                UIManager:show(InfoMessage:new{ text = _("Already up to date."), timeout = 3 })
                return
            end
            if self:isVersionIgnored(iref.id, remote_version) then
                UIManager:show(InfoMessage:new{
                    text    = string.format(
                        _("v%s is available but ignored.\nSee \u{201c}Ignored updates\u{2026}\u{201d} in the main menu to undo."),
                        remote_version
                    ),
                    timeout = 5,
                })
                return
            end
            local dlg
            dlg = ButtonDialog:new{
                title   = string.format(_("%s: v%s \u{2192} v%s"), iref.fullname, iref.version, remote_version),
                buttons = {
                    {{
                        text     = string.format(_("Update to v%s"), remote_version),
                        callback = function()
                            UIManager:close(dlg)
                            self:installFromGithubRepo(repo)
                        end,
                    }},
                    {{
                        text     = string.format(_("Ignore v%s"), remote_version),
                        callback = function()
                            UIManager:close(dlg)
                            self:setIgnoredVersion(iref.id, remote_version)
                            UIManager:show(InfoMessage:new{
                                text    = string.format(
                                    _("v%s will be hidden from updates until a newer version is released.\nSee \u{201c}Ignored updates\u{2026}\u{201d} in the main menu to undo."),
                                    remote_version
                                ),
                                timeout = 5,
                            })
                        end,
                    }},
                    {{
                        text     = _("Cancel"),
                        callback = function() UIManager:close(dlg) end,
                    }},
                },
            }
            UIManager:show(dlg)
        end)
    end
    if ok and NetworkMgr then NetworkMgr:runWhenOnline(run) else run() end
end

-- Fetches _meta.lua from owner/name's default branch to confirm it's
-- actually a KOReader plugin before linking (mirrors appstore's "Match with
-- URL" -- same idea, minus its SQLite-backed match bookkeeping). If it can't
-- be verified (network hiccup, private repo, wrong owner/name typed), the
-- user can still choose to link anyway rather than being blocked outright.
function PluginManager:verifyAndLinkRepo(iref, owner, name)
    local repo = { owner = owner, name = name, full_name = owner .. "/" .. name }
    local function link()
        self:recordDiscoverInstall(iref.id, repo)
        UIManager:show(InfoMessage:new{
            text    = string.format(_("Linked %s to %s."), iref.fullname, repo.full_name),
            timeout = 4,
        })
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    local function run()
        local notice = InfoMessage:new{ text = _("Verifying repository\u{2026}") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(notice)
            local body = fetch_url(github_raw_base_url(owner, name) .. "_meta.lua")
            if body and parse_meta(body).version then
                link()
            else
                UIManager:show(ConfirmBox:new{
                    text        = string.format(
                        _("Could not verify %s (no _meta.lua found on its default branch). Link anyway?"),
                        repo.full_name
                    ),
                    ok_text     = _("Link anyway"),
                    ok_callback = link,
                })
            end
        end)
    end
    if ok and NetworkMgr then NetworkMgr:runWhenOnline(run) else run() end
end

function PluginManager:showLinkRepoDialog(iref)
    local input
    input = InputDialog:new{
        title       = _("Link to GitHub repo"),
        description = string.format(
            _("Enter the owner/repo this plugin came from, e.g. t2ym5u/%s."), iref.dir
        ),
        input       = "",
        input_hint  = "owner/repo",
        buttons     = {{
            {
                text     = _("Cancel"),
                callback = function()
                    UIManager:close(input)
                    self:showLocalOnlyDialog(iref)
                end,
            },
            {
                text     = _("Search GitHub\u{2026}"),
                callback = function()
                    UIManager:close(input)
                    self:showDiscoverDialog(iref)
                end,
            },
            {
                text             = _("Link"),
                is_enter_default = true,
                callback         = function()
                    local text = input:getInputText():match("^%s*(.-)%s*$")
                    UIManager:close(input)
                    local owner, name = text:match("^([%w%-%_%.]+)/([%w%-%_%.]+)$")
                    if not owner then
                        UIManager:show(InfoMessage:new{
                            text    = _("Enter as owner/repo, e.g. t2ym5u/sudoku.koplugin."),
                            timeout = 4,
                        })
                        return
                    end
                    self:verifyAndLinkRepo(iref, owner, name)
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function PluginManager:showLocalOnlyDialog(inst_info)
    local iref = inst_info
    local repo = self:getDiscoverInstall(iref.id)
    local dlg
    local buttons = {}

    if repo then
        buttons[#buttons + 1] = {{
            text     = _("Check for update"),
            callback = function()
                UIManager:close(dlg)
                self:checkDiscoverUpdate(iref, repo)
            end,
        }}
        buttons[#buttons + 1] = {{
            -- Unconditional re-download, regardless of version: for when the
            -- local install is suspect (corrupted, half-written) or the
            -- upstream repo doesn't bump _meta.lua's version between
            -- changes, so "Check for update" would never notice.
            text     = _("Reinstall"),
            callback = function()
                UIManager:close(dlg)
                self:installFromGithubRepo(repo)
            end,
        }}
        buttons[#buttons + 1] = {{
            text     = _("README\u{2026}"),
            callback = function()
                UIManager:close(dlg)
                self:showReadme(
                    github_raw_base_url(repo.owner, repo.name) .. "README.md",
                    string.format(_("README: %s"), repo.full_name),
                    repo.owner .. "_" .. repo.name
                )
            end,
        }}
        buttons[#buttons + 1] = {{
            text     = _("Unlink"),
            callback = function()
                UIManager:close(dlg)
                self:forgetDiscoverInstall(iref.id)
                self:showLocalOnlyDialog(iref)
            end,
        }}
    else
        -- No recorded source repo: this is a genuinely untracked
        -- third-party plugin (installed by hand, from Discover before it
        -- tracked sources, or removed from manifest.json). Offer to link it
        -- to a GitHub repo -- same idea as appstore's "Match with URL" --
        -- so it can get update checks and a README too.
        buttons[#buttons + 1] = {{
            text     = _("Link to GitHub repo\u{2026}"),
            callback = function()
                UIManager:close(dlg)
                self:showLinkRepoDialog(iref)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text     = _("Remove"),
        callback = function()
            UIManager:close(dlg)
            UIManager:show(ConfirmBox:new{
                text        = string.format(
                    _("Remove %s?\nAll plugin files will be deleted."),
                    iref.fullname
                ),
                ok_text     = _("Remove"),
                ok_callback = function()
                    self:_doRemove(iref.fullname, iref.dir)
                end,
            })
        end,
    }}
    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(dlg) end,
    }}

    local title = iref.fullname .. "  v" .. iref.version
    if repo then title = title .. "\n" .. repo.full_name end
    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Plugin list popup (paginated)
-- ---------------------------------------------------------------------------

-- Sort groups for "status" sort mode: updates first, then plain installed,
-- then locally-installed-but-unknown, then not-yet-installed. "name" mode
-- ignores this and sorts purely alphabetically.
local SORT_GROUP_UPDATE       = 0
local SORT_GROUP_INSTALLED    = 1
local SORT_GROUP_LOCAL_ONLY   = 2
local SORT_GROUP_AVAILABLE    = 3

function PluginManager:getListSort()
    self:ensureSettings()
    return self.settings:readSetting("list_sort_mode") or "name"
end

function PluginManager:cycleListSort()
    local next_mode = self:getListSort() == "name" and "status" or "name"
    self:ensureSettings()
    self.settings:saveSetting("list_sort_mode", next_mode)
    self.settings:flush()
    return next_mode
end

function PluginManager:showPluginListFilterDialog()
    local input
    input = InputDialog:new{
        title      = _("Filter plugins"),
        input      = self._list_filter or "",
        input_hint = _("Plugin name\u{2026}"),
        buttons    = {{
            {
                text     = _("Clear"),
                callback = function()
                    UIManager:close(input)
                    self._list_filter = nil
                    self:showPluginList()
                end,
            },
            {
                text     = _("Cancel"),
                callback = function()
                    UIManager:close(input)
                    self:showPluginList()
                end,
            },
            {
                text             = _("Filter"),
                is_enter_default = true,
                callback         = function()
                    local text = input:getInputText():match("^%s*(.-)%s*$")
                    UIManager:close(input)
                    self._list_filter = text ~= "" and text or nil
                    self:showPluginList()
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function PluginManager:showPluginList()
    local Menu   = require("ui/widget/menu")
    local Screen = require("device").screen

    local installed = self:scanInstalled()
    local items     = {}

    if not self._manifest then
        -- Offline: show only locally-installed plugins
        for _i, inst in pairs(installed) do
            local iref = inst
            items[#items + 1] = {
                text        = (iref.disabled and (_("[DISABLED]") .. " ") or "") .. iref.fullname,
                mandatory   = "v" .. iref.version,
                _sort_group = SORT_GROUP_INSTALLED,
                callback    = function() self:showLocalOnlyDialog(iref) end,
            }
        end
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("No plugins installed.\nPress Update to fetch the list."),
                timeout = 3,
            })
            return
        end
    else
        local known_ids = {}
        for _i, p in ipairs(self._manifest.plugins) do
            known_ids[p.id] = true
            local inst = installed[p.id]
            if inst then
                local has_update = is_newer(inst.version, p.version) and not self:isVersionIgnored(p.id, p.version)
                local detail = has_update
                    and ("v" .. inst.version .. " \u{2192} v" .. p.version)
                    or  ("v" .. inst.version)
                local entry = { plugin = p, inst = inst, has_update = has_update }
                items[#items + 1] = {
                    text        = (inst.disabled and (_("[DISABLED]") .. " ") or "") .. inst.fullname,
                    mandatory   = detail,
                    bold        = has_update,
                    _sort_group = has_update and SORT_GROUP_UPDATE or SORT_GROUP_INSTALLED,
                    callback    = function()
                        self:showInstalledDialog(entry.plugin, entry.inst, entry.has_update)
                    end,
                }
            else
                local pref = p
                items[#items + 1] = {
                    text        = p.fullname,
                    mandatory   = "v" .. p.version,
                    dim         = true,
                    _sort_group = SORT_GROUP_AVAILABLE,
                    callback    = function() self:showAvailableDialog(pref) end,
                }
            end
        end
        -- Locally installed but absent from manifest
        for id, inst in pairs(installed) do
            if not known_ids[id] then
                local iref          = inst
                local repo          = self:getDiscoverInstall(id)
                local tag           = repo and _("(GitHub)") or _("(local)")
                local remote_version = repo and self:getDiscoverUpdateCache(id)
                local has_update    = remote_version
                    and is_newer(inst.version, remote_version)
                    and not self:isVersionIgnored(id, remote_version)
                local detail = has_update
                    and ("v" .. inst.version .. " \u{2192} v" .. remote_version .. " " .. tag)
                    or  ("v" .. inst.version .. " " .. tag)
                items[#items + 1] = {
                    text        = (inst.disabled and (_("[DISABLED]") .. " ") or "") .. inst.fullname,
                    mandatory   = detail,
                    bold        = has_update,
                    _sort_group = has_update and SORT_GROUP_UPDATE or SORT_GROUP_LOCAL_ONLY,
                    callback    = function() self:showLocalOnlyDialog(iref) end,
                }
            end
        end
    end

    local filter = (self._list_filter or ""):lower()
    if filter ~= "" then
        local filtered = {}
        for _, item in ipairs(items) do
            if item.text:lower():find(filter, 1, true) then
                filtered[#filtered + 1] = item
            end
        end
        items = filtered
    end

    if self:getListSort() == "status" then
        table.sort(items, function(a, b)
            if a._sort_group ~= b._sort_group then return a._sort_group < b._sort_group end
            return a.text < b.text
        end)
    else
        table.sort(items, function(a, b) return a.text < b.text end)
    end

    local menu_instance
    menu_instance = Menu:new{
        title               = _("Plugins"),
        subtitle            = filter ~= "" and string.format(_("Filter: %s"), self._list_filter) or nil,
        item_table          = items,
        width               = Screen:getWidth(),
        height              = Screen:getHeight(),
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap     = function()
            UIManager:close(menu_instance)
            self:showPluginListFilterDialog()
        end,
        onLeftButtonHold    = function()
            local mode = self:cycleListSort()
            UIManager:close(menu_instance)
            UIManager:show(InfoMessage:new{
                text    = mode == "status"
                    and _("Sorted by status (updates first).")
                    or  _("Sorted by name."),
                timeout = 2,
            })
            self:showPluginList()
        end,
    }
    function menu_instance:onMenuChoice(item)
        UIManager:close(self)
        if item.callback then item.callback() end
    end
    UIManager:show(menu_instance)
end

-- ---------------------------------------------------------------------------
-- Full update (fetch manifest + install new + update existing)
-- ---------------------------------------------------------------------------

-- Fetches manifest.json and caches the result on success. On failure, shows
-- the network-error dialog itself and returns nil -- callers can just bail
-- out when manifest is nil.
function PluginManager:_fetchManifest()
    local body, err = fetch_url(MANIFEST_URL)
    if not body then
        UIManager:show(InfoMessage:new{
            text    = _("Network error:") .. "\n" .. (err or "?"),
            timeout = 5,
        })
        return nil
    end
    local manifest, jerr = parse_json(body)
    if not manifest or not manifest.plugins then
        UIManager:show(InfoMessage:new{
            text    = _("Network error:") .. "\n" .. (jerr or _("invalid manifest")),
            timeout = 5,
        })
        return nil
    end
    self._manifest = manifest
    self:saveManifestCache(manifest)
    return manifest
end

-- Shared by doFullUpdate and doFullReinstall: refreshes every shared
-- library referenced by `to_process` (or already installed), then installs
-- each plugin in `to_process` one at a time with progress feedback.
-- `opts` lets callers customise the three user-facing strings without
-- duplicating this whole flow: nothing_to_do_text, done_text (takes one
-- %d, the count), progress_text (same).
function PluginManager:_runBulkInstall(manifest, to_process, opts)
    opts = opts or {}
    local installed = self:scanInstalled()

    -- Shared libraries must be refreshed independently of per-plugin
    -- version deltas: a plugin whose own version didn't change would never
    -- otherwise get its common/ mirror refreshed even when the shared lib
    -- itself did. Check every common_lib used by anything installed or
    -- about to be processed, every run.
    local to_process_ids = {}
    for _, p in ipairs(to_process) do to_process_ids[p.id] = true end
    local needed_libs = {}
    for _, p in ipairs(manifest.plugins) do
        if p.common_lib and manifest[p.common_lib] and (installed[p.id] or to_process_ids[p.id]) then
            needed_libs[p.common_lib] = true
        end
    end
    for lib_key in pairs(needed_libs) do
        local ok, err = safe_call(function() return self:ensureCommon(manifest, lib_key) end)
        if not ok then
            logger.warn("PluginManager: " .. lib_key .. " error:", err)
            UIManager:show(InfoMessage:new{
                text    = _("Shared library error:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
            return
        end
    end

    if #to_process == 0 then
        local removed_renamed = safe_call(function() return self:_cleanupRenamed(manifest) end) or {}
        local parts = {}
        parts[#parts + 1] = opts.nothing_to_do_text or _("All plugins are up to date.")
        for _i, fullname in ipairs(removed_renamed) do
            parts[#parts + 1] = string.format(_("Removed superseded %s."), fullname)
        end
        UIManager:show(InfoMessage:new{
            text    = table.concat(parts, "\n"),
            timeout = 4,
        })
        return
    end

    local total    = #to_process
    local failed   = {}
    local has_self = false

    local function finish()
        local removed_renamed = safe_call(function() return self:_cleanupRenamed(manifest) end) or {}
        local parts = {}
        if #failed > 0 then
            parts[#parts + 1] = string.format(
                _("%d/%d done. Failures:"), total - #failed, total)
            for _, f in ipairs(failed) do parts[#parts + 1] = f end
        else
            parts[#parts + 1] = string.format(opts.done_text or _("%d plugin(s) updated/installed."), total)
        end
        for _i, fullname in ipairs(removed_renamed) do
            parts[#parts + 1] = string.format(_("Removed superseded %s."), fullname)
        end
        if has_self then
            parts[#parts + 1] = _("Please restart KOReader to apply the Plugin Manager update.")
        end
        UIManager:show(InfoMessage:new{
            text    = table.concat(parts, "\n"),
            timeout = has_self and 10 or 6,
        })
    end

    local function step(i)
        if i > total then finish() return end
        local p   = to_process[i]
        local msg = InfoMessage:new{
            text = string.format(_("%d/%d  %s\u{2026}"), i, total, p.fullname),
        }
        UIManager:show(msg)
        UIManager:scheduleIn(0.1, function()
            UIManager:close(msg)
            local ok, err = safe_call(function() return self:installPlugin(p, manifest) end)
            if not ok then
                logger.warn("PluginManager: install failed for", p.id, ":", err)
                failed[#failed + 1] = p.fullname .. ": " .. (err or "?")
            elseif p.id == "pluginmanager" then
                has_self = true
            end
            -- Each fetch accumulates response-body strings that only
            -- become collectible once installPlugin returns; forcing a
            -- cycle here (rather than waiting for Lua to decide it's
            -- needed) matters on memory-constrained e-ink hardware during
            -- a long bulk run (Reinstall All processes every installed
            -- plugin, potentially dozens) -- letting memory pressure build
            -- across the whole batch is exactly what previously crashed
            -- KOReader mid-write and left a plugin's directory with only
            -- some of its files, which then failed to load at all afterward.
            collectgarbage("collect")
            -- Always advance, even after a failure above: one broken
            -- plugin must not stop the rest of a bulk run.
            step(i + 1)
        end)
    end

    local init_msg = InfoMessage:new{
        text = string.format(opts.progress_text or _("Updating %d plugin(s)\u{2026}"), total),
    }
    UIManager:show(init_msg)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(init_msg)
        step(1)
    end)
end

function PluginManager:doFullUpdate()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        NetworkMgr:runWhenOnline(function() self:_doFullUpdate() end)
    else
        self:_doFullUpdate()
    end
end

-- Refreshes the cached remote version of every Discover-linked plugin
-- that's still actually installed, piggybacked on the "Update" button
-- (already a network-required action the user takes periodically) so
-- showPluginList's "(GitHub)" section can show an update badge without
-- needing its own network call every time the list is opened. No failure
-- surfaced per item -- a plugin whose fetch fails just keeps its last known
-- cached version (or none) until the next Update.
function PluginManager:_refreshDiscoverLinkedVersions(installed, on_done)
    self:ensureSettings()
    local links = self.settings:readSetting("discover_installs") or {}
    local to_check = {}
    for id, repo in pairs(links) do
        if installed[id] then to_check[#to_check + 1] = { id = id, repo = repo } end
    end
    if #to_check == 0 then
        on_done()
        return
    end
    local notice = InfoMessage:new{ text = _("Checking linked plugins for updates\u{2026}") }
    UIManager:show(notice)
    local function step(i)
        if i > #to_check then
            UIManager:close(notice)
            on_done()
            return
        end
        local entry   = to_check[i]
        local body    = fetch_url(github_raw_base_url(entry.repo.owner, entry.repo.name) .. "_meta.lua")
        local version = body and parse_meta(body).version
        if version then self:setDiscoverUpdateCache(entry.id, version) end
        UIManager:scheduleIn(0, function() step(i + 1) end)
    end
    step(1)
end

function PluginManager:_doFullUpdate()
    local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local manifest = self:_fetchManifest()
        if not manifest then return end

        local installed  = self:scanInstalled()
        local to_process = {}
        for _, p in ipairs(manifest.plugins) do
            local inst = installed[p.id]
            if not inst or (is_newer(inst.version, p.version) and not self:isVersionIgnored(p.id, p.version)) then
                to_process[#to_process + 1] = p
            end
        end

        self:_refreshDiscoverLinkedVersions(installed, function()
            self:_runBulkInstall(manifest, to_process)
        end)
    end)
end

-- Forces a full reinstall of every currently-installed plugin, regardless
-- of whether its own version already matches the manifest. Complements
-- Update: a shared-lib-only fix bumps common_lib's version but not every
-- consuming plugin's own _meta.lua version, so those plugins never appear
-- in Update's to_process list and their common/ mirror is never refreshed by
-- it -- Reinstall All exists as the unconditional "just fetch everything
-- again" escape hatch for exactly that case (or any other local corruption).
function PluginManager:doFullReinstall()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        NetworkMgr:runWhenOnline(function() self:_doFullReinstall() end)
    else
        self:_doFullReinstall()
    end
end

function PluginManager:doRemoveAll()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        NetworkMgr:runWhenOnline(function() self:_doRemoveAll() end)
    else
        self:_doRemoveAll()
    end
end

-- Removes every installed plugin *that Plugin Manager itself manages*,
-- except Plugin Manager (deleting its own directory mid-run would leave no
-- way to reinstall anything afterwards). scanInstalled() picks up any
-- "*.koplugin" directory with a _meta.lua -- which includes KOReader's own
-- built-in plugins and unrelated third-party plugins, not just ones this
-- fleet's manifest installed. The manifest is the only reliable membership
-- check, so it's fetched live (like doFullUpdate/doFullReinstall) rather
-- than trusting scanInstalled() alone, to avoid deleting plugins Plugin
-- Manager never put there.
function PluginManager:_doRemoveAll()
    local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local manifest = self:_fetchManifest()
        if not manifest then return end

        local managed_ids = {}
        for _, p in ipairs(manifest.plugins) do managed_ids[p.id] = true end

        local installed = self:scanInstalled()
        local to_remove = {}
        for id, inst in pairs(installed) do
            if id ~= "pluginmanager" and managed_ids[id] then
                to_remove[#to_remove + 1] = inst
            end
        end
        table.sort(to_remove, function(a, b) return a.fullname < b.fullname end)

        if #to_remove == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("No plugins to remove."),
                timeout = 3,
            })
            return
        end

        local total = #to_remove
        local function step(i)
            if i > total then
                UIManager:show(InfoMessage:new{
                    text    = string.format(_("%d plugin(s) removed."), total),
                    timeout = 5,
                })
                return
            end
            local inst = to_remove[i]
            rm_rf(_plugins_dir .. "/" .. inst.dir)
            UIManager:scheduleIn(0, function() step(i + 1) end)
        end
        step(1)
    end)
end

function PluginManager:_doFullReinstall()
    local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local manifest = self:_fetchManifest()
        if not manifest then return end

        local installed  = self:scanInstalled()
        local to_process = {}
        for _, p in ipairs(manifest.plugins) do
            if installed[p.id] then
                to_process[#to_process + 1] = p
            end
        end

        self:_runBulkInstall(manifest, to_process, {
            nothing_to_do_text = _("No plugins installed."),
            done_text          = _("%d plugin(s) reinstalled."),
            progress_text      = _("Reinstalling %d plugin(s)\u{2026}"),
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Patches  (koreader/patches -- numbered *.lua files applied at startup;
-- see frontend/userpatch.lua in the main koreader checkout)
-- ---------------------------------------------------------------------------

-- A patch file KOReader's own loader will actually pick up: leading digit(s)
-- (the priority prefix, see userpatch.lua), a dash, then anything ending in
-- ".lua". Renaming to "<name>.disabled" is the same trick appstore.koplugin
-- uses to disable a single patch -- userpatch's own glob still matches the
-- prefix, but its final "%.lua$" check then skips it, so KOReader stops
-- loading it without the file having to be deleted.
local function is_patch_filename(name)
    return name:match("^%d+%-.+%.lua$") ~= nil
end

-- Mirrors looks_like_koreader_plugin's noise filter above, but for patch
-- repositories: the koreader-user-patch topic is just as self-tagged and
-- under-used, so the name-based fallback query below needs its own filter.
local function looks_like_koreader_patch_repo(repo)
    local name = json_str(repo.name):lower()
    local desc = json_str(repo.description):lower()
    return name:match("patches$") ~= nil
        or name:find("koreader", 1, true) ~= nil
        or (desc:find("koreader", 1, true) ~= nil and desc:find("patch", 1, true) ~= nil)
end

-- Searches GitHub for repositories carrying the koreader-user-patch topic
-- (the convention appstore.koplugin uses) merged with a name/description
-- fallback search -- same two-query strategy as searchGithubPlugins above,
-- for the same reason: plenty of real patch repos never set the topic.
function PluginManager:searchGithubPatchRepos(opts)
    opts = opts or {}
    local text = opts.text
    local sort = opts.sort or "stars"
    local page = opts.page or 1

    local topic_q = "topic:koreader-user-patch"
    if text and text ~= "" then topic_q = topic_q .. " " .. text .. " in:name,description" end

    local name_q = "koreader patches in:name,description"
    if text and text ~= "" then name_q = text .. " " .. name_q end

    local by_topic, topic_err = github_api_get("/search/repositories", build_search_query(topic_q, sort, page))
    local by_name,  name_err  = github_api_get("/search/repositories", build_search_query(name_q, sort, page))
    if not by_topic and not by_name then
        return nil, topic_err or name_err
    end

    local seen, items = {}, {}
    local function add_all(data)
        if not data then return end
        for _, repo in ipairs(data.items or {}) do
            local looks_like_fork_spam = repo.fork and json_num(repo.stargazers_count) == 0
            if not looks_like_fork_spam and not seen[repo.full_name] and looks_like_koreader_patch_repo(repo) then
                seen[repo.full_name] = true
                items[#items + 1] = repo_to_item(repo)
            end
        end
    end
    add_all(by_topic)
    add_all(by_name)

    if sort == "updated" then
        table.sort(items, function(a, b) return (a.updated_at or "") > (b.updated_at or "") end)
    else
        table.sort(items, function(a, b) return a.stars > b.stars end)
    end

    local total_count = json_num(by_topic and by_topic.total_count) + json_num(by_name and by_name.total_count)
    local has_more     = (by_topic and #(by_topic.items or {}) == 30) or (by_name and #(by_name.items or {}) == 30)
    return items, nil, total_count, has_more
end

-- Lists every patch file in `repo`: root-level files matching
-- is_patch_filename, plus (if present) the same under a top-level
-- "patches/" subfolder -- both conventions are common in the wild (checked
-- against real repos: sebdelsol/KOReader.patches keeps them at the root,
-- gennaro-tedesco/KOReader.patches nests them under patches/).
function PluginManager:listRepoPatchFiles(repo)
    local root, root_err = github_api_get(string.format("/repos/%s/%s/contents", url_encode(repo.owner), url_encode(repo.name)))
    if not root then return nil, root_err end

    local items, has_patches_dir = {}, false
    for _, entry in ipairs(root) do
        if entry.type == "file" and is_patch_filename(json_str(entry.name)) then
            items[#items + 1] = { name = entry.name, path = entry.path, sha = entry.sha, download_url = entry.download_url, repo = repo }
        elseif entry.type == "dir" and json_str(entry.name):lower() == "patches" then
            has_patches_dir = true
        end
    end
    if has_patches_dir then
        local sub = github_api_get(string.format("/repos/%s/%s/contents/patches", url_encode(repo.owner), url_encode(repo.name)))
        for _, entry in ipairs(sub or {}) do
            if entry.type == "file" and is_patch_filename(json_str(entry.name)) then
                items[#items + 1] = { name = entry.name, path = entry.path, sha = entry.sha, download_url = entry.download_url, repo = repo }
            end
        end
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

-- ---------------------------------------------------------------------------
-- Patches: installed-patch tracking (settings)
-- ---------------------------------------------------------------------------

-- Same idea as getDiscoverInstall/recordDiscoverInstall above, but keyed by
-- patch filename (a patch has no id of its own) and also remembering the
-- path within the repo (root or patches/) and the blob sha last installed,
-- so a later "Check for update" has something to diff against -- patches
-- carry no _meta.lua/version field to compare instead.
function PluginManager:getPatchInstall(name)
    self:ensureSettings()
    local all = self.settings:readSetting("patch_installs") or {}
    return all[name]
end

function PluginManager:recordPatchInstall(name, repo, path, sha)
    self:ensureSettings()
    local all = self.settings:readSetting("patch_installs") or {}
    all[name] = { owner = repo.owner, name = repo.name, full_name = repo.full_name, path = path, sha = sha }
    self.settings:saveSetting("patch_installs", all)
    self.settings:flush()
end

function PluginManager:forgetPatchInstall(name)
    self:ensureSettings()
    local all = self.settings:readSetting("patch_installs") or {}
    if all[name] == nil then return end
    all[name] = nil
    self.settings:saveSetting("patch_installs", all)
    self.settings:flush()
end

-- Builds an installable item out of a previously-recorded link, for
-- Reinstall/Update actions that don't already have a fresh listing result
-- (from listRepoPatchFiles) to hand.
local function patch_item_from_link(name, link)
    return {
        name         = name,
        path         = link.path,
        sha          = link.sha,
        repo         = { owner = link.owner, name = link.name, full_name = link.full_name },
        download_url = github_raw_base_url(link.owner, link.name) .. link.path,
    }
end

-- ---------------------------------------------------------------------------
-- Patches: installed scan / install / enable-disable
-- ---------------------------------------------------------------------------

function PluginManager:scanInstalledPatches()
    local lfs = get_lfs()
    if not lfs then return {} end
    local installed = {}
    pcall(function()
        for entry in lfs.dir(_patches_dir) do
            if entry ~= "." and entry ~= ".." and lfs.attributes(_patches_dir .. "/" .. entry, "mode") == "file" then
                local disabled = entry:match("%.disabled$") ~= nil
                local base     = disabled and entry:sub(1, -(#".disabled" + 1)) or entry
                if is_patch_filename(base) then
                    installed[base] = { name = base, file = entry, disabled = disabled }
                end
            end
        end
    end)
    return installed
end

function PluginManager:installPatchFile(item)
    mkdir_p(_patches_dir)
    local body, err = fetch_url(item.download_url)
    if not body then
        return false, string.format(_("Download failed: %s \u{2014} %s"), item.name, err)
    end
    local dest, disabled_dest = _patches_dir .. "/" .. item.name, _patches_dir .. "/" .. item.name .. ".disabled"
    local lfs = get_lfs()
    if lfs and lfs.attributes(disabled_dest, "mode") == "file" then
        -- Installing/updating always (re)enables the patch, matching what
        -- Update does for plugins: a stale disabled copy under the same
        -- name would otherwise sit alongside the freshly-installed one.
        os.remove(disabled_dest)
    end
    local ok, werr = write_file(dest, body)
    if not ok then
        return false, string.format(_("Write failed: %s \u{2014} %s"), item.name, werr)
    end
    self:recordPatchInstall(item.name, item.repo, item.path, item.sha)
    return true
end

function PluginManager:_doInstallPatch(item)
    local msg = InfoMessage:new{ text = string.format(_("Installing %s\u{2026}"), item.name) }
    UIManager:show(msg)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(msg)
        local ok, err = safe_call(function() return self:installPatchFile(item) end)
        if ok then
            UIManager:show(InfoMessage:new{
                text    = string.format(_("%s installed.\nRestart KOReader to apply."), item.name),
                timeout = 6,
            })
        else
            logger.warn("PluginManager: patch install failed for", item.name, ":", err)
            UIManager:show(InfoMessage:new{
                text    = _("Install failed:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
        end
    end)
end

function PluginManager:setPatchDisabled(name, disabled)
    local plain, off = _patches_dir .. "/" .. name, _patches_dir .. "/" .. name .. ".disabled"
    local lfs = get_lfs()
    if not lfs then return end
    if disabled and lfs.attributes(plain, "mode") == "file" then
        os.rename(plain, off)
    elseif not disabled and lfs.attributes(off, "mode") == "file" then
        os.rename(off, plain)
    end
end

function PluginManager:installAllPatches(items)
    local total, failed = #items, {}
    local function step(i)
        if i > total then
            local parts = {}
            if #failed > 0 then
                parts[#parts + 1] = string.format(_("%d/%d installed. Failures:"), total - #failed, total)
                for _, f in ipairs(failed) do parts[#parts + 1] = f end
            else
                parts[#parts + 1] = string.format(_("%d patch(es) installed.\nRestart KOReader to apply."), total)
            end
            UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 8 })
            return
        end
        local item = items[i]
        local ok, err = safe_call(function() return self:installPatchFile(item) end)
        if not ok then failed[#failed + 1] = item.name .. ": " .. (err or "?") end
        UIManager:scheduleIn(0, function() step(i + 1) end)
    end
    step(1)
end

function PluginManager:confirmInstallAllPatches(items)
    UIManager:show(ConfirmBox:new{
        text        = string.format(_("Install all %d patches shown?"), #items),
        ok_text     = _("Install all"),
        ok_callback = function() self:installAllPatches(items) end,
    })
end

-- ---------------------------------------------------------------------------
-- Patches: update check
-- ---------------------------------------------------------------------------

-- Patches carry no _meta.lua/version field, so "is there an update" is a
-- blob-sha comparison against what was recorded at install time -- the same
-- approach appstore.koplugin uses for patches.
function PluginManager:checkPatchUpdate(name, link)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    local function run()
        local notice = InfoMessage:new{ text = _("Checking for updates\u{2026}") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(notice)
            local data, err = github_api_get(string.format("/repos/%s/%s/contents/%s", url_encode(link.owner), url_encode(link.name), link.path))
            if not data or not data.sha then
                UIManager:show(InfoMessage:new{
                    text    = _("Update check failed:") .. "\n" .. (err or "?"),
                    timeout = 5,
                })
                return
            end
            if data.sha == link.sha then
                UIManager:show(InfoMessage:new{ text = _("Already up to date."), timeout = 3 })
                return
            end
            local item = patch_item_from_link(name, link)
            item.sha, item.download_url = data.sha, data.download_url or item.download_url
            local dlg
            dlg = ButtonDialog:new{
                title   = string.format(_("%s: update available"), name),
                buttons = {
                    {{
                        text     = _("Update"),
                        callback = function()
                            UIManager:close(dlg)
                            self:_doInstallPatch(item)
                        end,
                    }},
                    {{
                        text     = _("Cancel"),
                        callback = function() UIManager:close(dlg) end,
                    }},
                },
            }
            UIManager:show(dlg)
        end)
    end
    if ok and NetworkMgr then NetworkMgr:runWhenOnline(run) else run() end
end

-- ---------------------------------------------------------------------------
-- Patches: Discover UI
-- ---------------------------------------------------------------------------

function PluginManager:getDiscoverPatchesSort()
    self:ensureSettings()
    return self.settings:readSetting("discover_patches_sort_mode") or "stars"
end

function PluginManager:cycleDiscoverPatchesSort()
    local next_mode = self:getDiscoverPatchesSort() == "stars" and "updated" or "stars"
    self:ensureSettings()
    self.settings:saveSetting("discover_patches_sort_mode", next_mode)
    self.settings:flush()
    return next_mode
end

function PluginManager:showDiscoverPatchesFilterDialog()
    local input
    input = InputDialog:new{
        title      = _("Search GitHub patches"),
        input      = self._discover_patches_filter or "",
        input_hint = _("Search text (optional)\u{2026}"),
        buttons    = {{
            {
                text     = _("Clear"),
                callback = function()
                    UIManager:close(input)
                    self._discover_patches_filter = nil
                    self:showDiscoverPatchesDialog()
                end,
            },
            {
                text     = _("Cancel"),
                callback = function()
                    UIManager:close(input)
                    self:showDiscoverPatchesDialog()
                end,
            },
            {
                text             = _("Search"),
                is_enter_default = true,
                callback         = function()
                    local text = input:getInputText():match("^%s*(.-)%s*$")
                    UIManager:close(input)
                    self._discover_patches_filter = text ~= "" and text or nil
                    self:showDiscoverPatchesDialog()
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function PluginManager:showDiscoveredPatchDialog(item)
    local dlg
    local title = item.name
    if item._installed then
        title = title .. "\n" .. (item._installed.disabled and _("Already installed [DISABLED]") or _("Already installed"))
    end
    dlg = ButtonDialog:new{
        title   = title,
        buttons = {
            {{
                text     = _("Install"),
                callback = function()
                    UIManager:close(dlg)
                    self:_doInstallPatch(item)
                end,
            }},
            {{
                text     = _("README\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showReadme(
                        github_raw_base_url(item.repo.owner, item.repo.name) .. "README.md",
                        string.format(_("README: %s"), item.repo.full_name),
                        item.repo.owner .. "_" .. item.repo.name
                    )
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

function PluginManager:showPatchRepoDialog(repo)
    local notice = InfoMessage:new{ text = _("Loading patches\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local items, err = safe_call(function() return self:listRepoPatchFiles(repo) end)
        if not items then
            UIManager:show(InfoMessage:new{
                text    = _("Could not list patches:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
            return
        end
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text    = string.format(_("No patch files found in %s."), repo.full_name),
                timeout = 4,
            })
            return
        end

        local Menu      = require("ui/widget/menu")
        local Screen    = require("device").screen
        local installed = self:scanInstalledPatches()

        local menu_items = {}
        if #items >= 2 then
            menu_items[#menu_items + 1] = {
                text     = string.format(_("Install all %d patches\u{2026}"), #items),
                bold     = true,
                callback = function() self:confirmInstallAllPatches(items) end,
            }
        end
        for _i, it in ipairs(items) do
            it._installed = installed[it.name]
            local pref = it
            local status
            if it._installed then
                status = it._installed.disabled and _("Installed [DISABLED]") or _("Installed")
                local link = self:getPatchInstall(it.name)
                if link and link.sha and link.sha ~= it.sha then
                    status = status .. " " .. _("(update)")
                end
            end
            menu_items[#menu_items + 1] = {
                text      = it.name,
                mandatory = status,
                bold      = status ~= nil,
                callback  = function() self:showDiscoveredPatchDialog(pref) end,
            }
        end

        local menu_instance
        menu_instance = Menu:new{
            title      = repo.full_name,
            subtitle   = json_str(repo.description) ~= "" and repo.description or nil,
            item_table = menu_items,
            width      = Screen:getWidth(),
            height     = Screen:getHeight(),
        }
        function menu_instance:onMenuChoice(item)
            UIManager:close(self)
            if item.callback then item.callback() end
        end
        UIManager:show(menu_instance)
    end)
end

function PluginManager:showDiscoverPatchesDialog()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        NetworkMgr:runWhenOnline(function() self:_showDiscoverPatchesDialog(1, {}) end)
    else
        self:_showDiscoverPatchesDialog(1, {})
    end
end

function PluginManager:_showDiscoverPatchesDialog(page, accumulated)
    local notice = InfoMessage:new{ text = _("Searching GitHub\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local results, err, total_count, has_more = self:searchGithubPatchRepos{
            text = self._discover_patches_filter,
            sort = self:getDiscoverPatchesSort(),
            page = page,
        }
        if not results then
            UIManager:show(InfoMessage:new{
                text    = _("Search failed:") .. "\n" .. (err or "?"),
                timeout = 5,
            })
            return
        end
        for _, r in ipairs(results) do accumulated[#accumulated + 1] = r end

        if #accumulated == 0 then
            if self._discover_patches_filter then
                UIManager:show(ConfirmBox:new{
                    text        = string.format(
                        _("No results for \u{201c}%s\u{201d} (%d repositories are candidates in total, before that filter).\nClear the filter and search again?"),
                        self._discover_patches_filter, total_count or 0
                    ),
                    ok_text     = _("Clear filter"),
                    ok_callback = function()
                        self._discover_patches_filter = nil
                        self:showDiscoverPatchesDialog()
                    end,
                    cancel_text = _("Close"),
                })
            else
                UIManager:show(InfoMessage:new{ text = _("No results."), timeout = 3 })
            end
            return
        end

        local Menu   = require("ui/widget/menu")
        local Screen = require("device").screen

        local items = {}
        for _i, repo in ipairs(accumulated) do
            local pref = repo
            items[#items + 1] = {
                text      = repo.full_name,
                mandatory = string.format("\u{2605}%d", repo.stars),
                callback  = function() self:showPatchRepoDialog(pref) end,
            }
        end
        if has_more then
            items[#items + 1] = {
                text     = _("Load more\u{2026}"),
                callback = function() self:_showDiscoverPatchesDialog(page + 1, accumulated) end,
            }
        end

        local menu_instance
        menu_instance = Menu:new{
            title               = _("Discover patches"),
            subtitle            = self._discover_patches_filter and string.format(_("Search: %s"), self._discover_patches_filter) or nil,
            item_table          = items,
            width               = Screen:getWidth(),
            height              = Screen:getHeight(),
            title_bar_left_icon = "appbar.search",
            onLeftButtonTap     = function()
                UIManager:close(menu_instance)
                self:showDiscoverPatchesFilterDialog()
            end,
            onLeftButtonHold    = function()
                local mode = self:cycleDiscoverPatchesSort()
                UIManager:close(menu_instance)
                UIManager:show(InfoMessage:new{
                    text    = mode == "updated" and _("Sorted by last updated.") or _("Sorted by stars."),
                    timeout = 2,
                })
                self:showDiscoverPatchesDialog()
            end,
        }
        function menu_instance:onMenuChoice(item)
            UIManager:close(self)
            if item.callback then item.callback() end
        end
        UIManager:show(menu_instance)
    end)
end

-- ---------------------------------------------------------------------------
-- Patches: installed list + per-patch dialog
-- ---------------------------------------------------------------------------

function PluginManager:showInstalledPatchDialog(iref)
    local link = self:getPatchInstall(iref.name)
    local dlg
    local buttons = {}

    if link then
        buttons[#buttons + 1] = {{
            text     = _("Check for update"),
            callback = function()
                UIManager:close(dlg)
                self:checkPatchUpdate(iref.name, link)
            end,
        }}
        buttons[#buttons + 1] = {{
            text     = _("Reinstall"),
            callback = function()
                UIManager:close(dlg)
                self:_doInstallPatch(patch_item_from_link(iref.name, link))
            end,
        }}
        buttons[#buttons + 1] = {{
            text     = _("README\u{2026}"),
            callback = function()
                UIManager:close(dlg)
                self:showReadme(
                    github_raw_base_url(link.owner, link.name) .. "README.md",
                    string.format(_("README: %s"), link.full_name),
                    link.owner .. "_" .. link.name
                )
            end,
        }}
        buttons[#buttons + 1] = {{
            text     = _("Unlink"),
            callback = function()
                UIManager:close(dlg)
                self:forgetPatchInstall(iref.name)
                self:showInstalledPatchDialog(iref)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text     = iref.disabled and _("Enable") or _("Disable"),
        callback = function()
            UIManager:close(dlg)
            self:setPatchDisabled(iref.name, not iref.disabled)
            UIManager:show(InfoMessage:new{
                text    = iref.disabled
                    and string.format(_("%s enabled.\nRestart KOReader to apply."), iref.name)
                    or  string.format(_("%s disabled.\nRestart KOReader to apply."), iref.name),
                timeout = 5,
            })
        end,
    }}

    buttons[#buttons + 1] = {{
        text     = _("Remove"),
        callback = function()
            UIManager:close(dlg)
            UIManager:show(ConfirmBox:new{
                text        = string.format(_("Remove %s?"), iref.name),
                ok_text     = _("Remove"),
                ok_callback = function()
                    os.remove(_patches_dir .. "/" .. iref.file)
                    self:forgetPatchInstall(iref.name)
                    UIManager:show(InfoMessage:new{
                        text    = string.format(_("%s removed."), iref.name),
                        timeout = 5,
                    })
                end,
            })
        end,
    }}

    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(dlg) end,
    }}

    local title = iref.name
    if iref.disabled then title = title .. "  " .. _("[DISABLED]") end
    if link then title = title .. "\n" .. link.full_name end
    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

function PluginManager:showInstalledPatchesList()
    local Menu      = require("ui/widget/menu")
    local Screen    = require("device").screen
    local installed = self:scanInstalledPatches()

    local items = {}
    for _name, inst in pairs(installed) do
        local iref = inst
        local tag  = self:getPatchInstall(iref.name) and _("(GitHub)") or _("(local)")
        items[#items + 1] = {
            text      = (iref.disabled and (_("[DISABLED]") .. " ") or "") .. iref.name,
            mandatory = tag,
            callback  = function() self:showInstalledPatchDialog(iref) end,
        }
    end

    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No patches installed."), timeout = 3 })
        return
    end

    table.sort(items, function(a, b) return a.text < b.text end)

    local menu_instance
    menu_instance = Menu:new{
        title      = _("Installed patches"),
        item_table = items,
        width      = Screen:getWidth(),
        height     = Screen:getHeight(),
    }
    function menu_instance:onMenuChoice(item)
        UIManager:close(self)
        if item.callback then item.callback() end
    end
    UIManager:show(menu_instance)
end

-- ---------------------------------------------------------------------------
-- Patches: main dialog
-- ---------------------------------------------------------------------------

function PluginManager:showPatchesMainDialog()
    local dlg
    local ok_up, userpatch = pcall(require, "userpatch")
    local all_disabled = ok_up and userpatch.arePatchesDisabled and userpatch.arePatchesDisabled()
    local title = _("Patches")
    if ok_up then
        title = title .. "\n" .. (all_disabled and _("All patches: OFF") or _("All patches: ON"))
    end

    local buttons = {}
    buttons[#buttons + 1] = {{
        text     = _("Installed patches"),
        callback = function()
            UIManager:close(dlg)
            self:showInstalledPatchesList()
        end,
    }}
    buttons[#buttons + 1] = {{
        text     = _("Discover patches\u{2026}"),
        callback = function()
            UIManager:close(dlg)
            self:showDiscoverPatchesDialog()
        end,
    }}
    if ok_up and userpatch.togglePatchesDisabled then
        buttons[#buttons + 1] = {{
            text     = all_disabled and _("Enable all patches") or _("Disable all patches"),
            callback = function()
                UIManager:close(dlg)
                userpatch.togglePatchesDisabled()
                UIManager:show(InfoMessage:new{
                    text    = all_disabled
                        and _("All patches enabled.\nRestart KOReader to apply.")
                        or  _("All patches disabled.\nRestart KOReader to apply."),
                    timeout = 5,
                })
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text     = _("Close"),
        callback = function() UIManager:close(dlg) end,
    }}

    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Main dialog
-- ---------------------------------------------------------------------------

-- ✓/✗ Wi-Fi radio state, refreshed every time the main dialog is (re)opened.
-- isWifiOn() (as opposed to isConnected()) reflects the radio switch itself,
-- which is what a user checking "is Wi-Fi on" actually wants to know. On
-- devices without a Wi-Fi toggle it always returns true, so the line always
-- reads "on" there -- harmless, since network is effectively always available.
function PluginManager:wifiStatusLine()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isWifiOn then return nil end
    if NetworkMgr:isWifiOn() then
        return _("\u{2713} Wi-Fi on")
    end
    return _("\u{2717} Wi-Fi off")
end

function PluginManager:showMainDialog()
    local dlg
    local title = _("Plugin Manager")
    local wifi_status = self:wifiStatusLine()
    if wifi_status then title = title .. "\n" .. wifi_status end
    dlg = ButtonDialog:new{
        title   = title,
        buttons = {
            {{
                text     = _("Update"),
                callback = function()
                    UIManager:close(dlg)
                    self:doFullUpdate()
                end,
            }},
            {{
                text     = _("Reinstall all\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    UIManager:show(ConfirmBox:new{
                        text        = _("Reinstall every installed plugin?\nThis re-downloads all their files, including shared libraries."),
                        ok_text     = _("Reinstall all"),
                        ok_callback = function() self:doFullReinstall() end,
                    })
                end,
            }},
            {{
                text     = _("Remove all\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    UIManager:show(ConfirmBox:new{
                        text        = _("Remove every plugin managed by Plugin Manager?\nAll their files will be deleted. Plugin Manager itself and any other plugin on your device (including KOReader's own) are left untouched."),
                        ok_text     = _("Remove all"),
                        ok_callback = function() self:doRemoveAll() end,
                    })
                end,
            }},
            {{
                text     = _("Plugin list"),
                callback = function()
                    UIManager:close(dlg)
                    self:showPluginList()
                end,
            }},
            {{
                text     = _("Discover plugins\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showDiscoverDialog()
                end,
            }},
            {{
                text     = _("Patches\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showPatchesMainDialog()
                end,
            }},
            {{
                text     = _("Ignored updates\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showIgnoredDialog()
                end,
            }},
            {{
                text     = _("Close"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- KOReader plugin lifecycle
-- ---------------------------------------------------------------------------

function PluginManager:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadCachedManifest()

    -- Automatic background check: only if a previous fetch exists and the
    -- cached data is stale, and only when already connected (no user prompt).
    if self._last_check then
        local age = os.time() - self._last_check
        if age > AUTO_CHECK_TTL then
            UIManager:scheduleIn(30, function() self:_silentCheck() end)
        end
    end
end

function PluginManager:addToMainMenu(menu_items)
    menu_items.pluginmanager = {
        text         = _("Plugin Manager"),
        sorting_hint = "tools",
        callback     = function() self:showMainDialog() end,
    }
end

return PluginManager
