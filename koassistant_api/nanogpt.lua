-- NanoGPT's chat endpoint uses OpenAI-compatible messages, tools, and SSE.
local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local Handler = OpenAICompatibleHandler:new()

function Handler:getProviderName()
    return "NanoGPT"
end

function Handler:getProviderKey()
    return "nanogpt"
end

function Handler:getResponseParserKey()
    return "openai"
end

function Handler:customizeRequestBody(body, config)
    local enabled = config.enable_web_search
    if enabled == nil then
        enabled = config.features and config.features.enable_web_search or false
    end
    -- A saved suffix can otherwise keep searching after the switch is off.
    body.model = body.model:gsub(":online[%w%-%/]*$", "")
    if enabled and not config.tools then
        local effort = ModelConstraints.webSearchEffort(config.features)
        body.webSearch = { enabled = true,
            depth = effort == "thorough" and "deep" or "standard" }
    end

    -- NanoGPT accepts this field globally, but individual hosted models may not.
    -- The profile registry therefore grants it only for known compatible families.
    local reasoning = config.api_params and config.api_params.nanogpt_reasoning
    if reasoning and reasoning.effort then
        body.reasoning_effort = reasoning.effort
    end
    return body
end

return Handler
