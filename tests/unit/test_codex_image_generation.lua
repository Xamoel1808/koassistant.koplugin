-- OpenAI Subscription/Codex image transport tests. These tests never make a
-- network request; they cover the request/header contract and stream parser.

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")
package.loaded["mime"] = {
    unb64 = function(value) return value end,
    b64 = function(value) return value end,
}

local json = require("json")
local ImageGenerator = require("koassistant_image_generator")

local function ok(value, message)
    if not value then error(message or "expected true", 2) end
end

local function eq(actual, expected, message)
    if actual ~= expected then error((message or "values differ") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end

local auth = {
    access_token = "access-token-for-test",
    refresh_token = "refresh-token-for-test",
    chatgpt_account_id = "acct-test",
    expires_at = os.time() + 3600,
}
local settings = {
    readSetting = function(_, key)
        if key == "features" then return { openai_codex_oauth = auth } end
        return nil
    end,
}

local provider = ImageGenerator.effectiveProvider({}, "openai_codex", settings)
eq(provider, "openai_codex", "subscription provider needs OAuth, not an API key")

local request = ImageGenerator.buildCodexImageRequest("portrait prompt", "gpt-6-sol")
eq(request.model, "gpt-6-sol", "Codex image model")
eq(ImageGenerator.buildCodexImageRequest("portrait prompt").model,
    "gpt-6-sol", "Codex image fallback uses GPT-6")
eq(ImageGenerator.resolveImageModel("openai_codex", {}),
    "gpt-6-sol", "Codex image picker defaults to GPT-6")
eq(request.stream, true, "Codex image stream")
eq(request.store, false, "Codex image store=false")
eq(request.tools[1].type, "image_generation", "image tool type")
eq(request.tool_choice.type, "image_generation", "forced image tool")
eq(request.input[1].content[1].text, "portrait prompt", "prompt is sent as input text")

local headers = ImageGenerator.buildCodexImageHeaders(auth)
eq(headers["ChatGPT-Account-ID"], "acct-test", "ChatGPT account header")
eq(headers.Authorization, "Bearer access-token-for-test", "OAuth bearer header")
eq(headers.Accept, "text/event-stream", "SSE accept header")
ok(headers["X-API-Key"] == nil, "no API key header")

local sse = table.concat({
    "event: response.output_item.done",
    "data: " .. json.encode({
        type = "response.output_item.done",
        item = { type = "image_generation_call", result = "data:image/png;base64,IMAGE_BYTES", revised_prompt = "revised" },
    }),
    "",
    "data: " .. json.encode({
        type = "response.completed",
        response = { status = "completed", output = {}, model = "gpt-6-sol" },
    }),
    "",
}, "\n")
local parsed, parse_error = ImageGenerator.parseCodexImageSSE(sse)
ok(parsed and not parse_error, "completed SSE parses")
eq(parsed.image_data, "IMAGE_BYTES", "image bytes extracted")
eq(parsed.revised_prompt, "revised", "revised prompt extracted")
eq(parsed.model, "gpt-6-sol", "model metadata extracted")

local split = ImageGenerator.parseCodexImageSSE(
    "data: {\"type\":\"response.output_item.done\",\n"
    .. "data: \"item\":{\"type\":\"image_generation_call\",\"result\":\"SPLIT\"}}\n\n")
eq(split.image_data, "SPLIT", "multi-line SSE data block is joined")

local failed, failed_error = ImageGenerator.parseCodexImageSSE(
    "data: " .. json.encode({ type = "response.failed", error = { code = "rate_limit_exceeded", message = "slow down" } }) .. "\n")
ok(not failed, "failed response has no image")
ok(tostring(failed_error):find("slow down", 1, true) ~= nil, "failed error is surfaced")

local malformed, malformed_error = ImageGenerator.parseCodexImageSSE("data: {broken\n")
ok(not malformed, "malformed SSE has no image")
ok(tostring(malformed_error):find("malformed", 1, true) ~= nil, "malformed SSE explains the failure")

eq(ImageGenerator.codexErrorForStatus(401), "OpenAI Subscription authorization expired. Reconnect your ChatGPT account.", "401 handling")
eq(ImageGenerator.codexErrorForStatus(403), "OpenAI Subscription image generation is not permitted for this account or model.", "403 handling")
eq(ImageGenerator.codexErrorForStatus(429), "OpenAI Subscription image-generation usage limit reached. Try again later.", "429 handling")

print("  ✓ Codex subscription image request, headers, SSE, and status handling")
return true
