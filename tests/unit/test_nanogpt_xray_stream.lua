local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("(.+)/tests/unit/") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/lib/?.lua;" .. package.path
require("mock_koreader")

local json = require("json")
local Collector = require("koassistant_api.sse_collector")
local Handler = require("koassistant_api.custom_openai")

local complete = table.concat({
    'data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}',
    'data: {"choices":[{"delta":{"content":"{\\\"characters\\\":["}}]}',
    'data: {"choices":[{"delta":{"content":"1]}"},"finish_reason":"stop"}]}',
    'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}',
    'data: [DONE]',
    '',
}, "\n")
local result, err = Collector.decode(complete)
assert(result, err)
assert(result.choices[1].message.content == '{"characters":[1]}')
assert(result.choices[1].message.reasoning_content == "thinking")
assert(result.usage.prompt_tokens == 10)

local partial, partial_err = Collector.decode('data: {"choices":[{"delta":{"content":"partial"}}]}\n')
assert(partial == nil and partial_err:find("before the model completed", 1, true))
local failed, failed_err = Collector.decode('data: {"error":{"message":"gateway busy"}}\n')
assert(failed == nil and failed_err == "gateway busy")

local config = {
    provider = "custom_nanogpt",
    model = "z-ai/glm-5.3-flash",
    api_key = "test-key",
    base_url = "https://nano-gpt.com/api/v1/chat/completions",
    features = { enable_streaming = false, _background_request = true },
}
local original_request = Handler.backgroundRequest
local sent_body
Handler.backgroundRequest = function(_, _, _, body)
    sent_body = json.decode(body)
    return function() end
end
local background = Handler:query({ { role = "user", content = "test" } }, config)
assert(background._non_streaming and background._response_decoder == Collector.decode)
assert(sent_body.stream == true)
local other = Handler:query({ { role = "user", content = "test" } }, {
    provider = "custom_other", model = config.model, api_key = config.api_key,
    base_url = config.base_url, features = config.features,
})
assert(other._response_decoder == nil)
assert(sent_body.stream ~= true)
Handler.backgroundRequest = original_request

print("NanoGPT X-Ray SSE collection: complete, incomplete, error, and provider routing passed")
return true
