-- Drives "Install everything" end to end against a sandbox device and a
-- fake GitHub (raw files + the contents API): Update's bulk run, then every
-- patch of the manifest's patch_repos, then one summary.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path
local H = require("test_koreader_stubs")

local SRC  = _dir:gsub("/$", "")
local ROOT = os.getenv("TMPDIR") or "/tmp"
ROOT = ROOT:gsub("/$", "") .. "/pluginmanager_everything_spec"
H.root = ROOT
local PLUGINS = ROOT .. "/plugins"
local PATCHES = ROOT .. "/patches"

local function sh(c) os.execute(c) end
local function write(p, s)
  sh(("mkdir -p %q"):format(p:match("^(.*)/[^/]+$")))
  local f = assert(io.open(p, "w")); f:write(s); f:close()
end
local function read(p) local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s end

local MANIFEST_URL = "https://raw.githubusercontent.com/t2ym5u/koreader-plugins/master/manifest.json"
local CONTENTS_URL = "https://api.github.com/repos/t2ym5u/koreader-user-patches/contents"

local function manifest(with_patch_repos)
  return [[{
 "schema_version":1, "updated":"2026-10-30", "repo":"t2ym5u/koreader-plugins",]]
 .. (with_patch_repos and [[ "patch_repos":["t2ym5u/koreader-user-patches"],]] or "") .. [[
 "plugins":[
  {"id":"nonogram","dir":"nonogram.koplugin","fullname":"Nonogram","version":"1.3.0",
   "files":["_meta.lua","board.lua"],"raw_base_url":"https://x/nonogram/"},
  {"id":"chess","dir":"chess.koplugin","fullname":"Chess","version":"1.0.0",
   "files":["_meta.lua"],"raw_base_url":"https://x/chess/"}
 ]}]]
end

local CONTENTS = [=[[
 {"type":"file","name":"2-one.lua","path":"2-one.lua","sha":"s1",
  "download_url":"https://raw.githubusercontent.com/t2ym5u/koreader-user-patches/main/2-one.lua"},
 {"type":"file","name":"2-two.lua","path":"2-two.lua","sha":"s2",
  "download_url":"https://raw.githubusercontent.com/t2ym5u/koreader-user-patches/main/2-two.lua"},
 {"type":"file","name":"README.md","path":"README.md","sha":"s3","download_url":"https://x/readme"}
]]=]

local function server(with_patch_repos)
  return {
    [MANIFEST_URL]                = manifest(with_patch_repos),
    ["https://x/nonogram/_meta.lua"] = 'return { fullname = "Nonogram", version = "1.3.0" }\n',
    ["https://x/nonogram/board.lua"] = "-- nonogram board NEUF\n",
    ["https://x/chess/_meta.lua"]    = 'return { fullname = "Chess", version = "1.0.0" }\n',
    [CONTENTS_URL]                = CONTENTS,
    ["https://raw.githubusercontent.com/t2ym5u/koreader-user-patches/main/2-one.lua"] = "-- patch one\n",
    ["https://raw.githubusercontent.com/t2ym5u/koreader-user-patches/main/2-two.lua"] = "-- patch two\n",
  }
end

-- nonogram 1.2.1 installed (one update), chess not installed (one new).
local function setup_device()
  sh(("rm -rf %q"):format(ROOT))
  sh(("mkdir -p %q"):format(PLUGINS))
  sh(("cp -R %q %q"):format(SRC, PLUGINS .. "/pluginmanager.koplugin"))
  write(PLUGINS .. "/nonogram.koplugin/_meta.lua", 'return { fullname = "Nonogram", version = "1.2.1" }\n')
  write(PLUGINS .. "/nonogram.koplugin/board.lua", "-- nonogram board VIEUX\n")
end

local function load_pm(with_patch_repos)
  for k in pairs(package.loaded) do
    if tostring(k):find("pluginmanager.koplugin") then package.loaded[k] = nil end
  end
  H.messages, H.queue, H.fetched, H.widgets = {}, {}, {}, {}
  H.server = server(with_patch_repos)
  return assert(loadfile(PLUGINS .. "/pluginmanager.koplugin/main.lua"))()
end

local function confirm_box()
  for i = #H.widgets, 1, -1 do
    if H.widgets[i]._widget == "ConfirmBox" then return H.widgets[i] end
  end
