-- Retired plugins and templates: plugins taken out of the catalogue (and the
-- _skeleton template) found on the device are offered for real removal, and
-- a template is never installed. pmlogic's decisions first, then the real
-- manager code against a sandbox plugins/ tree (same harness as
-- test_install_integrity_spec.lua).
local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path

local L = require("pmlogic")

local function ids(list)
  local out = {}
  for i, u in ipairs(list) do out[i] = u.id .. ":" .. u.reason end
  return table.concat(out, ",")
end

describe("retiredIds", function()
  it("reads the manifest's retired list", function()
    local set = L.retiredIds({ retired = { "kakuro", "oldgame" }, plugins = {} })
    assert.is_true(set.kakuro)
    assert.is_true(set.oldgame)
    assert.is_nil(set.arrowwords)
  end)

  it("falls back to the built-in list without the field, or without a manifest", function()
    for _, m in ipairs({ { plugins = {} }, false }) do
      local set = L.retiredIds(m or nil)
      for _, id in ipairs({ "arrowwords", "boggleparty", "doubleornothing", "kakuro", "startmenu" }) do
        assert.is_true(set[id], id)
      end
    end
  end)

  it("an empty retired list means none: a plugin can come back", function()
    assert.is_nil(next(L.retiredIds({ retired = {}, plugins = {} })))
  end)

  it("never flags a plugin the catalogue still lists, nor Plugin Manager", function()
    local set = L.retiredIds({
      retired = { "kakuro", "pluginmanager", "galaxies" },
      plugins = { { id = "galaxies" } },
    })
    assert.is_true(set.kakuro)
    assert.is_nil(set.galaxies)
    assert.is_nil(set.pluginmanager)
  end)

  it("ignores junk entries", function()
    local set = L.retiredIds({ retired = { 1, "", {}, "kakuro" } })
    assert.are.same({ kakuro = true }, set)
  end)
end)

