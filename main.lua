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

local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = lrequire("i18n")

-- lrequire, not require: package.loaded["i18n"] is a single slot shared by
-- every plugin on the device and the first one loaded wins it. This plugin
-- is standalone (no common/), so it must not take that slot from the game
-- plugins, nor merge its own strings into their shared table. Its
-- translations (i18n_fr.lua) load on the first string translated into
-- that language, so English needs none of them.

local AUTO_CHECK_TTL = 86400  -- re-check automatically at most once every 24 h

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

-- KOReader builds a new instance of this plugin with every FileManager and
-- every ReaderUI, so once each time a book is opened and again when it is
-- closed. Each of them used to reopen the settings file (which holds the
-- whole cached manifest, ~230 KB) and decode the manifest again: the most
-- expensive plugin start of the fleet, paid twice per book on a slow reader.
-- The settings object and the decoded manifest are kept here, at module
-- level, and shared by every instance. Nothing modifies a decoded manifest,
-- and a new one is only ever stored through saveManifestCache.
local _shared_settings      = nil  -- { path, settings }
local _shared_manifest_json = nil  -- the manifest_json string last decoded
local _shared_manifest      = nil  -- ... and its decoded table

local function file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

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
        -- Reused only while the file is still there: once "Delete plugin
        -- settings" has removed it, start from an empty one again.
        local shared = _shared_settings
        if shared and shared.path == self.settings_file and file_exists(shared.path) then
            self.settings = shared.settings
        else
            self.settings = LuaSettings:open(self.settings_file)
            _shared_settings = { path = self.settings_file, settings = self.settings }
        end
    end
end

function PluginManager:saveManifestCache(manifest)
    self:ensureSettings()
    local ok, json = pcall(require, "rapidjson")
    local json_str = ok and json.encode(manifest) or "{}"
    self.settings:saveSetting("manifest_json", json_str)
    _shared_manifest_json, _shared_manifest = json_str, manifest
    self.settings:saveSetting("last_check",    os.time())
    self.settings:flush()
    self._last_check = os.time()
end

-- The decoded manifest (~350 KB) is only needed once the Plugin Manager is
-- actually used: an instance decodes it -- or takes the one another
-- instance already decoded -- on its first getManifest(), not in init().
function PluginManager:getManifest()
    if not self._manifest then self:loadCachedManifest() end
    return self._manifest
end

function PluginManager:loadCachedManifest()
    self:ensureSettings()
    local json_str   = self.settings:readSetting("manifest_json")
    local last_check = self.settings:readSetting("last_check")
    if not json_str then return end
    local manifest
    if json_str == _shared_manifest_json then
        manifest = _shared_manifest
    else
        manifest = parse_json(json_str)
        _shared_manifest_json, _shared_manifest = json_str, manifest
    end
    if manifest and manifest.plugins then
        self._manifest   = manifest
        self._last_check = last_check or 0
    end
end

-- ---------------------------------------------------------------------------
-- JSON  (rapidjson is bundled with KOReader)
-- ---------------------------------------------------------------------------

-- parse_json is a global on purpose: manager.lua uses it too.
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
-- The rest of the plugin: manager.lua, loaded on first use
-- ---------------------------------------------------------------------------

