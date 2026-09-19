-- Unit tests for what behavior_loader.lua and domain_loader.lua refuse to load.
--
-- Copying a plugin folder from a Mac to a Kobo writes a macOS AppleDouble
-- sidecar ("._name") next to every file that carries an extended attribute, and
-- a GitHub download stamps one on all of them. "._standard.md" ends in .md like
-- the real file, so the loader used to take it: the behavior became 4 KB of
-- binary, and every request built from it was rejected by the provider with
-- "There was an error parsing the body" (issue #112). Finder never shows those
-- files, so nothing about it was visible to the reader.
--
-- Run: lua tests/unit/test_loader_junk_files.lua

local plugin_dir
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local BehaviorLoader = require("behavior_loader")
local DomainLoader = require("domain_loader")
local TestRunner = require("test_runner"):new()

-- A real AppleDouble header, as macOS writes it onto a FAT volume: the magic,
-- the "Mac OS X" creator, the attribute block naming com.apple.quarantine, and
-- the standard filler. Lifted from a device copy (koassistant.koplugin/domains).
local APPLEDOUBLE = "\0\5\22\7\0\2\0\0Mac OS X        \0\2\0\0\0\9"
    .. "ATTR\0\0\0\0com.apple.quarantine\0" .. "0081;6aae4ded;Chrome;B640B31C"
    .. string.rep("\0", 64) .. "This resource fork intentionally left blank"
    .. string.rep("\0", 16)

local CLEAN = "# Test Behavior\n\nPlain text that must still load.\n"
local TRUNCATED = "# Test\n\nA multi-byte character cut in half: caf\195"

-- Distinct names so a crashed run never eats a reader's own file.
local FIXTURES = {
    ["._koa_test_junk.md"] = APPLEDOUBLE,       -- the AppleDouble sidecar
    [".koa_test_hidden.md"] = CLEAN,            -- an ordinary dotfile
    ["koa_test_corrupt.md"] = TRUNCATED,        -- a real name, damaged content
    ["koa_test_clean.md"] = CLEAN,              -- the control
}

local function write(dir, name, content)
    local fh = io.open(dir .. name, "wb")
    if not fh then return false end
    fh:write(content)
    fh:close()
    return true
end

local function place(dir)
    for name, content in pairs(FIXTURES) do
        os.remove(dir .. name)   -- a previous crashed run
        if not write(dir, name, content) then return false end
    end
    return true
end

local function clear(dir)
    for name in pairs(FIXTURES) do os.remove(dir .. name) end
end

local function check(label, dir, load_fn)
    local ok = place(dir)
    if not ok then
        TestRunner:assertTrue(true, label .. ": folder not writable, nothing asserted")
        return
    end
    local loaded = load_fn()
    clear(dir)

    TestRunner:assertEqual(loaded["._koa_test_junk"], nil,
        label .. ": the AppleDouble sidecar is not loaded")
    TestRunner:assertEqual(loaded[".koa_test_hidden"], nil,
        label .. ": a dotfile is not loaded")
    TestRunner:assertEqual(loaded["koa_test_corrupt"], nil,
        label .. ": a real name with damaged content is not loaded")
    TestRunner:assertTrue(loaded["koa_test_clean"] ~= nil,
        label .. ": a clean file still loads")
end

TestRunner:test("behaviors: junk files are refused, clean files still load", function()
    check("behaviors", plugin_dir .. "/behaviors/", BehaviorLoader.load)
end)

TestRunner:test("domains: junk files are refused, clean files still load", function()
    check("domains", plugin_dir .. "/domains/", DomainLoader.load)
end)

TestRunner:test("the shipped behaviors and domains are all loadable text", function()
    -- The guard must never reject what we ship: every builtin has to pass it.
    local builtin_b = BehaviorLoader.loadBuiltin()
    local n = 0
    for _idx in pairs(builtin_b) do n = n + 1 end
    TestRunner:assertTrue(n > 10, "builtin behaviors still load (" .. n .. ")")
    TestRunner:assertTrue(builtin_b.standard ~= nil, "standard.md loads")
    TestRunner:assertTrue(builtin_b.dictionary_direct ~= nil, "dictionary_direct.md loads")
end)

return TestRunner:summary()
