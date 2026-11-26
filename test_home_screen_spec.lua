-- The home screen: what it offers and in which order, its "Wi-Fi on/off"
-- line following the network events, and Wi-Fi handed back to KOReader's
-- "Action when done with Wi-Fi" setting when it closes. Real manager code;
-- Menu, the device and NetworkMgr are stubbed here.
local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path

local H = require("test_koreader_stubs")
local SRC  = _dir:gsub("/$", "")
local ROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/pluginmanager_home_spec"
H.root = ROOT
local PLUGINS = ROOT .. "/plugins"

-- NetworkMgr: the radio switch, and the calls Plugin Manager makes.
local net = { wifi_on = false, after = 0 }
package.preload["ui/network/manager"] = function()
  return {
    isWifiOn        = function() return net.wifi_on end,
    isConnected     = function() return net.wifi_on end,
    isOnline        = function() return net.wifi_on end,
    runWhenOnline   = function(_, fn) fn() end,
    afterWifiAction = function() net.after = net.after + 1 end,
  }
end
package.preload["device"] = function()
  return { screen = { getWidth = function() return 758 end, getHeight = function() return 1024 end } }
end
-- Menu: keeps its constructor arguments and what the manager does to it.
local menus = {}
package.preload["ui/widget/menu"] = function()
  local Menu = {}
  function Menu:extend(o)
    o = o or {}; o.__index = o
    return setmetatable(o, { __index = self })
  end
  function Menu:new(o)
    o = setmetatable(o or {}, self)
    o.subtitle_shown = o.subtitle
    o.title_bar = { setSubTitle = function(_, s) o.subtitle_shown = s end }
    menus[#menus + 1] = o
    return o
  end
  function Menu:switchItemTable(_, items) self.item_table = items end
  function Menu.updatePageInfo() end
  return Menu
end

local function sh(c) os.execute(c) end

local function load_pm()
  sh(("rm -rf %q && mkdir -p %q"):format(ROOT, PLUGINS))
  sh(("cp -R %q %q"):format(SRC, PLUGINS .. "/pluginmanager.koplugin"))
  for k in pairs(package.loaded) do
    if tostring(k):find("pluginmanager.koplugin") then package.loaded[k] = nil end
  end
  H.messages, H.queue, H.fetched, H.widgets = {}, {}, {}, {}
  H.server = {}
  net.wifi_on, net.after = false, 0
  menus = {}
  local PM = assert(loadfile(PLUGINS .. "/pluginmanager.koplugin/main.lua"))()
  return PM:new{}, PM
end

local function texts(entries)
  local out = {}
  for i, e in ipairs(entries) do out[i] = e.text end
  return out
end

-- The strings as the UI shows them, in whatever language the stubs set.
local tr = assert(loadfile(SRC .. "/i18n.lua"))()
local function trs(list)
  for i, s in ipairs(list) do list[i] = tr(s) end
  return list
end

describe("Plugin Manager home screen", function()
  it("puts the everyday actions first and the bulk ones under Maintenance", function()
    local pm = load_pm()
    assert.are.same(trs{ "Update", "Plugin list", "Discover plugins\u{2026}", "Patches\u{2026}",
      "Ignored updates\u{2026}", "Maintenance\u{2026}" }, texts(pm:homeEntries()))
    assert.are.same(trs{ "Install everything\u{2026}", "Reinstall all\u{2026}", "Remove all\u{2026}",
      "Export installed list", "Import list\u{2026}" }, texts(pm:maintenanceEntries()))
  end)

  it("is a flat full-screen list, not a rounded pop-up", function()
    local pm = load_pm()
    pm:showMainDialog()
    local m = menus[#menus]
    assert.is_true(m.is_borderless)
    assert.is_false(m.is_popout)
    assert.is_true(m.covers_fullscreen)
    assert.are.equal(758, m.width)
  end)

  it("updates its Wi-Fi line when Wi-Fi comes up, and when it goes down", function()
    local pm = load_pm()
    pm:showMainDialog()
    local m = menus[#menus]
    assert.are.equal(tr("\u{2717} Wi-Fi off"), m.subtitle_shown)
    net.wifi_on = true
    pm:onNetworkConnected()
    assert.are.equal(tr("\u{2713} Wi-Fi on"), m.subtitle_shown)
    net.wifi_on = false
    pm:onNetworkDisconnected()
    assert.are.equal(tr("\u{2717} Wi-Fi off"), m.subtitle_shown)
  end)

  it("ignores network events while closed, without loading manager.lua", function()
    local pm, PM = load_pm()
    pm:onNetworkConnected()
    assert.is_false(PM.isManagerLoaded())
  end)

  it("hands Wi-Fi back to KOReader's setting when it closes", function()
    local pm = load_pm()
    pm:showMainDialog()
    local m = menus[#menus]
    m:onCloseWidget()
    assert.are.equal(0, net.after)  -- not before the next tick
    H.drain()
    assert.are.equal(1, net.after)
    assert.is_nil(pm._home_menu)
  end)
end)

-- ---------------------------------------------------------------------------
-- The plugin list
-- ---------------------------------------------------------------------------

local function write(path, text)
  os.execute(("mkdir -p %q"):format(path:match("^(.*)/[^/]+$")))
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end

-- Installs fake plugins on the sandbox device and gives Plugin Manager a
-- manifest: bridges (logic) and wordle (words) have an update, netwalk
-- (logic) is up to date, chess (board) is not installed.
local function with_catalogue(pm)
  for id, v in pairs({ bridges = "1.0", netwalk = "1.0", wordle = "1.0" }) do
    write(PLUGINS .. "/" .. id .. ".koplugin/_meta.lua",
      ('return { fullname = "%s", version = "%s" }\n'):format(id, v))
  end
  pm._manifest = { plugins = {
    { id = "bridges", fullname = "bridges", version = "1.1", category = "logic",
      description = "Connect the islands.",
      description_i18n = { fr = "Reliez les îles.", es = "Conecta las islas.", de = "Verbinde die Inseln." } },
    { id = "netwalk", fullname = "netwalk", version = "1.0", category = "logic" },
    { id = "wordle",  fullname = "wordle",  version = "1.1", category = "words" },
    { id = "chess",   fullname = "chess",   version = "1.0", category = "board" },
  } }
end

local function find(rows, text)
  for _i, row in ipairs(rows) do if row.text == text then return row end end
end

describe("Plugin Manager plugin list", function()
  it("opens on the categories, with the pending updates first", function()
    local pm = load_pm()
    with_catalogue(pm)
    pm:showPluginList()
    local m = menus[#menus]
    local rows = m.item_table
    assert.are.equal(tr("Updates available"), rows[1].text)
    assert.are.equal("2", rows[1].mandatory)
    assert.are.equal(2, #rows[1].sub_item_table)
    local logic = rows[2]
    assert.are.equal("logic", logic._group)
    assert.are.equal(string.format(tr("%d to update \u{00B7} %d"), 1, 2), logic.mandatory)
    assert.are.equal(2, #logic.sub_item_table)
    assert.is_truthy(m.subtitle:find(string.format(tr("%d update(s) available"), 2), 1, true))
  end)

  it("has no updates row when everything is up to date", function()
    local pm = load_pm()
    with_catalogue(pm)
    for _i, p in ipairs(pm._manifest.plugins) do p.version = "1.0" end
    pm:showPluginList()
    assert.are.equal("logic", menus[#menus].item_table[1]._group)
  end)

  it("is flat when filtered by name", function()
    local pm = load_pm()
    with_catalogue(pm)
    pm._list_filter = "net"
    pm:showPluginList()
    local rows = menus[#menus].item_table
    assert.is_nil(rows[1].sub_item_table)
    assert.is_truthy(find(rows, "netwalk"))
  end)

  it("stays open under a plugin's dialog, and refreshes in the open category", function()
    local pm = load_pm()
    with_catalogue(pm)
    pm:showPluginList()
    local m = menus[#menus]
    -- Menu's sub_item_table navigation, as a tap on the row does it.
    local logic = find(m.item_table, tr("Logic puzzles"))
    m._group = logic._group
    m.item_table_stack = { m.item_table }
    m.item_table = logic.sub_item_table
    find(m.item_table, "bridges").callback()
    assert.are.equal(m, pm._list_menu)
    -- bridges gets updated: the category shows it, and stays open.
    write(PLUGINS .. "/bridges.koplugin/_meta.lua", 'return { fullname = "bridges", version = "1.1" }\n')
    pm:refreshHome()
    assert.are.equal(1, #m.item_table_stack)
    assert.are.equal("v1.1", find(m.item_table, "bridges").mandatory)
    -- The updates row now counts one; the overview below follows.
    assert.are.equal("1", m.item_table_stack[1][1].mandatory)
  end)

  it("shows a plugin's description in the reader's language", function()
    local pm = load_pm()
    with_catalogue(pm)
    local lang = (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
    local p = pm._manifest.plugins[1]
    pm:showInstalledDialog(p, pm:scanInstalled().bridges, true)
    local dlg = H.widgets[#H.widgets]
    local expected = p.description_i18n[lang] or p.description
    assert.is_truthy(dlg.title:find(expected, 1, true))
  end)
end)

describe("Plugin Manager Update started without its home screen", function()
  it("hands Wi-Fi back once done (Dashboard's Update plugins)", function()
    local pm = load_pm()
    with_catalogue(pm)
    pm:_runBulkInstall(pm._manifest, {}, { release_wifi = true })
    H.drain()
    assert.are.equal(1, net.after)
  end)

  it("leaves it to the home screen when that is open", function()
    local pm = load_pm()
    with_catalogue(pm)
    pm:_runBulkInstall(pm._manifest, {}, {})
    H.drain()
    assert.are.equal(0, net.after)
  end)
end)
