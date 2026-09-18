--[[
    KOAssistant persistent media for X-Ray entities.

    X-Ray JSON is deliberately rebuildable: the main artifact, sections,
    checkpoints and ladder rungs can all be replaced.  Portraits therefore
    live in this small, independent store instead of in an X-Ray snapshot.

    The index contains only metadata and relative file references.  Image
    bytes are copied below:

        <data dir>/koassistant_entity_media/images/<scope>/<entity>/portrait.<ext>

    A scope is normally a stable Book Group id, or a moved-book-aware book
    scope when the document is not grouped.  Book-local records are checked
    before group records, so a manual override in a later volume wins over an
    inherited portrait.  The matching code intentionally refuses ambiguous
    candidates and short-only cross-book matches.
]]

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local util = require("util")

local EntityMedia = {}

local INDEX_FILENAME = "koassistant_entity_media.lua"
local ROOT_NAME = "koassistant_entity_media"
local IMAGE_DIR_NAME = "images"
local SCHEMA_VERSION = 1
local MAX_HANDLES = 32
local MAX_PROMPT_TEXT = 1400

local test_root
local test_group_resolver
local test_group_lookup

local function rootPath()
    if test_root then return test_root end
    return DataStorage:getDataDir() .. "/" .. ROOT_NAME
end

local function fileMode(path)
    local value = lfs.attributes(path, "mode")
    -- The test fallback returns the complete attribute table even when the
    -- second argument is ignored; real LuaFileSystem returns the string.
    if type(value) == "table" then return value.mode end
    return value
end

local function imageRoot()
    return rootPath() .. "/" .. IMAGE_DIR_NAME
end

local function indexPath()
    return rootPath() .. "/" .. INDEX_FILENAME
end

local function ensureDir(path)
    if fileMode(path) == "directory" then return true end
    local ok = pcall(function() util.makePath(path) end)
    if ok and fileMode(path) == "directory" then return true end
    -- Some small KOReader builds do not expose util.makePath in tests.
    local parts = {}
    for part in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = part end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for _, part in ipairs(parts) do
        if current == "" or current == "/" then
            current = current .. part
        else
            current = current .. "/" .. part
        end
        if fileMode(current) ~= "directory" then
            pcall(lfs.mkdir, current)
        end
    end
    return fileMode(path) == "directory"
end

local function copyFile(source, target)
    local input = io.open(source, "rb")
    if not input then return false, "source image could not be opened" end
    local output, open_err = io.open(target, "wb")
    if not output then
        input:close()
        return false, "managed media directory is not writable: " .. tostring(open_err or "open failed")
    end
    local total = 0
    local write_error
    while true do
        local chunk = input:read(64 * 1024)
        if not chunk then break end
        if chunk == "" then break end
        local ok, err = output:write(chunk)
        if not ok then
            write_error = err or "image copy failed"
            break
        end
        total = total + #chunk
    end
    input:close()
    output:close()
    if write_error then
        os.remove(target)
        return false, tostring(write_error)
    end
    if total == 0 then
        os.remove(target)
        return false, "source image is empty or unreadable"
    end
    return true
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeHandle(value)
    value = trim(value):lower():gsub("%s+", " ")
    return value
end

local function safeSegment(value, fallback)
    value = tostring(value or ""):gsub("[^%w%-%._]", "_")
    value = value:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if value == "" then value = fallback or "item" end
    return value:sub(1, 80)
end

-- A deterministic, bit-library-free id.  It is not intended as a security
-- primitive; it only keeps names and paths short and filesystem-safe.
local function hash(value)
    local h = 2166136261
    value = tostring(value or "")
    for i = 1, #value do
        h = (h * 16777619 + value:byte(i)) % 4294967291
    end
    return string.format("%08x", h)
end

local function now()
    return os.time()
end

local function newStore()
    return { version = SCHEMA_VERSION, next_id = 1, records = {} }
end