end

local function run(pm)
  pm:_doInstallEverything()
  H.drain()
  local box = confirm_box()
  assert.is_truthy(box, "no confirmation shown")
  local announced = box.text
  box.ok_callback()
  H.drain()
  return announced, table.concat(H.texts(), "\n")
end

describe("Tout installer", function()
  it("annonce plugins et patchs, installe tout, un seul résumé avec redémarrage", function()
    setup_device()
    local pm = load_pm(true):new{}
    local announced, seen = run(pm)
    assert.is_truthy(announced:find("Plugins : 1 à installer, 1 à mettre à jour.", 1, true))
    assert.is_truthy(announced:find("Patchs : 2 à installer depuis 1 dépôt(s).", 1, true))
    assert.are.equal("-- nonogram board NEUF\n", read(PLUGINS .. "/nonogram.koplugin/board.lua"))
    assert.is_truthy(read(PLUGINS .. "/chess.koplugin/_meta.lua"))
    assert.are.equal("-- patch one\n", read(PATCHES .. "/2-one.lua"))
    assert.are.equal("-- patch two\n", read(PATCHES .. "/2-two.lua"))
    assert.is_nil(read(PATCHES .. "/README.md"))
    assert.is_truthy(seen:find("2 patch(s) installé(s).", 1, true))
    assert.is_truthy(seen:find("Redémarrez KOReader pour appliquer la mise à jour.", 1, true))
  end)

  it("ne réinstalle pas un patch déjà à jour, ne réactive pas un patch désactivé", function()
    setup_device()
    local pm = load_pm(true):new{}
    write(PATCHES .. "/2-one.lua", "-- patch one\n")
    pm:recordPatchInstall("2-one.lua", { owner = "t2ym5u", name = "koreader-user-patches" }, "2-one.lua", "s1")
    write(PATCHES .. "/2-two.lua.disabled", "-- ancien\n")
    local announced, seen = run(pm)
    assert.is_truthy(announced:find("Patchs : 0 à installer", 1, true))
    assert.is_truthy(announced:find("Laissés désactivés : 2-two.lua", 1, true))
    assert.is_nil(read(PATCHES .. "/2-two.lua"))
    assert.are.equal("-- ancien\n", read(PATCHES .. "/2-two.lua.disabled"))
    for _, u in ipairs(H.fetched) do
      assert.is_falsy(u:find("/2-one.lua", 1, true), "re-downloaded a current patch")
    end
    assert.is_truthy(seen:find("Tous les patchs sont à jour.", 1, true))
  end)

  it("un échec de l'API GitHub n'efface pas les résultats des plugins", function()
    setup_device()
    local pm = load_pm(true):new{}
    H.server[CONTENTS_URL] = nil   -- 404
    local announced, seen = run(pm)
    assert.is_truthy(announced:find("Impossible de lister les patchs de t2ym5u/koreader-user-patches", 1, true))
    assert.are.equal("-- nonogram board NEUF\n", read(PLUGINS .. "/nonogram.koplugin/board.lua"))
    assert.is_truthy(seen:find("2 plugin(s) mis à jour/installé(s).", 1, true))
    assert.is_truthy(seen:find("Impossible de lister les patchs", 1, true))
  end)

  it("un manifeste sans patch_repos fait simplement la mise à jour", function()
    setup_device()
    local pm = load_pm(false):new{}
    local announced = run(pm)
    assert.is_falsy(announced:find("Patchs", 1, true))
    for _, u in ipairs(H.fetched) do assert.is_falsy(u:find("api.github.com", 1, true)) end
    assert.is_truthy(read(PLUGINS .. "/chess.koplugin/_meta.lua"))
  end)

  it("sans rien à faire, pas de confirmation, juste le résumé", function()
    setup_device()
    write(PLUGINS .. "/nonogram.koplugin/_meta.lua", 'return { fullname = "Nonogram", version = "1.3.0" }\n')
    write(PLUGINS .. "/chess.koplugin/_meta.lua", 'return { fullname = "Chess", version = "1.0.0" }\n')
    local pm = load_pm(false):new{}
    pm:_doInstallEverything()
    H.drain()
    assert.is_nil(confirm_box())
    assert.is_truthy(table.concat(H.texts(), "\n"):find("Tous les plugins sont à jour.", 1, true))
  end)
end)
