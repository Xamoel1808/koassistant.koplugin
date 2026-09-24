-- Unit tests for the persistent X-Ray entity-media store.

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local root = "/tmp/koassistant_entity_media_test"
os.execute('rm -rf "' .. root .. '" && mkdir -p "' .. root .. '/source"')

-- The real plugin uses LuaSettings; the test keeps its small index in memory
-- while image bytes still exercise the actual managed-file copy path.
local stores = {}
local previous_settings = package.loaded["luasettings"]
package.loaded["luasettings"] = {
    open = function(_, path)
        stores[path] = stores[path] or {}
        local data = stores[path]
        local instance = {}
        function instance:readSetting(key) return data[key] end
        function instance:saveSetting(key, value) data[key] = value end
        function instance:flush() end
        return instance
    end,
}

local EntityMedia = require("koassistant_entity_media")
EntityMedia._setRootForTests(root)

local function writeSource(name, bytes)
    local path = root .. "/source/" .. name
    local file = assert(io.open(path, "wb"))
    file:write(bytes or "PNG")
    file:close()
    return path
end

local function assertTrue(value, message)
    if not value then error(message or "expected true", 2) end
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. " (expected " .. tostring(expected)
            .. ", got " .. tostring(actual) .. ")", 2)
    end
end

local group_id = "g-series"
EntityMedia._setResolversForTests(
    function(_file)
        return { { id = group_id } }
    end,
    function(file, _handles, _category)
        if file == "/books/volume-3.epub" then
            return {
                {
                    file = "/books/volume-1.epub",
                    direction = "earlier",
                    item = { name = "Shinei Nouzen", aliases = { "Shin", "Undertaker" } },
                    category_key = "characters",
                },
            }
        end
        return {}
    end)

local shin_v1 = { name = "Shinei Nouzen", aliases = { "Shin" } }
local shin_v3 = { name = "Shin", aliases = { "Undertaker" } }

local source = writeSource("shin.png", "managed portrait")
local ok, path = EntityMedia.attachLocal(
    "/books/volume-1.epub", shin_v1, "characters", source)
assertTrue(ok, "local portrait attaches")
assertTrue(type(path) == "string", "managed path returned")
local managed_file = io.open(path, "rb")
assertTrue(managed_file ~= nil, "source was copied to managed storage")
if managed_file then managed_file:close() end

local direct = EntityMedia.resolve("/books/volume-1.epub", shin_v1, "characters")
assertTrue(direct.portrait ~= nil, "portrait retrieval")
assertEqual(direct.portrait.source, "manual", "manual source metadata")

local commons_item = { name = "Silver Key", description = "An ornate key." }
local commons_source = writeSource("key.jpg", "managed image")
local commons_ok = EntityMedia.attachLocal("/books/volume-1.epub", commons_item,
    "lexicon", commons_source, {
        source = "commons",
        original = "https://upload.wikimedia.org/wikipedia/commons/a/key.jpg",
        source_page = "https://commons.wikimedia.org/wiki/File:Key.jpg",
        license = "CC BY 4.0",
        artist = "Example Artist",
    })
assertTrue(commons_ok, "Commons image attaches to a non-person entry")
local commons_record = EntityMedia.resolve("/books/volume-1.epub", commons_item, "lexicon")
assertEqual(commons_record.portrait.license, "CC BY 4.0", "license persists")
assertEqual(commons_record.portrait.artist, "Example Artist", "artist persists")

local appearance_item = {
    name = "Mira Alvsund",
    aliases = { "Mira" },
    description = "A tall woman with dark hair and a scar over one eye.",
}
assertTrue(EntityMedia.hasKnownAppearance(appearance_item), "appearance is detected")
assertTrue(not EntityMedia.hasKnownAppearance({ name = "Mira", description = "A squad leader." }),
    "role-only description is not treated as physical appearance")
local prompt = EntityMedia.buildPortraitPrompt(appearance_item, "characters",
    { title = "Current Volume" }, { style = "illustrated" })
assertTrue(prompt:find("dark hair", 1, true) ~= nil, "prompt includes known appearance")
assertTrue(prompt:find("future appearance", 1, true) == nil, "prompt has no future data")

