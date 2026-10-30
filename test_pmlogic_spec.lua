-- Spec for pmlogic.lua: the decisions behind the update count, What's new,
-- the integrity check, min_koreader, screenshots, categories and
-- export/import. No KOReader needed.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local L = require("pmlogic")

describe("isNewer", function()
    it("compares numerically, part by part", function()
        assert.is_true(L.isNewer("1.2.9", "1.2.10"))
        assert.is_false(L.isNewer("1.2.10", "1.2.9"))
        assert.is_false(L.isNewer("1.2.0", "1.2"))
        assert.is_true(L.isNewer(nil, "0.1"))
    end)
end)

describe("changelogSlice", function()
    local CL = table.concat({
        "# Changelog",
        "",
        "All notable changes.",
        "",
        "## [Unreleased]",
        "",
        "### Added",
        "- not shipped yet",
        "",
        "## [1.3.0] - 2026-10-30",
        "",
        "### Changed",
        "- three",
        "",
        "## [1.2.1]",
        "",
        "- two-one",
        "",
        "## [1.2.0] - 2026-09-01",
        "",
        "- two",
        "",
        "## [1.1.0] - 2026-08-01",
        "",
        "- one",
    }, "\n")

    it("keeps only versions newer than installed, up to the offered one", function()
        local s = L.changelogSlice(CL, "1.2.0", "1.3.0")
        assert.is_truthy(s:find("## [1.3.0] - 2026-10-30", 1, true))
        assert.is_truthy(s:find("- two-one", 1, true))
        assert.is_falsy(s:find("- two\n", 1, true))
        assert.is_falsy(s:find("[1.2.0]", 1, true))
        assert.is_falsy(s:find("[1.1.0]", 1, true))
    end)

    it("skips [Unreleased] and the document title", function()
        local s = L.changelogSlice(CL, "1.0.0", "9.9.9")
        assert.is_falsy(s:find("not shipped yet", 1, true))
        assert.is_falsy(s:find("Unreleased", 1, true))
        assert.is_falsy(s:find("# Changelog", 1, true))
        assert.is_falsy(s:find("All notable", 1, true))
    end)

    it("stops at the offered version", function()
        local s = L.changelogSlice(CL, "1.1.0", "1.2.1")
        assert.is_falsy(s:find("[1.3.0]", 1, true))
        assert.is_truthy(s:find("[1.2.1]", 1, true))
        assert.is_truthy(s:find("[1.2.0]", 1, true))
    end)

    it("does not count ### subheadings as versions", function()
        local s, n = L.changelogSlice(CL, "1.2.1", "1.3.0")
        assert.are.equal(4, n)
        assert.is_truthy(s:find("### Changed", 1, true))
    end)

    it("returns nil when no heading parses, so the caller shows the whole file", function()
        local s, n = L.changelogSlice("# Notes\n\nfree text\n## Someday\n", "1.0", "2.0")
        assert.is_nil(s)
        assert.are.equal(0, n)
    end)

    it("returns an empty slice when the file parses but nothing is in range", function()
        local s, n = L.changelogSlice(CL, "1.3.0", "1.3.1")
        assert.are.equal("", s)
        assert.are.equal(4, n)
    end)

    it("accepts bare and v-prefixed headings", function()
        local s = L.changelogSlice("## v2.0.0\n- b\n## 1.0.0 (2026-01-01)\n- a\n", "1.0.0", "2.0.0")
        assert.are.equal("## v2.0.0\n- b", s)
    end)
end)

