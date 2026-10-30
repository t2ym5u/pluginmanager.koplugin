-- Drives the real installPlugin / ensureCommon / bulk paths against a sandbox
-- plugins/ tree and a fake raw.githubusercontent, for what 1.5.0 added:
-- staging (nothing half-installed), the compile check, sha256 with its drift
-- rule, the kept previous version and its restore, min_koreader skipping,
-- and import.
local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path
local H = require("test_koreader_stubs")

local SRC  = _dir:gsub("/$", "")
local ROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/pluginmanager_integrity_spec"
H.root = ROOT
local PLUGINS = ROOT .. "/plugins"

-- Busted runs under Lua 5.5, where KOReader's ffi/sha2 does not load, so
-- the spec supplies its own stand-in. Any deterministic digest will do: the
-- point is the decisions taken on match/mismatch, not SHA-256 itself (the
-- real one is checked against Python's hashlib on LuaJIT, see README).
local function fake_sha(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967291 end
  return string.format("%08x%06x", h, #s)
end
package.preload["ffi/sha2"] = function() return { sha256 = fake_sha } end

local function sh(c) os.execute(c) end
local function write(p, s)
  sh(("mkdir -p %q"):format(p:match("^(.*)/[^/]+$")))
  local f = assert(io.open(p, "w")); f:write(s); f:close()
end
local function read(p) local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s end
local function exists(p) return os.execute(("test -e %q"):format(p)) == true or os.execute(("test -e %q"):format(p)) == 0 end

local META_OLD = 'return { fullname = "Sudoku", version = "2.4.0" }\n'
local META_NEW = 'return { fullname = "Sudoku", version = "2.5.0" }\n'
local BOARD    = "local Board = {}\nreturn Board\n"
local GOOD_LIB = "local M = {}\nreturn M\n"

local function sudoku_entry(extra)
  local e = {
    id = "sudoku", dir = "sudoku.koplugin", fullname = "Sudoku", version = "2.5.0",
    files = { "_meta.lua", "board.lua" },
    raw_base_url = "https://x/sudoku/",
    sha256 = { ["_meta.lua"] = fake_sha(META_NEW), ["board.lua"] = fake_sha(BOARD) },
  }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

local function setup_device()
  sh(("rm -rf %q"):format(ROOT))
  sh(("mkdir -p %q"):format(PLUGINS))
  sh(("cp -R %q %q"):format(SRC, PLUGINS .. "/pluginmanager.koplugin"))
  write(PLUGINS .. "/sudoku.koplugin/_meta.lua", META_OLD)
  write(PLUGINS .. "/sudoku.koplugin/board.lua", "-- old board\n")
end

local function load_pm(server)
  for k in pairs(package.loaded) do
    if tostring(k):find("pluginmanager.koplugin") then package.loaded[k] = nil end
  end
  H.messages, H.queue, H.fetched = {}, {}, {}
  H.server = server or {
    ["https://x/sudoku/_meta.lua"] = META_NEW,
    ["https://x/sudoku/board.lua"] = BOARD,
  }
  local PM = assert(loadfile(PLUGINS .. "/pluginmanager.koplugin/main.lua"))()
  return PM:new{}
end

local function count_fetches(url)
  local n = 0
  for _, u in ipairs(H.fetched) do if u == url then n = n + 1 end end
  return n
end

local MANIFEST = { plugins = {} }

describe("installation par étapes", function()
  it("installe quand les empreintes correspondent", function()
    setup_device()
    local pm = load_pm()
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    assert.are.equal(META_NEW, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.is_falsy(exists(PLUGINS .. "/.pluginmanager-staging/sudoku.koplugin"))
  end)

  it("supprime les fichiers périmés mais garde la configuration de l'utilisateur", function()
    setup_device()
    write(PLUGINS .. "/sudoku.koplugin/old_board.lua", "-- removed upstream\n")
    write(PLUGINS .. "/sudoku.koplugin/pluginmanager_configuration.lua", "return { token = 't' }\n")
    local pm = load_pm()
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    assert.is_falsy(exists(PLUGINS .. "/sudoku.koplugin/old_board.lua"))
    assert.are.equal("return { token = 't' }\n",
      read(PLUGINS .. "/sudoku.koplugin/pluginmanager_configuration.lua"))
  end)

  it("sans sha256 dans le manifeste, installe comme avant", function()
    setup_device()
    local pm = load_pm()
    assert.is_true((pm:installPlugin(sudoku_entry{ sha256 = nil }, MANIFEST)))
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("un .lua tronqué ne laisse aucune installation à moitié faite", function()
    setup_device()
    local pm = load_pm{
      ["https://x/sudoku/_meta.lua"] = META_NEW,
      ["https://x/sudoku/board.lua"] = "local Board = {\n",   -- truncated, twice
    }
    local ok, err = pm:installPlugin(sudoku_entry{ sha256 = nil }, MANIFEST)
    assert.is_false(ok)
    assert.is_truthy(err:find("board.lua", 1, true))
    -- The installed version is untouched, file for file.
    assert.are.equal(META_OLD, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    assert.are.equal("-- old board\n", read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.is_falsy(exists(PLUGINS .. "/.pluginmanager-staging/sudoku.koplugin"))
    assert.are.equal(2, count_fetches("https://x/sudoku/board.lua"))
  end)

  it("re-télécharge une fois un fichier tronqué, et garde le bon", function()
    setup_device()
    local n = 0
    local pm = load_pm{
      ["https://x/sudoku/_meta.lua"] = META_NEW,
      ["https://x/sudoku/board.lua"] = function()
        n = n + 1
        return n == 1 and "local Board = {\n" or BOARD
      end,
    }
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    assert.are.equal(BOARD, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("accepte une dérive quand le dépôt est en avance sur le manifeste", function()
    setup_device()
    -- Pushed after the manifest was regenerated: new content, new version.
    local pushed_meta  = 'return { fullname = "Sudoku", version = "2.5.1" }\n'
    local pushed_board = "local Board = { v = 2 }\nreturn Board\n"
    local pm = load_pm{
      ["https://x/sudoku/_meta.lua"] = pushed_meta,
      ["https://x/sudoku/board.lua"] = pushed_board,
    }
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    assert.are.equal(pushed_board, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.are.equal(2, count_fetches("https://x/sudoku/board.lua"))
  end)

  it("accepte une dérive poussée sans changement de version", function()
    setup_device()
    local pushed_board = "local Board = { fix = true }\nreturn Board\n"
    local pm = load_pm{
      ["https://x/sudoku/_meta.lua"] = META_NEW,
      ["https://x/sudoku/board.lua"] = pushed_board,
    }
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    assert.are.equal(pushed_board, read(PLUGINS .. "/sudoku.koplugin/board.lua"))
  end)

  it("refuse une copie périmée (version plus ancienne que le manifeste)", function()
    setup_device()
    -- What a wrong branch in raw_base_url serves: a frozen old copy, with 200.
    local stale_meta = 'return { fullname = "Sudoku", version = "2.3.0" }\n'
    local pm = load_pm{
      ["https://x/sudoku/_meta.lua"] = stale_meta,
      ["https://x/sudoku/board.lua"] = "local B = {}\nreturn B\n",
    }
    local ok, err = pm:installPlugin(sudoku_entry(), MANIFEST)
    assert.is_false(ok)
    assert.is_truthy(err:find("integrity", 1, true) or err:find("intégrité", 1, true))
    assert.are.equal(META_OLD, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    assert.are.equal("-- old board\n", read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    assert.is_falsy(exists(PLUGINS .. "/.pluginmanager-staging/sudoku.koplugin"))
  end)

  it("refuse un fichier de bibliothèque qui ne compile pas, sans toucher à l'existant", function()
    setup_device()
    write(PLUGINS .. "/game-common/hint.lua", GOOD_LIB)
    write(PLUGINS .. "/game-common/.version", "1.0.0")
    local pm = load_pm{ ["https://x/gc/hint.lua"] = "local M = {\n" }
    local manifest = { common = { version = "1.1.0", dir = "game-common", files = { "hint.lua" },
                                  raw_base_url = "https://x/gc/" } }
    local ok = pm:ensureCommon(manifest, "common")
    assert.is_false(ok)
    assert.are.equal(GOOD_LIB, read(PLUGINS .. "/game-common/hint.lua"))
    assert.are.equal("1.0.0", read(PLUGINS .. "/game-common/.version"))
  end)
end)

describe("version précédente", function()
  it("une mise à jour garde la version remplacée, et la restauration la remet", function()
    setup_device()
    local pm = load_pm()
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    assert.are.equal("2.4.0", pm:getBackupVersion("sudoku.koplugin"))
    assert.are.equal("-- old board\n", read(PLUGINS .. "/.pluginmanager-backup/sudoku.koplugin/board.lua"))

    local ok, version = pm:restoreBackup("sudoku.koplugin")
    assert.is_true(ok)
    assert.are.equal("2.4.0", version)
    assert.are.equal(META_OLD, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    assert.are.equal("-- old board\n", read(PLUGINS .. "/sudoku.koplugin/board.lua"))
    -- Consumed by the restore, and nothing left aside.
    assert.is_nil(pm:getBackupVersion("sudoku.koplugin"))
    assert.is_falsy(exists(PLUGINS .. "/.pluginmanager-staging/sudoku.koplugin"))
  end)

  it("réinstaller la même version n'écrase pas la copie utile", function()
    setup_device()
    local pm = load_pm()
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))      -- 2.4.0 -> 2.5.0
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))      -- 2.5.0 again
    assert.are.equal("2.4.0", pm:getBackupVersion("sudoku.koplugin"))
  end)

  it("après restauration, la version annulée est ignorée et le redémarrage proposé", function()
    setup_device()
    local pm = load_pm()
    local entry = sudoku_entry()
    assert.is_true((pm:installPlugin(entry, MANIFEST)))
    pm:_doRestore(entry, { fullname = "Sudoku", version = "2.5.0" })
    H.drain()
    assert.is_true(pm:isVersionIgnored("sudoku", "2.5.0"))
    local seen = table.concat(H.texts(), "\n")
    assert.is_truthy(seen:find("Redémarrez KOReader", 1, true))
  end)

  it("refuse un nom de dossier dangereux", function()
    setup_device()
    local pm = load_pm()
    local ok = pm:restoreBackup("../etc")
    assert.is_false(ok)
  end)

  it("supprimer un plugin supprime aussi sa copie", function()
    setup_device()
    local pm = load_pm()
    assert.is_true((pm:installPlugin(sudoku_entry(), MANIFEST)))
    pm:_doRemove("Sudoku", "sudoku.koplugin")
    assert.is_falsy(exists(PLUGINS .. "/sudoku.koplugin"))
    assert.is_nil(pm:getBackupVersion("sudoku.koplugin"))
  end)
end)

describe("KOReader minimum et import", function()
  local MANIFEST_JSON = [[{
   "schema_version":1,
   "plugins":[
    {"id":"sudoku","dir":"sudoku.koplugin","fullname":"Sudoku","version":"2.5.0",
     "files":["_meta.lua","board.lua"],"raw_base_url":"https://x/sudoku/"},
    {"id":"wordle","dir":"wordle.koplugin","fullname":"Wordle","version":"1.3.0",
     "files":["_meta.lua"],"raw_base_url":"https://x/wordle/","min_koreader":"2099.01"},
    {"id":"chess","dir":"chess.koplugin","fullname":"Chess","version":"1.2.0",
     "files":["_meta.lua"],"raw_base_url":"https://x/chess/"}
   ]}]]
  local function server()
    return {
      ["https://raw.githubusercontent.com/t2ym5u/koreader-plugins/master/manifest.json"] = MANIFEST_JSON,
      ["https://x/sudoku/_meta.lua"] = META_NEW,
      ["https://x/sudoku/board.lua"] = BOARD,
      ["https://x/wordle/_meta.lua"] = 'return { fullname = "Wordle", version = "1.3.0" }\n',
      ["https://x/chess/_meta.lua"]  = 'return { fullname = "Chess", version = "1.2.0" }\n',
    }
  end

  setup(function()
    package.preload["version"] = function()
      return { getNormalizedCurrentVersion = function() return 202603000000 end,
               getShortVersion             = function() return "v2026.03" end }
    end
  end)
  teardown(function()
    package.preload["version"] = nil
    package.loaded["version"]  = nil
  end)

  it("Mettre à jour saute un plugin qui demande un KOReader plus récent, et le dit", function()
    setup_device()
    local pm = load_pm(server())
    pm:_doFullUpdate()
    H.drain()
    assert.is_falsy(exists(PLUGINS .. "/wordle.koplugin"))
    assert.is_truthy(exists(PLUGINS .. "/chess.koplugin/_meta.lua"))
    assert.are.equal(META_NEW, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    local seen = table.concat(H.texts(), "\n")
    assert.is_truthy(seen:find("Wordle (KOReader 2099.01)", 1, true))
  end)

  it("le compteur de mises à jour suit le manifeste en cache", function()
    setup_device()
    local pm = load_pm(server())
    pm._manifest = require("rapidjson").decode(MANIFEST_JSON)
    local updates = pm:pendingUpdates(pm._manifest)
    assert.are.equal(1, #updates)
    assert.are.equal("Mettre à jour (1)", pm:updateEntryText())
    pm:setIgnoredVersion("sudoku", "2.5.0")
    assert.are.equal("Mettre à jour", pm:updateEntryText())
  end)

  it("l'import installe ce qui manque et ne touche pas au reste", function()
    setup_device()
    local pm = load_pm(server())
    local manifest = require("rapidjson").decode(MANIFEST_JSON)
    local plan = require("pmlogic").planImport({
      format = "pluginmanager-export",
      plugins = { { id = "sudoku" }, { id = "chess" }, { id = "wordle" } },
    }, manifest.plugins, pm:scanInstalled())
    local to_install, skipped = pm:_splitCompatible(plan.install)
    assert.are.equal(1, #to_install)
    assert.are.equal(1, #skipped)
    pm:_runImport(manifest, to_install, {}, skipped)
    H.drain()
    assert.is_truthy(exists(PLUGINS .. "/chess.koplugin/_meta.lua"))
    assert.is_falsy(exists(PLUGINS .. "/wordle.koplugin"))
    -- Present plugin left as it was (no update as a side effect).
    assert.are.equal(META_OLD, read(PLUGINS .. "/sudoku.koplugin/_meta.lua"))
    local seen = table.concat(H.texts(), "\n")
    assert.is_truthy(seen:find("Redémarrez KOReader", 1, true))
  end)
end)
