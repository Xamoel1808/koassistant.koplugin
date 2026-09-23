-- Search Wikimedia Commons for an image that the reader explicitly chooses.
-- Only a search term is sent; book text and X-Ray descriptions stay local.
local json = require("json")
local BaseHandler = require("koassistant_api.base")

local CommonsImages = {}
local API = "https://commons.wikimedia.org/w/api.php"

local function encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

function CommonsImages.searchUrl(query)
    return API .. "?action=query&format=json&formatversion=2"
        .. "&generator=search&gsrnamespace=6&gsrlimit=8&gsrsearch=" .. encode(query)
        .. "&prop=imageinfo&iiprop=url%7Cmime%7Cthumbmime%7Cextmetadata&iiurlwidth=640"
        .. "&iiextmetadatafilter=LicenseShortName%7CArtist"
end

local function plain(value)
    if type(value) ~= "string" then return "" end
    return value:gsub("<[^>]*>", "")
        :gsub("&amp;", "&"):gsub("&quot;", '"')
        :gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :sub(1, 300)
end

local function imageFormat(mime)
    if mime == "image/jpeg" then return ".jpg" end
    if mime == "image/png" then return ".png" end
end

function CommonsImages.isSafeImageUrl(url)
    return type(url) == "string"
        and url:match("^https://upload%.wikimedia%.org/wikipedia/commons/") ~= nil
end

function CommonsImages.parseSearch(body)
    local ok, result = pcall(json.decode, body or "")
    if not ok or type(result) ~= "table" or type(result.query) ~= "table" then
        return nil, "invalid Commons search response"
    end
    local images = {}
    for _, page in ipairs(result.query.pages or {}) do
        local info = type(page.imageinfo) == "table" and page.imageinfo[1] or nil
        local url = info and info.thumburl
        local extension = info and imageFormat(info.thumbmime or info.mime)
        if extension and CommonsImages.isSafeImageUrl(url) then
            local meta = info.extmetadata or {}
            images[#images + 1] = {
                title = plain((page.title or ""):gsub("^File:", "")),
                url = url,
                extension = extension,
                source_page = info.descriptionurl,
                license = plain(meta.LicenseShortName and meta.LicenseShortName.value),
                artist = plain(meta.Artist and meta.Artist.value),
            }
        end
    end
    return images
end

function CommonsImages.search(query, on_done)
    query = tostring(query or ""):match("^%s*(.-)%s*$")
    if query == "" then on_done(nil, "enter a search term") return end
    query = query:sub(1, 200)
    BaseHandler.fetchAsync(CommonsImages.searchUrl(query), { timeout = 30 },
        function(status, body)
            if status ~= 200 then
                on_done(nil, "Commons search failed (HTTP " .. tostring(status or "offline") .. ")")
                return
            end
            on_done(CommonsImages.parseSearch(body))
        end)
end

function CommonsImages.download(image, on_done)
    if type(image) ~= "table" or not CommonsImages.isSafeImageUrl(image.url) then
        on_done(nil, "invalid Commons image URL")
        return
    end
    require("koassistant_image_generator").downloadImageUrl(image.url, function(bytes, err)
        if not bytes then on_done(nil, err or "download failed") return end
        if #bytes > 10 * 1024 * 1024 then
            on_done(nil, "image is too large")
            return
        end
        local extension = image.extension
        local valid = (extension == ".png" and bytes:sub(1, 8) == "\137PNG\r\n\26\n")
            or (extension == ".jpg" and bytes:sub(1, 3) == "\255\216\255")
        if not valid then on_done(nil, "downloaded file is not a supported image") return end
        local path = require("datastorage"):getDataDir()
            .. "/koassistant_commons_preview_" .. os.time()
            .. "_" .. math.random(100000, 999999) .. extension
        local file = io.open(path, "wb")
        if not file then on_done(nil, "could not save preview") return end
        file:write(bytes)
        file:close()
        on_done(path)
    end)
end

return CommonsImages
