-- Native NanoGPT request contract: search, book tools, and model-specific effort.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/?.lua;"
    .. root .. "/tests/lib/?.lua;" .. package.path
require("mock_koreader")

local Handler = require("koassistant_api.nanogpt")
local Constraints = require("model_constraints")
local Lists = require("koassistant_model_lists")
local TestRunner = require("test_runner"):new()

TestRunner:test("NanoGPT is a native provider with current model IDs", function()
    assert(Lists.nanogpt[1] == "z-ai/glm-5.3-flash")
    assert(Lists.nanogpt[3] == "xiaomi/mimo-v2.6-flash")
    assert(Lists.deepseek[2] == "deepseek-flash")
    assert(Constraints.supportsCapability("nanogpt", Lists.nanogpt[1], "tools"))
    assert(Constraints.supportsWebSearch("nanogpt", Lists.nanogpt[1]))
end)

TestRunner:test("Book Tools use function calls without web search", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "Find a name" } }, {
        api_key = "test", model = "z-ai/glm-5.3-flash",
        features = { enable_web_search = true },
        tools = { mode = "ANY", specs = { {
            name = "search_book", description = "Search book text",
            parameters = { type = "object", properties = {} },
        } } },
    })
    assert(result.url == "https://api.nano-gpt.com/api/v1/chat/completions")
    assert(result.body.tool_choice == "required")
    assert(result.body.tools[1]["function"].name == "search_book")
    assert(result.body.webSearch == nil)
end)

TestRunner:test("Web toggle and depth follow the request", function()
    local config = { api_key = "test", model = "z-ai/glm-5.3-flash:online",
        features = { web_search_effort = "thorough" }, enable_web_search = true }
    local body = Handler:buildRequestBody({}, config).body
    assert(body.model == "z-ai/glm-5.3-flash")
    assert(body.webSearch.enabled and body.webSearch.depth == "deep")
    config.enable_web_search = false
    body = Handler:buildRequestBody({}, config).body
    assert(body.webSearch == nil and body.model == "z-ai/glm-5.3-flash")
end)

TestRunner:test("MiMo sends no unsupported effort; Gemini does", function()
    local mimo = Constraints.resolveReasoning("nanogpt", "xiaomi/mimo-v2.6-flash",
        { global_stance = "maximum" })
    assert(mimo.axis == "none")
    local params = {}
    Constraints.applyReasoningParams("nanogpt", params, mimo)
    assert(params.nanogpt_reasoning == nil)
    local gemini = Constraints.resolveReasoning("nanogpt", "google/gemini-3.5-flash-lite",
        { global_stance = "maximum" })
    Constraints.applyReasoningParams("nanogpt", params, gemini)
    local body = Handler:buildRequestBody({}, { api_key = "test",
        model = "google/gemini-3.5-flash-lite", api_params = params }).body
    assert(body.reasoning_effort == "high")
end)

TestRunner:test("Existing NanoGPT custom key is copied without changing selection", function()
    local Migrations = require("koassistant_migrations")
    local features = {
        provider = "custom_nanogpt", model = "xiaomi/mimo-v2.5",
        custom_providers = { { id = "custom_nanogpt",
            base_url = "https://api.nano-gpt.com/api/v1/chat/completions" } },
        api_keys = { custom_nanogpt = { { key = "example", alias = "original" } } },
    }
    assert(Migrations.run(features))
    assert(features.api_keys.nanogpt[1].key == "example")
    assert(features.api_keys.nanogpt ~= features.api_keys.custom_nanogpt)
    assert(features.provider == "custom_nanogpt" and features.model == "xiaomi/mimo-v2.5")
end)

assert(TestRunner:summary())
