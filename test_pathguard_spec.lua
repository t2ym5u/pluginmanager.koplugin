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

describe("PathGuard.filePath", function()
    -- These entries name a file to write: one from manifest.json's `files`,
    -- one from inside a downloaded zip. Both are chosen by whoever produced
    -- the manifest or the archive, not by this plugin.
    local ROOT = "/mnt/plugins/sudoku.koplugin"

    it("builds the path for an ordinary file", function()
        assert.are.equal(ROOT .. "/main.lua", PathGuard.filePath(ROOT, "main.lua"))
    end)

    it("allows a subdirectory, which is why isSafeName is not used here", function()
        -- Real entries look like this; a plugin directory name may not.
        assert.are.equal(ROOT .. "/common/i18n.lua",
            PathGuard.filePath(ROOT, "common/i18n.lua"))
        assert.are.equal(ROOT .. "/a/b/c/d.lua",
            PathGuard.filePath(ROOT, "a/b/c/d.lua"))
    end)

    it("refuses an entry that climbs out of the plugin directory", function()
        -- Zip Slip: inside an archive this is how a file lands in someone
        -- else's directory, or over KOReader's own settings.
        assert.is_nil(PathGuard.filePath(ROOT, "../evil.lua"))
        assert.is_nil(PathGuard.filePath(ROOT, "../../evil.lua"))
        assert.is_nil(PathGuard.filePath(ROOT, "../../../../../../etc/passwd"))
    end)

    it("refuses a climb hidden in the middle of the path", function()
        -- The entry looks well-behaved until it is walked.
        assert.is_nil(PathGuard.filePath(ROOT, "common/../../evil.lua"))
        assert.is_nil(PathGuard.filePath(ROOT, "a/b/../../../evil.lua"))
    end)

    it("refuses a climb at the very end", function()
        assert.is_nil(PathGuard.filePath(ROOT, "common/.."))
        assert.is_nil(PathGuard.filePath(ROOT, ".."))
    end)

    it("allows a name that merely begins with dots", function()
        -- "..foo" walks nowhere; only the "." and ".." segments do.
        assert.are.equal(ROOT .. "/..foo.lua", PathGuard.filePath(ROOT, "..foo.lua"))
        assert.are.equal(ROOT .. "/.version", PathGuard.filePath(ROOT, ".version"))
    end)

    it("refuses an absolute entry, which is not a relative path at all", function()
        assert.is_nil(PathGuard.filePath(ROOT, "/etc/passwd"))
        assert.is_nil(PathGuard.filePath(ROOT, "/"))
    end)

    it("refuses a backslash, which two hosts would read differently", function()
        -- A separator on one system, a literal character here: the two
        -- readings disagree about where the file lands.
        assert.is_nil(PathGuard.filePath(ROOT, "..\\evil.lua"))
        assert.is_nil(PathGuard.filePath(ROOT, "common\\i18n.lua"))
    end)

    it("refuses an entry naming a directory rather than a file", function()
        assert.is_nil(PathGuard.filePath(ROOT, "common/"))
        assert.is_nil(PathGuard.filePath(ROOT, ""))
    end)

    it("refuses a null byte, which truncates the path for whatever opens it", function()
        assert.is_nil(PathGuard.filePath(ROOT, "main.lua\0/../../evil.lua"))
    end)

    it("refuses an absurdly long entry rather than passing it on", function()
        assert.is_nil(PathGuard.filePath(ROOT, string.rep("a", 1025)))
        assert.is_truthy(PathGuard.filePath(ROOT, string.rep("a", 1024)))
    end)

    it("refuses non-string input rather than guessing", function()
        assert.is_nil(PathGuard.filePath(ROOT, nil))
        assert.is_nil(PathGuard.filePath(ROOT, 42))
        assert.is_nil(PathGuard.filePath(nil, "main.lua"))
    end)

    it("tolerates a trailing slash on the root", function()
        assert.are.equal(ROOT .. "/main.lua", PathGuard.filePath(ROOT .. "/", "main.lua"))
    end)

    it("agrees with isWithin on everything it returns", function()
        -- filePath is only trustworthy if it never hands back a path isWithin
        -- would have refused, so the two are checked against each other.
        local entries = {
            "main.lua", "common/i18n.lua", "a/b/c.lua", "..foo.lua", ".version",
            "../evil.lua", "common/../../evil.lua", "/etc/passwd", "..", "",
        }
        for _, rel in ipairs(entries) do
            local path = PathGuard.filePath(ROOT, rel)
            if path then
                assert.is_true(PathGuard.isWithin(ROOT, path),
                    "filePath returned a path isWithin refuses: " .. rel)
            end
        end
    end)
end)
