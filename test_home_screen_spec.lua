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
