-- KOReader builds a new PluginManager instance with every FileManager and
-- every ReaderUI, i.e. twice per book opened. Each instance used to reopen
-- the settings file (it holds the whole cached manifest) and decode the
-- manifest again. Regression check: the settings object and the decoded
-- manifest are shared, re-read only when they actually changed.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path
local H = require("test_koreader_stubs")

local ROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/pluginmanager_instance_cache_spec"
H.root = ROOT
local SETTINGS = ROOT .. "/settings/pluginmanager.lua"

local MANIFEST = '{"plugins":[{"id":"sudoku","dir":"sudoku.koplugin","fullname":"Sudoku","version":"2.4.1"}]}'

-- A LuaSettings that persists across opens, like the real one, and counts them.
local opens, decodes = 0, 0
local disk = {}
package.loaded["luasettings"] = { open = function(_, path)
  opens = opens + 1
  local store = disk[path] or {}
  disk[path] = store
  return { readSetting = function(_, k) return store[k] end,
           saveSetting = function(_, k, v) store[k] = v end,
           delSetting  = function(_, k) store[k] = nil end,
           flush       = function() end }
end }
local rapidjson = require("rapidjson")
local real_decode = rapidjson.decode
rapidjson.decode = function(s) decodes = decodes + 1; return real_decode(s) end
rapidjson.encode = function() return '{"plugins":[]}' end

local function reset_disk()
  os.execute(("rm -rf %q && mkdir -p %q"):format(ROOT, ROOT .. "/settings"))
  local f = assert(io.open(SETTINGS, "w")); f:write("return {}\n"); f:close()
  disk = {}
  disk[SETTINGS] = { manifest_json = MANIFEST, last_check = os.time() }
end

local function load_pm()
  return assert(loadfile(_dir .. "main.lua"))()
end

local fake_ui = { menu = { registerToMainMenu = function() end } }

describe("PluginManager instances (one per FileManager / ReaderUI)", function()
  before_each(function()
    reset_disk()
    opens, decodes = 0, 0
  end)

  it("open the settings and decode the cached manifest once, not per instance", function()
    local PM = load_pm()
    local first = PM:new{ ui = fake_ui }
    first:init()
    for _ = 1, 10 do PM:new{ ui = fake_ui }:init() end
    local last = PM:new{ ui = fake_ui }
    last:init()
    assert.are.equal(1, opens)
    -- nothing is decoded until the manifest is used
    assert.are.equal(0, decodes)
    assert.are.equal(first:getManifest(), last:getManifest())
    assert.are.equal(1, decodes)
    assert.are.equal("sudoku", last:getManifest().plugins[1].id)
  end)

  it("a manifest saved by one instance is what the next one gets, without decoding it", function()
    local PM = load_pm()
    local a = PM:new{ ui = fake_ui }
    a:init()
    local fresh = { plugins = { { id = "nonogram", version = "1.0.0" } } }
    a:saveManifestCache(fresh)
    local b = PM:new{ ui = fake_ui }
    b:init()
    assert.are.equal(fresh, b:getManifest())
    assert.are.equal(0, decodes)
  end)

  it("starts afresh once the settings file was deleted (Delete plugin settings)", function()
    local PM = load_pm()
    PM:new{ ui = fake_ui }:init()
    os.remove(SETTINGS)
    disk[SETTINGS] = nil
    local b = PM:new{ ui = fake_ui }
    b:init()
    assert.are.equal(2, opens)
    assert.is_nil(b:getManifest())
  end)
end)
