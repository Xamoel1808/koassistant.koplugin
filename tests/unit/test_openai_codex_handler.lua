local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local Handler = require("koassistant_api.openai_codex")
local ModelConstraints = require("model_constraints")
local json = require("json")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: OpenAI Codex Handler")
print(string.rep("=", 50))

local SPECS = {
    {
        name = "search_book",
        description = "Search book text.",
        parameters = { type = "object", properties = { query = { type = "string" } } },
    },
}

local function config(overrides)
    local c = {
        model = "gpt-5.6-terra",
        api_key = "access_token_123",
        system = { text = "You are helpful." },
        oauth = { chatgpt_account_id = "acct_123" },
        features = { enable_streaming = false },
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

TestRunner:test("buildRequestBody targets ChatGPT codex responses endpoint", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, config())
    TestRunner:assertEqual(result.url, "https://chatgpt.com/backend-api/codex/responses", "codex URL")
    TestRunner:assertEqual(result.provider, "openai_codex", "provider id")
    TestRunner:assertEqual(result.parser, "openai_responses", "responses parser")
    TestRunner:assertEqual(result.body.store, false, "stateless request")
    TestRunner:assertEqual(result.body.max_output_tokens, nil, "Codex backend rejects public max_output_tokens")
    TestRunner:assertEqual(result.body.instructions, "You are helpful.", "instructions carried")
end)

TestRunner:test("Codex request fallback uses GPT-6", function()
    local request_config = config()
    request_config.model = nil
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, request_config)
    TestRunner:assertEqual(result.body.model, "gpt-6-sol", "GPT-6 fallback")
end)

TestRunner:test("buildRequestBody uses codex auth headers and account id", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, config())
    TestRunner:assertEqual(result.headers["Authorization"], "Bearer access_token_123", "bearer token")
    TestRunner:assertEqual(result.headers["ChatGPT-Account-ID"], "acct_123", "account header")
    TestRunner:assertTrue(result.headers["User-Agent"]:find("KOAssistant/", 1, true) == 1, "honest user agent")
    TestRunner:assertEqual(result.headers["originator"], "koassistant", "honest originator header")
end)

TestRunner:test("OpenAI Subscription advertises web search support", function()
    TestRunner:assertTrue(ModelConstraints.supportsWebSearch("openai_codex", "gpt-5.6-terra"), "web search gate")
end)

TestRunner:test("web-search effort maps to Codex Responses search context", function()
    local light = config({
        enable_web_search = true,
        features = { enable_streaming = true, web_search_effort = "light" },
    })
    local thorough = config({
        enable_web_search = true,
        features = { enable_streaming = true, web_search_effort = "thorough" },
    })
    local light_body = Handler:buildRequestBody({ { role = "user", content = "news" } }, light).body
    local thorough_body = Handler:buildRequestBody({ { role = "user", content = "news" } }, thorough).body
    TestRunner:assertEqual(light_body.tools[1].type, "web_search", "hosted web-search tool")
    TestRunner:assertEqual(light_body.tools[1].search_context_size, "low", "light search")
    TestRunner:assertEqual(thorough_body.tools[1].search_context_size, "high", "thorough search")
end)

TestRunner:test("buildRequestBody keeps responses tools wire and include for tool turns", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, config({
        tools = { specs = SPECS, mode = "ANY" },
    }))
    TestRunner:assertEqual(result.body.tools[1].type, "function", "flat function tool")
    TestRunner:assertEqual(result.body.tools[1].name, "search_book", "tool name")
    TestRunner:assertEqual(result.body.tool_choice, "required", "ANY => required")
    TestRunner:assertTrue(result.body.include ~= nil, "reasoning include for stateless replay")
end)

TestRunner:test("non-streaming query uses collected SSE transport with Codex headers", function()
    local BaseHandler = require("koassistant_api.base")
    local original_resolve = BaseHandler.resolveForSubprocess
    local original_fetch = BaseHandler.fetchInSubprocess
    local original_write = BaseHandler.writeAllToFD
    local captured, written
    BaseHandler.resolveForSubprocess = function() return "203.0.113.10" end
    BaseHandler.fetchInSubprocess = function(url, opts)
        captured = { url = url, opts = opts }
        return 200, 'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n'
    end
    BaseHandler.writeAllToFD = function(_fd, value) written = value end

    local result = Handler:query({ { role = "user", content = "hello" } }, config())
    result._background_fn(1, 2)

    BaseHandler.resolveForSubprocess = original_resolve
    BaseHandler.fetchInSubprocess = original_fetch
    BaseHandler.writeAllToFD = original_write

    TestRunner:assertEqual(captured.url, "https://chatgpt.com/backend-api/codex/responses", "request url")
    TestRunner:assertEqual(captured.opts.headers["ChatGPT-Account-ID"], "acct_123", "account header forwarded")
    TestRunner:assertTrue(captured.opts.headers["User-Agent"]:find("KOAssistant/", 1, true) == 1, "user agent forwarded")
    TestRunner:assertEqual(captured.opts.headers["originator"], "koassistant", "originator forwarded")
    TestRunner:assertEqual(captured.opts.headers["Accept"], "text/event-stream", "SSE requested")
    TestRunner:assertEqual(json.decode(captured.opts.body).stream, true, "backend always receives stream=true")
    TestRunner:assertEqual(json.decode(written).status, "completed", "SSE collected before pipe write")
end)

TestRunner:test("collected function calls pass through the Responses parser", function()
    local result = Handler:query({ { role = "user", content = "find whales" } }, config({
        tools = { specs = SPECS, mode = "ANY" },
    }))

    local parsed = {
        status = "completed",
        output = {{
            type = "function_call",
            call_id = "call_1",
            name = "search_book",
            arguments = '{"query":"whale"}',
        }},
    }
    local ok, tool_turn = result._response_parser(parsed)
    TestRunner:assertTrue(ok, "response parsed")
    TestRunner:assertTrue(tool_turn._tool_calls, "neutral tool-call turn")
    TestRunner:assertEqual(tool_turn.calls[1].id, "call_1", "call id")
    TestRunner:assertEqual(tool_turn.calls[1].args.query, "whale", "arguments decoded")
end)

return TestRunner:summary()
