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
local _               = lrequire("i18n")

-- lrequire, not require: package.loaded["i18n"] is a single slot shared by
-- every plugin on the device and the first one loaded wins it. This plugin
-- is standalone (no common/), so it must not take that slot from the game
-- plugins, nor merge its own strings into their shared table.
lrequire("i18n").extend(lrequire("i18n_fr"))

-- Pure decision logic (no KOReader dependency), specced in test_pmlogic_spec.lua.
local PMLogic = lrequire("pmlogic")

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
    -- settings_file must be a field, not a local. KOReader's PluginLoader
    -- reads instance.settings_file to decide whether to offer "Delete plugin
    -- settings", and removes the file itself (2026.07, PR #15240). Compute
    -- the path inline and the option never appears at all, leaving the file
    -- behind when the plugin is deleted.
    if not self.settings_file then
        self.settings_file = DataStorage:getSettingsDir() .. "/pluginmanager.lua"
    end
    if not self.settings then
        self.settings = LuaSettings:open(self.settings_file)
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
-- Restart prompt
-- ---------------------------------------------------------------------------

-- KOReader loads plugin and patch Lua once, at startup, so every change this
-- plugin makes waits for a restart. Rather than only saying so, offer it:
-- UIManager:askForRestart shows KOReader's own "Restart now / Restart later"
-- box where the device can restart itself, and a plain notice where it
-- cannot. It needs the Restart handler the device layer installs; without
-- it (an older KOReader, or a test harness) the text is shown as a plain
-- notice. Both land on the next tick, so the box comes out on top of a
-- screen rebuilt in the same callback (showScreenMenu's `reopen`).
function PluginManager:askRestart(text)
    if UIManager.askForRestart and UIManager.event_handlers
       and UIManager.event_handlers.Restart and UIManager.event_handlers.PowerOff then
        UIManager:askForRestart(text)
        return
    end
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{ text = text, timeout = 8 })
    end)
end

-- ---------------------------------------------------------------------------
-- KOReader version (manifest `min_koreader`)
-- ---------------------------------------------------------------------------

-- Normalised the way frontend/version.lua does it; nil when KOReader cannot
-- say (no version module, or a dev build), which PMLogic treats as
-- "compatible" -- the field warns, it never locks anyone out.
local function koreader_version()
    local ok, Version = pcall(require, "version")
    if not ok or type(Version) ~= "table" or not Version.getNormalizedCurrentVersion then return nil end
    local ok2, v = pcall(Version.getNormalizedCurrentVersion, Version)
    return ok2 and v or nil
end

local function koreader_short_version()
    local ok, Version = pcall(require, "version")
    if ok and type(Version) == "table" and Version.getShortVersion then
        local ok2, v = pcall(Version.getShortVersion, Version)
        if ok2 and v then return v end
    end
    return "?"
end

function PluginManager:isCompatible(plugin_info)
    local min = plugin_info and plugin_info.min_koreader
    return PMLogic.koreaderCompatible(type(min) == "string" and min or nil, koreader_version())
end

