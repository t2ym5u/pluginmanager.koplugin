-- Drives 1.7.0's one-zip-per-plugin install, the bulk run's Stop button and
-- its keep-awake hold, against a sandbox plugins/ tree, a fake
-- raw.githubusercontent and real zip files (built with Python's zipfile,
-- read back through the unzip-backed ffi/archiver stub).
local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path
local H = require("test_koreader_stubs")

local SRC  = _dir:gsub("/$", "")
local ROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/pluginmanager_zip_spec"
H.root = ROOT
local PLUGINS = ROOT .. "/plugins"
local ZIPS    = ROOT .. "/zips"

-- Same stand-in digest as test_install_integrity_spec.lua: Busted runs under
-- Lua 5.5, where KOReader's ffi/sha2 does not load.
local function fake_sha(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967291 end
  return string.format("%08x%06x", h, #s)
end
package.preload["ffi/sha2"] = function() return { sha256 = fake_sha } end

local function sh(c) os.execute(c) end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function write(p, s)
  sh(("mkdir -p %s"):format(q(p:match("^(.*)/[^/]+$"))))
  local f = assert(io.open(p, "wb")); f:write(s); f:close()
end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end

-- Builds a zip holding `entries` ({ {name, content}, ... }, names verbatim,
-- "../" included) and returns its bytes.
local zip_n = 0
local function make_zip(entries)
  zip_n = zip_n + 1
  local work = ("%s/src%d"):format(ZIPS, zip_n)
  local args = {}
  for i, e in ipairs(entries) do
    write(("%s/%d"):format(work, i), e[2])
    args[#args + 1] = q(e[1]) .. " " .. q(("%s/%d"):format(work, i))
  end
  local out = ("%s/%d.zip"):format(ZIPS, zip_n)
  sh(("python3 -I -c %s %s %s"):format(q([[
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
a = sys.argv[2:]
for i in range(0, len(a), 2):
    # ZipInfo + writestr keeps the name verbatim (write() would normalise
    # "x/../../y" to "../y").
    z.writestr(zipfile.ZipInfo(a[i], (2026, 11, 3, 0, 0, 0)), open(a[i + 1], "rb").read())
z.close()
]]), q(out), table.concat(args, " ")))
  return assert(read(out))
end

local BASE      = "https://raw.githubusercontent.com/t2ym5u/koreader-plugins/master/"
local META      = 'return { fullname = "Sudoku", version = "2.5.0" }\n'
local BOARD     = "local Board = {}\nreturn Board\n"
local LIB_HINT  = "local Hint = {}\nreturn Hint\n"

local function sudoku_zip(extra)
  local entries = {
    { "game-common/hint.lua", LIB_HINT },
    { "sudoku.koplugin/_meta.lua", META },
    { "sudoku.koplugin/board.lua", BOARD },
    { "sudoku.koplugin/common/hint.lua", LIB_HINT },
  }
  for _i, e in ipairs(extra or {}) do entries[#entries + 1] = e end
  return make_zip(entries)
end

local function entry(id, zip_body, zip_extra)
  local e = {
    id = id, dir = id .. ".koplugin", fullname = id:gsub("^%l", string.upper), version = "2.5.0",
    files = { "_meta.lua", "board.lua" },
    raw_base_url = "https://x/" .. id .. "/",
    sha256 = { ["_meta.lua"] = fake_sha(META), ["board.lua"] = fake_sha(BOARD) },
  }
  if zip_body then
    e.zip = { path = "dist/" .. id .. ".zip", sha256 = fake_sha(zip_body), size = #zip_body }
    for k, v in pairs(zip_extra or {}) do e.zip[k] = v end
  end
  return e
end

local function setup_device()
  sh(("rm -rf %s"):format(q(ROOT)))
  sh(("mkdir -p %s %s"):format(q(PLUGINS), q(ZIPS)))
  sh(("cp -R %s %s"):format(q(SRC), q(PLUGINS .. "/pluginmanager.koplugin")))
end

local function load_pm(server)
  for k in pairs(package.loaded) do
    if tostring(k):find("pluginmanager.koplugin") then package.loaded[k] = nil end
  end
  H.messages, H.queue, H.fetched, H.widgets = {}, {}, {}, {}
  H.standby_prevented, H.input_events = 0, 0
  for k in pairs(H.pluginshare) do H.pluginshare[k] = nil end
  H.server = server
  local PM = assert(loadfile(PLUGINS .. "/pluginmanager.koplugin/main.lua"))()
  return PM:new{}
end

local function per_file_server(id, t)
  t = t or {}
  t["https://x/" .. id .. "/_meta.lua"] = META
  t["https://x/" .. id .. "/board.lua"] = BOARD
  return t
end

local function fetched(url)
  local n = 0
  for _, u in ipairs(H.fetched) do if u == url then n = n + 1 end end
  return n
end

local function per_file_fetches()
  local n = 0
  for _, u in ipairs(H.fetched) do if u:find("^https://x/") then n = n + 1 end end
  return n
end

-- The progress dialog's Stop button.
local function press_stop()
  for _i, w in ipairs(H.widgets) do
    if w._widget == "ButtonDialog" and w.buttons and w.buttons[1] and w.buttons[1][1] then
      w.buttons[1][1].callback()
      return true
    end
  end
  return false
end

describe("installation depuis le zip du plugin", function()
  it("installe tout depuis un seul téléchargement", function()
    setup_device()
    local zip = sudoku_zip()
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    local ok, err = pm:installPlugin(entry("sudoku", zip), { plugins = {} })
    assert.is_true(ok, err)
    assert.are.equal(META,  read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.are.equal(1, fetched(BASE .. "dist/sudoku.zip"))
    assert.are.equal(0, per_file_fetches())
    -- only the plugin's own files: common/ comes from the shared library
    assert.is_false(exists(PLUGINS .. "/sudoku.koplugin/common/hint.lua"))
    -- nothing left behind
    assert.is_false(exists(ROOT .. "/cache/pluginmanager/sudoku.zip"))
    assert.is_false(exists(PLUGINS .. "/.pluginmanager-staging/sudoku.koplugin"))
  end)

  it("hash différent (CDN encore sur l'ancien zip) : repli fichier par fichier", function()
    setup_device()
    local zip = sudoku_zip()
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    local ok, err = pm:installPlugin(entry("sudoku", zip, { sha256 = fake_sha("autre chose") }), { plugins = {} })
    assert.is_true(ok, err)
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.are.equal(1, fetched("https://x/sudoku/board.lua"))
  end)

  it("taille différente : repli fichier par fichier", function()
    setup_device()
    local zip = sudoku_zip()
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    local ok = pm:installPlugin(entry("sudoku", zip, { size = #zip + 1 }), { plugins = {} })
    assert.is_true(ok)
    assert.are.equal(1, fetched("https://x/sudoku/board.lua"))
  end)

  it("zip absent du serveur : repli fichier par fichier", function()
    setup_device()
    local zip = sudoku_zip()
    local pm = load_pm(per_file_server("sudoku"))
    local ok = pm:installPlugin(entry("sudoku", zip), { plugins = {} })
    assert.is_true(ok)
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("zip corrompu (hash pourtant conforme) : repli fichier par fichier", function()
    setup_device()
    local junk = "PK\3\4 ceci n'est pas une archive"
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = junk }))
    local ok, err = pm:installPlugin(entry("sudoku", junk), { plugins = {} })
    assert.is_true(ok, err)
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.are.equal(1, fetched("https://x/sudoku/board.lua"))
  end)

  it("zip incomplet (fichier listé manquant) : repli fichier par fichier", function()
    setup_device()
    local zip = make_zip({ { "sudoku.koplugin/_meta.lua", META } })
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    local ok = pm:installPlugin(entry("sudoku", zip), { plugins = {} })
    assert.is_true(ok)
    assert.are.equal(1, fetched("https://x/sudoku/board.lua"))
  end)

  it("un .lua du zip qui ne compile pas : repli fichier par fichier", function()
    setup_device()
    local zip = make_zip({ { "sudoku.koplugin/_meta.lua", META },
                           { "sudoku.koplugin/board.lua", "local x = = 1" } })
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    local ok = pm:installPlugin(entry("sudoku", zip), { plugins = {} })
    assert.is_true(ok)
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("PathGuard : une entrée « ../ » fait refuser tout le zip", function()
    setup_device()
    local zip = sudoku_zip({ { "../evil.lua", "-- evil\n" },
                             { "sudoku.koplugin/../../evil2.lua", "-- evil\n" } })
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    local ok, err = pm:installPlugin(entry("sudoku", zip), { plugins = {} })
    assert.is_true(ok, err)
    assert.is_false(exists(ROOT .. "/evil.lua"))
    assert.is_false(exists(ROOT .. "/evil2.lua"))
    assert.is_false(exists(PLUGINS .. "/evil.lua"))
    assert.is_false(exists(PLUGINS .. "/evil2.lua"))
    assert.is_false(exists(PLUGINS .. "/.pluginmanager-staging/evil.lua"))
    -- refused, then installed file by file
    assert.are.equal(1, fetched("https://x/sudoku/board.lua"))
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("un zip qui contient une version plus ancienne est refusé", function()
    setup_device()
    local zip = make_zip({ { "sudoku.koplugin/_meta.lua", 'return { version = "2.4.0" }\n' },
                           { "sudoku.koplugin/board.lua", BOARD } })
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    assert.is_true(pm:installPlugin(entry("sudoku", zip), { plugins = {} }))
    assert.are.equal(META, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
  end)

  it("garde la version remplacée pour le retour arrière, comme le chemin fichier par fichier", function()
    setup_device()
    write(PLUGINS .. "/sudoku.koplugin/_meta.lua", 'return { fullname = "Sudoku", version = "2.4.0" }\n')
    write(PLUGINS .. "/sudoku.koplugin/board.lua", "-- old board\n")
    local zip = sudoku_zip()
    local pm = load_pm(per_file_server("sudoku", { [BASE .. "dist/sudoku.zip"] = zip }))
    assert.is_true(pm:installPlugin(entry("sudoku", zip), { plugins = {} }))
    assert.are.equal("2.4.0", pm:getBackupVersion("sudoku.koplugin"))
    assert.are.equal(0, per_file_fetches())
  end)
end)

describe("bibliothèque partagée depuis un zip", function()
  local function lib_manifest(zip)
    local e = entry("sudoku", zip)
    e.common_lib = "common"
    return {
      common = { version = "1.9.1", dir = "game-common", files = { "hint.lua" },
                 raw_base_url = "https://x/gc/" },
      plugins = { e },
    }
  end

  it("Tout réinstaller rafraîchit game-common depuis le zip, sans téléchargement par fichier", function()
    setup_device()
    write(PLUGINS .. "/sudoku.koplugin/_meta.lua", META)
    write(PLUGINS .. "/game-common/hint.lua", "-- VIEUX\n")
    write(PLUGINS .. "/game-common/.version", "1.9.1")
    local zip = sudoku_zip()
    local m = lib_manifest(zip)
    local pm = load_pm(per_file_server("sudoku", {
      [BASE .. "dist/sudoku.zip"] = zip,
      ["https://x/gc/hint.lua"] = "-- per-file\n",
    }))
    pm:_runBulkInstall(m, m.plugins, { force_common = true })
    H.drain()
    assert.are.equal(LIB_HINT, read(PLUGINS .. "/game-common/hint.lua"))
    assert.are.equal("1.9.1", read(PLUGINS .. "/game-common/.version"))
    assert.are.equal(LIB_HINT, read(PLUGINS .. "/sudoku.koplugin/common/hint.lua"))
    assert.are.equal(0, fetched("https://x/gc/hint.lua"))
    assert.are.equal(0, per_file_fetches())
  end)

  it("zip inutilisable : la bibliothèque est téléchargée fichier par fichier", function()
    setup_device()
    write(PLUGINS .. "/sudoku.koplugin/_meta.lua", META)
    local zip = sudoku_zip()
    local m = lib_manifest(zip)
    m.plugins[1].zip.sha256 = fake_sha("faux")
    local pm = load_pm(per_file_server("sudoku", {
      [BASE .. "dist/sudoku.zip"] = zip,
      ["https://x/gc/hint.lua"] = LIB_HINT,
    }))
    pm:_runBulkInstall(m, m.plugins, { force_common = true })
    H.drain()
    assert.are.equal(LIB_HINT, read(PLUGINS .. "/game-common/hint.lua"))
    assert.are.equal(1, fetched("https://x/gc/hint.lua"))
  end)
end)

describe("Arrêter pendant une mise à jour groupée", function()
  it("termine le plugin en cours puis s'arrête, avec un résumé", function()
    setup_device()
    local server = {}
    for _i, id in ipairs({ "alpha", "beta", "gamma" }) do per_file_server(id, server) end
    -- The tap lands while beta is downloading.
    server["https://x/beta/board.lua"] = function() press_stop(); return BOARD end
    local pm = load_pm(server)
    local list = { entry("alpha"), entry("beta"), entry("gamma") }
    pm:_runBulkInstall({ plugins = list }, list, {})
    H.drain()
    assert.are.equal(BOARD, read(PLUGINS .. "/alpha.koplugin/board.lua"))
    assert.are.equal(BOARD, read(PLUGINS .. "/beta.koplugin/board.lua"))
    assert.is_false(exists(PLUGINS .. "/gamma.koplugin/_meta.lua"))
    assert.are.equal(0, fetched("https://x/gamma/_meta.lua"))
    local seen = table.concat(H.texts(), "\n")
    assert.is_truthy(seen:find("Arrêté après 2/3.", 1, true), seen)
    assert.is_truthy(seen:find("Redémarrez KOReader", 1, true))
  end)

  it("Tout installer : Arrêter n'enchaîne pas sur les patchs", function()
    setup_device()
    local server = per_file_server("alpha")
    server["https://x/alpha/board.lua"] = function() press_stop(); return BOARD end
    local pm = load_pm(server)
    local list = { entry("alpha") }
    local patch_plan = { install = { { name = "2-one.lua", download_url = "https://x/p/2-one.lua" } }, disabled = {} }
    pm:_runInstallEverything({ plugins = list }, { installed = {}, to_process = list, skipped = {} },
      patch_plan, { { full_name = "o/r", items = patch_plan.install } })
    H.drain()
    assert.are.equal(0, fetched("https://x/p/2-one.lua"))
    local seen = table.concat(H.texts(), "\n")
    assert.is_truthy(seen:find("1 plugin(s) mis à jour/installé(s).", 1, true), seen)
    assert.is_truthy(seen:find("Patchs : arrêt après 0/1.", 1, true), seen)
    assert.are.equal(0, H.standby_prevented)
  end)
end)

describe("garder la liseuse éveillée", function()
  local function during(url, server, probe)
    server[url] = function()
      probe.standby = H.standby_prevented
      probe.pause   = H.pluginshare.pause_auto_suspend
      return BOARD
    end
  end

  it("pendant la mise à jour, puis rendu à la fin", function()
    setup_device()
    local server, probe = per_file_server("alpha"), {}
    during("https://x/alpha/board.lua", server, probe)
    local pm = load_pm(server)
    local list = { entry("alpha") }
    pm:_runBulkInstall({ plugins = list }, list, {})
    H.drain()
    assert.are.equal(1, probe.standby)
    assert.is_true(probe.pause)
    assert.are.equal(0, H.standby_prevented)
    assert.is_nil(H.pluginshare.pause_auto_suspend)
    -- the end of the run counts as activity for autosuspend's countdown
    assert.is_true(H.input_events >= 1)
  end)

  it("rendu après un arrêt", function()
    setup_device()
    local server = per_file_server("alpha")
    per_file_server("beta", server)
    server["https://x/alpha/board.lua"] = function() press_stop(); return BOARD end
    local pm = load_pm(server)
    local list = { entry("alpha"), entry("beta") }
    pm:_runBulkInstall({ plugins = list }, list, {})
    H.drain()
    assert.are.equal(0, H.standby_prevented)
    assert.is_nil(H.pluginshare.pause_auto_suspend)
  end)

  it("rendu après une erreur de bibliothèque partagée", function()
    setup_device()
    local pm = load_pm(per_file_server("alpha"))  -- no https://x/gc/ files: 404
    local e = entry("alpha"); e.common_lib = "common"
    local m = { common = { version = "1.0.0", dir = "game-common", files = { "hint.lua" },
                           raw_base_url = "https://x/gc/" }, plugins = { e } }
    pm:_runBulkInstall(m, m.plugins, {})
    H.drain()
    assert.is_truthy(table.concat(H.texts(), "\n"):find("bibliothèque partagée", 1, true))
    assert.are.equal(0, H.standby_prevented)
    assert.is_nil(H.pluginshare.pause_auto_suspend)
  end)

  it("rendu quand il n'y a rien à faire, et après un échec d'installation", function()
    setup_device()
    local pm = load_pm({})
    pm:_runBulkInstall({ plugins = {} }, {}, {})
    H.drain()
    assert.are.equal(0, H.standby_prevented)
    local list = { entry("alpha") }  -- every download 404s
    pm:_runBulkInstall({ plugins = list }, list, {})
    H.drain()
    assert.are.equal(0, H.standby_prevented)
    assert.is_nil(H.pluginshare.pause_auto_suspend)
  end)

  it("respecte un pause_auto_suspend déjà posé par un autre plugin (keepalive)", function()
    setup_device()
    local pm = load_pm(per_file_server("alpha"))
    H.pluginshare.pause_auto_suspend = true
    local list = { entry("alpha") }
    pm:_runBulkInstall({ plugins = list }, list, {})
    H.drain()
    assert.is_true(H.pluginshare.pause_auto_suspend)
  end)

  it("Import : tenu pendant les deux moitiés, rendu à la fin", function()
    setup_device()
    local pm = load_pm(per_file_server("alpha"))
    local list = { entry("alpha") }
    local seen_between
    pm.installAllFromGithub = function(_self, _repos, on_done)
      seen_between = H.standby_prevented
      on_done({ "github ok" }, 1)
    end
    pm:_runImport({ plugins = list }, list, { { full_name = "o/r" } }, {})
    H.drain()
    assert.are.equal(1, seen_between)
    assert.are.equal(0, H.standby_prevented)
  end)
end)
