-- Unit tests for BaseHandler.encodeBody: the one place every request body is
-- encoded, and the only guard between reading data and a body the provider
-- cannot parse (issue #112).
--
-- KOReader's LuaJSON ships bytes >= 0x80 verbatim, prints a non-finite number
-- as `NaN`/`Infinity` and the decoder's `undefined` sentinel as a bare
-- `undefined`. Each of those makes the WHOLE request unparseable, so the reader
-- gets a provider error naming nothing they can act on.
--
-- Run: lua tests/unit/test_request_body_sanitize.lua

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

local json = require("json")
local BaseHandler = require("koassistant_api.base")
local TestRunner = require("test_runner"):new()

local encode = BaseHandler.encodeBody

--- The repaired value of a single string field, isolated from the encoder's
--- key ordering.
local function roundTrip(s)
    return json.decode(encode({ v = s })).v
end

-- valid text survives byte for byte

TestRunner:test("ASCII and multi-byte characters are untouched", function()
    TestRunner:assertEqual(roundTrip("plain ascii"), "plain ascii", "ASCII")
    TestRunner:assertEqual(roundTrip("café"), "café", "2-byte")
    TestRunner:assertEqual(roundTrip("東京"), "東京", "3-byte")
    TestRunner:assertEqual(roundTrip("😀"), "😀", "4-byte")
    TestRunner:assertEqual(roundTrip("‘smart’ quotes — dash"), "‘smart’ quotes — dash",
        "the punctuation every EPUB is full of")
    TestRunner:assertEqual(roundTrip(""), "", "empty")
end)

TestRunner:test("a clean body encodes exactly as the bare encoder would", function()
    local body = { model = "m", messages = {{ role = "user", content = "café 東京" }} }
    TestRunner:assertEqual(encode(body), json.encode(body), "no repair, no difference")
end)

-- invalid UTF-8 is dropped, the rest of the text kept

TestRunner:test("stray continuation bytes", function()
    TestRunner:assertEqual(roundTrip("a\128b"), "ab", "lone continuation")
    TestRunner:assertEqual(roundTrip("a\191\191b"), "ab", "two lone continuations")
end)

TestRunner:test("a sequence cut short by a byte cut", function()
    TestRunner:assertEqual(roundTrip("caf\195"), "caf", "2-byte lead, no continuation")
    TestRunner:assertEqual(roundTrip("\230\157"), "", "3-byte truncated to two")
    TestRunner:assertEqual(roundTrip("ab\240\159\152"), "ab", "4-byte truncated to three")
    TestRunner:assertEqual(roundTrip("\230\157\177ab"), "東ab", "complete sequence then ASCII")
end)

TestRunner:test("a cp1252 byte in a title (the #112 shape)", function()
    -- "Café" written by a Windows tool that never converted to UTF-8
    TestRunner:assertEqual(roundTrip("Caf\233 and more"), "Caf and more", "lone 0xE9")
end)

TestRunner:test("the sequences the standard forbids", function()
    TestRunner:assertEqual(roundTrip("a\192\175b"), "ab", "overlong C0")
    TestRunner:assertEqual(roundTrip("a\193\191b"), "ab", "overlong C1")
    TestRunner:assertEqual(roundTrip("a\224\128\128b"), "ab", "overlong E0")
    TestRunner:assertEqual(roundTrip("a\237\160\128b"), "ab", "surrogate ED A0 80")
    TestRunner:assertEqual(roundTrip("a\244\144\128\128b"), "ab", "past U+10FFFF")
    TestRunner:assertEqual(roundTrip("a\245b"), "ab", "F5")
    TestRunner:assertEqual(roundTrip("a\255b"), "ab", "FF")
end)

TestRunner:test("damage deep in the message list is reached", function()
    local body = { messages = {
        { role = "system", content = "clean" },
        { role = "user", content = "From \"Caf\233\" by X" },
    }}
    local out = json.decode(encode(body))
    TestRunner:assertEqual(out.messages[2].content, "From \"Caf\" by X", "nested content repaired")
    TestRunner:assertEqual(out.messages[1].content, "clean", "sibling untouched")
end)

-- numbers the encoder cannot represent

TestRunner:test("non-finite numbers are dropped, finite ones kept", function()
    local out = json.decode(encode({
        nan = 0 / 0, pos = math.huge, neg = -math.huge,
        max_tokens = 32768, temperature = 0.7, zero = 0,
    }))
    TestRunner:assertEqual(out.nan, nil, "NaN dropped")
    TestRunner:assertEqual(out.pos, nil, "Infinity dropped")
    TestRunner:assertEqual(out.neg, nil, "-Infinity dropped")
    TestRunner:assertEqual(out.max_tokens, 32768, "integer kept")
    TestRunner:assertEqual(out.temperature, 0.7, "float kept")
    TestRunner:assertEqual(out.zero, 0, "zero kept")
end)

TestRunner:test("a NaN budget cannot reach the wire as a token", function()
    -- The RateLimits.budgetCap class of bug: a cap that came out NaN used to be
    -- pinned straight onto max_tokens.
    local encoded = encode({ model = "m", max_completion_tokens = 0 / 0 })
    TestRunner:assertTrue(not encoded:find("NaN", 1, true), "no bare NaN token in the body")
    TestRunner:assertTrue(not encoded:find("Infinity", 1, true), "no bare Infinity token")
end)

TestRunner:test("the decoder's undefined sentinel is dropped", function()
    -- Only KOReader's LuaJSON has one: it accepts a provider's non-standard
    -- `undefined` and prints it straight back out, so a replayed tool turn can
    -- carry the token into our next request. The test encoders have no
    -- sentinel, which is why this asserts nothing under them.
    local sentinel = type(json) == "table" and json.util and json.util.undefined
    if not sentinel then
        TestRunner:assertTrue(true, "no sentinel in this encoder: nothing to drop")
        return
    end
    local encoded = encode({ model = "m", arg = sentinel })
    TestRunner:assertTrue(not encoded:find("undefined", 1, true), "no bare undefined token")
end)

-- the caller's tables are never mutated

TestRunner:test("repair copies, it does not write back", function()
    local content = "bad\195"
    local body = { messages = {{ role = "user", content = content }}, n = 0 / 0 }
    encode(body)
    TestRunner:assertEqual(body.messages[1].content, content, "original string untouched")
    TestRunner:assertTrue(body.n ~= body.n, "original NaN field still present")
end)

-- every request body goes through the one encoder

TestRunner:test("no handler encodes a request body directly", function()
    -- A new handler copy-pasting `json.encode(request_body)` would ship the
    -- unguarded body again. The stream re-encode (json.encode of a DECODE of an
    -- already-encoded body) is safe and deliberately not matched here.
    local offenders = {}
    local function scan(path)
        local fh = io.open(path, "r")
        if not fh then return end
        local src = fh:read("*a")
        fh:close()
        local n = 0
        for _idx in src:gmatch("json%.encode%(%s*request_body%s*%)") do n = n + 1 end
        if n > 0 then offenders[#offenders + 1] = path .. " (" .. n .. ")" end
    end

    local handle = io.popen('ls "' .. plugin_dir .. '"/koassistant_api/*.lua 2>/dev/null')
    if handle then
        for line in handle:lines() do scan(line) end
        handle:close()
    end
    scan(plugin_dir .. "/koassistant_image_generator.lua")

    TestRunner:assertEqual(table.concat(offenders, ", "), "",
        "these must call BaseHandler.encodeBody instead")
end)

return TestRunner:summary()