describe("unwantedPlugins", function()
  local DIRS = { "2048.koplugin", "arrowwords.koplugin", "_skeleton.koplugin",
                 "kakuro.koplugin", "pluginmanager.koplugin", "notes.txt", "kakuro" }

  it("finds retired plugins and templates, sorted, with the reason", function()
    assert.are.equal("_skeleton:template,arrowwords:retired,kakuro:retired",
      ids(L.unwantedPlugins(DIRS, nil)))
  end)

  it("follows the manifest's list when it has one", function()
    assert.are.equal("_skeleton:template,kakuro:retired",
      ids(L.unwantedPlugins(DIRS, { retired = { "kakuro" }, plugins = {} })))
  end)

  it("keeps the directory name", function()
    local list = L.unwantedPlugins({ "arrowwords.koplugin" })
    assert.are.equal("arrowwords.koplugin", list[1].dir)
  end)

  it("nothing to do on a clean device", function()
    assert.are.equal(0, #L.unwantedPlugins({ "2048.koplugin", "sudoku.koplugin" }))
    assert.are.equal(0, #L.unwantedPlugins(nil))
  end)
end)

describe("isTemplate", function()
  it("is any name starting with an underscore", function()
    assert.is_true(L.isTemplate("_skeleton"))
    assert.is_true(L.isTemplate("_skeleton.koplugin"))
    assert.is_false(L.isTemplate("skeleton"))
    assert.is_false(L.isTemplate(nil))
  end)
end)

-- ---------------------------------------------------------------------------
-- The manager, on a sandbox device
-- ---------------------------------------------------------------------------

local H = require("test_koreader_stubs")
local SRC  = _dir:gsub("/$", "")
local ROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/pluginmanager_retired_spec"
H.root = ROOT
local PLUGINS = ROOT .. "/plugins"

local function sh(c) os.execute(c) end
local function write(p, s)
  sh(("mkdir -p %q"):format(p:match("^(.*)/[^/]+$")))
  local f = assert(io.open(p, "w")); f:write(s); f:close()
end
local function exists(p)
  local r = os.execute(("test -e %q"):format(p))
  return r == true or r == 0
end

local function setup_device()
  sh(("rm -rf %q"):format(ROOT))
  sh(("mkdir -p %q"):format(PLUGINS))
  sh(("cp -R %q %q"):format(SRC, PLUGINS .. "/pluginmanager.koplugin"))
  write(PLUGINS .. "/2048.koplugin/_meta.lua", 'return { fullname = "2048", version = "1.0" }\n')
  -- The stale copy found on the device: main.lua, its old common/.
  write(PLUGINS .. "/arrowwords.koplugin/_meta.lua", 'return { fullname = "Mots fléchés", version = "1.2.11" }\n')
  write(PLUGINS .. "/arrowwords.koplugin/main.lua", "return {}\n")
  write(PLUGINS .. "/arrowwords.koplugin/common/screen_base.lua", "return {}\n")
  -- Half-deleted: no _meta.lua left, but KOReader still runs main.lua.
  write(PLUGINS .. "/kakuro.koplugin/main.lua", "return {}\n")
  write(PLUGINS .. "/_skeleton.koplugin/_meta.lua", 'return { fullname = "Skeleton", version = "0.1" }\n')
end

local function load_pm()
  for k in pairs(package.loaded) do
    if tostring(k):find("pluginmanager.koplugin") then package.loaded[k] = nil end
  end
  H.messages, H.queue, H.fetched, H.widgets = {}, {}, {}, {}
  H.server = {}
  local PM = assert(loadfile(PLUGINS .. "/pluginmanager.koplugin/main.lua"))()
  return PM:new{}
end

local function last_confirm()
  for i = #H.widgets, 1, -1 do
    if H.widgets[i]._widget == "ConfirmBox" then return H.widgets[i] end
  end
end

describe("Plugin Manager on a device with retired plugins", function()
  it("finds them, even one without a _meta.lua", function()
    setup_device()
    local pm = load_pm()
    assert.are.equal("_skeleton:template,arrowwords:retired,kakuro:retired", ids(pm:scanUnwanted()))
    -- kakuro is invisible to the installed scan, as before.
    assert.is_nil(pm:scanInstalled().kakuro)
  end)

  it("offers them first on the home screen, only while there are some", function()
    setup_device()
    local pm = load_pm()
    local first = pm:homeEntries()[1].text
    assert.is_truthy(first:find("(3)", 1, true))
    sh(("rm -rf %q %q %q"):format(PLUGINS .. "/arrowwords.koplugin",
      PLUGINS .. "/kakuro.koplugin", PLUGINS .. "/_skeleton.koplugin"))
    assert.is_falsy(pm:homeEntries()[1].text:find("(3)", 1, true))
    assert.are.equal(0, #pm:scanUnwanted())
  end)

  it("removes every file of them after the confirmation, and nothing else", function()
    setup_device()
    local pm = load_pm()
    pm:showUnwantedDialog()
    local box = last_confirm()
    assert.is_truthy(box)
    assert.is_truthy(box.text:find("arrowwords.koplugin", 1, true))
    assert.is_truthy(box.text:find("_skeleton.koplugin", 1, true))
    box.ok_callback()
    H.drain()
    assert.is_falsy(exists(PLUGINS .. "/arrowwords.koplugin"))
    assert.is_falsy(exists(PLUGINS .. "/kakuro.koplugin"))
    assert.is_falsy(exists(PLUGINS .. "/_skeleton.koplugin"))
    assert.is_truthy(exists(PLUGINS .. "/2048.koplugin/_meta.lua"))
    assert.is_truthy(exists(PLUGINS .. "/pluginmanager.koplugin/main.lua"))
    assert.is_truthy(table.concat(H.texts(), "\n"):find("3", 1, true))
  end)

  it("never installs a template, whatever lists it", function()
    setup_device()
    sh(("rm -rf %q"):format(PLUGINS .. "/_skeleton.koplugin"))
    local pm = load_pm()
    local ok, err = pm:installPlugin({
      id = "_skeleton", dir = "_skeleton.koplugin", fullname = "Skeleton", version = "0.1",
      files = { "_meta.lua" }, raw_base_url = "https://x/_skeleton/",
    }, { plugins = {} })
    assert.is_false(ok)
    assert.is_truthy(err:find("_skeleton", 1, true))
    assert.is_falsy(exists(PLUGINS .. "/_skeleton.koplugin"))
    assert.are.equal(0, #H.fetched)
  end)
end)
