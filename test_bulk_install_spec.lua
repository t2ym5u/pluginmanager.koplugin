-- Drives the real _doFullUpdate / _doFullReinstall against a sandbox
-- "device" (a plugins/ tree on disk) and a fake raw.githubusercontent,
-- so the bulk paths are covered end to end rather than by reading.
--
-- The regression that prompted it: Reinstall All short-circuited on the
-- shared libraries' .version stamp, so it could neither re-download them
-- (which its own prompt promises) nor repair a corrupted one -- and then
-- copied the stale bundle into every consuming plugin's common/.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path
local H = require("test_koreader_stubs")

local SRC  = _dir:gsub("/$", "")
local ROOT = os.getenv("TMPDIR") or "/tmp"
ROOT = ROOT:gsub("/$", "") .. "/pluginmanager_bulk_spec"
H.root = ROOT
local PLUGINS = ROOT .. "/plugins"


local function sh(c) os.execute(c) end
local function write(p, s)
  sh(("mkdir -p %q"):format(p:match("^(.*)/[^/]+$")))
  local f = assert(io.open(p, "w")); f:write(s); f:close()
end
local function read(p) local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s end

local MANIFEST = [[{
 "schema_version":1, "updated":"2026-10-07", "repo":"t2ym5u/koreader-plugins",
 "common":{"version":"1.5.0","dir":"game-common","files":["hint.lua","i18n.lua"],
           "raw_base_url":"https://x/gc/"},
 "sudoku_common":{"version":"1.4.0","dir":"sudoku-common","files":["base_screen.lua","logic_solver.lua"],
           "raw_base_url":"https://x/sc/"},
 "plugins":[
  {"id":"sudoku","dir":"sudoku.koplugin","fullname":"Sudoku","version":"2.4.1",
   "files":["_meta.lua","board.lua","screen.lua"],"common_lib":"sudoku_common",
   "raw_base_url":"https://x/sudoku/"},
  {"id":"nonogram","dir":"nonogram.koplugin","fullname":"Nonogram","version":"1.2.1",
   "files":["_meta.lua","board.lua"],"common_lib":"common",
   "raw_base_url":"https://x/nonogram/"}
 ]}]]

local function server()
  local s = {
    ["https://raw.githubusercontent.com/t2ym5u/koreader-plugins/master/manifest.json"] = MANIFEST,
    ["https://x/gc/hint.lua"]            = "-- hint.lua NEUF\n",
    ["https://x/gc/i18n.lua"]            = "-- i18n.lua NEUF\n",
    ["https://x/sc/base_screen.lua"]     = "-- base_screen.lua NEUF\n",
    ["https://x/sc/logic_solver.lua"]    = "-- logic_solver.lua NEUF\n",
    ["https://x/sudoku/_meta.lua"]       = 'return { fullname = "Sudoku", version = "2.4.1" }\n',
    ["https://x/sudoku/board.lua"]       = "-- sudoku board NEUF\n",
    ["https://x/sudoku/screen.lua"]      = "-- sudoku screen NEUF\n",
    ["https://x/nonogram/_meta.lua"]     = 'return { fullname = "Nonogram", version = "1.2.1" }\n',
    ["https://x/nonogram/board.lua"]     = "-- nonogram board NEUF\n",
  }
  return s
end

