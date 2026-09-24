-- Real archive check for EPUB image selection and the extraction size limit.
package.path = package.path .. ";./?.lua"
local BookImages = require("koassistant_book_images")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)) == 0)

local function write(name, suffix, count)
    local file = assert(io.open(root .. "/" .. name, "wb"))
    file:write("\137PNG\r\n\026\n")
    for _ = 1, count do file:write(suffix) end
    file:close()
end

write("small.png", "test", 1)
write("large.png", string.rep("x", 1024 * 1024), 16)
assert(os.execute("cd " .. string.format("%q", root)
    .. " && python3 -m zipfile -c test.epub small.png large.png") == 0)

local archive = root .. "/test.epub"
local images = assert(BookImages.list(archive))
assert(#images == 1 and images[1].name == "small.png")
local extracted = assert(BookImages.extract(archive, images[1]))
local file = assert(io.open(extracted, "rb"))
assert(file:read("*a") == "\137PNG\r\n\026\ntest")
file:close()
os.remove(extracted)

local too_large, err = BookImages.extract(archive, { name = "large.png" })
assert(too_large == nil and err:find("too large", 1, true))
assert(os.execute("rm -rf " .. string.format("%q", root)) == 0)
return true
