package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local json = require("json")
local Commons = require("koassistant_commons_images")

local url = Commons.searchUrl("Silver Key & castle")
assert(url:find("gsrnamespace=6", 1, true), "searches only Commons files")
assert(url:find("Silver%%20Key%%20%%26%%20castle"), "search term is URL encoded")

local payload = json.encode({ query = { pages = {
    { title = "File:Glass Keep.jpg", imageinfo = {{
        thumburl = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Glass_Keep.jpg/640px-Glass_Keep.jpg",
        thumbmime = "image/jpeg",
        descriptionurl = "https://commons.wikimedia.org/wiki/File:Glass_Keep.jpg",
        extmetadata = {
            LicenseShortName = { value = "CC BY-SA 4.0" },
            Artist = { value = "<a href=\"#\">A &amp; B</a>" },
        },
    }}},
    { title = "File:Bad.svg", imageinfo = {{
        thumburl = "https://evil.example/image.jpg", thumbmime = "image/jpeg",
    }}},
} } })

local results = assert(Commons.parseSearch(payload))
assert(#results == 1, "unsafe image hosts are ignored")
assert(results[1].title == "Glass Keep.jpg", "file prefix removed")
assert(results[1].license == "CC BY-SA 4.0", "license retained")
assert(results[1].artist == "A & B", "artist HTML simplified")
assert(results[1].extension == ".jpg", "thumbnail extension follows MIME")
assert(not Commons.isSafeImageUrl("https://upload.wikimedia.org.evil.example/a.png"),
    "lookalike host is rejected")

print("Commons image tests passed")
return true
