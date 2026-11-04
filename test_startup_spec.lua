-- Startup cost: KOReader loads every plugin's main.lua when it starts, and
-- keeps what it loaded for the whole session, whether the plugin is used or
-- not. main.lua therefore holds only the menu entry, the settings / manifest
-- cache and the background check; the rest (manager.lua, ~200 KB of code)
-- loads on the first call of one of its methods, and the translations load
-- for the UI language only, on the first string translated into it.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path
local H = require("test_koreader_stubs")

H.root = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/pluginmanager_startup_spec"
os.execute(("rm -rf %q && mkdir -p %q"):format(H.root, H.root .. "/settings"))

local fake_ui = { menu = { registerToMainMenu = function() end } }

local function own_loaded()
    local names = {}
    for k in pairs(package.loaded) do
        if type(k) == "string" and k:sub(1, #DIR) == DIR then names[#names + 1] = k:sub(#DIR + 1) end
    end
    table.sort(names)
    return names
end

local function fresh_main()
    for k in pairs(package.loaded) do
        if type(k) == "string" and k:sub(1, #DIR) == DIR then package.loaded[k] = nil end
    end
    return assert(loadfile(DIR .. "main.lua"))()
end

local function with_language(lang, fn)
    local saved = _G.G_reader_settings
    _G.G_reader_settings = { readSetting = function(_, k) if k == "language" then return lang end end,
                          saveSetting = function() end }
    local ok, err = pcall(fn)
    _G.G_reader_settings = saved
    if not ok then error(err, 0) end
end

describe("main.lua at KOReader startup", function()
    it("loads only i18n.lua: not manager.lua, nor any translation in English", function()
        with_language("en", function()
            local PM = fresh_main()
            local pm = PM:new{ ui = fake_ui }
            pm:init()
            local items = {}
            pm:addToMainMenu(items)
            assert.are.equal("Plugin Manager", items.pluginmanager.text)
            assert.are.same({ "i18n" }, own_loaded())
            assert.is_false(PM.isManagerLoaded())
            assert.is_nil(package.loaded[DIR .. "i18n"].loadedLanguage())
        end)
    end)

    it("stubs exactly the methods manager.lua defines", function()
        local PM = fresh_main()
        local f = assert(io.open(DIR .. "manager.lua")); local src = f:read("*a"); f:close()
        local defined = {}
        for name in src:gmatch("\nfunction PluginManager:([%w_]+)%(") do defined[#defined + 1] = name end
        local listed = {}
        for _, name in ipairs(PM.MANAGER_METHODS) do listed[#listed + 1] = name end
        table.sort(defined); table.sort(listed)
        assert.are.same(defined, listed)
        local main_src = assert(io.open(DIR .. "main.lua")):read("*a")
        for _, name in ipairs(defined) do
            assert.is_nil(main_src:find("function PluginManager:" .. name .. "(", 1, true), name)
        end
    end)

    it("loads manager.lua on the first call and replaces every stub", function()
        local PM = fresh_main()
        local stubs = {}
        for _, name in ipairs(PM.MANAGER_METHODS) do stubs[name] = PM[name] end
        local pm = PM:new{ ui = fake_ui }
        pm:init()
        assert.is_false(PM.isManagerLoaded())
        assert.is_string(pm:getListSort())
        assert.is_true(PM.isManagerLoaded())
        for name, stub in pairs(stubs) do
            assert.is_function(PM[name], name)
            assert.are_not.equal(stub, PM[name], name)
        end
        -- another instance (the next FileManager / ReaderUI) uses them directly
        assert.is_string(PM:new{ ui = fake_ui }:getListSort())
    end)

    it("still schedules the daily background check, which then loads manager.lua", function()
        local PM = fresh_main()
        local f = assert(io.open(H.root .. "/settings/pluginmanager.lua", "w")); f:write("return {}\n"); f:close()
        local a = PM:new{ ui = fake_ui }
        a:ensureSettings()
        a.settings:saveSetting("manifest_json", '{"plugins":[]}')
        a.settings:saveSetting("last_check", 0)
        H.queue, H.server = {}, {}
        local b = PM:new{ ui = fake_ui }
        b:init()
        assert.are.equal(0, b._last_check)
        assert.is_false(PM.isManagerLoaded())
        assert.are.equal(1, #H.queue)
        H.queue[1]()   -- offline here: the check fetches nothing and stops
        assert.is_true(PM.isManagerLoaded())
        assert.are.same({ plugins = {} }, b:getManifest())
    end)

    it("translates into the UI language only, loading its strings once", function()
        with_language("fr", function()
            fresh_main()
            local _ = package.loaded[DIR .. "i18n"]
            assert.are.equal("Fermer", _("Close"))
            assert.are.equal("fr", _.loadedLanguage())
        end)
        with_language("de", function()
            local _ = package.loaded[DIR .. "i18n"]
            assert.are.equal("Schließen", _("Close"))
            assert.are.equal("de", _.loadedLanguage())
        end)
        with_language("en", function()
            local _ = package.loaded[DIR .. "i18n"]
            assert.are.equal("Close", _("Close"))
        end)
    end)
end)