describe("min_koreader", function()
    it("normalises on KOReader's own scale", function()
        -- Version:getNormalizedVersion("v2026.03") == 202603000000
        assert.are.equal(202603000000, L.normalizeKoreaderVersion("2026.03"))
        assert.are.equal(202603010000, L.normalizeKoreaderVersion("v2026.03.1"))
        assert.is_nil(L.normalizeKoreaderVersion("soon"))
    end)

    it("compares against the running version", function()
        local cur = 202603000012  -- v2026.03-12
        assert.is_true(L.koreaderCompatible("2026.03", cur))
        assert.is_true(L.koreaderCompatible("2025.10", cur))
        assert.is_false(L.koreaderCompatible("2026.04", cur))
    end)

    it("never blocks on what it cannot read", function()
        assert.is_true(L.koreaderCompatible(nil, 1))
        assert.is_true(L.koreaderCompatible("", 1))
        assert.is_true(L.koreaderCompatible("garbage", 1))
        assert.is_true(L.koreaderCompatible("2099.01", nil))
        assert.is_true(L.koreaderCompatible("2099.01", 0))
    end)
end)

describe("pendingUpdates", function()
    local plugins = {
        { id = "a", version = "1.1" },
        { id = "b", version = "2.0" },
        { id = "c", version = "1.0" },
        { id = "d", version = "3.0", min_koreader = "2099.01" },
        { id = "e", version = "5.0" },
    }
    local installed = {
        a = { version = "1.0" }, b = { version = "1.0" }, c = { version = "1.0" }, d = { version = "2.0" },
    }
    it("counts newer, not ignored, compatible -- and reports the blocked ones apart", function()
        local updates, blocked = L.pendingUpdates(plugins, installed,
            function(id, v) return id == "b" and v == "2.0" end,
            function(p) return p.min_koreader == nil end)
        assert.are.equal(1, #updates)
        assert.are.equal("a", updates[1].id)
        assert.are.equal(1, #blocked)
        assert.are.equal("d", blocked[1].id)
    end)
    it("does not count plugins that are not installed", function()
        local updates = L.pendingUpdates(plugins, {}, nil, nil)
        assert.are.equal(0, #updates)
    end)
end)

describe("integrity decisions", function()
    it("verdicts", function()
        assert.are.equal("ok", L.hashVerdict("ABCD", "abcd"))
        assert.are.equal("mismatch", L.hashVerdict("abcd", "abce"))
        -- A manifest without sha256, or no SHA-256 implementation: not a failure.
        assert.are.equal("unverified", L.hashVerdict(nil, "abcd"))
        assert.are.equal("unverified", L.hashVerdict("", "abcd"))
        assert.are.equal("unverified", L.hashVerdict("abcd", nil))
    end)

    it("accepts drift only when the downloaded _meta.lua is at least the manifest's", function()
        assert.is_true(L.driftAcceptable("1.3.0", "1.2.0"))   -- upstream ahead
        assert.is_true(L.driftAcceptable("1.2.0", "1.2.0"))   -- pushed without a bump
        assert.is_false(L.driftAcceptable("1.1.0", "1.2.0"))  -- stale copy
        assert.is_false(L.driftAcceptable(nil, "1.2.0"))      -- no _meta.lua to judge by
    end)

    it("compile check catches a truncated file", function()
        assert.is_true((L.compiles("local t = { 1, 2 }\nreturn t\n", "x.lua")))
        assert.is_false((L.compiles("local t = { 1, 2\nreturn", "x.lua")))
        assert.is_true(L.isLuaFile("common/i18n.lua"))
        assert.is_false(L.isLuaFile("images/x.png"))
    end)
end)

describe("pickScreenshot", function()
    it("prefers the image named after the plugin", function()
        assert.are.equal("images/sudoku.png", L.pickScreenshot("sudoku", { "_meta.lua", "images/sudoku.png" }))
        assert.are.equal("images/arrow-sudoku.png", L.pickScreenshot("arrowsudoku", { "images/arrow-sudoku.png" }))
        assert.are.equal("images/fifteen-puzzle.png",
            L.pickScreenshot("fifteen", { "images/aqueduct.png", "images/bear.png", "images/fifteen-puzzle.png" }))
    end)
    it("takes a lone image as is", function()
        assert.are.equal("images/killer-sudoku.png", L.pickScreenshot("sudokukiller", { "images/killer-sudoku.png" }))
    end)
    it("gives nothing rather than a random game asset", function()
        assert.is_nil(L.pickScreenshot("chess", { "images/wk.png", "images/bk.png" }))
        assert.is_nil(L.pickScreenshot("x", { "main.lua", "pieces/x.png" }))
        assert.is_nil(L.pickScreenshot("x", nil))
    end)
end)

describe("groupByCategory", function()
    it("orders sections, keeps item order, puts unknown and missing under other", function()
        local groups = L.groupByCategory({
            { text = "Z", category = "words" },
            { text = "A", category = "logic" },
            { text = "B" },
            { text = "C", category = "space-opera" },
            { text = "D", category = "logic" },
        })
        assert.are.equal(3, #groups)
        assert.are.equal("logic", groups[1].id)
        assert.are.equal("A", groups[1].items[1].text)
        assert.are.equal("D", groups[1].items[2].text)
        assert.are.equal("words", groups[2].id)
        assert.are.equal("other", groups[3].id)
        assert.are.equal(2, #groups[3].items)
    end)
end)

describe("export / import", function()
    local manifest = {
        { id = "sudoku", fullname = "Sudoku", version = "2.5.0" },
        { id = "wordle", fullname = "Wordle", version = "1.3.0" },
        { id = "chess",  fullname = "Chess",  version = "1.2.0" },
    }

    it("exports only manifest plugins and Discover-linked ones", function()
        local data = L.buildExport(
            { sudoku = { version = "2.4.0" }, calibre = { version = "1.0" }, myplug = { version = "0.1" } },
            manifest,
            { myplug = { owner = "someone", name = "myplug.koplugin" } },
            "2026-10-30")
        assert.are.equal("pluginmanager-export", data.format)
        assert.are.equal(1, #data.plugins)
        assert.are.equal("sudoku", data.plugins[1].id)
        assert.are.equal("2.4.0", data.plugins[1].version)
        assert.are.equal(1, #data.github)
        assert.are.equal("someone/myplug.koplugin", data.github[1].repo)
    end)

    it("plans: install the missing, leave the present, report the unknown", function()
        local plan = L.planImport({
            format  = "pluginmanager-export",
            plugins = { { id = "sudoku" }, { id = "wordle" }, { id = "gone" }, { id = "wordle" } },
            github  = { { id = "myplug", repo = "someone/myplug.koplugin" }, { id = "bad", repo = "../x" } },
        }, manifest, { sudoku = { version = "2.5.0" } })
        assert.are.equal(1, #plan.install)
        assert.are.equal("wordle", plan.install[1].id)
        assert.are.same({ "sudoku" }, plan.present)
        assert.are.same({ "gone" }, plan.unknown)
        assert.are.equal(1, #plan.github)
        assert.are.equal("someone", plan.github[1].owner)
        assert.are.equal("myplug.koplugin", plan.github[1].name)
    end)

    it("refuses a file that is not an export", function()
        assert.is_nil(L.planImport({ plugins = {} }, manifest, {}))
        assert.is_nil(L.planImport(nil, manifest, {}))
        assert.is_nil(L.planImport("x", manifest, {}))
    end)

    it("encodes deterministic, readable JSON that round-trips", function()
        local data = L.buildExport({ wordle = { version = "1.3.0" } }, manifest, {}, "2026-10-30")
        local json = L.encodeJson(data)
        assert.is_truthy(json:find('"format": "pluginmanager-export"', 1, true))
        assert.is_truthy(json:find('"github": []', 1, true))
        assert.is_truthy(json:find('"format_version": 1', 1, true))
        assert.are.equal(json, L.encodeJson(data))
        -- Round trip through the same minimal decoder the other specs use.
        package.path = DIR .. "?.lua;" .. package.path
        local H = require("test_koreader_stubs")  -- luacheck: ignore
        local decoded = require("rapidjson").decode(json)
        local plan = L.planImport(decoded, manifest, {})
        assert.are.equal("wordle", plan.install[1].id)
    end)

    it("escapes strings", function()
        assert.are.equal('"a\\"b\\\\c\\n"', L.encodeJson('a"b\\c\n'))
    end)
end)