local place_prompt = EntityMedia.buildPortraitPrompt(
    { name = "Glass Keep", description = "A tower beside the western lake." },
    "locations", { title = "Current Volume" })
assertTrue(place_prompt:find("landscape or architectural scene", 1, true) ~= nil,
    "location prompt asks for a scene")
assertTrue(place_prompt:find("clear face", 1, true) == nil,
    "location prompt does not ask for a character portrait")
local item_prompt = EntityMedia.buildPortraitPrompt(
    { name = "Silver Key", description = "An ornate key." },
    "lexicon", { title = "Current Volume" })
assertTrue(item_prompt:find("named object or concept", 1, true) ~= nil,
    "non-person entry prompt asks for an object image")

local inherited = EntityMedia.resolve("/books/volume-3.epub", shin_v3, "characters")
assertTrue(inherited.inherited, "group portrait inheritance")
assertTrue(inherited.portrait ~= nil, "inherited portrait is available")

-- Removing an inherited portrait is local to the current volume; it must not
-- clear the shared source used by the earlier volume.
assertTrue(EntityMedia.removePortrait("/books/volume-3.epub", shin_v3, "characters"),
    "removing inherited portrait creates a local hide")
local hidden = EntityMedia.resolve("/books/volume-3.epub", shin_v3, "characters")
assertTrue(hidden.portrait == nil and hidden.hidden, "inherited removal is local")
local source_still_present = EntityMedia.resolve("/books/volume-1.epub", shin_v1, "characters")
assertTrue(source_still_present.portrait ~= nil, "shared portrait survives inherited removal")

-- A later-volume manual assignment becomes a book-local override and never
-- mutates the group portrait.
local override_source = writeSource("override.jpg", "override portrait")
local override_ok = EntityMedia.attachLocal(
    "/books/volume-3.epub", shin_v3, "characters", override_source)
assertTrue(override_ok, "manual later-volume override attaches")
local overridden = EntityMedia.resolve("/books/volume-3.epub", shin_v3, "characters")
assertTrue(not overridden.inherited, "override is book-local")
assertTrue(overridden.portrait ~= nil, "override portrait retrieves")
assertTrue(overridden.path ~= inherited.path, "override does not reuse group file")

-- A second manual image is never silently written over the first one.
local conflict_ok, conflict_error = EntityMedia.attachLocal(
    "/books/volume-3.epub", shin_v3, "characters", source)
assertTrue(not conflict_ok, "manual replacement requires explicit replace")
assertTrue(tostring(conflict_error):find("already attached", 1, true) ~= nil,
    "conflict explains the required action")

-- Explicit replacement is allowed and keeps the association in the same scope.
local replace_ok = EntityMedia.attachLocal(
    "/books/volume-3.epub", shin_v3, "characters", source, { replace = true })
assertTrue(replace_ok, "explicit replacement succeeds")

-- Removing the local override reveals the inherited group portrait again; the
-- managed file remains safe unless an explicit delete is requested.
assertTrue(EntityMedia.removePortrait("/books/volume-3.epub", shin_v3, "characters"),
    "portrait association removal")
local after_remove = EntityMedia.resolve("/books/volume-3.epub", shin_v3, "characters")
assertTrue(after_remove.inherited, "group portrait remains after local removal")
assertTrue(after_remove.portrait ~= nil, "inherited portrait survives removal")

-- Simulate two manually retained records after an entity merge.  Resolution
-- stays ambiguous, but an explicit user choice can create a new book-local
-- override without mutating or deleting either conflicting record.
local media_snapshot = EntityMedia.exportMetadata()
local group_bucket
for scope, records in pairs(media_snapshot.records or {}) do
    if scope:find("^group:") then group_bucket = records break end
end
local original_id, original_record
for id, record in pairs(group_bucket or {}) do
    if record.canonical_name == "Shinei Nouzen" then
        original_id, original_record = id, record
        break
    end