-- KOReader loads every plugin's main.lua at startup and keeps it for the
-- whole session, used or not. All the Plugin Manager needs until then is
-- above: its menu entry, the settings / manifest cache and the daily
-- background check. Everything else -- screens, installs, updates, Discover,
-- patches (~200 KB of code) -- lives in manager.lua, which adds its methods
-- to PluginManager the first time one of them is called. Each one is a stub
-- here until then; test_startup_spec.lua checks this list against
-- manager.lua.
local MANAGER_METHODS = {
    "isVersionIgnored",
    "setIgnoredVersion",
    "askRestart",
    "isCompatible",
    "confirmCompatible",
    "getDiscoverInstall",
    "recordDiscoverInstall",
    "forgetDiscoverInstall",
    "getDiscoverUpdateCache",
    "setDiscoverUpdateCache",
    "searchGithubPlugins",
    "listGithubOwnerPlugins",
    "listGithubOwnerPatchRepos",
    "scanInstalled",
    "pendingUpdates",
    "_silentCheck",
    "showIgnoredDialog",
    "ensureCommon",
    "getBackupVersion",
    "backupPlugin",
    "restoreBackup",
    "installPlugin",
    "_doInstall",
    "describeExistingInstall",
    "installFromGithubRepo",
    "installAllFromGithub",
    "getDiscoverSort",
    "cycleDiscoverSort",
    "showDiscoverFilterDialog",
    "showDiscoveredRepoDialog",
    "showDiscoverDialog",
    "confirmInstallAll",
    "confirmLinkRepo",
    "_showDiscoverDialog",
    "_doRemove",
    "_cleanupRenamed",
    "scanUnwanted",
    "showUnwantedDialog",
    "removeUnwanted",
    "_displayReadme",
    "_fetchAndShowReadme",
    "showReadme",
    "showWhatsNew",
    "showScreenshot",
    "showInstalledDialog",
    "showAvailableDialog",
    "_doRestore",
    "checkDiscoverUpdate",
    "verifyAndLinkRepo",
    "showLinkRepoDialog",
    "showLocalOnlyDialog",
    "getListSort",
    "cycleListSort",
    "showCategoryFilterDialog",
    "showPluginListFilterDialog",
    "showPluginList",
    "_fetchManifest",
    "_showSummary",
    "_splitCompatible",
    "_openProgress",
    "_runBulkInstall",
    "doFullUpdate",
    "_refreshDiscoverLinkedVersions",
    "_planFullUpdate",
    "_doFullUpdate",
    "doFullReinstall",
    "doRemoveAll",
    "_doRemoveAll",
    "_doFullReinstall",
    "searchGithubPatchRepos",
    "listRepoPatchFiles",
    "getPatchInstall",
    "recordPatchInstall",
    "forgetPatchInstall",
    "scanInstalledPatches",
    "installPatchFile",
    "_doInstallPatch",
    "setPatchDisabled",
    "_installPatchBatch",
    "installAllPatches",
    "confirmInstallAllPatches",
    "patchStates",
    "_listManifestPatches",
    "doInstallEverything",
    "_doInstallEverything",
    "_runInstallEverything",
    "checkPatchUpdate",
    "getDiscoverPatchesSort",
    "cycleDiscoverPatchesSort",
    "showDiscoverPatchesFilterDialog",
    "showDiscoveredPatchDialog",
    "showPatchRepoDialog",
    "showDiscoverPatchesDialog",
    "_showDiscoverPatchesDialog",
    "showInstalledPatchDialog",
    "showInstalledPatchesList",
    "showPatchesMainDialog",
    "wifiStatusLine",
    "showScreenMenu",
    "updateEntryText",
    "homeEntries",
    "showMainDialog",
    "refreshHome",
    "exportInstalled",
    "confirmImport",
    "_runImport",
}

local _manager_loaded = false

local function load_manager()
    if _manager_loaded then return end
    _manager_loaded = true
    local ok, err = pcall(function()
        assert(loadfile(_dir .. "manager.lua"))(PluginManager)
    end)
    if not ok then
        _manager_loaded = false
        error(err, 0)
    end
end

PluginManager.MANAGER_METHODS = MANAGER_METHODS
PluginManager.isManagerLoaded = function() return _manager_loaded end

for _i, name in ipairs(MANAGER_METHODS) do
    local stub
    stub = function(self, ...)
        load_manager()
        local method = PluginManager[name]
        if method == stub then error("manager.lua does not define PluginManager:" .. name, 2) end
        return method(self, ...)
    end
    PluginManager[name] = stub
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
    -- Only the date of the last check is needed here; the cached manifest
    -- itself is decoded on first use (getManifest).
    if self.settings:readSetting("manifest_json") then
        self._last_check = self.settings:readSetting("last_check") or 0
    end

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