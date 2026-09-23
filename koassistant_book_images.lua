-- Images embedded in an EPUB/CBZ.  BusyBox unzip is available on KOReader's
-- Kindle builds; use stdout extraction so archive paths never touch the disk.
local BookImages = {}

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function supportedBook(path)
    if type(path) ~= "string" then return false end
    local ext = path:lower():match("%.([^.]+)$")
    return ext == "epub" or ext == "cbz" or ext == "zip"
end

local function imageExtension(name)
    local ext = type(name) == "string" and name:lower():match("%.([^.]+)$")
    if ext == "jpg" or ext == "jpeg" or ext == "png" then return ext end
end

local function readSmallEntry(archive, name)
    local pipe = io.popen("unzip -p " .. shellQuote(archive) .. " "
        .. shellQuote(name) .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local contents = pipe:read(512 * 1024 + 1)
    pipe:close()
    return contents and #contents <= 512 * 1024 and contents or nil
end

local function xmlAttribute(tag, attribute)
    local key = attribute:gsub("([^%w])", "%%%1")
    return tag:match(key .. '%s*=%s*"([^"]+)"')
        or tag:match(key .. "%s*=%s*'([^']+)'")
end

local function normalizedArchivePath(dir, href)
    local parts = {}
    href = href:gsub("#.*$", ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    for part in (dir .. "/" .. href):gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return table.concat(parts, "/")
end

local function epubCoverPath(archive)
    local container = readSmallEntry(archive, "META-INF/container.xml")
    local package = container and container:match("<rootfile%s+[^>]*>")
    local opf_name = package and xmlAttribute(package, "full-path")
    if not opf_name then return nil end
    local opf = readSmallEntry(archive, opf_name)
    if not opf then return nil end
    local cover_id
    for meta in opf:gmatch("<meta%s+[^>]*>") do
        if xmlAttribute(meta, "name") == "cover" then
            cover_id = xmlAttribute(meta, "content")
            break
        end
    end
    local directory = opf_name:match("^(.*)/") or ""
    for item in opf:gmatch("<item%s+[^>]*>") do
        local props = xmlAttribute(item, "properties") or ""
        if (cover_id and xmlAttribute(item, "id") == cover_id)
            or props:match("%f[%w]cover%-image%f[%W]") then
            local href = xmlAttribute(item, "href")
            if href and imageExtension(href) then
                return normalizedArchivePath(directory, href)
            end
        end
    end
end

function BookImages.list(path)
    if not supportedBook(path) then return nil, "Book images are available for EPUB and CBZ files." end
    local pipe = io.popen("unzip -l " .. shellQuote(path) .. " 2>/dev/null", "r")
    if not pipe then return nil, "Could not open the book archive." end
    local images = {}
    local cover_path = path:lower():match("%.epub$") and epubCoverPath(path)
    for line in pipe:lines() do
        local size, name = line:match("^%s*(%d+)%s+%S+%s+%S+%s+(.+)%s*$")
        size = tonumber(size)
        if size and name and size > 0 and size <= 15 * 1024 * 1024
            and not name:find("[\r\n]") and not name:match("^%-")
            and imageExtension(name) then
            images[#images + 1] = {
                name = name,
                label = name:match("([^/]+)$") or name,
                size = size,
                cover = name == cover_path
                    or name:lower():find("cover", 1, true) ~= nil,
            }
        end
    end
    pipe:close()
    table.sort(images, function(a, b)
        if a.cover ~= b.cover then return a.cover end
        return a.name:lower() < b.name:lower()
    end)
    return images
end

function BookImages.extract(path, entry)
    if not supportedBook(path) or type(entry) ~= "table"
        or type(entry.name) ~= "string" or not imageExtension(entry.name)
        or entry.name:find("[\r\n]") or entry.name:match("^%-") then
        return nil, "Unsupported book image."
    end
    local base = os.tmpname()
    os.remove(base)
    local output = base .. "." .. imageExtension(entry.name)
    local command = "unzip -p " .. shellQuote(path) .. " " .. shellQuote(entry.name)
        .. " > " .. shellQuote(output) .. " 2>/dev/null"
    os.execute(command)
    local file = io.open(output, "rb")
    if not file then return nil, "Could not extract the book image." end
    local header = file:read(8) or ""
    local size = file:seek("end") or 0
    file:close()
    local valid = (imageExtension(entry.name) == "png" and header:sub(1, 8) == "\137PNG\r\n\026\n")
        or (imageExtension(entry.name) ~= "png" and header:sub(1, 3) == "\255\216\255")
    if not valid or size == 0 or size > 15 * 1024 * 1024 then
        os.remove(output)
        return nil, "The book image is invalid or too large."
    end
    return output
end

return BookImages
