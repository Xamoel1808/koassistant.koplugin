--[[
Unit tests: ModelLists.resolveModelRefresh — should a persisted features.model be moved to
the provider's current default, reset as stale, or left alone?

Guards defaults_propagation_plan.md §3 (gaps G2/G3): `features.model` conflates a default
auto-baked on provider switch with a model the user deliberately picked, so the refresh
heuristic MUST never clobber an explicit choice, and must never reset a valid/custom model.

Run: lua tests/unit/test_model_refresh.lua  (auto-discovered by run_tests.lua --unit)
]]

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

local TestRunner = require("test_runner"):new()
local ModelLists = require("koassistant_model_lists")

local GEMINI_KNOWN = { "gemini-3.6-flash", "gemini-3.5-flash", "gemini-2.5-flash" }
local GEMINI_SHIPPED = { "gemini-3.6-flash", "gemini-3.5-flash", "gemini-2.5-flash" }

local function resolve(overrides)
    local opts = {
        model = "gemini-3.5-flash",
        current_default = "gemini-3.6-flash",
        explicit = nil,
        known_models = GEMINI_KNOWN,
        shipped_defaults = GEMINI_SHIPPED,
    }
    for k, v in pairs(overrides or {}) do
        if v == "\0nil" then opts[k] = nil else opts[k] = v end
    end
    return ModelLists.resolveModelRefresh(opts)
end

TestRunner:test("resolveModelRefresh — refresh an auto-baked old default", function()
    local action, to = resolve({})
    TestRunner:assertEqual(action, "refresh", "old shipped default is refreshed")
    TestRunner:assertEqual(to, "gemini-3.6-flash", "moves to the current default")
end)

TestRunner:test("resolveModelRefresh — never clobber an explicit pick", function()
    local action = resolve({ explicit = true })
    TestRunner:assertEqual(action, "keep", "explicit pick is pinned even if it is an old default")

    -- The exact regression the flag exists for: user deliberately chose the previous default.
    local action2 = resolve({ model = "gemini-2.5-flash", explicit = true })
    TestRunner:assertEqual(action2, "keep", "explicit older default is kept")
end)

TestRunner:test("resolveModelRefresh — keep a deliberate non-default model", function()
    -- Never shipped as a default, but valid: the user must have picked it.
    local action = resolve({ model = "gemini-2.5-pro", known_models = { "gemini-3.6-flash", "gemini-2.5-pro" } })
    TestRunner:assertEqual(action, "keep", "valid non-default model is left alone")
end)

TestRunner:test("resolveModelRefresh — stale id is reset (G3)", function()
    local action, to = resolve({ model = "gemini-1.0-obsolete" })
    TestRunner:assertEqual(action, "reset", "unknown id is reset")
    TestRunner:assertEqual(to, "gemini-3.6-flash", "reset lands on the current default")
end)

TestRunner:test("resolveModelRefresh — custom models are never stale", function()
    local action = resolve({
        model = "my-local-model",
        known_models = { "gemini-3.6-flash", "my-local-model" },
    })
    TestRunner:assertEqual(action, "keep", "user custom model is preserved")
end)

TestRunner:test("resolveModelRefresh — safe no-ops", function()
    TestRunner:assertEqual(resolve({ model = "\0nil" }), "keep", "nil model")
    TestRunner:assertEqual(resolve({ model = "" }), "keep", "empty model")
    TestRunner:assertEqual(resolve({ current_default = "\0nil" }), "keep", "no current default (custom provider)")
    TestRunner:assertEqual(resolve({ current_default = "" }), "keep", "empty current default")
    TestRunner:assertEqual(resolve({ model = "gemini-3.6-flash" }), "keep", "already on the default")
    TestRunner:assertEqual(ModelLists.resolveModelRefresh(nil), "keep", "nil opts")
    -- No known_models list => cannot judge staleness => must not reset.
    TestRunner:assertEqual(resolve({ model = "who-knows", known_models = "\0nil" }), "keep",
        "absent known list never triggers a reset")
    TestRunner:assertEqual(resolve({ model = "who-knows", known_models = {} }), "keep",
        "empty known list never triggers a reset")
end)

TestRunner:test("_shipped_defaults data integrity", function()
    local shipped = ModelLists._shipped_defaults
    TestRunner:assertTrue(type(shipped) == "table", "_shipped_defaults exists")
    -- The CURRENT default must be present for every provider that has a history, otherwise a
    -- future bump could not tell that today's default was auto-baked.
    for provider, ids in pairs(shipped) do
        local current = (ModelLists[provider] or {})[1]
        if current then
            local found = false
            for _idx, id in ipairs(ids) do
                if id == current then found = true break end
            end
            TestRunner:assertTrue(found,
                string.format("%s: current default '%s' is listed in _shipped_defaults", provider, current))
        end
    end
end)

TestRunner:test("Codex picker promotes GPT-6 and omits old GPT-5.6 models", function()
    TestRunner:assertEqual(ModelLists.openai_codex[1], "gpt-6-sol", "Codex default")
    TestRunner:assertEqual(ModelLists.openai_codex[2], "gpt-6-luna", "Codex fast model")
    for _, model in ipairs(ModelLists.openai_codex) do
        TestRunner:assertTrue(not model:find("gpt-5.6", 1, true), "old Codex model hidden")
    end
    for _, model in ipairs(ModelLists.getImageModels("openai_codex")) do
        TestRunner:assertTrue(not model:find("gpt-5.6", 1, true), "old Codex image model hidden")
    end
end)

TestRunner:test("promoted custom Codex models become built-in without losing other IDs", function()
    local filtered, changed = ModelLists.filterPromotedCustomModels("openai_codex",
        { "gpt-6-luna", "other-model", "gpt-6-sol" })
    TestRunner:assertTrue(changed, "duplicates are found")
    TestRunner:assertEqual(#filtered, 1, "only the unrelated custom model remains")
    TestRunner:assertEqual(filtered[1], "other-model", "custom model preserved")
    local custom, untouched = ModelLists.filterPromotedCustomModels("custom_nanogpt",
        { "gpt-6-sol" })
    TestRunner:assertTrue(not untouched, "custom provider models are untouched")
    TestRunner:assertEqual(custom[1], "gpt-6-sol", "custom provider keeps its model")
end)

local ok = TestRunner:summary()
return ok
