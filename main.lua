local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local _plugins_dir = _dir:match("^(.*)/[^/]+/$") or (_dir .. "..")

local ButtonDialog    = require("ui/widget/buttondialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("gettext")

local MANIFEST_URL   = "https://raw.githubusercontent.com/t2ym5u/koreader-plugins/master/manifest.json"
local AUTO_CHECK_TTL = 86400  -- re-check automatically at most once every 24 h

-- Shared-library keys: manifest.json top-level sections describing a
-- downloadable common/ bundle, one per shared-code family (see the
-- project-sudoku-common-architecture memory — game-common's ScreenBase and
-- sudoku-common's BaseScreen are NOT interchangeable). Each plugin_info
-- names the one it needs via plugin_info.common_lib, e.g. "common" or
-- "sudoku_common", which indexes straight into this list / into manifest.
local COMMON_LIB_KEYS = { "common", "sudoku_common" }

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

local function source_from_url(url)
    local user = url:match("raw%.githubusercontent%.com/([^/]+)/")
    if user then return user end
    return url:match("https?://([^/]+)/") or url
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

local function fetch_url(url)
    local ok1, https = pcall(require, "ssl.https")
    if not ok1 then return nil, _("ssl.https not available") end
    local ok2, ltn12 = pcall(require, "ltn12")
    if not ok2 then return nil, _("ltn12 not available") end
    local chunks = {}
    local result, status = https.request{
        url      = url,
        sink     = ltn12.sink.table(chunks),
        verify   = "none",
        protocol = "tlsv1_2",
    }
    if result and status == 200 then
        return table.concat(chunks)
    end
    return nil, string.format(_("HTTP %s"), tostring(status or "?"))
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

local function read_meta(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return {
        -- %f[%w] anchors to a word boundary so this doesn't match "name"
        -- inside "fullname".
        name     = src:match('%f[%w]name%s*=%s*"([^"]+)"'),
        fullname = src:match('fullname%s*=[^"]*"([^"]*)"')
               or  src:match('fullname%s*=.-%[%[([^%]]-)%]%]'),
        version  = src:match('version%s*=%s*"([^"]+)"'),
    }
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
            if entry:match("%.koplugin$") then
                local meta = read_meta(_plugins_dir .. "/" .. entry .. "/_meta.lua")
                if meta and meta.name then
                    installed[meta.name] = {
                        version  = meta.version or "?",
                        fullname = meta.fullname or meta.name,
                        dir      = entry,
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

    local urls = self:getRepoURLs()
    local results = {}
    for _, url in ipairs(urls) do
        local body = fetch_url(url)
        if body then
            local manifest = parse_json(body)
            if manifest and manifest.plugins then
                results[#results + 1] = { url = url, manifest = manifest }
            end
        end
    end
    if #results == 0 then return end
    local manifest = self:mergeManifests(results)
    self._manifest = manifest
    self:saveManifestCache(manifest)

    local installed = self:scanInstalled()
    local n_update  = 0
    for _, p in ipairs(manifest.plugins) do
        local inst = installed[p.id]
        if inst and is_newer(inst.version, p.version) then
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

-- ---------------------------------------------------------------------------
-- Multi-source helpers
-- ---------------------------------------------------------------------------

function PluginManager:getRepoURLs()
    self:ensureSettings()
    local urls = { MANIFEST_URL }
    local extra = self.settings:readSetting("extra_repos") or {}
    for _, u in ipairs(extra) do urls[#urls + 1] = u end
    return urls
end

function PluginManager:mergeManifests(results)
    local merged = { plugins = {} }
    local multi = #results > 1
    for _, r in ipairs(results) do
        local src = source_from_url(r.url)
        for _, lib_key in ipairs(COMMON_LIB_KEYS) do
            if not merged[lib_key] and r.manifest[lib_key] then
                merged[lib_key] = r.manifest[lib_key]
            end
        end
        for _, p in ipairs(r.manifest.plugins or {}) do
            local entry = {}
            for k, v in pairs(p) do entry[k] = v end
            if multi then entry._source = src end
            merged.plugins[#merged.plugins + 1] = entry
        end
    end
    return merged
end

function PluginManager:showManageReposDialog()
    self:ensureSettings()
    local extra = self.settings:readSetting("extra_repos") or {}
    local dlg
    local buttons = {}

    buttons[#buttons + 1] = {{
        text    = source_from_url(MANIFEST_URL) .. "  " .. _("(default)"),
        enabled = false,
    }}

    for i, url in ipairs(extra) do
        local idx = i
        buttons[#buttons + 1] = {
            { text = source_from_url(url), enabled = false },
            {
                text     = _("Remove"),
                callback = function()
                    UIManager:close(dlg)
                    table.remove(extra, idx)
                    self.settings:saveSetting("extra_repos", extra)
                    self.settings:flush()
                    self._manifest = nil
                    self:showManageReposDialog()
                end,
            },
        }
    end

    buttons[#buttons + 1] = {{
        text     = _("Add source\u{2026}"),
        callback = function()
            UIManager:close(dlg)
            local input = InputDialog:new{
                title      = _("Add plugin source"),
                input_hint = "https://raw.githubusercontent.com/user/repo/main/manifest.json",
                buttons    = {{
                    {
                        text     = _("Cancel"),
                        callback = function() UIManager:close(input) end,
                    },
                    {
                        text             = _("Add"),
                        is_enter_default = true,
                        callback         = function()
                            local url = input:getInputText():match("^%s*(.-)%s*$")
                            UIManager:close(input)
                            if url == "" or url == MANIFEST_URL then return end
                            for _, u in ipairs(extra) do
                                if u == url then return end
                            end
                            extra[#extra + 1] = url
                            self.settings:saveSetting("extra_repos", extra)
                            self.settings:flush()
                            self._manifest = nil
                            UIManager:show(InfoMessage:new{
                                text    = _("Source added. Press Update to load its plugins."),
                                timeout = 3,
                            })
                        end,
                    },
                }},
            }
            UIManager:show(input)
            input:onShowKeyboard()
        end,
    }}

    buttons[#buttons + 1] = {{
        text     = _("Close"),
        callback = function() UIManager:close(dlg) end,
    }}

    dlg = ButtonDialog:new{ title = _("Plugin sources"), buttons = buttons }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Install helpers
-- ---------------------------------------------------------------------------

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
        local spec = manifest[plugin_info.common_lib]
        local lib_relpath = "../" .. spec.dir
        local common_path = plugin_dir .. "/common"
        local lfs  = get_lfs()
        local mode = lfs and lfs.attributes(common_path, "mode")
        if mode ~= "link" and mode ~= "directory" then
            -- Prefer lfs.link (in-process syscall) over os.execute("ln -sf"):
            -- forking a subprocess for every single new plugin during a bulk
            -- "Install all new" run (potentially dozens in a row, unlike
            -- "Update all" where the symlink already exists and this branch
            -- is skipped) can exhaust memory on e-ink hardware and crash
            -- KOReader partway through the batch.
            local linked = false
            if lfs and lfs.link then
                local ok = pcall(lfs.link, lib_relpath, common_path, true)
                linked = ok and lfs.attributes(common_path, "mode") == "link"
            end
            if not linked then
                local rc = os.execute("ln -sf " .. lib_relpath .. " " .. common_path .. " 2>/dev/null")
                if rc ~= 0 then
                    local lib_dir = _plugins_dir .. "/" .. spec.dir
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
-- Remove
-- ---------------------------------------------------------------------------

function PluginManager:_doRemove(fullname, plugin_dir)
    rm_rf(_plugins_dir .. "/" .. plugin_dir)
    UIManager:show(InfoMessage:new{
        text    = string.format(_("%s removed."), fullname),
        timeout = 5,
    })
end

-- ---------------------------------------------------------------------------
-- Per-plugin dialogs
-- ---------------------------------------------------------------------------

function PluginManager:showInstalledDialog(plugin_info, inst_info, has_update)
    local dlg
    local buttons = {}

    if has_update then
        local pref = plugin_info
        buttons[#buttons + 1] = {{
            text     = string.format(_("Update to v%s"), plugin_info.version),
            callback = function()
                UIManager:close(dlg)
                self:_doInstall(pref, self._manifest)
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
    if has_update then
        title = title .. "  \u{2192}  v" .. plugin_info.version
    end
    if plugin_info.description and plugin_info.description ~= "" then
        title = title .. "\n" .. plugin_info.description
    end

    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

function PluginManager:showAvailableDialog(plugin_info)
    local dlg
    local title = plugin_info.fullname .. "  v" .. plugin_info.version
    if plugin_info.description and plugin_info.description ~= "" then
        title = title .. "\n" .. plugin_info.description
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
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

-- Dialog for a plugin installed locally but absent from the manifest.
function PluginManager:showLocalOnlyDialog(inst_info)
    local iref = inst_info
    UIManager:show(ConfirmBox:new{
        text        = string.format(
            _("Remove %s?\nThis plugin is not in the repository.\nAll its files will be deleted."),
            iref.fullname
        ),
        ok_text     = _("Remove"),
        ok_callback = function()
            self:_doRemove(iref.fullname, iref.dir)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Plugin list popup (paginated)
-- ---------------------------------------------------------------------------

function PluginManager:showPluginList()
    local Menu   = require("ui/widget/menu")
    local Screen = require("device/screen")

    local installed = self:scanInstalled()
    local items     = {}

    if not self._manifest then
        -- Offline: show only locally-installed plugins
        for _, inst in pairs(installed) do
            local iref = inst
            items[#items + 1] = {
                text      = iref.fullname,
                mandatory = "v" .. iref.version,
                callback  = function() self:showLocalOnlyDialog(iref) end,
            }
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("No plugins installed.\nPress Update to fetch the list."),
                timeout = 3,
            })
            return
        end
    else
        local known_ids = {}
        for _, p in ipairs(self._manifest.plugins) do
            known_ids[p.id] = true
            local inst = installed[p.id]
            if inst then
                local has_update = is_newer(inst.version, p.version)
                local detail = has_update
                    and ("v" .. inst.version .. " \u{2192} v" .. p.version)
                    or  ("v" .. inst.version)
                local entry = { plugin = p, inst = inst, has_update = has_update }
                items[#items + 1] = {
                    text      = inst.fullname,
                    mandatory = detail,
                    bold      = has_update,
                    callback  = function()
                        self:showInstalledDialog(entry.plugin, entry.inst, entry.has_update)
                    end,
                }
            else
                local pref = p
                items[#items + 1] = {
                    text      = p.fullname,
                    mandatory = "v" .. p.version,
                    dim       = true,
                    callback  = function() self:showAvailableDialog(pref) end,
                }
            end
        end
        -- Locally installed but absent from manifest
        for id, inst in pairs(installed) do
            if not known_ids[id] then
                local iref = inst
                items[#items + 1] = {
                    text      = inst.fullname,
                    mandatory = "v" .. inst.version .. " (local)",
                    callback  = function() self:showLocalOnlyDialog(iref) end,
                }
            end
        end
        table.sort(items, function(a, b) return a.text < b.text end)
    end

    local menu_instance
    menu_instance = Menu:new{
        title      = _("Plugins"),
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
-- Full update (fetch manifest + install new + update existing)
-- ---------------------------------------------------------------------------

function PluginManager:doFullUpdate()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        NetworkMgr:runWhenOnline(function() self:_doFullUpdate() end)
    else
        self:_doFullUpdate()
    end
end

function PluginManager:_doFullUpdate()
    local notice = InfoMessage:new{ text = _("Fetching plugin list\u{2026}") }
    UIManager:show(notice)
    UIManager:scheduleIn(0.2, function()
        UIManager:close(notice)
        local urls = self:getRepoURLs()
        local results, errors = {}, {}
        for _, url in ipairs(urls) do
            local body, err = fetch_url(url)
            if body then
                local manifest = parse_json(body)
                if manifest and manifest.plugins then
                    results[#results + 1] = { url = url, manifest = manifest }
                else
                    errors[#errors + 1] = source_from_url(url) .. ": " .. _("invalid manifest")
                end
            else
                errors[#errors + 1] = source_from_url(url) .. ": " .. (err or "?")
            end
        end
        if #results == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("Network error:") .. "\n" .. table.concat(errors, "\n"),
                timeout = 5,
            })
            return
        end
        local manifest = self:mergeManifests(results)
        self._manifest = manifest
        self:saveManifestCache(manifest)

        local installed  = self:scanInstalled()
        local to_process = {}

        for _, p in ipairs(manifest.plugins) do
            local inst = installed[p.id]
            if not inst or is_newer(inst.version, p.version) then
                to_process[#to_process + 1] = p
            end
        end

        -- Shared libraries must be refreshed independently of per-plugin
        -- version deltas: once every consuming plugin's own version is
        -- already current, to_process stops referencing common_lib, so a
        -- shared-lib-only bump (or a lib a previous run failed to pick up,
        -- e.g. mid-way through a PluginManager self-update) would otherwise
        -- never be retried. Check every common_lib used by anything
        -- installed or about to be installed on every run, even when no
        -- plugin file itself needs updating.
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
            local parts = {}
            if #errors > 0 then
                parts[#parts + 1] = string.format(_("%d source(s) unavailable"), #errors)
            end
            parts[#parts + 1] = _("All plugins are up to date.")
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
            local parts = {}
            if #errors > 0 then
                parts[#parts + 1] = string.format(_("%d source(s) unavailable"), #errors)
            end
            if #failed > 0 then
                parts[#parts + 1] = string.format(
                    _("%d/%d done. Failures:"), total - #failed, total)
                for _, f in ipairs(failed) do parts[#parts + 1] = f end
            else
                parts[#parts + 1] = string.format(_("%d plugin(s) updated/installed."), total)
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
                    logger.warn("PluginManager: update failed for", p.id, ":", err)
                    failed[#failed + 1] = p.fullname .. ": " .. (err or "?")
                elseif p.id == "pluginmanager" then
                    has_self = true
                end
                -- Always advance, even after a failure above: one broken
                -- plugin must not stop the rest of a bulk update.
                step(i + 1)
            end)
        end

        local init_msg = InfoMessage:new{
            text = string.format(_("Updating %d plugin(s)\u{2026}"), total),
        }
        UIManager:show(init_msg)
        UIManager:scheduleIn(0.2, function()
            UIManager:close(init_msg)
            step(1)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Main dialog
-- ---------------------------------------------------------------------------

function PluginManager:showMainDialog()
    local dlg
    dlg = ButtonDialog:new{
        title   = _("Plugin Manager"),
        buttons = {
            {{
                text     = _("Update"),
                callback = function()
                    UIManager:close(dlg)
                    self:doFullUpdate()
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
                text     = _("Manage sources\u{2026}"),
                callback = function()
                    UIManager:close(dlg)
                    self:showManageReposDialog()
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