local function normalizeStore(value)
    if type(value) ~= "table" then return newStore() end
    value.version = tonumber(value.version) or SCHEMA_VERSION
    value.next_id = tonumber(value.next_id) or 1
    value.records = type(value.records) == "table" and value.records or {}
    if value.version < SCHEMA_VERSION then value.version = SCHEMA_VERSION end
    return value
end

local function readStore()
    ensureDir(rootPath())
    local settings = LuaSettings:open(indexPath())
    return normalizeStore(settings:readSetting("media"))
end

local function writeStore(store)
    ensureDir(rootPath())
    local settings = LuaSettings:open(indexPath())
    settings:saveSetting("media", store)
    if settings.flush then settings:flush() end
end

local function bookKey(file)
    return "book:" .. hash(file)
end

local function groupKey(group_id)
    -- Group ids are already stable in BookGroups, but hashing avoids path
    -- collisions when legacy/user-created ids differ only by punctuation or
    -- case after filesystem sanitization.
    return "group:" .. hash(group_id)
end

local function categoryFamily(category_key)
    local ok, parser = pcall(require, "koassistant_xray_parser")
    if ok and parser.CATEGORY_FAMILY then
        return parser.CATEGORY_FAMILY[category_key] or category_key or "entity"
    end
    return category_key or "entity"
end

local function itemName(item, category_key)
    local ok, parser = pcall(require, "koassistant_xray_parser")
    if ok and parser.getItemName then
        local name = parser.getItemName(item or {}, category_key)
        if type(name) == "string" and name ~= "" and name ~= "Unknown" then
            return name
        end
    end
    local value = item and (item.name or item.term or item.event)
    return type(value) == "string" and value or ""
end

