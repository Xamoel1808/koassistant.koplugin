-- Collect an OpenAI-compatible SSE chat completion into the ordinary response
-- shape. Background X-Ray builds need a complete result but some gateways close
-- long, silent non-streaming requests before the model finishes.
local json = require("json")

local Collector = {}

function Collector.decode(body)
    if type(body) ~= "string" or body == "" then
        return nil, "Empty streamed response"
    end

    local content, reasoning = {}, {}
    local usage, finish_reason, completed, saw_event
    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        local payload = line:match("^data:%s*(.*)$")
        if payload then
            if payload == "[DONE]" then
                completed = true
            elseif payload ~= "" then
                local ok, event = pcall(json.decode, payload)
                if not ok or type(event) ~= "table" then
                    return nil, "Invalid streamed response event"
                end
                saw_event = true
                if event.error then
                    local err = event.error
                    return nil, type(err) == "table" and (err.message or err.type)
                        or tostring(err)
                end
                local choice = event.choices and event.choices[1]
                if choice then
                    local delta = choice.delta or {}
                    if type(delta.content) == "string" then
                        content[#content + 1] = delta.content
                    end
                    local thought = delta.reasoning_content or delta.reasoning
                    if type(thought) == "string" then
                        reasoning[#reasoning + 1] = thought
                    end
                    if choice.finish_reason then
                        finish_reason = choice.finish_reason
                        completed = true
                    end
                end
                if type(event.usage) == "table" then usage = event.usage end
            end
        end
    end
    if not saw_event or not completed then
        return nil, "Stream ended before the model completed its response"
    end
    if finish_reason == "length" then
        return nil, "X-Ray response reached the model's output limit"
    end
    local answer = table.concat(content)
    if answer == "" then
        return nil, "Stream completed without X-Ray content"
    end
    return {
        choices = {{
            message = { content = answer, reasoning_content = table.concat(reasoning) },
            finish_reason = finish_reason or "stop",
        }},
        usage = usage,
    }
end

return Collector