-- A device that already has everything installed and up to date.
local function setup_device()
  sh(("rm -rf %q"):format(ROOT))
  sh(("mkdir -p %q"):format(PLUGINS))
  sh(("cp -R %q %q"):format(SRC, PLUGINS .. "/pluginmanager.koplugin"))
  write(PLUGINS .. "/sudoku.koplugin/_meta.lua",  'return { fullname = "Sudoku", version = "2.4.1" }\n')
  write(PLUGINS .. "/sudoku.koplugin/board.lua",  "-- sudoku board VIEUX\n")
  write(PLUGINS .. "/sudoku.koplugin/screen.lua", "-- sudoku screen VIEUX\n")
  write(PLUGINS .. "/nonogram.koplugin/_meta.lua", 'return { fullname = "Nonogram", version = "1.2.1" }\n')
  write(PLUGINS .. "/nonogram.koplugin/board.lua", "-- nonogram board VIEUX\n")
  -- shared libraries, already stamped at the manifest's current versions
  write(PLUGINS .. "/sudoku-common/base_screen.lua",  "-- base_screen.lua VIEUX\n")
  write(PLUGINS .. "/sudoku-common/logic_solver.lua", "-- logic_solver.lua VIEUX\n")
  write(PLUGINS .. "/sudoku-common/.version", "1.4.0")
  write(PLUGINS .. "/game-common/hint.lua", "-- hint.lua VIEUX\n")
  write(PLUGINS .. "/game-common/i18n.lua", "-- i18n.lua VIEUX\n")
  write(PLUGINS .. "/game-common/.version", "1.5.0")
end

local function load_pm()
  for k in pairs(package.loaded) do
    if tostring(k):find("pluginmanager.koplugin") then package.loaded[k] = nil end
  end
  H.messages, H.queue, H.fetched = {}, {}, {}
  H.server = server()
  return assert(loadfile(PLUGINS .. "/pluginmanager.koplugin/main.lua"))()
end

describe("Tout réinstaller", function()
  it("re-télécharge les fichiers propres de chaque plugin installé", function()
    setup_device()
    local PM = load_pm()
    local pm = PM:new{}
    pm:_doFullReinstall()
    H.drain()
    assert.are.equal("-- sudoku board NEUF\n",   read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.are.equal("-- sudoku screen NEUF\n",  read(PLUGINS .. "/sudoku.koplugin/screen.lua"))
    assert.are.equal("-- nonogram board NEUF\n", read(PLUGINS .. "/nonogram.koplugin/board.lua"))
  end)

  it("restaure un fichier de plugin supprimé", function()
    setup_device()
    os.remove(PLUGINS .. "/sudoku.koplugin/board.lua")
    local PM = load_pm()
    PM:new{}:_doFullReinstall()
    H.drain()
    assert.are.equal("-- sudoku board NEUF\n", read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("re-télécharge les bibliothèques partagées, comme la confirmation l'annonce", function()
    setup_device()
    local PM = load_pm()
    PM:new{}:_doFullReinstall()
    H.drain()
    local hit = false
    for _, u in ipairs(H.fetched) do if u == "https://x/sc/base_screen.lua" then hit = true end end
    assert.is_true(hit)
  end)

  it("répare une bibliothèque partagée corrompue", function()
    setup_device()
    write(PLUGINS .. "/sudoku-common/logic_solver.lua", "TRONQUE")
    local PM = load_pm()
    PM:new{}:_doFullReinstall()
    H.drain()
    assert.are.equal("-- logic_solver.lua NEUF\n", read(PLUGINS .. "/sudoku-common/logic_solver.lua"))
  end)

  it("propage la bibliothèque dans le common/ de chaque plugin", function()
    setup_device()
    local PM = load_pm()
    PM:new{}:_doFullReinstall()
    H.drain()
    assert.are.equal("-- base_screen.lua NEUF\n", read(PLUGINS .. "/sudoku.koplugin/common/base_screen.lua"))
  end)

  it("Mettre à jour garde le court-circuit : pas de re-téléchargement inutile", function()
    setup_device()
    local PM = load_pm()
    PM:new{}:_doFullUpdate()
    H.drain()
    for _, u in ipairs(H.fetched) do
      assert.is_not.equal("https://x/sc/base_screen.lua", u)
      assert.is_not.equal("https://x/gc/hint.lua", u)
    end
  end)

  it("Tout réinstaller demande le redémarrage", function()
    setup_device()
    local PM = load_pm()
    PM:new{}:_doFullReinstall()
    H.drain()
    local seen = table.concat(H.texts(), "\n")
    assert.is_truthy(seen:find("Redémarrez KOReader pour appliquer la mise à jour.", 1, true))
  end)
end)
