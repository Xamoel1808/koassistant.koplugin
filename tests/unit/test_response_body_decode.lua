-- Unit tests for the non-streaming response pipe (issue #111)
-- Covers:
--   * GptQuery.decodeResponseBody — the guard that keeps an empty or non-table
--     body out of the provider transforms
--   * the marker-only buffer, which RateLimits.extractMarker leaves empty
--   * GptQuery.readOutcome — grading one read() result off errno (B325), so a
--     signal-interrupted read is not mistaken for an empty pipe
-- No API calls - tests with mock data.
--
-- Why this exists: KOReader's lpeg json decoder returns nil WITHOUT raising for
-- an empty or whitespace-only string, so the pcall that used to wrap json.decode
-- passed that nil straight into the transform, which indexed it and took the whole
-- app down on a Kindle mid-X-Ray. The guard must not depend on what a given
-- decoder does with "" — dkjson (this harness) and KOReader's json disagree on
-- the shape of the failure, and only the plugin's own check is common to both.

-- Setup paths (detect script location)
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")

    return plugin_dir, tests_dir
end

setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Simple test framework
local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = "",
}

function TestRunner:suite(name)
    self.current_suite = name
    print(string.format("\n  [%s]", name))
end

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:summary()
    print("")
    print(string.format("    %d passed, %d failed", self.passed, self.failed))
    return self.failed == 0
end

local GptQuery = require("koassistant_gpt_query")
local RateLimits = require("koassistant_rate_limits")
local decode = GptQuery.decodeResponseBody
local readOutcome = GptQuery.readOutcome

-- Platform errno values, the same split koassistant_gpt_query.lua makes.
local EINTR = 4
local EAGAIN = (require("ffi").os == "OSX") and 35 or 11

--------------------------------------------------------------------------------
TestRunner:suite("Empty bodies are named, never decoded")
--------------------------------------------------------------------------------

TestRunner:test("empty string reports 'empty'", function()
    local parsed, err = decode("")
    TestRunner:assertNil(parsed, "nothing decoded")
    TestRunner:assertEqual(err, "empty", "reason")
end)

TestRunner:test("whitespace-only bodies report 'empty'", function()
    for _, body in ipairs({ " ", "\n", "\r\n\r\n", "\t \n " }) do
        local parsed, err = decode(body)
        TestRunner:assertNil(parsed, "nothing decoded from " .. string.format("%q", body))
        TestRunner:assertEqual(err, "empty", "reason for " .. string.format("%q", body))
    end
end)

TestRunner:test("a nil buffer reports 'empty' rather than raising", function()
    local parsed, err = decode(nil)
    TestRunner:assertNil(parsed, "nothing decoded")
    TestRunner:assertEqual(err, "empty", "reason")
end)

TestRunner:test("a marker-only buffer is empty once the marker is stripped", function()
    -- The child forwards the provider's rate-limit headers as their own line;
    -- a 200 with no body leaves nothing else behind.
    local marker = RateLimits.encodeMarker({
        ["x-ratelimit-limit-tokens"] = "6000",
        ["x-ratelimit-remaining-tokens"] = "5000",
    })
    TestRunner:assertEqual(type(marker), "string", "marker built")
    local fields, cleaned = RateLimits.extractMarker(marker)
    TestRunner:assertEqual(type(fields), "table", "marker decoded")
    local parsed, err = decode(cleaned)
    TestRunner:assertNil(parsed, "nothing left to decode")
    TestRunner:assertEqual(err, "empty", "reason")
end)

--------------------------------------------------------------------------------
TestRunner:suite("Non-table results never reach a transform")
--------------------------------------------------------------------------------

TestRunner:test("a bare JSON null reports 'unparseable'", function()
    -- KOReader's json decodes null to a TRUTHY function sentinel; indexing it
    -- crashes the same way a nil does.
    local parsed, err = decode("null")
    TestRunner:assertNil(parsed, "sentinel not passed on")
    TestRunner:assertEqual(err, "unparseable", "reason")
end)

TestRunner:test("scalars report 'unparseable'", function()
    for _, body in ipairs({ "5", '"done"', "true" }) do
        local parsed, err = decode(body)
        TestRunner:assertNil(parsed, "scalar not passed on: " .. body)
        TestRunner:assertEqual(err, "unparseable", "reason for " .. body)
    end
end)

TestRunner:test("truncated and non-JSON bodies report 'unparseable'", function()
    for _, body in ipairs({ '{"choices":', "<html>502 Bad Gateway</html>", "Error: boom" }) do
        local parsed, err = decode(body)
        TestRunner:assertNil(parsed, "nothing decoded from " .. body)
        TestRunner:assertEqual(err, "unparseable", "reason for " .. body)
    end
end)

--------------------------------------------------------------------------------
TestRunner:suite("Real bodies pass through")
--------------------------------------------------------------------------------

TestRunner:test("an OpenAI-shaped body decodes with no error", function()
    local parsed, err = decode('{"choices":[{"message":{"content":"hi"}}]}')
    TestRunner:assertNil(err, "no failure reason")
    TestRunner:assertEqual(type(parsed), "table", "decoded")
    TestRunner:assertEqual(parsed.choices[1].message.content, "hi", "content survives")
end)

TestRunner:test("an error envelope decodes (the transform reports it, not the guard)", function()
    local parsed, err = decode('{"error":{"message":"rate limited"}}')
    TestRunner:assertNil(err, "no failure reason")
    TestRunner:assertEqual(parsed.error.message, "rate limited", "error body reaches the transform")
end)

TestRunner:test("an empty JSON object is a real body, not an empty one", function()
    local parsed, err = decode("{}")
    TestRunner:assertNil(err, "no failure reason")
    TestRunner:assertEqual(type(parsed), "table", "decoded")
end)

--------------------------------------------------------------------------------
TestRunner:suite("readOutcome: a -1 read is graded off errno (B325)")
--------------------------------------------------------------------------------

TestRunner:test("bytes read are data, a zero read is EOF", function()
    TestRunner:assertEqual(readOutcome(4096, nil), "data", "positive read")
    TestRunner:assertEqual(readOutcome(1, nil), "data", "one byte")
    TestRunner:assertEqual(readOutcome(0, nil), "eof", "child closed its end")
end)

TestRunner:test("EAGAIN is the ONLY errno that means the pipe is empty", function()
    TestRunner:assertEqual(readOutcome(-1, EAGAIN), "empty", "nothing to read yet")
end)

TestRunner:test("EINTR is retried, never read as an empty pipe", function()
    -- The bug: a signal-interrupted read reads as "nothing there", the drain
    -- stops, and the bytes still queued in the pipe are dropped.
    TestRunner:assertEqual(readOutcome(-1, EINTR), "interrupted", "signal hit the read")
end)

TestRunner:test("every other errno is a failure, not an empty pipe", function()
    for _idx, err in ipairs({ 5, 9, 14, 22 }) do   -- EIO, EBADF, EFAULT, EINVAL
        TestRunner:assertEqual(readOutcome(-1, err), "failed", "errno " .. err)
    end
end)

TestRunner:test("the platform's OTHER EAGAIN value is not treated as empty", function()
    -- EAGAIN is 11 on Linux and 35 on macOS; reading the wrong one as "empty"
    -- would put the bug back on one platform only, which is how the O_NONBLOCK
    -- mix-up in this same poll setup went unnoticed on device for so long.
    local other = (EAGAIN == 11) and 35 or 11
    TestRunner:assertEqual(readOutcome(-1, other), "failed", "the other platform's EAGAIN")
end)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

local success = TestRunner:summary()
return success