local function identityHandles(item, category_key)
    local out, seen = {}, {}
    local function add(value)
        local raw = trim(value)
        local key = normalizeHandle(raw)
        if raw ~= "" and key ~= "" and not seen[key] and #out < MAX_HANDLES then
            seen[key] = true
            out[#out + 1] = raw
        end
    end
    add(itemName(item, category_key))
    for _, alias in ipairs(type(item) == "table" and item.aliases or {}) do
        if type(alias) == "string" then add(alias) end
    end
    return out
end

local function handleSet(handles)
    local out = {}
    for _, value in ipairs(handles or {}) do
        local key = normalizeHandle(value)
        if key ~= "" then out[key] = true end
    end
    return out
end

local function handlesIntersect(left, right)
    local wanted = handleSet(left)
    local count, matched = 0, {}
    for _, value in ipairs(right or {}) do
        local key = normalizeHandle(value)
        if key ~= "" and wanted[key] and not matched[key] then
            matched[key] = true
            count = count + 1
        end
    end
    return count, matched
end

local function recordHandles(record)
    if type(record) ~= "table" then return {} end
    if type(record.handles) == "table" then return record.handles end
    local out = {}
    if record.canonical_name then out[#out + 1] = record.canonical_name end
    for _, alias in ipairs(record.aliases or {}) do out[#out + 1] = alias end
    return out
end

local function recordMatches(record, handles, family)
    if type(record) ~= "table" or record.family ~= family then return false end
    local count = handlesIntersect(recordHandles(record), handles)
    return count > 0
end

local function getGroups(file)
    if test_group_resolver then
        local ok, groups = pcall(test_group_resolver, file)
        if ok and type(groups) == "table" then return groups end
    end
    local ok, groups = pcall(function()
        return require("koassistant_book_groups").groupsFor(file)
    end)
    return ok and type(groups) == "table" and groups or {}
end

local function groupFor(file, opts)
    if opts and opts.group_id then return opts.group_id end
    local groups = getGroups(file)
    if #groups ~= 1 then return nil end
    local group = groups[1]
    return type(group) == "table" and group.id or nil
end

local function settingsFeatures(opts)
    if opts and type(opts.features) == "table" then return opts.features end
    return {}
end

local function inheritanceEnabled(opts)
    local features = settingsFeatures(opts)
    return features.xray_entity_portraits_inherit_group ~= false
        and not (opts and opts.inherit_group == false)
end

local function recordsInScope(store, scope)
    local bucket = store.records[scope]
    if type(bucket) ~= "table" then
        bucket = {}
        store.records[scope] = bucket
    end
    return bucket
end

local function matchingRecords(store, scope, handles, family)
    local out = {}
    local bucket = store.records[scope]
    if type(bucket) ~= "table" then return out end
    for _, record in pairs(bucket) do
        if recordMatches(record, handles, family) then out[#out + 1] = record end
    end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

local function nextRecordId(store, scope, family, canonical)
    local base = "e_" .. hash(scope .. "\0" .. family .. "\0" .. normalizeHandle(canonical))
    local bucket = recordsInScope(store, scope)
    if not bucket[base] then return base end
    local n = 2
    while bucket[base .. "_" .. n] do n = n + 1 end
    return base .. "_" .. n
end

local function ensureRecord(store, scope, item, category_key, file, force_new)
    local handles = identityHandles(item, category_key)
    local family = categoryFamily(category_key)
    local matches = matchingRecords(store, scope, handles, family)
    if #matches == 1 and not force_new then
        local record = matches[1]
        local seen = handleSet(recordHandles(record))
        for _, value in ipairs(handles) do
            if not seen[normalizeHandle(value)] then
                record.handles = record.handles or {}
                record.handles[#record.handles + 1] = value
            end
        end
        record.canonical_name = record.canonical_name or itemName(item, category_key)
        record.aliases = record.aliases or {}
        record.family = family
        record.category_key = category_key or record.category_key
        record.last_seen_file = file or record.last_seen_file
        return record, false, handles
    end
    if #matches > 1 and not force_new then return nil, true, handles, matches end
    local canonical = itemName(item, category_key)
    local id = nextRecordId(store, scope, family, canonical)
    local record = {
        id = id,
        scope = scope,
        family = family,
        category_key = category_key,
        canonical_name = canonical,
        aliases = {},
        handles = handles,
        source_file = file,
        created_at = now(),
        updated_at = now(),
    }
    recordsInScope(store, scope)[id] = record
    return record, false, handles
end

local function portraitPath(record, extension)
    local ext = extension or (record.portrait and record.portrait.extension) or "png"
    ext = tostring(ext):lower():gsub("[^a-z0-9]", "")
    if ext ~= "jpg" and ext ~= "jpeg" and ext ~= "png" then ext = "png" end
    local scope = safeSegment(record.scope, "scope")
    local entity = safeSegment(record.id, "entity")
    return imageRoot() .. "/" .. scope .. "/" .. entity .. "/portrait." .. ext, ext
end

local function relativePortraitPath(record, extension)
    local _, ext = portraitPath(record, extension)
    return IMAGE_DIR_NAME .. "/" .. safeSegment(record.scope, "scope") .. "/"
        .. safeSegment(record.id, "entity") .. "/portrait." .. ext
end

local function validExtension(path)
    local ext = tostring(path or ""):match("%.([^./\\]+)$")
    ext = ext and ext:lower()
    if ext == "png" or ext == "jpg" or ext == "jpeg" then return ext end
    return nil
end

local function hasFile(path)
    return type(path) == "string" and fileMode(path) == "file"
end

local function setRecordMetadata(record, item, category_key, file)
    local handles = identityHandles(item, category_key)
    local known = handleSet(recordHandles(record))
    record.handles = record.handles or {}
    for _, value in ipairs(handles) do
        if not known[normalizeHandle(value)] then
            record.handles[#record.handles + 1] = value
            known[normalizeHandle(value)] = true
        end
    end
    record.canonical_name = record.canonical_name or itemName(item, category_key)
    record.category_key = category_key or record.category_key
    record.family = categoryFamily(category_key or record.category_key)
    record.last_seen_file = file or record.last_seen_file
    record.updated_at = now()
end

local function safeGroupMatch(local_handles, remote_item, remote_category, record)
    local remote_handles = identityHandles(remote_item, remote_category)
    local count = handlesIntersect(local_handles, remote_handles)
    if count == 0 then return false end
    -- A one-word, short handle is too weak for automatic cross-volume media
    -- inheritance.  A long canonical name or a second alias is enough; a
    -- user-created alias bridge also survives here as a long handle.
    if count >= 2 then return true end
    for _, value in ipairs(local_handles or {}) do
        local normalized = normalizeHandle(value)
        if normalized:find(" ", 1, true) or #normalized >= 5 then return true end
    end
    for _, value in ipairs(recordHandles(record)) do
        local normalized = normalizeHandle(value)
        if normalized:find(" ", 1, true) or #normalized >= 5 then return true end
    end
    for _, value in ipairs(remote_handles) do
        local normalized = normalizeHandle(value)
        if normalized:find(" ", 1, true) or #normalized >= 5 then return true end
    end
    return false
end

local function findGroupCandidates(store, scope, local_handles, family, remote_hits)
    local candidates, seen = {}, {}
    local candidate_scopes = { [scope] = true }
    for _, remote in ipairs(remote_hits or {}) do
        -- A portrait may have been attached before the user created a Book
        -- Group. The normal group/X-Ray identity walk is still the authority
        -- for whether that earlier book is the same entity, so a confident
        -- hit can reuse its book-local record without rewriting it into the
        -- group store.
        if type(remote.file) == "string" and remote.file ~= "" then
            candidate_scopes[bookKey(remote.file)] = true
        end
    end
    local function add(record, remote, record_scope)
        if not record then return end
        local key = tostring(record_scope or scope) .. "\0" .. tostring(record.id)
        if seen[key] then return end
        seen[key] = true
        candidates[#candidates + 1] = {
            record = record,
            remote = remote,
            scope = record_scope or scope,
        }
    end
    for _, hit in ipairs(remote_hits or {}) do
        local remote_handles = identityHandles(hit.item, hit.category_key)
        for candidate_scope in pairs(candidate_scopes) do
            local bucket = store.records[candidate_scope]
            if type(bucket) == "table" then
                for _, record in pairs(bucket) do
                    if recordMatches(record, remote_handles, family)
                        and safeGroupMatch(local_handles, hit.item, hit.category_key, record) then
                        add(record, hit, candidate_scope)
                    end
                end
            end
        end
    end
    return candidates
end

local function safeAlsoInGroup(file, handles, category_key)
    if test_group_lookup then
        local ok, result = pcall(test_group_lookup, file, handles, category_key)
        return ok and type(result) == "table" and result or {}
    end
    local ok, result = pcall(function()
        return require("koassistant_action_cache").alsoInGroup(file, handles, category_key)
    end)
    return ok and type(result) == "table" and result or {}
end

--- Configure test seams.  These are intentionally small and do not alter the
--- production path; unit tests can use a temporary root and deterministic
--- group/X-Ray resolvers without mocking the whole reader.
function EntityMedia._setRootForTests(path)
    test_root = path
end

function EntityMedia._setResolversForTests(group_resolver, group_lookup)
    test_group_resolver = group_resolver
    test_group_lookup = group_lookup
end

function EntityMedia._resetForTests()
    test_root = nil
    test_group_resolver = nil
    test_group_lookup = nil
end

function EntityMedia.getRoot()
    return rootPath()
end

function EntityMedia.getIndexPath()
    return indexPath()
end

function EntityMedia.getImageRoot()
    return imageRoot()
end

function EntityMedia.normalizeHandle(value)
    return normalizeHandle(value)
end

function EntityMedia.identityHandles(item, category_key)
    return identityHandles(item, category_key)
end

--- Return the resolved portrait record.  `ambiguous=true` is deliberate: the
--- caller must not silently choose between two manually assigned portraits.
function EntityMedia.resolve(file, item, category_key, opts)
    if type(file) ~= "string" or file == "" or type(item) ~= "table" then
        return { portrait = nil, record = nil, handles = identityHandles(item, category_key) }
    end
    opts = opts or {}
    local store = readStore()
    local handles = identityHandles(item, category_key)
    local family = categoryFamily(category_key)
    local book_scope = bookKey(file)
    local direct = matchingRecords(store, book_scope, handles, family)
    if #direct > 1 then
        return { ambiguous = true, conflicts = direct, handles = handles, scope = book_scope }
    end
    if #direct == 1 then
        local record = direct[1]
        if record.hidden and not opts.include_hidden then
            return { hidden = true, record = record, handles = handles, scope = book_scope }
        end
        local path = record.portrait and record.portrait.path
        local absolute = path and (rootPath() .. "/" .. path) or nil
        return {
            record = record,
            portrait = absolute and hasFile(absolute) and record.portrait or nil,
            path = absolute and hasFile(absolute) and absolute or nil,
            missing = absolute ~= nil and not hasFile(absolute),
            inherited = false,
            handles = handles,
            scope = book_scope,
        }
    end

    local gid = groupFor(file, opts)
    if not gid or not inheritanceEnabled(opts) then
        return { portrait = nil, handles = handles, scope = book_scope }
    end
    local scope = groupKey(gid)
    local group_direct = matchingRecords(store, scope, handles, family)
    if #group_direct == 1 then
        local record = group_direct[1]
        if not safeGroupMatch(handles, item, category_key, record) then
            -- The record may have been created from a short/common name.  A
            -- later book must not inherit it without a stronger canonical or
            -- alias handle.
            group_direct = {}
        else
        local path = record.portrait and record.portrait.path
        local absolute = path and (rootPath() .. "/" .. path) or nil
        return {
            record = record,
            portrait = absolute and hasFile(absolute) and record.portrait or nil,
            path = absolute and hasFile(absolute) and absolute or nil,
            missing = absolute ~= nil and not hasFile(absolute),
            inherited = true,
            handles = handles,
            scope = scope,
            record_scope = scope,
        }
        end
    elseif #group_direct > 1 then
        return { ambiguous = true, conflicts = group_direct, handles = handles, scope = scope }
    end

    -- ActionCache.alsoInGroup is the same spoiler-aware walk used by the X-Ray
    -- UI.  It excludes unrevealed later volumes, so portrait inheritance never
    -- widens the reader's spoiler surface.
    local remote_hits = safeAlsoInGroup(file, handles, category_key)
    local candidates = findGroupCandidates(store, scope, handles, family, remote_hits)
    if #candidates == 1 then
        local record = candidates[1].record
        local path = record.portrait and record.portrait.path
        local absolute = path and (rootPath() .. "/" .. path) or nil
        return {
            record = record,
            portrait = absolute and hasFile(absolute) and record.portrait or nil,
            path = absolute and hasFile(absolute) and absolute or nil,
            missing = absolute ~= nil and not hasFile(absolute),
            inherited = true,
            matched_remote = candidates[1].remote,
            handles = handles,
            scope = candidates[1].scope,
            group_scope = scope,
            record_scope = candidates[1].scope,
        }
    elseif #candidates > 1 then
        return {
            ambiguous = true,
            conflicts = (function()
                local out = {}
                for _, candidate in ipairs(candidates) do out[#out + 1] = candidate.record end
                return out
            end)(),
            handles = handles,
            scope = scope,
        }
    end
    return { portrait = nil, handles = handles, scope = scope }
end

function EntityMedia.getPortrait(file, item, category_key, opts)
    return EntityMedia.resolve(file, item, category_key, opts).portrait
end

local function chooseScope(store, file, item, category_key, opts, resolved)
    if opts and opts.scope == "book" then return bookKey(file) end
    if opts and opts.scope == "group" then
        local gid = groupFor(file, opts)
        if gid then return groupKey(gid) end
    end
    if resolved and resolved.record and resolved.scope == bookKey(file) then
        return bookKey(file)
    end
    if resolved and (resolved.inherited or (resolved.ambiguous and opts and opts.allow_ambiguous)) then
        -- An explicit user action may create a book-local override when two
        -- merged/group records are ambiguous.  It must never pick or mutate
        -- either conflicting record.
        return bookKey(file)
    end
    local gid = groupFor(file, opts)
    if gid and inheritanceEnabled(opts) then return groupKey(gid) end
    return bookKey(file)
end

local function copyPortraitIntoStore(source_path, record, metadata)
    local extension = validExtension(source_path)
    if not extension then return nil, "unsupported image format (use PNG, JPG, or JPEG)" end
    local destination = portraitPath(record, extension)
    local parent = destination:match("^(.*)/[^/]+$")
    if not ensureDir(parent) then return nil, "managed media directory could not be created" end
    local ok, err = copyFile(source_path, destination)
    if not ok then return nil, err end
    record.portrait = {
        path = relativePortraitPath(record, extension),
        extension = extension,
        source = metadata and metadata.source or "manual",
        created_at = (metadata and metadata.created_at) or now(),
        generation_provider = metadata and metadata.generation_provider,
        generation_model = metadata and metadata.generation_model,
        prompt = metadata and metadata.prompt,
        original = metadata and metadata.original,
    }
    return destination
end

--- Attach an image already on disk.  The source is copied; it is never moved,
--- modified, or left as a fragile reference.
function EntityMedia.attachLocal(file, item, category_key, source_path, opts)
    opts = opts or {}
    if not validExtension(source_path) then
        return false, "unsupported image format (use PNG, JPG, or JPEG)"
    end
    if not hasFile(source_path) then return false, "image file does not exist" end
    local resolved = EntityMedia.resolve(file, item, category_key, opts)
    if resolved.ambiguous and not opts.record and not opts.allow_ambiguous then
        return false, "portrait identity is ambiguous", resolved
    end
    local store = readStore()
    local scope = chooseScope(store, file, item, category_key, opts, resolved)
    local record = opts.record
    if not record then
        record = ensureRecord(store, scope, item, category_key, file,
            resolved.ambiguous and opts.allow_ambiguous == true)
        if type(record) ~= "table" then return false, "portrait identity is ambiguous" end
    end
    if record.portrait and record.portrait.source == "manual" and not opts.replace then
        return false, "a manual portrait is already attached; choose replace explicitly", record
    end
    setRecordMetadata(record, item, category_key, file)
    local destination, err = copyPortraitIntoStore(source_path, record, {
        source = opts.source or "manual",
        generation_provider = opts.generation_provider,
        generation_model = opts.generation_model,
        prompt = opts.prompt,
        original = source_path,
    })
    if not destination then return false, err end
    record.hidden = nil
    writeStore(store)
    return true, destination, record
end

function EntityMedia.attachGenerated(file, item, category_key, source_path, metadata, opts)
    opts = opts or {}
    metadata = metadata or {}
    metadata.source = "generated"
    return EntityMedia.attachLocal(file, item, category_key, source_path, {
        scope = opts.scope,
        replace = opts.replace,
        allow_ambiguous = opts.allow_ambiguous,
        features = opts.features,
        source = "generated",
        generation_provider = metadata.generation_provider or metadata.provider,
        generation_model = metadata.generation_model or metadata.model,
        prompt = metadata.prompt,
    })
end

function EntityMedia.attachExisting(file, item, category_key, source_path, opts)
    opts = opts or {}
    opts.source = "gallery"
    return EntityMedia.attachLocal(file, item, category_key, source_path, opts)
end

--- Remove the association.  By default the managed image is retained so a
--- later explicit re-attach or backup can recover it.  `delete_image=true`
--- only removes an unreferenced managed file.
function EntityMedia.removePortrait(file, item, category_key, opts)
    opts = opts or {}
    local resolved = EntityMedia.resolve(file, item, category_key, { inherit_group = true, include_hidden = true })
    if resolved.ambiguous then return false, "portrait identity is ambiguous", resolved end
    local store = readStore()
    local record = resolved.record
    if not record then return false, "no portrait is attached" end
    local scope = resolved.scope
    local bucket = store.records[scope]
    if type(bucket) ~= "table" or not bucket[record.id] then return false, "portrait is not attached here" end
    local old_path = record.portrait and record.portrait.path
    if resolved.inherited and scope ~= bookKey(file) then
        -- Removing an inherited image is a local reader choice. Do not clear
        -- the shared group/source-book association for every other volume.
        local local_record = ensureRecord(store, bookKey(file), item,
            category_key, file, false)
        local_record.portrait = nil
        local_record.hidden = true
        local_record.updated_at = now()
        writeStore(store)
        return true
    end
    if scope == bookKey(file) then
        -- Removing a local override should reveal a safe group portrait again;
        -- keeping an empty local record would permanently mask inheritance.
        bucket[record.id] = nil
    else
        record.portrait = nil
        record.hidden = nil
        record.updated_at = now()
    end
    writeStore(store)
    if opts.delete_image and old_path then
        local still_used = false
        local fresh = readStore()
        for _, records in pairs(fresh.records) do
            for _, candidate in pairs(type(records) == "table" and records or {}) do
                if candidate.portrait and candidate.portrait.path == old_path then
                    still_used = true
                    break
                end
            end
            if still_used then break end
        end
        if not still_used then os.remove(rootPath() .. "/" .. old_path) end
    end
    return true
end

function EntityMedia.renameEntity(file, item, category_key, old_name)
    local store = readStore()
    local resolved = EntityMedia.resolve(file, item, category_key, { include_hidden = true })
    if not resolved.record then return false end
    local record = resolved.record
    record.aliases = record.aliases or {}
    record.handles = record.handles or {}
    local old_key = normalizeHandle(old_name)
    if old_key ~= "" then
        local known = handleSet(recordHandles(record))
        if not known[old_key] then record.handles[#record.handles + 1] = old_name end
    end
    setRecordMetadata(record, item, category_key, file)
    writeStore(store)
    return true
end

function EntityMedia.updateForMove(old_path, new_path, copy)
    if copy then return end
    local store = readStore()
    local changed = false
    local old_key = bookKey(old_path)
    local new_key = new_path and bookKey(new_path) or nil
    if store.records[old_key] then
        if new_key then
            if store.records[new_key] then
                -- Keep both records if a destination already exists; this is a
                -- user-data conflict, never silently overwrite it.
                for id, record in pairs(store.records[old_key]) do
                    local new_id = id
                    while store.records[new_key][new_id] do new_id = new_id .. "_moved" end
                    record.scope = new_key
                    store.records[new_key][new_id] = record
                end
            else
                store.records[new_key] = store.records[old_key]
                for _, record in pairs(store.records[new_key]) do record.scope = new_key end
            end
            store.records[old_key] = nil
        else
            -- Keep the files and group-level media, but remove a stale local
            -- book scope.  The managed image is intentionally not deleted.
            store.records[old_key] = nil
        end
        changed = true
    end
    for _, records in pairs(store.records) do
        for _, record in pairs(type(records) == "table" and records or {}) do
            if record.source_file == old_path then
                record.source_file = new_path
                changed = true
            end
            if new_path and record.last_seen_file == old_path then
                record.last_seen_file = new_path
                changed = true
            end
        end
    end
    if changed then writeStore(store) end
end

function EntityMedia.listManagedRecords()
    return readStore()
end

--- Metadata-only backup payload.  It contains no base64 image data.
function EntityMedia.exportMetadata()
    return readStore()
end

function EntityMedia.importMetadata(value, merge)
    local incoming = normalizeStore(value)
    if not merge then
        writeStore(incoming)
        return true
    end
    local store = readStore()
    for scope, records in pairs(incoming.records) do
        local target = recordsInScope(store, scope)
        for id, record in pairs(type(records) == "table" and records or {}) do
            if not target[id] then target[id] = record end
        end
    end
    writeStore(store)
    return true
end

--- Return whether the supplied, already spoiler-filtered entity contains a
--- physical/visual description.  Roles and plot descriptions do not count:
--- without this distinction the portrait action could silently turn a lack
--- of appearance information into an invented likeness.
function EntityMedia.hasKnownAppearance(item)
    if type(item) ~= "table" then return false end
    for _, field in ipairs({
        "appearance", "physical_appearance", "physical_description",
        "visual_description", "looks", "portrait_description",
    }) do
        if type(item[field]) == "string" and trim(item[field]) ~= "" then
            return true
        end
    end
    local description = item.description
    if type(description) ~= "string" or trim(description) == "" then return false end
    -- English X-Ray descriptions commonly put appearance in the prose rather
    -- than a dedicated field.  This is intentionally conservative; a false
    -- negative only asks the user to confirm a deliberately generic portrait.
    local words = {}
    for word in description:lower():gmatch("[%a]+") do words[word] = true end
    for _, word in ipairs({
        "hair", "eyes", "face", "skin", "tall", "short", "height", "build",
        "wears", "wearing", "dressed", "clothing", "uniform", "scar", "beard",
        "age", "young", "old", "pale", "dark-haired", "fair-haired",
    }) do
        if words[word] then return true end
    end
    return false
end

--- Build a spoiler-safe portrait prompt from the supplied entity only.  The
--- caller must pass the live/position-safe X-Ray item; this function never
--- reads another X-Ray snapshot or book text.
function EntityMedia.buildPortraitPrompt(item, category_key, book_metadata, opts)
    opts = opts or {}
    local name = itemName(item, category_key)
    local aliases = {}
    for _, alias in ipairs(type(item) == "table" and item.aliases or {}) do
        if type(alias) == "string" and trim(alias) ~= "" then aliases[#aliases + 1] = trim(alias) end
    end
    local details = {}
    local function add(label, value)
        if type(value) == "string" and trim(value) ~= "" then
            value = trim(value)
            if #value > MAX_PROMPT_TEXT then value = value:sub(1, MAX_PROMPT_TEXT) .. "…" end
            details[#details + 1] = label .. ": " .. value
        end
    end
    add("Known description", item and item.description)
    add("Known role", item and item.role)
    add("Known appearance", item and (item.appearance or item.physical_appearance
        or item.physical_description or item.visual_description
        or item.looks or item.portrait_description))
    add("Known background", item and item.background_text)
    if type(item) == "table" and type(item.background) == "table" then
        local background = {}
        for _, value in ipairs(item.background) do
            if type(value) == "string" then background[#background + 1] = value end
        end
        add("Known context", table.concat(background, " "))
    end
    local title = type(book_metadata) == "table" and book_metadata.title or nil
    local style = opts.style or "auto"
    local style_text = style == "auto" and "Choose a suitable restrained visual style for the book" or style
    local lines = {
        "Create a spoiler-safe character reference portrait based only on the information below.",
        "Do not invent plot spoilers, future developments, or information not supplied.",
        "Single character, clear face, upper-body or bust portrait, neutral simple background, no text, no watermark.",
        "Character: " .. (name ~= "" and name or "unnamed entity"),
    }
    if title and title ~= "" then lines[#lines + 1] = "Book: " .. title end
    if #aliases > 0 then lines[#lines + 1] = "Aliases currently known: " .. table.concat(aliases, ", ") end
    if #details > 0 then
        lines[#lines + 1] = table.concat(details, "\n")
    end
    if not EntityMedia.hasKnownAppearance(item) then
        lines[#lines + 1] = "Physical appearance is not established in the supplied information; keep the portrait deliberately non-specific."
    end
    lines[#lines + 1] = "Style: " .. style_text
    if type(opts.custom_instruction) == "string" and trim(opts.custom_instruction) ~= "" then
        lines[#lines + 1] = "Additional user instruction: " .. trim(opts.custom_instruction):sub(1, 300)
    end
    return table.concat(lines, "\n\n")
end

return EntityMedia
