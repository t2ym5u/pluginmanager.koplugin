-- Spec for pathguard.lua — the only code in this collection that can delete a
-- user's files. Self-contained and free of KOReader dependencies, which is
-- exactly why the logic was pulled out of main.lua.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local PathGuard = require("pathguard")

local ROOT = "/mnt/onboard/.adds/koreader/plugins"

describe("PathGuard.isWithin", function()

    it("allows a plugin directory inside the plugins folder", function()
        assert.is_true(PathGuard.isWithin(ROOT, ROOT .. "/sudoku.koplugin"))
        assert.is_true(PathGuard.isWithin(ROOT, ROOT .. "/sudoku.koplugin/board.lua"))
    end)

    it("refuses a sibling whose name merely starts with the plugins folder", function()
        -- The bug this replaces: find(path, root, 1, true) is a substring
        -- test, so every one of these used to pass and be deleted.
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. "-backup/my-saves"))
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. "_old"))
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. ".bak/anything"))
    end)

    it("refuses a path that merely contains the plugins folder further along", function()
        assert.is_false(PathGuard.isWithin(ROOT, "/tmp/elsewhere" .. ROOT))
    end)

    it("refuses the plugins folder itself", function()
        assert.is_false(PathGuard.isWithin(ROOT, ROOT))
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. "/"))
    end)

    it("refuses any path with a .. segment", function()
        -- entry.dir comes from a manifest fetched over the network.
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. "/../../etc"))
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. "/foo/../../bar"))
        assert.is_false(PathGuard.isWithin(ROOT, ROOT .. "/.."))
    end)

    it("tolerates a trailing slash on the root", function()
        assert.is_true(PathGuard.isWithin(ROOT .. "/", ROOT .. "/sudoku.koplugin"))
        assert.is_false(PathGuard.isWithin(ROOT .. "/", ROOT .. "-backup/x"))
    end)

    it("refuses empty and non-string input rather than guessing", function()
        assert.is_false(PathGuard.isWithin(ROOT, ""))
        assert.is_false(PathGuard.isWithin("", ROOT .. "/x"))
        assert.is_false(PathGuard.isWithin(ROOT, nil))
        assert.is_false(PathGuard.isWithin(nil, ROOT .. "/x"))
    end)
end)

describe("PathGuard.isSafeName", function()

    it("accepts a plain plugin directory name", function()
        assert.is_true(PathGuard.isSafeName("sudoku.koplugin"))
        assert.is_true(PathGuard.isSafeName("2048.koplugin"))
    end)

    it("refuses anything that could walk out of the folder", function()
        assert.is_false(PathGuard.isSafeName(".."))
        assert.is_false(PathGuard.isSafeName("."))
        assert.is_false(PathGuard.isSafeName("../evil"))
        assert.is_false(PathGuard.isSafeName("a/b"))
        assert.is_false(PathGuard.isSafeName("a\\b"))
    end)

    it("refuses hidden names and empty input", function()
        assert.is_false(PathGuard.isSafeName(".git"))
        assert.is_false(PathGuard.isSafeName(""))
        assert.is_false(PathGuard.isSafeName(nil))
        assert.is_false(PathGuard.isSafeName(42))
    end)
end)

describe("PathGuard.pluginPath", function()

    it("builds the path for a name it trusts", function()
        assert.are.equal(ROOT .. "/sudoku.koplugin",
                         PathGuard.pluginPath(ROOT, "sudoku.koplugin"))
    end)

    it("returns nil rather than a path it would have to refuse later", function()
        assert.is_nil(PathGuard.pluginPath(ROOT, "../../etc"))
        assert.is_nil(PathGuard.pluginPath(ROOT, ".."))
        assert.is_nil(PathGuard.pluginPath(ROOT, "a/b"))
        assert.is_nil(PathGuard.pluginPath(ROOT, ""))
    end)
end)

describe("PathGuard.shellQuote", function()
    -- Only the no-lfs fallback uses the shell, but an unquoted path with a
    -- space in it hands `rm -rf` two targets instead of one.

    it("quotes a path containing spaces", function()
        assert.are.equal("'/a/my game.koplugin'", PathGuard.shellQuote("/a/my game.koplugin"))
    end)

    it("closes and reopens the quoting around an embedded quote", function()
        assert.are.equal([['/a/it'\''s']], PathGuard.shellQuote("/a/it's"))
    end)

    it("leaves shell metacharacters inert", function()
        local q = PathGuard.shellQuote("/a/x; rm -rf ~")
        assert.are.equal("'/a/x; rm -rf ~'", q)
    end)
end)