end
assertTrue(original_record ~= nil, "group record available for conflict test")
local conflicting = {}
for key, value in pairs(original_record) do conflicting[key] = value end
conflicting.id = original_id .. "_conflict"
conflicting.portrait = { path = original_record.portrait.path, extension = "png", source = "manual" }
group_bucket[conflicting.id] = conflicting
EntityMedia.importMetadata(media_snapshot, false)
local ambiguous = EntityMedia.resolve("/books/volume-4.epub", shin_v3, "characters")
assertTrue(ambiguous.ambiguous, "conflicting manual portraits remain ambiguous")
local explicit_ok = EntityMedia.attachLocal("/books/volume-4.epub", shin_v3,
    "characters", source, { allow_ambiguous = true, replace = false })
assertTrue(explicit_ok, "explicit ambiguous choice creates a safe local override")
local explicit_resolved = EntityMedia.resolve("/books/volume-4.epub", shin_v3, "characters")
assertTrue(explicit_resolved.path ~= nil and not explicit_resolved.ambiguous,
    "book-local override resolves without destroying conflicts")

-- Gallery attachments are managed copies: deleting the gallery source must not
-- make the portrait disappear.
local gallery_source = writeSource("gallery.jpg", "gallery image")
assertTrue(EntityMedia.attachExisting("/books/volume-1.epub", { name = "Gallery Hero" },
    "characters", gallery_source, { scope = "book" }), "gallery image attaches")
os.remove(gallery_source)
local gallery_portrait = EntityMedia.resolve("/books/volume-1.epub",
    { name = "Gallery Hero" }, "characters")
assertTrue(gallery_portrait.path and gallery_portrait.portrait,
    "managed portrait survives gallery deletion")

-- Short/common names alone are not enough to inherit across a group.
local bob_source = writeSource("bob.png", "bob")
assertTrue(EntityMedia.attachLocal("/books/volume-1.epub", { name = "Bob" },
    "characters", bob_source, { scope = "group" }), "short-name source attaches")
local bob = EntityMedia.resolve("/books/volume-3.epub", { name = "Bob" }, "characters")
assertTrue(bob.portrait == nil, "short/common group name is not auto-inherited")

local bad_ok, bad_error = EntityMedia.attachLocal(
    "/books/volume-1.epub", shin_v1, "characters", root .. "/source/nope.gif")
assertTrue(not bad_ok and tostring(bad_error):find("unsupported", 1, true) ~= nil,
    "unsupported format produces a useful error")

local missing_ok = EntityMedia.attachLocal(
    "/books/volume-1.epub", shin_v1, "characters", root .. "/source/missing.png")
assertTrue(not missing_ok, "missing image is handled gracefully")

-- Moving the book rekeys only its local metadata; group media remains stable.
EntityMedia.attachLocal("/books/volume-1.epub", { name = "Mira Alvsund" },
    "characters", source, { scope = "book" })
EntityMedia.updateForMove("/books/volume-1.epub", "/books/renamed.epub", false)
local moved = EntityMedia.resolve("/books/renamed.epub", { name = "Mira Alvsund" }, "characters")
assertTrue(moved.portrait ~= nil, "book-local portrait survives a book move")

-- These two paths collide under the store's legacy hash. Their local records
-- must still remain independent, including when one book moves.
local same_name = { name = "Collision Hero" }
assertTrue(EntityMedia.attachLocal("/books/volume-1.epub", same_name,
    "characters", source, { scope = "book" }))
assertTrue(EntityMedia.attachLocal("/books/volume-3.epub", same_name,
    "characters", override_source, { scope = "book" }))
local other = EntityMedia.resolve("/books/volume-3.epub", same_name, "characters")
EntityMedia.updateForMove("/books/volume-1.epub", "/books/second-name.epub", false)
assertTrue(EntityMedia.resolve("/books/second-name.epub", same_name, "characters").portrait,
    "moved book keeps its portrait")
assertTrue(EntityMedia.resolve("/books/volume-3.epub", same_name, "characters").path == other.path,
    "moving one colliding book leaves the other untouched")

EntityMedia._resetForTests()
package.loaded["luasettings"] = previous_settings
os.execute('rm -rf "' .. root .. '"')

print("  ✓ Entity media persistence, inheritance, overrides, conflicts, and file handling")
return true