-- Runs `proceed` straight away for a compatible plugin; otherwise says what
-- it needs and lets the user install anyway (a plugin may well degrade
-- gracefully -- only its author's declared minimum is known here).
function PluginManager:confirmCompatible(plugin_info, proceed)
    if self:isCompatible(plugin_info) then return proceed() end
    UIManager:show(ConfirmBox:new{
        text        = string.format(
            _("%s v%s needs KOReader %s or newer (this is %s).\nIt may not work. Install anyway?"),
            plugin_info.fullname, plugin_info.version, plugin_info.min_koreader, koreader_short_version()
        ),
        ok_text     = _("Install anyway"),
        ok_callback = proceed,
    })
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

-- Explicit timeouts, so a dead connection (Wi-Fi gone, the reader's radio
-- asleep, a stalled CDN edge) fails in seconds instead of hanging the run:
-- LuaSocket's own default is 60 s per blocking operation with no overall
-- limit, and a bulk run makes over a hundred requests. KOReader's socketutil
-- is the supported way (it patches socket.tcp, which LuaSec uses too, and
-- provides sinks that enforce the total once data flows); where it cannot
-- be loaded (headless specs) requests simply run with the library defaults.
local TIMEOUT_CONNECT    = 15   -- seconds without progress on the socket
local TIMEOUT_FILE_TOTAL = 20   -- one small file
local TIMEOUT_ZIP_TOTAL  = 60   -- one plugin zip (a few hundred KB) ...
local ZIP_MIN_RATE       = 32 * 1024  -- ... plus 1 s per 32 KB (fifteen's is 2 MB)
local TIMEOUT_LARGE      = 60   -- manifest.json

local function get_socketutil()
    local ok, su = pcall(require, "socketutil")
    if ok and type(su) == "table" and su.set_timeout and su.reset_timeout then return su end
    return nil
end

-- Runs https.request(req) with the given timeouts (total < 0: none) and
-- always restores KOReader's defaults afterwards, even if the request
-- raises. `make_sink(su)` builds the sink, so it can be socketutil's
-- timeout-aware one. Returns https.request's own (result, status, headers).
local function timed_request(https, req, total, make_sink)
    local su = get_socketutil()
    if su then su:set_timeout(TIMEOUT_CONNECT, total) end
    req.sink = make_sink(su)
    local ok, result, status, headers = pcall(https.request, req)
    if su then su:reset_timeout() end
    if not ok then return nil, tostring(result) end
    return result, status, headers
end

-- `total_timeout` (seconds) defaults to one small file's.
local function fetch_url(url, total_timeout)
    local ok1, https = pcall(require, "ssl.https")
    if not ok1 then return nil, _("ssl.https not available") end
    local ok2, ltn12 = pcall(require, "ltn12")
    if not ok2 then return nil, _("ltn12 not available") end

    local delay = FETCH_RETRY_DELAY
    for attempt = 1, FETCH_MAX_RETRIES do
        sleep(FETCH_PACE_DELAY)
        local chunks = {}
        local result, status, headers = timed_request(https, {
            url      = url,
            verify   = "none",
            protocol = "tlsv1_2",
        }, total_timeout or TIMEOUT_FILE_TOTAL, function(su)
            return su and su.table_sink and su.table_sink(chunks) or ltn12.sink.table(chunks)
        end)
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
-- hardware. The file sink closes the handle itself once done, on both
-- success and failure. `total_timeout` nil: no overall limit (a Discover
-- zipball can be large), only the per-operation one.
local function fetch_to_file(url, path, extra_headers, total_timeout)
    local ok1, https = pcall(require, "ssl.https")
    if not ok1 then return false, _("ssl.https not available") end
    local ok2, ltn12 = pcall(require, "ltn12")
    if not ok2 then return false, _("ltn12 not available") end
    local file, ferr = io.open(path, "wb")
    if not file then return false, ferr end

    local headers = { ["User-Agent"] = "pluginmanager.koplugin" }
    for k, v in pairs(extra_headers or {}) do headers[k] = v end

    local result, status = timed_request(https, {
        url      = url,
        headers  = headers,
        verify   = "none",
        protocol = "tlsv1_2",
    }, total_timeout or -1, function(su)
        return su and su.file_sink and su.file_sink(file) or ltn12.sink.file(file)
    end)
    if result and status == 200 then return true end
    pcall(file.close, file)  -- already closed by the sink in most cases
    os.remove(path)
    return false, string.format(_("HTTP %s"), tostring(status or "?")), status
end

-- ---------------------------------------------------------------------------
-- GitHub API (repository discovery)
-- ---------------------------------------------------------------------------

-- Optional local config file (never committed -- see .gitignore) letting a
-- user supply a classic GitHub PAT to raise the search API's very low
-- unauthenticated rate limit (10 requests/minute). Mirrors the same pattern
-- appstore.koplugin uses, so anyone already familiar with that plugin's
-- config file recognises this one.
-- Files a user puts in a plugin's folder by hand. Installs never delete them
-- as stale (see installPlugin).
local USER_FILES = {
    ["pluginmanager_configuration.lua"] = true,
}

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

-- Every public repo `owner` owns whose raw API entry passes keep(repo), as
-- Discover items. Shared by the plugin and patch `user:NAME` modes: the
-- listing is the general API (60 requests/hour unauthenticated), one
-- request per 100 repos, never one per repo.
local function list_owner_repos(owner, keep)
    local items, seen_any = {}, false
    for page = 1, 5 do
        local query = string.format("type=owner&per_page=100&page=%d", page)
        local data, err = github_api_get("/users/" .. url_encode(owner) .. "/repos", query)
        if not data then
            if not seen_any then return nil, err end
            break
        end
        if type(data) ~= "table" or #data == 0 then break end
        seen_any = true
        for _i, repo in ipairs(data) do
            if keep(repo) then items[#items + 1] = repo_to_item(repo, owner) end
        end
        if #data < 100 then break end
    end
    return items
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
    return list_owner_repos(owner, function(repo)
        return json_str(repo.name):match("%.koplugin$") ~= nil
    end)
end

-- Same, for "Discover patches…": the account's repositories that look like
-- patch collections (PMLogic.isOwnerPatchRepo). Their files are listed when
-- one is opened, exactly as for a search result.
function PluginManager:listGithubOwnerPatchRepos(owner)
    return list_owner_repos(owner, PMLogic.isOwnerPatchRepo)
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

-- True when `b` is newer than `a`. Lives in pmlogic.lua so the update count,
-- the changelog slicing and the integrity drift rule all compare versions
-- the same way.
local is_newer = PMLogic.isNewer

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

local PathGuard = lrequire("pathguard")

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
        os.execute("mkdir -p " .. PathGuard.shellQuote(path))
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

-- Deletes a path, but only one that sits strictly inside the plugins
-- directory. The previous guard was `path:find(_plugins_dir, 1, true)`, a
-- SUBSTRING test: it also let through any sibling whose name merely began
-- with the plugins directory -- "plugins-backup", "plugins_old" -- and said
-- nothing about "..", although the paths it protects are built from
-- manifest.json's `dir` field, which arrives over the network. See
-- pathguard.lua and its spec.
local function rm_rf(path)
    if not PathGuard.isWithin(_plugins_dir, path) then return end
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
        -- Quoted: an unquoted path with a space in it would hand `rm -rf`
        -- two targets instead of one.
        os.execute("rm -rf " .. PathGuard.shellQuote(path))
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

-- The one definition of "an update is available", shared by the home
-- screen's count, the silent check and the Update button so the three never
-- disagree: an installed plugin whose manifest version is newer, not
-- ignored, and runnable on this KOReader. The second list holds the updates
-- held back by min_koreader. No network: `manifest` is whatever is cached.
function PluginManager:pendingUpdates(manifest, installed)
    if not manifest or type(manifest.plugins) ~= "table" then return {}, {} end
    return PMLogic.pendingUpdates(
        manifest.plugins,
        installed or self:scanInstalled(),
        function(id, version) return self:isVersionIgnored(id, version) end,
        function(p) return self:isCompatible(p) end
    )
end

function PluginManager:_silentCheck()
    -- Only run if already connected; never prompt the user.
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and not NetworkMgr:isConnected() then return end

    local body = fetch_url(MANIFEST_URL, TIMEOUT_LARGE)
    if not body then return end
    local manifest = parse_json(body)
    if not manifest or not manifest.plugins then return end
    self._manifest = manifest
    self:saveManifestCache(manifest)

    local n_update = #self:pendingUpdates(manifest)
    self:refreshHome()
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

-- Two working folders, both inside plugins/: a plugin's next version is
-- assembled in .pluginmanager-staging/<dir> before anything live is touched,
-- and the version an update replaces is kept in .pluginmanager-backup/<dir>
-- for "Restore previous version". Inside plugins/ because that is the same
-- filesystem as the plugins themselves (os.rename moves instead of copying)
-- and because rm_rf's guard already covers it; dot-prefixed and without the
-- .koplugin suffix, so neither KOReader's PluginLoader nor scanInstalled()
-- ever takes them for a plugin. PathGuard.pluginPath validates `dir` -- it
-- comes from manifest.json -- before it becomes a path under either.
local STAGING_DIR = ".pluginmanager-staging"
local BACKUP_DIR  = ".pluginmanager-backup"

local function staging_path(dir) return PathGuard.pluginPath(_plugins_dir .. "/" .. STAGING_DIR, dir) end
local function backup_path(dir)  return PathGuard.pluginPath(_plugins_dir .. "/" .. BACKUP_DIR, dir) end

local function copy_file(src, dst)
    local f = io.open(src, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    return write_file(dst, data)
end

local function copy_tree(src, dst)
    local lfs = get_lfs()
    if not lfs then return false end
    mkdir_p(dst)
    for entry in lfs.dir(src) do
        if entry ~= "." and entry ~= ".." then
            local s, d = src .. "/" .. entry, dst .. "/" .. entry
            local mode = lfs.attributes(s, "mode")
            if mode == "directory" then
                if not copy_tree(s, d) then return false end
            elseif mode == "file" then
                if not copy_file(s, d) then return false end
            end
        end
    end
    return true
end

-- SHA-256 from KOReader's own base library (ffi/sha2, on every device).
-- nil when it cannot be loaded, which switches hash checking off -- never
-- installing.
local _sha256
local function sha256(body)
    if _sha256 == nil then
        local ok, sha2 = pcall(require, "ffi/sha2")
        _sha256 = ok and type(sha2) == "table" and sha2.sha256 or false
    end
    if not _sha256 then return nil end
    local ok, h = pcall(_sha256, body)
    return ok and h or nil
end

-- The manifest's expected hash for `fname`, or nil: a manifest written
-- before the sha256 maps existed simply has none, and installs unverified
-- exactly as it always did.
local function expected_hash(map, fname)
    local h = type(map) == "table" and map[fname]
    return type(h) == "string" and h ~= "" and h or nil
end

-- Downloads one file and checks it. Returns (body, verdict, compiles) --
-- verdict is PMLogic.hashVerdict's "ok" / "unverified" / "mismatch",
-- compiles is false only for a .lua file that does not compile -- or
-- (nil, err) when the download itself failed.
--
-- A file failing either check is fetched once more before anything is
-- concluded: a transfer cut short, or a CDN edge still serving half of a
-- fresh push, usually comes back right the second time.
local function fetch_checked(url, fname, expected)
    local body, verdict, compiles
    for _attempt = 1, 2 do
        local b, err = fetch_url(url)
        if not b then return nil, err end
        body     = b
        verdict  = PMLogic.hashVerdict(expected, expected and sha256(b))
        compiles = not PMLogic.isLuaFile(fname) or PMLogic.compiles(b, fname)
        if verdict ~= "mismatch" and compiles then break end
    end
    return body, verdict, compiles
end

-- ---------------------------------------------------------------------------
-- Cooperative yielding: keeps the UI alive during a bulk run
-- ---------------------------------------------------------------------------

-- A bulk run installs each plugin inside a coroutine of its own (run_async).
-- ui_yield() hands control back to UIManager for one turn of its loop --
-- the progress dialog repaints, a tap on Stop is processed -- and the
-- install resumes on the next tick. Outside that coroutine (a single
-- install, the specs calling installPlugin directly, any coroutine someone
-- else owns) it does nothing, so the install code stays plain sequential
-- code either way.
local _run_co = nil

local function ui_yield()
    if _run_co ~= nil and coroutine.running() == _run_co then
        coroutine.yield()
    end
end

-- Runs fn() in a coroutine, resuming it from UIManager after every
-- ui_yield(), then calls on_done(fn's two results) -- or on_done(false,
-- message) when fn raised, like safe_call.
local function run_async(fn, on_done)
    local co = coroutine.create(fn)
    local function resume()
        local prev = _run_co
        _run_co = co
        local ok, a, b = coroutine.resume(co)
        _run_co = prev
        if not ok then
            logger.warn("PluginManager:", a)
            return on_done(false, tostring(a))
        end
        if coroutine.status(co) == "dead" then return on_done(a, b) end
        UIManager:scheduleIn(0, resume)
    end
    resume()
end

-- ---------------------------------------------------------------------------
-- Keeping the reader awake during a bulk run
-- ---------------------------------------------------------------------------

-- A full run can take many minutes on a slow reader, with no input from the
-- user. KOReader's autosuspend plugin suspends a Kobo after 15 minutes of
-- that by default, Wi-Fi drops with it, and the run dies mid-way. Two
-- supported switches hold it off, both what KOReader's own background jobs
-- use: PluginShare.pause_auto_suspend (read by autosuspend each time its
-- timer fires; keepalive.koplugin uses the same flag) and
-- UIManager:preventStandby() (paired allowStandby(), counted). Nested runs
-- (Import = bulk install + GitHub installs) share one hold through a count.
-- Each piece is a no-op where it does not exist (emulator, older builds).
local _awake_holds   = 0
local _awake_saved   = nil   -- pause_auto_suspend as it was before the first hold
local _awake_standby = false

local function get_pluginshare()
    local ok, PluginShare = pcall(require, "pluginshare")
    return ok and type(PluginShare) == "table" and PluginShare or nil
end

local function hold_awake()
    _awake_holds = _awake_holds + 1
    if _awake_holds > 1 then return end
    local share = get_pluginshare()
    if share then
        _awake_saved = share.pause_auto_suspend
        share.pause_auto_suspend = true
    end
    _awake_standby = false
    if type(UIManager.preventStandby) == "function" and type(UIManager.allowStandby) == "function" then
        _awake_standby = pcall(UIManager.preventStandby, UIManager)
    end
end

-- Returns a release function that is safe to call more than once: every
-- exit path of a run calls it, and only the first call counts.
local function awake_guard()
    hold_awake()
    local released = false
    return function()
        if released then return end
        released = true
        if _awake_holds <= 0 then return end
        _awake_holds = _awake_holds - 1
        if _awake_holds > 0 then return end
        local share = get_pluginshare()
        if share then share.pause_auto_suspend = _awake_saved end
        _awake_saved = nil
        if _awake_standby then pcall(UIManager.allowStandby, UIManager) end
        _awake_standby = false
        -- The end of a run counts as activity: the suspend countdown starts
        -- from now, so the summary does not vanish into an instant sleep.
        if type(UIManager.event_hook) == "table" and UIManager.event_hook.execute then
            pcall(UIManager.event_hook.execute, UIManager.event_hook, "InputEvent")
        end
    end
end

-- ---------------------------------------------------------------------------
-- One zip per plugin
-- ---------------------------------------------------------------------------

-- The monorepo commits a ready zip of every plugin (dist/<id>.zip, built by
-- scripts/build_release.sh: <dir>/ with its common/, plus game-common/ or
-- sudoku-common/ beside it), and manifest.json names it with its sha256 and
-- size. One download per plugin instead of one per file -- about ten times
-- fewer HTTPS requests over a whole Update -- which is what makes a full run
-- bearable on a slow reader. Any problem with it (no sha2 to check it with,
-- HTTP error, wrong size or hash -- e.g. the CDN still serving the previous
-- release's zip for a few minutes --, a corrupt archive, a missing or
-- unsafe entry) falls back to the per-file download for that plugin.
local ZIP_BASE_URL = MANIFEST_URL:match("^(.*/)")
local ZIP_DIR      = DataStorage:getDataDir() .. "/cache/pluginmanager"

-- The manifest's `zip` field, validated, or nil.
local function zip_spec(info)
    local z = type(info) == "table" and info.zip
    if type(z) ~= "table" then return nil end
    if type(z.path) ~= "string" or not z.path:match("^dist/[%w][%w%._-]*%.zip$") or z.path:find("..", 1, true) then
        return nil
    end
    if type(z.sha256) ~= "string" or not z.sha256:match("^%x+$") then return nil end
    local size = tonumber(z.size)
    if not size or size <= 0 then return nil end
    return { url = ZIP_BASE_URL .. z.path, sha256 = z.sha256:lower(), size = size }
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

-- SHA-256 of a file, fed in 64 KB chunks where ffi/sha2 supports it
-- (sha256() with no argument returns an incremental hasher), else from the
-- whole file at once. nil when no sha2 is available.
local function file_sha256(path)
    if sha256("") == nil then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok_inc, append = pcall(_sha256)
    if ok_inc and type(append) == "function" then
        local ok, h = pcall(function()
            while true do
                local chunk = f:read(65536)
                if not chunk then break end
                append(chunk)
            end
            return append()
        end)
        f:close()
        return ok and h or nil
    end
    local body = f:read("*a")
    f:close()
    return sha256(body)
end

-- Downloads `info`'s zip to a cache file and checks its size and hash.
-- Returns the file's path, or (nil, message). Paced and retried on 429 like
-- fetch_url.
local function download_zip(info)
    local z = zip_spec(info)
    if not z then return nil, "no zip in the manifest" end
    if sha256("") == nil then return nil, "sha256 not available" end
    mkdir_p(ZIP_DIR)
    local path = string.format("%s/%s.zip", ZIP_DIR, tostring(info.id or info.dir):gsub("[^%w%._-]", "_"))
    local delay = FETCH_RETRY_DELAY
    for attempt = 1, FETCH_MAX_RETRIES do
        sleep(FETCH_PACE_DELAY)
        local ok, err, status = fetch_to_file(z.url, path, nil, TIMEOUT_ZIP_TOTAL + math.ceil(z.size / ZIP_MIN_RATE))
        if ok then break end
        if status == 429 and attempt < FETCH_MAX_RETRIES then
            sleep(delay)
            delay = delay * 2
        else
            return nil, err
        end
    end
    local size = file_size(path)
    if size ~= z.size then
        os.remove(path)
        return nil, string.format("zip size %s, expected %d", tostring(size), z.size)
    end
    if file_sha256(path) ~= z.sha256 then
        os.remove(path)
        return nil, "zip sha256 mismatch"
    end
    return path
end

local function open_zip(path)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, _("Archive support not available.")
    end
    local reader = Archiver.Reader:new()
    local ok_open, opened = pcall(reader.open, reader, path)
    if not ok_open or not opened then
        return nil, _("Failed to open downloaded archive.")
    end
    return reader
end

-- Extracts, from the open zip, every entry `prefix .. rel` with `wanted[rel]`
-- into dest_root/rel, in one pass in archive order (ffi/archiver reads
-- sequentially; seeking backwards re-opens the file). The whole archive is
-- refused at the first entry name PathGuard rejects -- anywhere in it, not
-- only under `prefix`: a zip carrying a "../" entry is not one
-- build_release.sh made. Every wanted entry must be found.
local function extract_from_zip(reader, prefix, wanted, dest_root)
    local found, n = {}, 0
    for entry in reader:iterate() do
        local name  = entry.path or ""
        local check = name:gsub("/+$", "")
        if check == "" or not PathGuard.filePath(dest_root, check) then
            return false, string.format(_("Refused archive entry: %s"), name)
        end
        if entry.mode == "file" and name:sub(1, #prefix) == prefix then
            local rel = name:sub(#prefix + 1)
            if wanted[rel] and not found[rel] then
                local dest = PathGuard.filePath(dest_root, rel)
                if not dest then
                    return false, string.format(_("Refused archive entry: %s"), name)
                end
                local subdir = dest:match("^(.*)/[^/]+$")
                if subdir then mkdir_p(subdir) end
                if not reader:extractToPath(name, dest) then
                    return false, string.format(_("Failed to extract %s"), rel)
                end
                found[rel] = true
                n = n + 1
                if n % 8 == 0 then ui_yield() end
            end
        end
    end
    if reader.err then return false, tostring(reader.err) end
    for rel in pairs(wanted) do
        if not found[rel] then return false, "missing from zip: " .. rel end
    end
    return true
end

-- The compile check of the per-file path, on extracted files: every .lua
-- in `files` under `root` must compile. Returns true or (false, message).
local function check_compiles(root, files)
    for _i, fname in ipairs(files) do
        if PMLogic.isLuaFile(fname) then
            local f = io.open(root .. "/" .. fname, "rb")
            local body = f and f:read("*a")
            if f then f:close() end
            if not body or not PMLogic.compiles(body, fname) then
                return false, string.format(_("%s does not compile (incomplete download?)"), fname)
            end
        end
    end
    return true
end

-- Downloads `info`'s zip and extracts `entries` (a list of paths relative
-- to `prefix` inside the zip) into `stage`, which is emptied first. On
-- failure `stage` is removed again. Returns true or (false, message).
local function stage_from_zip(info, prefix, entries, stage)
    local zip_path, err = download_zip(info)
    if not zip_path then return false, err end
    ui_yield()
    local reader, oerr = open_zip(zip_path)
    if not reader then
        os.remove(zip_path)
        return false, oerr
    end
    local wanted = {}
    for _i, rel in ipairs(entries) do wanted[rel] = true end
    rm_rf(stage)
    mkdir_p(stage)
    local ok, xerr = safe_call(extract_from_zip, reader, prefix, wanted, stage)
    pcall(reader.close, reader)
    os.remove(zip_path)
    if ok then ok, xerr = check_compiles(stage, entries) end
    if not ok then
        rm_rf(stage)
        return false, xerr
    end
    return true
end

-- A plugin whose zip can refresh shared library `lib_key`: one that uses it
-- and ships a zip, preferring the smallest download.
local function lib_carrier(manifest, lib_key)
    local best, best_size
    for _i, p in ipairs(manifest.plugins or {}) do
        local z = p.common_lib == lib_key and zip_spec(p)
        if z and (not best_size or z.size < best_size) then
            best, best_size = p, z.size
        end
    end
    return best
end

-- `lib_key` is a manifest.json top-level key naming a downloadable common/
-- bundle -- "common" (game-common, ScreenBase-based games) or
-- "sudoku_common" (sudoku-common, BaseScreen-based sudoku variants); see the
-- project-sudoku-common-architecture memory for why the two are NOT
-- interchangeable. Each plugin_info names the one it needs via its own
-- common_lib field, which indexes straight into manifest[lib_key] here.
--
-- `force` skips the .version short-circuit and re-fetches the bundle even
-- when the stamp already says it is current. Update wants the gate (there
-- is nothing to re-download); Reinstall All must not have it. The stamp
-- records a version, not integrity, so a bundle truncated by a mid-write
-- crash or a half-finished run keeps a perfectly current .version and was
-- silently skipped -- by the one action whose whole purpose is to re-fetch
-- everything, and whose own prompt promises "including shared libraries".
-- Worse, installPlugin then copies that stale bundle into every consuming
-- plugin's common/, so the damage was propagated fleet-wide rather than
-- repaired.
--
-- Every file is downloaded and checked before the first one is written, so
-- a failure leaves the bundle on disk as it was. A shared library has no
-- _meta.lua to tell "upstream moved ahead of the manifest" from "stale
-- copy", so a hash mismatch that survives the re-download is accepted for a
-- .lua that compiles (the common case: the library was pushed and the
-- manifest not yet regenerated) and refused for anything else.
function PluginManager:ensureCommon(manifest, lib_key, force)
    local spec    = manifest[lib_key]
    local lib_dir = PathGuard.pluginPath(_plugins_dir, spec.dir)
    if not lib_dir then
        return false, string.format("%s: refused directory entry %q", lib_key, tostring(spec.dir))
    end
    local lfs     = get_lfs()
    if not force and lfs and lfs.attributes(lib_dir, "mode") == "directory" then
        local vf = io.open(lib_dir .. "/.version", "r")
        if vf then
            local v = vf:read("*l"); vf:close()
            if not is_newer(v or "0", spec.version) then return true end
        end
    end
    -- Zip first: the library sits at the top level of every consuming
    -- plugin's zip (as <spec.dir>/), so one download refreshes all of it.
    -- Staged and compile-checked before the first file is written, like the
    -- per-file path below, which remains the fallback.
    local carrier = lib_carrier(manifest, lib_key)
    local stage   = carrier and type(spec.files) == "table" and staging_path(spec.dir)
    if stage then
        local all_safe = true
        for _i, fname in ipairs(spec.files) do
            if not PathGuard.filePath(lib_dir, fname) or not PathGuard.filePath(stage, fname) then all_safe = false end
        end
        local ok, zerr = false, "refused file entry"
        if all_safe then ok, zerr = stage_from_zip(carrier, spec.dir .. "/", spec.files, stage) end
        if ok then
            mkdir_p(lib_dir)
            for _i, fname in ipairs(spec.files) do
                local src, dest = PathGuard.filePath(stage, fname), PathGuard.filePath(lib_dir, fname)
                local subdir = dest:match("^(.*)/[^/]+$")
                if subdir then mkdir_p(subdir) end
                if not os.rename(src, dest) and not copy_file(src, dest) then
                    rm_rf(stage)
                    return false, string.format("%s: %s", dest, "rename")
                end
            end
            rm_rf(stage)
            write_file(lib_dir .. "/.version", spec.version)
            return true
        end
        logger.info("PluginManager:", lib_key, "zip refresh failed, downloading file by file:", zerr)
    end

    local base    = spec.raw_base_url or ((manifest.raw_base_url or "") .. spec.dir .. "/")
    local fetched = {}
    for _i, fname in ipairs(spec.files) do
        -- fname comes straight out of manifest.json, so it is checked
        -- before it becomes a path, the same way `dir` already is.
        local dest = PathGuard.filePath(lib_dir, fname)
        if not dest then
            return false, string.format("%s: refused file entry %q", spec.dir, tostring(fname))
        end
        local body, verdict, compiles = fetch_checked(base .. fname, fname, expected_hash(spec.sha256, fname))
        if not body then
            return false, string.format("%s/%s: %s", spec.dir, fname, verdict)
        end
        if not compiles then
            return false, string.format(_("%s does not compile (incomplete download?)"), spec.dir .. "/" .. fname)
        end
        if verdict == "mismatch" then
            if not PMLogic.isLuaFile(fname) then
                return false, string.format(_("%s failed its integrity check."), spec.dir .. "/" .. fname)
            end
            logger.info("PluginManager: accepted hash drift for", spec.dir .. "/" .. fname)
        end
        fetched[#fetched + 1] = { dest = dest, body = body }
        ui_yield()
    end
    mkdir_p(lib_dir)
    for _i, f in ipairs(fetched) do
        local subdir = f.dest:match("^(.*)/[^/]+$")
        if subdir then mkdir_p(subdir) end
        local ok, werr = write_file(f.dest, f.body)
        if not ok then
            return false, string.format("%s: %s", f.dest, tostring(werr))
        end
    end
    -- Stamped last: a run that dies before this point leaves the old stamp,
    -- so the next Update fetches the bundle again.
    write_file(lib_dir .. "/.version", spec.version)
    return true
end

-- ---------------------------------------------------------------------------
-- Roll back: the version an update replaced
-- ---------------------------------------------------------------------------

-- Version of the kept copy of `dir`, or nil when there is none.
function PluginManager:getBackupVersion(dir)
    local path = backup_path(dir)
    if not path then return nil end
    local meta = read_meta(path .. "/_meta.lua")
    return meta and meta.version or nil
end

-- Keeps the version about to be replaced. Only a real version change is
-- kept: reinstalling the same version would otherwise overwrite the one
-- useful copy (the version before the last update) with what is installed
-- now. One version per plugin -- the previous one -- and best effort: a
-- backup that cannot be written never blocks the update itself.
function PluginManager:backupPlugin(plugin_info, plugin_dir)
    local lfs = get_lfs()
    if not lfs or lfs.attributes(plugin_dir, "mode") ~= "directory" then return end
    local meta = read_meta(plugin_dir .. "/_meta.lua")
    if not meta or not meta.version or meta.version == plugin_info.version then return end
    local dest = backup_path(plugin_info.dir)
    if not dest then return end
    rm_rf(dest)
    mkdir_p(_plugins_dir .. "/" .. BACKUP_DIR)
    local ok = safe_call(copy_tree, plugin_dir, dest)
    if not ok then rm_rf(dest) end
end

-- Puts the kept copy back in place of the installed plugin. A swap of two
-- renames on one filesystem: installed -> staging, backup -> installed, so
-- there is never a moment with no plugin directory at all, and if the
-- second rename fails the first is undone. Every path goes through
-- PathGuard and every delete through rm_rf. Returns (true, version) or
-- (false, message).
function PluginManager:restoreBackup(dir)
    local live   = PathGuard.pluginPath(_plugins_dir, dir)
    local backup = backup_path(dir)
    local aside  = staging_path(dir)
    if not live or not backup or not aside then
        return false, _("Refused: unsafe directory name.")
    end
    local meta = read_meta(backup .. "/_meta.lua")
    if not meta or not meta.version then
        return false, _("No previous version is kept for this plugin.")
    end
    local lfs = get_lfs()
    if not lfs then return false, _("No previous version is kept for this plugin.") end
    rm_rf(aside)
    mkdir_p(_plugins_dir .. "/" .. STAGING_DIR)
    local had_live = lfs.attributes(live, "mode") == "directory"
    if had_live and not os.rename(live, aside) then
        return false, _("Could not restore the previous version.")
    end
    if not os.rename(backup, live) then
        if had_live then os.rename(aside, live) end
        return false, _("Could not restore the previous version.")
    end
    rm_rf(aside)
    return true, meta.version
end

-- Installs or updates one plugin, in three steps:
--
-- 1. Every file is downloaded into the staging folder and checked -- taken
--    from the plugin's zip when the manifest names one, else (or when the
--    zip is unusable) downloaded one by one. Nothing
--    under the plugin's own directory is touched yet, so any failure leaves
--    the installed version exactly as it was. (The old code wrote each file
--    over the live plugin as it arrived; a download failing half way left a
--    mix of two versions that KOReader then failed to load.)
-- 2. Checks. Every .lua must compile, whatever the manifest says: that alone
--    catches a truncated download. When the manifest carries sha256, each
--    file must also match it -- except that a mismatch can be legitimate:
--    files come from raw.githubusercontent at the branch head, hashes from
--    the monorepo's checked-out submodule at the last manifest regeneration,
--    and between a plugin push and the next regeneration the two differ. So
--    a mismatch that survives a re-download is accepted when the downloaded
--    _meta.lua is at least the manifest's version (upstream moved ahead),
--    and refused when it is older (a stale copy; see PMLogic.driftAcceptable).
--    Drift therefore never blocks a good install, and a refused install
--    leaves nothing behind.
-- 3. The version being replaced is kept for roll back, then the staged
--    files are moved into place.
function PluginManager:installPlugin(plugin_info, manifest)
    local plugin_dir = PathGuard.pluginPath(_plugins_dir, plugin_info.dir)
    local stage      = staging_path(plugin_info.dir)
    if not plugin_dir or not stage then
        return false, string.format(_("Refused file entry: %s"), tostring(plugin_info.dir))
    end
    local base   = plugin_info.raw_base_url or ((manifest.raw_base_url or "") .. plugin_info.dir .. "/")
    local hashes = plugin_info.sha256

    local function fail(msg)
        rm_rf(stage)
        return false, msg
    end

    -- Every entry is checked against both trees before anything is
    -- downloaded: it names where the file will finally land, not just where
    -- it is staged.
    for _i, fname in ipairs(plugin_info.files) do
        if not PathGuard.filePath(stage, fname) or not PathGuard.filePath(plugin_dir, fname) then
            return fail(string.format(_("Refused file entry: %s"), tostring(fname)))
        end
    end

    -- 1. Into staging: from the plugin's zip when the manifest names one
    --    (one download, verified by its sha256 as a whole; see "One zip per
    --    plugin" above), else -- or when anything about the zip is wrong --
    --    file by file.
    local staged_from_zip = false
    if zip_spec(plugin_info) then
        local ok, zerr = stage_from_zip(plugin_info, plugin_info.dir .. "/", plugin_info.files, stage)
        if ok then
            local meta = read_meta(stage .. "/_meta.lua")
            if PMLogic.driftAcceptable(meta and meta.version, plugin_info.version) then
                staged_from_zip = true
            else
                zerr = "zip holds an older version"
            end
        end
        if not staged_from_zip then
            logger.info("PluginManager:", plugin_info.id, "zip install failed, downloading file by file:", zerr)
        end
    end

    if not staged_from_zip then
        rm_rf(stage)
        mkdir_p(stage)
        local drifted, meta_body = {}, nil
        for _i, fname in ipairs(plugin_info.files) do
            local staged = PathGuard.filePath(stage, fname)
            local body, verdict, compiles = fetch_checked(base .. fname, fname, expected_hash(hashes, fname))
            if not body then
                return fail(string.format(_("Download failed: %s \u{2014} %s"), fname, verdict))
            end
            -- 2a. Compile check.
            if not compiles then
                return fail(string.format(_("%s does not compile (incomplete download?)"), fname))
            end
            if verdict == "mismatch" then drifted[#drifted + 1] = fname end
            if fname == "_meta.lua" then meta_body = body end
            local subdir = staged:match("^(.*)/[^/]+$")
            if subdir then mkdir_p(subdir) end
            local ok, werr = write_file(staged, body)
            if not ok then
                return fail(string.format(_("Write failed: %s \u{2014} %s"), fname, werr))
            end
            body = nil
            ui_yield()
        end

        -- 2b. Hash drift.
        if #drifted > 0 then
            local meta_version = meta_body and parse_meta(meta_body).version
            if not PMLogic.driftAcceptable(meta_version, plugin_info.version) then
                return fail(string.format(
                    _("%s failed its integrity check (%s)."),
                    plugin_info.fullname or plugin_info.id, table.concat(drifted, ", ")
                ))
            end
            logger.info("PluginManager:", plugin_info.id, "accepted hash drift, upstream is ahead of the manifest:",
                table.concat(drifted, ", "))
        end
    end -- per-file staging

    -- 3. Keep the replaced version, then commit.
    self:backupPlugin(plugin_info, plugin_dir)
    mkdir_p(plugin_dir)
    for _i, fname in ipairs(plugin_info.files) do
        local src  = PathGuard.filePath(stage, fname)
        local dest = PathGuard.filePath(plugin_dir, fname)
        local subdir = dest:match("^(.*)/[^/]+$")
        if subdir then mkdir_p(subdir) end
        if not os.rename(src, dest) and not copy_file(src, dest) then
            return fail(string.format(_("Write failed: %s \u{2014} %s"), fname, "rename"))
        end
    end
    rm_rf(stage)

    -- Remove stale files left over from a previous version (renamed/removed
    -- source files) that are no longer listed for this version. Only
    -- top-level regular files are considered; `common` and any other
    -- subdirectory are never touched here. Files the user creates beside the
    -- plugin's own (USER_FILES) are never in the manifest and must survive:
    -- a Plugin Manager self-update used to delete the GitHub token.
    local expected = {}
    for _i, fname in ipairs(plugin_info.files) do expected[fname] = true end
    for _i, fname in ipairs(list_top_level_files(plugin_dir)) do
        if not expected[fname] and not USER_FILES[fname] then
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
        local lib_dir = PathGuard.pluginPath(_plugins_dir, spec.dir)
        local lfs = get_lfs()
        mkdir_p(common_path)
        if lib_dir and lfs and lfs.attributes(lib_dir, "mode") == "directory" then
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
            self:refreshHome()
            local is_self = plugin_info.id == "pluginmanager"
            self:askRestart(is_self
                and string.format(
                    _("%s v%s installed.\nPlease restart KOReader to apply the update."),
                    plugin_info.fullname, plugin_info.version
                )
                or  string.format(
                    _("%s v%s installed.\nPlease restart KOReader to load it."),
                    plugin_info.fullname, plugin_info.version
                ))
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
            -- The archive names its own entries, so "plugin/../../x" would
            -- pass the prefix test above and still land outside dest_dir.
            local dest_path = PathGuard.filePath(dest_dir, relative)
            if not dest_path then
                return false, string.format(_("Refused archive entry: %s"), relative)
            end
            local subdir = dest_path:match("^(.*)/[^/]+$")
            if subdir then mkdir_p(subdir) end
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
            if on_done then
                -- Part of a batch: the batch asks for the restart once, at
                -- the end, instead of one prompt per plugin.
                on_done(true)
            else
                self:askRestart(string.format(
                    _("%s installed.\nPlease restart KOReader to load it."),
                    (meta and meta.fullname) or repo.name
                ))
            end
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
-- manifest-driven bulk install in _runBulkInstall), then shows one summary
-- and asks for the restart once. `on_done(parts, succeeded)`, if given,
-- receives the summary lines instead (Import chains this after its own
-- batch and asks once for both).
function PluginManager:installAllFromGithub(repos, on_done)
    local release = awake_guard()
    local total  = #repos
    local failed = {}
    local function step(i)
        if i > total then
            release()
            local parts = {}
            if #failed > 0 then
                parts[#parts + 1] = string.format(_("%d/%d installed. Failures:"), total - #failed, total)
                for _, f in ipairs(failed) do parts[#parts + 1] = f end
            else
                parts[#parts + 1] = string.format(_("%d plugin(s) installed."), total)
            end
            local succeeded = total - #failed
            if on_done then return on_done(parts, succeeded) end
            self:_showSummary(parts, succeeded > 0)
            return
        end
        local repo = repos[i]
        -- safe_call: one malformed repo must not stop the batch (see the
        -- note on safe_call at the top of this file).
        local ok_call, call_err = safe_call(function()
            self:installFromGithubRepo(repo, function(ok, err)
                if not ok then
                    failed[#failed + 1] = repo.full_name .. ": " .. (err or "?")
                end
                step(i + 1)
            end)
            return true
        end)
        if not ok_call then
            failed[#failed + 1] = tostring(repo.full_name) .. ": " .. (call_err or "?")
            UIManager:scheduleIn(0, function() step(i + 1) end)
        end
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
    local owner_query = PMLogic.ownerQuery(self._discover_filter)

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
    -- Validate the name before building a path out of it, rather than relying
    -- on rm_rf to catch it afterwards.
    local target = PathGuard.pluginPath(_plugins_dir, plugin_dir)
    if not target then
        UIManager:show(InfoMessage:new{
            text    = string.format(_("Refused to remove %s: unsafe directory name."), fullname),
            timeout = 5,
        })
        return
    end
    rm_rf(target)
    -- Its kept previous version goes with it: nothing could restore it
    -- (the restore button lives on the installed plugin's dialog).
    local backup = backup_path(plugin_dir)
    if backup then rm_rf(backup) end
    local id = plugin_dir:match("^(.*)%.koplugin$")
    if id then self:forgetDiscoverInstall(id) end
    self:refreshHome()
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
                    local old_path = PathGuard.pluginPath(_plugins_dir, old.dir)
                    if old_path then rm_rf(old_path) end
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
-- What's new (CHANGELOG.md between the installed and the offered version)
-- ---------------------------------------------------------------------------

local function cache_path(name)
    return DataStorage:getDataDir() .. "/cache/pluginmanager/" .. name:gsub("[^%w%-%.]", "_")
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body ~= "" and body or nil
end

-- Runs fn now when online, or after KOReader has brought the network up
-- (asking the user first, as every other network action here does).
local function when_online(fn)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then NetworkMgr:runWhenOnline(fn) else fn() end
end

-- The changelog is cached per *offered* version, like a README but without
-- a Refresh button: the sections up to that version do not change once it
-- is released, and a newer manifest version is a new cache key anyway.
function PluginManager:showWhatsNew(plugin_info, inst_info)
    if not plugin_info.raw_base_url then
        UIManager:show(InfoMessage:new{ text = _("No changelog available for this plugin."), timeout = 4 })
        return
    end
    local path = cache_path("changelog_" .. plugin_info.id .. "_" .. plugin_info.version .. ".md")

    local function display(body)
        -- Only what changed since the installed version; the whole file
        -- when its headings cannot be read, or when none falls in range
        -- (a version bumped without a changelog line) -- something is
        -- always better than an empty viewer.
        local slice = PMLogic.changelogSlice(body, inst_info.version, plugin_info.version)
        local text  = (slice and slice ~= "") and slice or body
        local TextViewer = require("ui/widget/textviewer")
        local viewer
        viewer = TextViewer:new{
            title               = string.format(_("What's new: %s v%s \u{2192} v%s"),
                inst_info.fullname, inst_info.version, plugin_info.version),
            text                = text,
            text_format         = textviewer_supports_md() and "md" or nil,
            add_default_buttons = true,
            buttons_table       = {{
                {
                    text     = string.format(_("Update to v%s"), plugin_info.version),
                    callback = function()
                        UIManager:close(viewer)
                        self:confirmCompatible(plugin_info, function()
                            self:_doInstall(plugin_info, self._manifest)
                        end)
                    end,
                },
            }},
        }
        UIManager:show(viewer)
    end

    local cached = read_file(path)
    if cached then return display(cached) end
    when_online(function()
        local notice = InfoMessage:new{ text = _("Fetching changelog\u{2026}") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(notice)
            local body, err = fetch_url(plugin_info.raw_base_url .. "CHANGELOG.md")
            if not body then
                UIManager:show(InfoMessage:new{
                    text    = _("Changelog download failed:") .. "\n" .. (err or "?"),
                    timeout = 5,
                })
                return
            end
            mkdir_p(path:match("^(.*)/"))
            write_file(path, body)
            display(body)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Screenshot preview
-- ---------------------------------------------------------------------------

-- The README screenshot shipped in the plugin's own images/ (see
-- PMLogic.pickScreenshot), or nil when the manifest lists none.
local function screenshot_of(plugin_info)
    return PMLogic.pickScreenshot(plugin_info.id, plugin_info.files)
end

-- Decodes first, so a damaged file gives a message instead of an ImageViewer
-- failing half-built. Returns false when the image cannot be shown.
local function view_image(path, title)
    local ok_r, RenderImage = pcall(require, "ui/renderimage")
    local ok_v, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok_r or not ok_v then return false end
    local ok_bb, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok_bb or not bb then return false end
    local ok_new, viewer = pcall(ImageViewer.new, ImageViewer, {
        image            = bb,
        image_disposable = true,
        fullscreen       = true,
        with_title_bar   = true,
        title_text       = title,
    })
    if not ok_new or not viewer then
        bb:free()
        return false
    end
    UIManager:show(viewer)
    return true
end

-- An installed plugin already has the image on disk (it is one of its
-- files); otherwise it is downloaded once into the cache, next to the
-- READMEs, keyed by plugin and version.
function PluginManager:showScreenshot(plugin_info)
    local rel = screenshot_of(plugin_info)
    if not rel then return end
    local title = plugin_info.fullname

    local plugin_dir = PathGuard.pluginPath(_plugins_dir, plugin_info.dir or "")
    local on_disk    = plugin_dir and PathGuard.filePath(plugin_dir, rel)
    local lfs        = get_lfs()
    if on_disk and lfs and lfs.attributes(on_disk, "mode") == "file" and view_image(on_disk, title) then
        return
    end

    local path = cache_path("shot_" .. plugin_info.id .. "_" .. tostring(plugin_info.version) .. ".png")
    if lfs and lfs.attributes(path, "mode") == "file" then
        if view_image(path, title) then return end
        os.remove(path)  -- damaged: fetch it again below
    end
    if not plugin_info.raw_base_url then return end
    when_online(function()
        local notice = InfoMessage:new{ text = _("Fetching screenshot\u{2026}") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(notice)
            mkdir_p(path:match("^(.*)/"))
            local ok, err = fetch_to_file(plugin_info.raw_base_url .. rel, path)
            if not ok or not view_image(path, title) then
                os.remove(path)
                UIManager:show(InfoMessage:new{
                    text    = _("Screenshot download failed:") .. "\n" .. (err or "?"),
                    timeout = 5,
                })
            end
        end)
    end)
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

    local shot = screenshot_of(plugin_info)
    if shot then
        buttons[#buttons + 1] = {{
            text     = _("Screenshot"),
            callback = function()
                UIManager:close(dlg)
                self:showScreenshot(plugin_info)
            end,
        }}
    end

    if has_update then
        local pref = plugin_info
        buttons[#buttons + 1] = {
            {
                text     = string.format(_("Update to v%s"), plugin_info.version),
                callback = function()
                    UIManager:close(dlg)
                    self:confirmCompatible(pref, function() self:_doInstall(pref, self._manifest) end)
                end,
            },
            {
                text     = _("What's new"),
                callback = function()
                    UIManager:close(dlg)
                    self:showWhatsNew(pref, inst_info)
                end,
            },
        }
        buttons[#buttons + 1] = {{
            text     = string.format(_("Ignore v%s"), plugin_info.version),
            callback = function()
                UIManager:close(dlg)
                self:setIgnoredVersion(pref.id, pref.version)
                self:refreshHome()
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
                sha256       = pref.sha256,
                min_koreader = pref.min_koreader,
                common_lib   = pref.common_lib,
                raw_base_url = pref.raw_base_url,
            }
            self:confirmCompatible(current, function() self:_doInstall(current, self._manifest) end)
        end,
    }}

    -- Roll back to the version the last update replaced, when one is kept.
    local backup_version = self:getBackupVersion(plugin_info.dir)
    if backup_version then
        buttons[#buttons + 1] = {{
            text     = string.format(_("Restore previous version (v%s)"), backup_version),
            callback = function()
                UIManager:close(dlg)
                UIManager:show(ConfirmBox:new{
                    text        = string.format(
                        _("Replace %s v%s with the previous version, v%s?"),
                        inst_info.fullname, inst_info.version, backup_version
                    ),
                    ok_text     = _("Restore"),
                    ok_callback = function() self:_doRestore(plugin_info, inst_info) end,
                })
            end,
        }}
    end

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
                self:askRestart(iref.disabled
                    and string.format(_("%s enabled.\nRestart KOReader to apply."), iref.fullname)
                    or  string.format(_("%s disabled.\nRestart KOReader to apply."), iref.fullname))
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
    if not self:isCompatible(plugin_info) then
        title = title .. "\n" .. string.format(_("v%s needs KOReader %s or newer."), plugin_info.version, plugin_info.min_koreader)
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
    if not self:isCompatible(plugin_info) then
        title = title .. "\n" .. string.format(_("Needs KOReader %s or newer."), plugin_info.min_koreader)
    end
    local buttons = {
        {{
            text     = _("Install"),
            callback = function()
                UIManager:close(dlg)
                self:confirmCompatible(plugin_info, function()
                    self:_doInstall(plugin_info, self._manifest)
                end)
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
    }
    if screenshot_of(plugin_info) then
        buttons[#buttons + 1] = {{
            text     = _("Screenshot"),
            callback = function()
                UIManager:close(dlg)
                self:showScreenshot(plugin_info)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(dlg) end,
    }}
    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

-- Restores the kept previous version and, if the manifest still offers the
-- version just rolled back from (or newer), ignores it: otherwise the very
-- next Update would reinstall what the user has just backed out of.
function PluginManager:_doRestore(plugin_info, inst_info)
    local ok, result = safe_call(function() return self:restoreBackup(plugin_info.dir) end)
    if not ok then
        UIManager:show(InfoMessage:new{
            text    = _("Restore failed:") .. "\n" .. (result or "?"),
            timeout = 5,
        })
        return
    end
    local parts = { string.format(_("%s v%s restored."), inst_info.fullname, result) }
    if is_newer(result, plugin_info.version) then
        self:setIgnoredVersion(plugin_info.id, plugin_info.version)
        parts[#parts + 1] = string.format(
            _("v%s will be hidden from updates until a newer version is released.\nSee \u{201c}Ignored updates\u{2026}\u{201d} in the main menu to undo."),
            plugin_info.version
        )
    end
    self:refreshHome()
    parts[#parts + 1] = _("Please restart KOReader to apply the change.")
    self:askRestart(table.concat(parts, "\n"))
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

-- Category labels, by the stable ids update_manifest.py writes from
-- .github/scripts/categories.json. A function, not a table built at load
-- time, so the labels follow the UI language. Anything else -- no category
-- (a manifest from before categories, a locally-installed plugin) or one
-- this version does not know yet -- goes under "Other".
local function category_label(id)
    local labels = {
        logic   = _("Logic puzzles"),
        sudoku  = _("Sudoku"),
        words   = _("Word games"),
        board   = _("Board games"),
        cards   = _("Card & dice games"),
        classic = _("Classic puzzles"),
        party   = _("Party & quiz"),
        tools   = _("Utilities"),
    }
    return labels[id] or _("Other")
end

local function category_of(id)
    for _i, known in ipairs(PMLogic.CATEGORY_ORDER) do
        if known == id then return id end
    end
    return "other"
end

-- Picks the category the list is narrowed to (nil = all), then reopens it.
function PluginManager:showCategoryFilterDialog()
    local dlg
    local function choose(id)
        return function()
            UIManager:close(dlg)
            self._list_category = id
            self:showPluginList()
        end
    end
    local buttons = {{{ text = _("All categories"), callback = choose(nil) }}}
    local ids = {}
    for _i, id in ipairs(PMLogic.CATEGORY_ORDER) do ids[#ids + 1] = id end
    ids[#ids + 1] = "other"
    -- Two per row: nine single rows would not fit a small screen.
    for i = 1, #ids, 2 do
        local row = {}
        for j = i, math.min(i + 1, #ids) do
            local id = ids[j]
            row[#row + 1] = {
                text     = (self._list_category == id and "\u{2713} " or "") .. category_label(id),
                callback = choose(id),
            }
        end
        buttons[#buttons + 1] = row
    end
    dlg = ButtonDialog:new{ title = _("Show category"), buttons = buttons }
    UIManager:show(dlg)
end

function PluginManager:showPluginListFilterDialog()
    local input
    input = InputDialog:new{
        title      = _("Filter plugins"),
        input      = self._list_filter or "",
        input_hint = _("Plugin name\u{2026}"),
        buttons    = {
            {
                {
                    text     = string.format(_("Category: %s"),
                        self._list_category and category_label(self._list_category) or _("All")),
                    callback = function()
                        -- Keep whatever was typed: picking a category is
                        -- part of the same filter, not a cancel.
                        local text = input:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(input)
                        self._list_filter = text ~= "" and text or nil
                        self:showCategoryFilterDialog()
                    end,
                },
            },
            {
                {
                    text     = _("Clear"),
                    callback = function()
                        UIManager:close(input)
                        self._list_filter   = nil
                        self._list_category = nil
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
            },
        },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

-- The list is split into one section per category (manifest field
-- `category`), each opened by a non-selectable header row; the sort mode
-- (name, or status with updates first) applies inside each section, and the
-- name filter and category filter narrow it first. Offline -- no manifest
-- cached yet -- there are no categories to go by and the list stays flat.
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
            local inst       = installed[p.id]
            local compatible = self:isCompatible(p)
            local category   = category_of(json_str(p.category))
            if inst then
                local newer      = is_newer(inst.version, p.version) and not self:isVersionIgnored(p.id, p.version)
                -- An update this KOReader cannot run is shown, not offered
                -- as one: not bold, not sorted first, and the reason given.
                local has_update = newer and compatible
                local detail
                if has_update then
                    detail = "v" .. inst.version .. " \u{2192} v" .. p.version
                elseif newer then
                    detail = "v" .. inst.version .. "  " .. string.format(_("(v%s needs KOReader %s)"), p.version, p.min_koreader)
                else
                    detail = "v" .. inst.version
                end
                local entry = { plugin = p, inst = inst, has_update = has_update }
                items[#items + 1] = {
                    text        = (inst.disabled and (_("[DISABLED]") .. " ") or "") .. inst.fullname,
                    mandatory   = detail,
                    bold        = has_update,
                    category    = category,
                    _sort_group = has_update and SORT_GROUP_UPDATE or SORT_GROUP_INSTALLED,
                    callback    = function()
                        self:showInstalledDialog(entry.plugin, entry.inst, entry.has_update)
                    end,
                }
            else
                local pref = p
                items[#items + 1] = {
                    text        = p.fullname,
                    mandatory   = compatible and ("v" .. p.version)
                        or ("v" .. p.version .. "  " .. string.format(_("(needs KOReader %s)"), p.min_koreader)),
                    dim         = true,
                    category    = category,
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
                    category    = "other",
                    _sort_group = has_update and SORT_GROUP_UPDATE or SORT_GROUP_LOCAL_ONLY,
                    callback    = function() self:showLocalOnlyDialog(iref) end,
                }
            end
        end
    end

    local filter = (self._list_filter or ""):lower()
    if filter ~= "" or self._list_category then
        local filtered = {}
        for _, item in ipairs(items) do
            if (filter == "" or item.text:lower():find(filter, 1, true))
               and (not self._list_category or (item.category or "other") == self._list_category) then
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

    -- Sections. Not when the list is narrowed to one category (the subtitle
    -- already names it), offline, or with a manifest from before categories
    -- existed (nothing to group by: one "Other" header over everything).
    local has_categories = false
    for _i, p in ipairs(self._manifest and self._manifest.plugins or {}) do
        if json_str(p.category) ~= "" then has_categories = true break end
    end
    if has_categories and not self._list_category then
        local grouped = {}
        for _i, group in ipairs(PMLogic.groupByCategory(items)) do
            grouped[#grouped + 1] = {
                text           = "\u{25B8} " .. category_label(group.id),
                mandatory      = tostring(#group.items),
                bold           = true,
                select_enabled = false,
            }
            for _j, item in ipairs(group.items) do grouped[#grouped + 1] = item end
        end
        items = grouped
    end

    local subtitle_parts = {}
    if self._list_category then subtitle_parts[#subtitle_parts + 1] = category_label(self._list_category) end
    if filter ~= "" then subtitle_parts[#subtitle_parts + 1] = string.format(_("Filter: %s"), self._list_filter) end

    local menu_instance
    menu_instance = Menu:new{
        title               = _("Plugins"),
        subtitle            = #subtitle_parts > 0 and table.concat(subtitle_parts, " \u{00B7} ") or nil,
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
        if not item.callback then return end  -- a section header
        UIManager:close(self)
        item.callback()
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
    local body, err = fetch_url(MANIFEST_URL, TIMEOUT_LARGE)
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

-- The end of every bulk run: its summary lines, and -- when anything was
-- written -- the restart offer, asked once for the whole batch.
--
-- KOReader only loads plugin Lua at startup (see is_plugin_disabled above --
-- there is no live reload), so every file written by a run is inert until a
-- restart. This prompt used to be shown only when Plugin Manager had updated
-- *itself*, which meant a bulk run that updated thirty games ended on a bare
-- "30 plugin(s) updated" and nothing said the new code wasn't live yet: the
-- user opened a game, got the previous version's behaviour, and reasonably
-- concluded the update had not been delivered.
function PluginManager:_showSummary(parts, needs_restart, has_self)
    if has_self then
        parts[#parts + 1] = _("Please restart KOReader to apply the Plugin Manager update.")
    elseif needs_restart then
        parts[#parts + 1] = _("Please restart KOReader to apply the update.")
    end
    if has_self or needs_restart then
        self:askRestart(table.concat(parts, "\n"))
    else
        UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 6 })
    end
end

-- Lists the entries of `plugins` this KOReader can run, and the names of the
-- ones it cannot (min_koreader): bulk runs skip those and say so in their
-- summary instead of installing something that will not load.
function PluginManager:_splitCompatible(plugins)
    local ok, skipped = {}, {}
    for _i, p in ipairs(plugins) do
        if self:isCompatible(p) then
            ok[#ok + 1] = p
        else
            skipped[#skipped + 1] = string.format("%s (KOReader %s)", p.fullname or p.id, p.min_koreader)
        end
    end
    return ok, skipped
end

-- One dialog for a whole bulk run: a heading ("Updating 110 plugin(s)…"),
-- the current item ("12/110 · Boggle") and a Stop button. Updated in place
-- with a "ui" refresh of its own area, instead of the old close-one-
-- InfoMessage-show-the-next per plugin. Stop is honoured between items: the
-- run finishes the one in progress, then ends with its summary. Neither Back
-- nor a tap beside the dialog closes it -- the run would carry on unseen.
-- Returns an object with update(line), stopped(), close() and a writable
-- `heading`.
function PluginManager:_openProgress(heading)
    local prog = { heading = heading, stop_requested = false, closed = false }
    local function text()
        local t = { prog.heading }
        if prog.line then t[#t + 1] = prog.line end
        if prog.note then t[#t + 1] = prog.note end
        return table.concat(t, "\n")
    end
    function prog.refresh()
        if prog.closed then return end
        local d = prog.dialog
        d.title = text()
        if type(d.reinit) ~= "function" then return end
        pcall(function()
            local old = d.movable and d.movable.dimen
            if old and old.copy then old = old:copy() end
            d:reinit()
            UIManager:setDirty("all", function()
                local new = d.movable and d.movable.dimen
                if old and new and old.combine then return "ui", old:combine(new) end
                return "ui", new or old
            end)
        end)
    end
    function prog.update(_self, line)
        prog.line = line
        prog.refresh()
    end
    function prog.stopped() return prog.stop_requested end
    function prog.close()
        if prog.closed then return end
        prog.closed = true
        UIManager:close(prog.dialog)
    end
    local dialog = ButtonDialog:new{
        title       = text(),
        title_align = "center",
        buttons     = { {
            {
                text     = _("Stop"),
                callback = function()
                    if prog.stop_requested then return end
                    prog.stop_requested = true
                    prog.note = _("Stopping after the current one\u{2026}")
                    prog.refresh()
                end,
            },
        } },
    }
    dialog.onClose    = function() return true end
    dialog.onTapClose = function() return true end
    prog.dialog = dialog
    UIManager:show(dialog)
    return prog
end

-- Shared by doFullUpdate, doFullReinstall, Install everything and Import:
-- refreshes every shared library referenced by `to_process` (or already
-- installed), then installs each plugin in `to_process` one at a time, under
-- one progress dialog (see _openProgress) and with the reader kept awake
-- (see awake_guard) until the very end, whichever way the run ends.
-- `opts` lets callers customise the three user-facing strings without
-- duplicating this whole flow: nothing_to_do_text, done_text (takes one
-- %d, the count), progress_text (same). `opts.force_common` re-fetches the
-- shared libraries even when their .version stamp is already current.
-- `opts.skipped` lists plugins left out for needing a newer KOReader, for
-- the summary. `opts.progress`, if given, is a progress dialog the caller
-- owns (and closes): Install everything keeps one for plugins and patches.
-- `opts.on_done(parts, succeeded, has_self, stopped)`, if given, gets the
-- summary instead of it being shown (Import appends its GitHub installs);
-- `stopped` is true when the user pressed Stop.
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
    local needed_libs, lib_order = {}, {}
    for _, p in ipairs(manifest.plugins) do
        if p.common_lib and manifest[p.common_lib] and (installed[p.id] or to_process_ids[p.id])
           and not needed_libs[p.common_lib] then
            needed_libs[p.common_lib] = true
            lib_order[#lib_order + 1] = p.common_lib
        end
    end

    local total    = #to_process
    local failed   = {}
    local has_self = false

    local own_progress = not opts.progress
    local progress = opts.progress or self:_openProgress(total == 0 and _("Checking for updates\u{2026}")
        or string.format(opts.progress_text or _("Updating %d plugin(s)\u{2026}"), total))
    local release = awake_guard()

    -- Every way out of the run goes through here first.
    local function leave()
        if own_progress then progress:close() end
        release()
    end

    local function skipped_line(parts)
        if opts.skipped and #opts.skipped > 0 then
            parts[#parts + 1] = string.format(_("Skipped, needs a newer KOReader: %s"), table.concat(opts.skipped, ", "))
        end
    end

    local function nothing_to_do()
        local removed_renamed = safe_call(function() return self:_cleanupRenamed(manifest) end) or {}
        local parts = {}
        parts[#parts + 1] = opts.nothing_to_do_text or _("All plugins are up to date.")
        for _i, fullname in ipairs(removed_renamed) do
            parts[#parts + 1] = string.format(_("Removed superseded %s."), fullname)
        end
        skipped_line(parts)
        leave()
        self:refreshHome()
        if opts.on_done then return opts.on_done(parts, 0, false, false) end
        UIManager:show(InfoMessage:new{
            text    = table.concat(parts, "\n"),
            timeout = 4,
        })
    end

    -- `done`: how many plugins were attempted.
    local function finish(done, stopped)
        local removed_renamed = safe_call(function() return self:_cleanupRenamed(manifest) end) or {}
        local parts = {}
        if stopped then
            parts[#parts + 1] = string.format(_("Stopped after %d/%d."), done, total)
            if #failed > 0 then
                parts[#parts + 1] = _("Failures:")
                for _, f in ipairs(failed) do parts[#parts + 1] = f end
            end
        elseif #failed > 0 then
            parts[#parts + 1] = string.format(
                _("%d/%d done. Failures:"), total - #failed, total)
            for _, f in ipairs(failed) do parts[#parts + 1] = f end
        else
            parts[#parts + 1] = string.format(opts.done_text or _("%d plugin(s) updated/installed."), total)
        end
        for _i, fullname in ipairs(removed_renamed) do
            parts[#parts + 1] = string.format(_("Removed superseded %s."), fullname)
        end
        skipped_line(parts)
        local succeeded = done - #failed
        leave()
        self:refreshHome()
        if opts.on_done then return opts.on_done(parts, succeeded, has_self, stopped) end
        self:_showSummary(parts, succeeded > 0, has_self)
    end

    local function step(i)
        if i > total then return finish(total, false) end
        if progress:stopped() then return finish(i - 1, true) end
        local p = to_process[i]
        progress:update(string.format(_("%d/%d \u{00b7} %s"), i, total, p.fullname or p.id))
        -- A short delay rather than nextTick: the dialog repaints, and a tap
        -- on Stop made during the previous plugin is read, before the next
        -- one starts.
        UIManager:scheduleIn(0.1, function()
            run_async(function() return self:installPlugin(p, manifest) end, function(ok, err)
                if not ok then
                    logger.warn("PluginManager: install failed for", p.id, ":", err)
                    failed[#failed + 1] = (p.fullname or p.id) .. ": " .. (err or "?")
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
        end)
    end

    if #lib_order > 0 then progress:update(_("Shared libraries\u{2026}")) end
    UIManager:scheduleIn(0.2, function()
        run_async(function()
            for _i, lib_key in ipairs(lib_order) do
                local ok, err = safe_call(function()
                    return self:ensureCommon(manifest, lib_key, opts.force_common)
                end)
                if not ok then
                    logger.warn("PluginManager: " .. lib_key .. " error:", err)
                    return false, err
                end
            end
            return true
        end, function(ok, err)
            if not ok then
                local text = _("Shared library error:") .. "\n" .. (err or "?")
                leave()
                -- A caller with more to do after the plugins (Import's GitHub
                -- installs, Install everything's patches) still gets to run it,
                -- with this error at the top of its summary.
                if opts.on_done then return opts.on_done({ text }, 0, false, false) end
                UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
                return
            end
            if total == 0 then return nothing_to_do() end
            step(1)
        end)
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

-- What Update does with `manifest`: the updates (the same list the home
-- screen counts), plus every plugin not installed yet -- Update has always
-- installed the whole catalogue. Anything needing a newer KOReader is
-- skipped and named. Shared with Install everything, which runs exactly
-- this before its patches.
function PluginManager:_planFullUpdate(manifest)
    local installed        = self:scanInstalled()
    local updates, blocked = self:pendingUpdates(manifest, installed)
    local candidates       = {}
    for _i, p in ipairs(manifest.plugins) do
        if not installed[p.id] then candidates[#candidates + 1] = p end
    end
    local new_ok, new_skipped = self:_splitCompatible(candidates)
    local to_process = {}
    for _i, p in ipairs(updates) do to_process[#to_process + 1] = p end
    for _i, p in ipairs(new_ok)  do to_process[#to_process + 1] = p end
    local _ok, skipped = self:_splitCompatible(blocked)
    for _i, name in ipairs(new_skipped) do skipped[#skipped + 1] = name end
    return {
        installed  = installed,
        to_process = to_process,
        skipped    = skipped,
        n_update   = #updates,
        n_new      = #new_ok,
    }
end

function PluginManager:_doFullUpdate()
    local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local manifest = self:_fetchManifest()
        if not manifest then return end

        local plan = self:_planFullUpdate(manifest)
        self:_refreshDiscoverLinkedVersions(plan.installed, function()
            self:_runBulkInstall(manifest, plan.to_process, { skipped = plan.skipped })
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
                self:refreshHome()
                UIManager:show(InfoMessage:new{
                    text    = string.format(_("%d plugin(s) removed."), total),
                    timeout = 5,
                })
                return
            end
            local inst = to_remove[i]
            local inst_path = PathGuard.pluginPath(_plugins_dir, inst.dir)
            if inst_path then rm_rf(inst_path) end
            local backup = backup_path(inst.dir)
            if backup then rm_rf(backup) end
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
        local candidates = {}
        for _, p in ipairs(manifest.plugins) do
            if installed[p.id] then
                candidates[#candidates + 1] = p
            end
        end
        -- Reinstall fetches the manifest's (latest) version, so the same
        -- KOReader requirement applies as for an update.
        local to_process, skipped = self:_splitCompatible(candidates)

        self:_runBulkInstall(manifest, to_process, {
            nothing_to_do_text = _("No plugins installed."),
            done_text          = _("%d plugin(s) reinstalled."),
            progress_text      = _("Reinstalling %d plugin(s)\u{2026}"),
            force_common       = true,
            skipped            = skipped,
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
            self:askRestart(string.format(_("%s installed.\nRestart KOReader to apply."), item.name))
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

-- Installs `items` one at a time, with progress, every one shielded by
-- safe_call so a bad file cannot stop the rest; then on_done(succeeded,
-- failed), failed being "name: error" lines. Shared by "Install all N
-- patches" and Install everything.
-- `progress`, if given, is a bulk run's progress dialog (Install
-- everything): the batch reports into it and honours its Stop button, and
-- on_done gets a third argument, true when stopped.
function PluginManager:_installPatchBatch(items, on_done, progress)
    local release = awake_guard()
    local total, failed = #items, {}
    local function step(i)
        if i > total then
            release()
            return on_done(total - #failed, failed, false)
        end
        if progress and progress:stopped() then
            release()
            return on_done(i - 1 - #failed, failed, true)
        end
        local item = items[i]
        local msg
        if progress then
            progress:update(string.format(_("%d/%d \u{00b7} %s"), i, total, item.name))
        else
            msg = InfoMessage:new{
                text = string.format(_("%d/%d  %s\u{2026}"), i, total, item.name),
            }
            UIManager:show(msg)
        end
        UIManager:scheduleIn(0.1, function()
            if msg then UIManager:close(msg) end
            local ok, err = safe_call(function() return self:installPatchFile(item) end)
            if not ok then failed[#failed + 1] = item.name .. ": " .. (err or "?") end
            step(i + 1)
        end)
    end
    step(1)
end

function PluginManager:installAllPatches(items)
    local total = #items
    self:_installPatchBatch(items, function(_succeeded, failed)
        local parts = {}
        if #failed > 0 then
            parts[#parts + 1] = string.format(_("%d/%d installed. Failures:"), total - #failed, total)
            for _, f in ipairs(failed) do parts[#parts + 1] = f end
            if #failed < total then
                parts[#parts + 1] = _("Restart KOReader to apply.")
                self:askRestart(table.concat(parts, "\n"))
            else
                UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 8 })
            end
        else
            parts[#parts + 1] = string.format(_("%d patch(es) installed.\nRestart KOReader to apply."), total)
            self:askRestart(table.concat(parts, "\n"))
        end
    end)
end

function PluginManager:confirmInstallAllPatches(items)
    UIManager:show(ConfirmBox:new{
        text        = string.format(_("Install all %d patches shown?"), #items),
        ok_text     = _("Install all"),
        ok_callback = function() self:installAllPatches(items) end,
    })
end

-- ---------------------------------------------------------------------------
-- Install everything (home screen): Update, then the manifest's patches
-- ---------------------------------------------------------------------------

-- The git blob sha of `body` -- what GitHub's contents API reports as a
-- file's `sha` -- so a patch already on the device can be compared with the
-- repository's copy by content, whoever installed it. nil when KOReader's
-- ffi/sha2 is missing; the sha recorded at install time is used instead.
local _sha1
local function git_blob_sha(body)
    if _sha1 == nil then
        local ok, sha2 = pcall(require, "ffi/sha2")
        _sha1 = ok and type(sha2) == "table" and sha2.sha1 or false
    end
    if not _sha1 or not body then return nil end
    local ok, h = pcall(_sha1, "blob " .. #body .. "\0" .. body)
    return ok and h or nil
end

-- The patches on the device as PMLogic.planPatchInstalls wants them:
-- filename -> {disabled, sha}.
function PluginManager:patchStates()
    local states = {}
    for name, inst in pairs(self:scanInstalledPatches()) do
        local link = self:getPatchInstall(name)
        states[name] = {
            disabled = inst.disabled,
            sha      = git_blob_sha(read_file(_patches_dir .. "/" .. inst.file))
                or (link and link.sha) or nil,
        }
    end
    return states
end

-- Lists every patch file of every `patch_repos` repository of the manifest.
-- One entry per repository, {repo, items} or {repo, err}: a repository that
-- cannot be listed (rate limit, renamed, network) is reported, never fatal.
function PluginManager:_listManifestPatches(manifest)
    local results = {}
    for _i, repo in ipairs(PMLogic.patchRepos(manifest)) do
        local items, err = safe_call(function() return self:listRepoPatchFiles(repo) end)
        if items then
            results[#results + 1] = { full_name = repo.full_name, items = items }
        else
            results[#results + 1] = { full_name = repo.full_name, err = err or "?" }
        end
    end
    return results
end

function PluginManager:doInstallEverything()
    when_online(function() self:_doInstallEverything() end)
end

-- Fetches the plugin list, works out what Update would do and which
-- patches the manifest's repositories would add or change, and confirms
-- with those numbers before touching anything.
function PluginManager:_doInstallEverything()
    local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local manifest = self:_fetchManifest()
        if not manifest then return end
        local plan = self:_planFullUpdate(manifest)

        local listing = InfoMessage:new{ text = _("Loading patches\u{2026}") }
        UIManager:show(listing)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(listing)
            local repo_results = self:_listManifestPatches(manifest)
            local all_items = {}
            for _i, r in ipairs(repo_results) do
                for _j, it in ipairs(r.items or {}) do all_items[#all_items + 1] = it end
            end
            local patch_plan = PMLogic.planPatchInstalls(all_items, self:patchStates())
            local counts     = PMLogic.everythingCounts(plan.n_update, plan.n_new, repo_results, patch_plan)

            local lines = {}
            local function notes()
                if #plan.skipped > 0 then
                    lines[#lines + 1] = string.format(_("Skipped, needs a newer KOReader: %s"), table.concat(plan.skipped, ", "))
                end
                if counts.patches_disabled > 0 then
                    local names = {}
                    for _i, it in ipairs(patch_plan.disabled) do names[#names + 1] = it.name end
                    lines[#lines + 1] = string.format(_("Left disabled: %s"), table.concat(names, ", "))
                end
                for _i, r in ipairs(repo_results) do
                    if r.err then
                        lines[#lines + 1] = string.format(_("Could not list patches from %s: %s"), r.full_name, r.err)
                    end
                end
            end

            -- Nothing to confirm, but the run still happens: like Update
            -- with nothing outdated, it refreshes a shared library whose
            -- version moved on its own, and its summary says all is current.
            if counts.nothing_to_do then
                return self:_runInstallEverything(manifest, plan, patch_plan, repo_results)
            end

            lines[#lines + 1] = _("Install everything?")
            lines[#lines + 1] = string.format(_("Plugins: %d to install, %d to update."), counts.plugins_new, counts.plugins_update)
            if counts.repos > 0 then
                lines[#lines + 1] = string.format(_("Patches: %d to install from %d repositories."), counts.patches, counts.repos)
            end
            notes()
            UIManager:show(ConfirmBox:new{
                text        = table.concat(lines, "\n"),
                ok_text     = _("Install"),
                ok_callback = function()
                    self:_runInstallEverything(manifest, plan, patch_plan, repo_results)
                end,
            })
        end)
    end)
end

-- Update's own bulk run, then the patches, then one summary and one
-- restart prompt. The patch part runs whatever the plugin part did (even a
-- shared-library error), and its own failures are added to the plugin
-- results rather than replacing them.
function PluginManager:_runInstallEverything(manifest, plan, patch_plan, repo_results)
    -- Held across both halves, and one progress dialog for both.
    local release = awake_guard()
    self:_refreshDiscoverLinkedVersions(plan.installed, function()
        local progress = self:_openProgress(#plan.to_process == 0 and _("Checking for updates\u{2026}")
            or string.format(_("Updating %d plugin(s)\u{2026}"), #plan.to_process))
        local function summary(parts, needs_restart, has_self)
            progress:close()
            release()
            self:_showSummary(parts, needs_restart, has_self)
        end
        self:_runBulkInstall(manifest, plan.to_process, {
            skipped  = plan.skipped,
            progress = progress,
            on_done  = function(parts, succeeded, has_self, stopped)
                -- Stop ends the whole run: the patches are not started.
                if stopped then return summary(parts, succeeded > 0, has_self) end
                local function finish(p_succeeded, p_failed, p_stopped)
                    if #repo_results > 0 then
                        local total = #patch_plan.install
                        if p_stopped then
                            parts[#parts + 1] = string.format(_("Patches: stopped after %d/%d."), p_succeeded + #p_failed, total)
                            if #p_failed > 0 then
                                parts[#parts + 1] = _("Failures:")
                                for _i, f in ipairs(p_failed) do parts[#parts + 1] = f end
                            end
                        elseif total == 0 then
                            parts[#parts + 1] = _("All patches are up to date.")
                        elseif #p_failed > 0 then
                            parts[#parts + 1] = string.format(_("Patches: %d/%d installed. Failures:"), p_succeeded, total)
                            for _i, f in ipairs(p_failed) do parts[#parts + 1] = f end
                        else
                            parts[#parts + 1] = string.format(_("%d patch(es) installed."), p_succeeded)
                        end
                    end
                    if #patch_plan.disabled > 0 then
                        local names = {}
                        for _i, it in ipairs(patch_plan.disabled) do names[#names + 1] = it.name end
                        parts[#parts + 1] = string.format(_("Left disabled: %s"), table.concat(names, ", "))
                    end
                    for _i, r in ipairs(repo_results) do
                        if r.err then
                            parts[#parts + 1] = string.format(_("Could not list patches from %s: %s"), r.full_name, r.err)
                        end
                    end
                    summary(parts, succeeded + p_succeeded > 0, has_self)
                end
                progress.heading = _("Patches")
                local ok, err = safe_call(function()
                    self:_installPatchBatch(patch_plan.install, finish, progress)
                    return true
                end)
                if not ok then
                    parts[#parts + 1] = _("Install failed:") .. " " .. (err or "?")
                    summary(parts, succeeded > 0, has_self)
                end
            end,
        })
    end)
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
        title       = _("Search GitHub patches"),
        description = _("Type user:NAME to browse every patch repository from one GitHub account."),
        input       = self._discover_patches_filter or "",
        input_hint  = _("Search text (optional)\u{2026}"),
        buttons     = {{
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

-- Same two modes as _showDiscoverDialog: a search (topic + name, paged), or
-- `user:NAME`, one account's patch repositories in a single listing.
function PluginManager:_showDiscoverPatchesDialog(page, accumulated)
    local owner_query = PMLogic.ownerQuery(self._discover_patches_filter)

    local notice = InfoMessage:new{ text = _("Searching GitHub\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local results, err, total_count, has_more
        if owner_query then
            results, err = safe_call(function() return self:listGithubOwnerPatchRepos(owner_query) end)
        else
            results, err, total_count, has_more = self:searchGithubPatchRepos{
                text = self._discover_patches_filter,
                sort = self:getDiscoverPatchesSort(),
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
                    text    = string.format(_("No patch repositories found for \u{201c}%s\u{201d}."), owner_query),
                    timeout = 4,
                })
            elseif self._discover_patches_filter then
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
        if not owner_query and has_more then
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
            self:askRestart(iref.disabled
                and string.format(_("%s enabled.\nRestart KOReader to apply."), iref.name)
                or  string.format(_("%s disabled.\nRestart KOReader to apply."), iref.name))
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
    local ok_up, userpatch = pcall(require, "userpatch")
    local all_disabled = ok_up and userpatch.arePatchesDisabled and userpatch.arePatchesDisabled()

    local entries = {
        { text = _("Installed patches"),       callback = function() self:showInstalledPatchesList() end },
        { text = _("Discover patches\u{2026}"), callback = function() self:showDiscoverPatchesDialog() end },
    }
    if ok_up and userpatch.togglePatchesDisabled then
        entries[#entries + 1] = {
            text     = all_disabled and _("Enable all patches") or _("Disable all patches"),
            -- The label and the subtitle both change: rebuild the screen.
            reopen   = true,
            callback = function()
                userpatch.togglePatchesDisabled()
                -- askRestart lands on the next tick, so it shows on top of
                -- this screen once rebuilt.
                self:askRestart(all_disabled
                    and _("All patches enabled.\nRestart KOReader to apply.")
                    or  _("All patches disabled.\nRestart KOReader to apply."))
            end,
        }
    end

    local subtitle
    if ok_up then
        subtitle = all_disabled and _("All patches: OFF") or _("All patches: ON")
    end
    self:showScreenMenu(_("Patches"), subtitle, entries, function()
        self:showPatchesMainDialog()
    end)
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

-- A full-screen menu, like the plugin list and like every game in the fleet,
-- rather than a pop-up. entries are { text, callback [, reopen] }. A chosen
-- entry opens on top of it, so closing a list comes back here instead of
-- dropping out to the book; an entry marked `reopen` changes this screen's own
-- labels, so the screen is closed and `rebuild` builds it afresh.
local function screen_menu_items(entries)
    local items = {}
    for _i, entry in ipairs(entries) do
        items[#items + 1] = { text = entry.text, entry = entry }
    end
    return items
end

function PluginManager:showScreenMenu(title, subtitle, entries, rebuild)
    local Menu   = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = screen_menu_items(entries)

    local menu_instance = Menu:new{
        title      = title,
        subtitle   = subtitle,
        item_table = items,
        width      = Screen:getWidth(),
        height     = Screen:getHeight(),
    }
    function menu_instance:onMenuChoice(item)
        local entry = item.entry
        if entry.reopen then
            UIManager:close(self)
            entry.callback()
            if rebuild then rebuild() end
        else
            entry.callback()
        end
    end
    UIManager:show(menu_instance)
    return menu_instance
end

-- "Update", or "Update (3)" when the cached manifest already shows three
-- updates (the same count pendingUpdates gives the Update button). Read from
-- the cache and a local scan only: opening the home screen never touches
-- the network.
function PluginManager:updateEntryText()
    local n = #self:pendingUpdates(self._manifest)
    if n > 0 then return string.format(_("Update (%d)"), n) end
    return _("Update")
end

function PluginManager:homeEntries()
    return {
        { text = self:updateEntryText(), callback = function() self:doFullUpdate() end },
        { text = _("Install everything\u{2026}"), callback = function() self:doInstallEverything() end },
        {
            text     = _("Reinstall all\u{2026}"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text        = _("Reinstall every installed plugin?\nThis re-downloads all their files, including shared libraries."),
                    ok_text     = _("Reinstall all"),
                    ok_callback = function() self:doFullReinstall() end,
                })
            end,
        },
        {
            text     = _("Remove all\u{2026}"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text        = _("Remove every plugin managed by Plugin Manager?\nAll their files will be deleted. Plugin Manager itself and any other plugin on your device (including KOReader's own) are left untouched."),
                    ok_text     = _("Remove all"),
                    ok_callback = function() self:doRemoveAll() end,
                })
            end,
        },
        { text = _("Plugin list"),                   callback = function() self:showPluginList() end },
        { text = _("Discover plugins\u{2026}"),       callback = function() self:showDiscoverDialog() end },
        { text = _("Patches\u{2026}"),                callback = function() self:showPatchesMainDialog() end },
        { text = _("Ignored updates\u{2026}"),        callback = function() self:showIgnoredDialog() end },
        { text = _("Export installed list"),           callback = function() self:exportInstalled() end },
        { text = _("Import list\u{2026}"),             callback = function() self:confirmImport() end },
    }
end

function PluginManager:showMainDialog()
    local menu = self:showScreenMenu(_("Plugin Manager"), self:wifiStatusLine(), self:homeEntries())
    -- Remembered while it is open, so an install, update, ignore or remove
    -- made from a screen above it can refresh its update count in place.
    self._home_menu = menu
    local pm = self
    local orig_close = menu.onCloseWidget
    function menu:onCloseWidget()
        if pm._home_menu == self then pm._home_menu = nil end
        if orig_close then return orig_close(self) end
    end
end

-- Recounts updates on the home screen, if it is open. Cheap -- cached
-- manifest plus a local scan -- and silent on any error: a stale label must
-- never break the action that triggered the refresh.
function PluginManager:refreshHome()
    local menu = self._home_menu
    if not menu then return end
    pcall(function()
        menu:switchItemTable(nil, screen_menu_items(self:homeEntries()), -1)
    end)
end

-- ---------------------------------------------------------------------------
-- Export / import of the installed list
-- ---------------------------------------------------------------------------

-- JSON, in KOReader's data directory (next to settings/ and plugins/), so it
-- is easy to find over USB and to copy to another reader: a person can read
-- it, and it holds no settings, only what to install (see PMLogic.buildExport).
local EXPORT_FILE = "pluginmanager-export.json"

local function export_path()
    return DataStorage:getDataDir() .. "/" .. EXPORT_FILE
end

function PluginManager:exportInstalled()
    if not self._manifest then
        UIManager:show(InfoMessage:new{
            text    = _("Press Update once first: the export needs the plugin list."),
            timeout = 5,
        })
        return
    end
    self:ensureSettings()
    local data = PMLogic.buildExport(
        self:scanInstalled(),
        self._manifest.plugins,
        self.settings:readSetting("discover_installs") or {},
        os.date("%Y-%m-%d")
    )
    local ok, err = write_file(export_path(), PMLogic.encodeJson(data) .. "\n")
    if not ok then
        UIManager:show(InfoMessage:new{
            text    = _("Export failed:") .. "\n" .. tostring(err),
            timeout = 5,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text    = string.format(_("%d plugin(s) exported to:\n%s\nCopy this file to the same place on another reader, then use Import there."),
            #data.plugins + #data.github, export_path()),
        timeout = 10,
    })
end

-- Reads the export file, fetches the live manifest and shows what would be
-- installed before anything is. Installs go through the bulk path
-- (_runBulkInstall: per-plugin safe_call, one summary, one restart prompt),
-- then any GitHub-linked plugins through installAllFromGithub.
function PluginManager:confirmImport()
    local body = read_file(export_path())
    if not body then
        UIManager:show(InfoMessage:new{
            text    = string.format(_("No export file found at:\n%s\nUse \u{201c}Export installed list\u{201d} on the other reader and copy the file here."), export_path()),
            timeout = 8,
        })
        return
    end
    local data = parse_json(body)
    if type(data) ~= "table" or data.format ~= PMLogic.EXPORT_FORMAT then
        UIManager:show(InfoMessage:new{
            text    = string.format(_("%s is not a Plugin Manager export."), export_path()),
            timeout = 6,
        })
        return
    end
    when_online(function()
        local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
        UIManager:show(notice)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(notice)
            local manifest = self:_fetchManifest()
            if not manifest then return end
            local plan = PMLogic.planImport(data, manifest.plugins, self:scanInstalled())
            if not plan then
                UIManager:show(InfoMessage:new{
                    text    = string.format(_("%s is not a Plugin Manager export."), export_path()),
                    timeout = 6,
                })
                return
            end
            local to_install, skipped = self:_splitCompatible(plan.install)
            if #to_install == 0 and #plan.github == 0 then
                local parts = { _("Nothing to import: every plugin in the list is already installed.") }
                if #plan.unknown > 0 then
                    parts[#parts + 1] = string.format(_("No longer in the repository: %s"), table.concat(plan.unknown, ", "))
                end
                if #skipped > 0 then
                    parts[#parts + 1] = string.format(_("Skipped, needs a newer KOReader: %s"), table.concat(skipped, ", "))
                end
                UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 6 })
                return
            end
            local names = {}
            for _i, p in ipairs(to_install) do names[#names + 1] = p.fullname end
            for _i, r in ipairs(plan.github) do names[#names + 1] = r.full_name .. " (GitHub)" end
            local parts = { string.format(_("Install %d plugin(s)?"), #names), table.concat(names, ", ") }
            if #plan.present > 0 then
                parts[#parts + 1] = string.format(_("Already installed, left as is: %d"), #plan.present)
            end
            if #plan.unknown > 0 then
                parts[#parts + 1] = string.format(_("No longer in the repository: %s"), table.concat(plan.unknown, ", "))
            end
            if #skipped > 0 then
                parts[#parts + 1] = string.format(_("Skipped, needs a newer KOReader: %s"), table.concat(skipped, ", "))
            end
            if #plan.github > 0 then
                parts[#parts + 1] = _("GitHub plugins are third-party code \u{2014} only install plugins you trust.")
            end
            UIManager:show(ConfirmBox:new{
                text        = table.concat(parts, "\n"),
                ok_text     = _("Install"),
                ok_callback = function() self:_runImport(manifest, to_install, plan.github, skipped) end,
            })
        end)
    end)
end

function PluginManager:_runImport(manifest, to_install, github, skipped)
    local release = awake_guard()  -- across both halves
    self:_runBulkInstall(manifest, to_install, {
        nothing_to_do_text = _("No plugin to install from the repository."),
        done_text          = _("%d plugin(s) installed."),
        progress_text      = _("Installing %d plugin(s)\u{2026}"),
        skipped            = skipped,
        on_done            = function(parts, succeeded, has_self, stopped)
            if #github == 0 or stopped then
                release()
                return self:_showSummary(parts, succeeded > 0, has_self)
            end
            self:installAllFromGithub(github, function(gparts, gsucceeded)
                for _i, line in ipairs(gparts) do parts[#parts + 1] = line end
                release()
                self:_showSummary(parts, succeeded + gsucceeded > 0, has_self)
            end)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- KOReader plugin lifecycle
-- ---------------------------------------------------------------------------

function PluginManager:init()
    -- Resolves settings_file, which KOReader reads off the instance to
    -- offer "Delete plugin settings" -- it must exist before the plugin
    -- dialog is built, not merely on first getSetting().
    self:ensureSettings()
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
