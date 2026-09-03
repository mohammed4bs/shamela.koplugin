--[[--
Shamela Library for KOReader

Uses Shamela's official sync endpoint.  Unlike a conventional ebook site, the
endpoint supplies each book as a ZIP archive with SQLite databases.  KOReader
ships libarchive and SQLite bindings, so this plugin extracts the page database locally
and writes a standards-compliant EPUB that can be read immediately.

The endpoint and API key are configurable from the plugin menu. Enter your
own Shamela API key before the first catalog sync.
--]]--

local Archiver = require("ffi/archiver")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local Menu = require("ui/widget/menu")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local lfs = require("libs/libkoreader-lfs")

local Shamela = WidgetContainer:extend{
    name = "shamela",
    is_doc_only = false,
}

local DEFAULT_API_URL = "https://dev.shamela.ws/api/v1"
local DEFAULT_API_KEY = ""
local DEFAULT_DOWNLOAD_DIR = "/mnt/us/documents/"
local USER_AGENT = "Mozilla/5.0 (compatible; KOReader Shamela plugin)"
local PUBLIC_SITE_URL = "https://shamela.ws"
local MAX_PUBLIC_PAGES = 5000

local function safe(fn)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function() return fn(unpack(args)) end, debug.traceback)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Shamela encountered an error:\n%1"), tostring(err)) })
        end
    end
end

local function ensureDir(path)
    if not lfs.attributes(path, "mode") then util.makePath(path) end
    return path
end

local function cacheDir()
    return ensureDir(DataStorage:getFullDataDir() .. "/shamela/")
end

local function getDownloadDir()
    local path = G_reader_settings:readSetting("shamela_download_dir") or DEFAULT_DOWNLOAD_DIR
    if path:sub(-1) ~= "/" then path = path .. "/" end
    return ensureDir(path)
end

local function apiUrl()
    return (G_reader_settings:readSetting("shamela_api_url") or DEFAULT_API_URL):gsub("/+$", "")
end

local function apiKey()
    return G_reader_settings:readSetting("shamela_api_key") or DEFAULT_API_KEY
end

local function requestUrl(path)
    return apiUrl() .. path .. (path:find("?", 1, true) and "&" or "?") .. "api_key=" .. socket_url.escape(apiKey())
end

local function httpGet(url)
    local sink = {}
    socketutil:set_timeout(20, 180)
    local requester = url:match("^https") and https.request or http.request
    local ok, code = requester{
        url = url,
        sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = USER_AGENT, ["Accept-Language"] = "ar,en;q=0.8" },
    }
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    if tonumber(code) < 200 or tonumber(code) >= 300 then return nil, "HTTP " .. tostring(code) end
    return table.concat(sink)
end

local function httpDownload(url, path)
    local file, open_err = io.open(path, "wb")
    if not file then return nil, open_err end
    socketutil:set_timeout(30, 1800)
    local requester = url:match("^https") and https.request or http.request
    local ok, code = requester{
        url = url,
        sink = ltn12.sink.file(file),
        headers = { ["User-Agent"] = USER_AGENT },
    }
    socketutil:reset_timeout()
    if not ok or tonumber(code) < 200 or tonumber(code) >= 300 then
        os.remove(path)
        return nil, ok and ("HTTP " .. tostring(code)) or tostring(code)
    end
    return true
end

local function decodeJson(body)
    local ok, value = pcall(JSON.decode, body)
    if not ok then return nil, tostring(value) end
    return value
end

local function sqlQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

local function dbRows(path, sql)
    local db = SQ3.open(path)
    if not db then return nil, "Could not open SQLite database" end
    local rows = {}
    local ok, dataset, count = pcall(function() return db:exec(sql, "hi") end)
    db:close()
    if not ok then return nil, tostring(dataset) end
    if not dataset or not count or count == 0 then return rows end
    local headers = dataset[0]
    for row_index = 1, count do
        local row = {}
        for column_index, header in ipairs(headers) do
            row[header] = dataset[column_index][row_index]
        end
        table.insert(rows, row)
    end
    return rows
end

local function extractArchive(archive_path, files)
    local archive = Archiver.Reader:new()
    if not archive:open(archive_path) then return nil, archive.err or "invalid ZIP" end
    -- Populate the archive index before extracting by name.
    for _ in archive:iterate() do end
    for name, destination in pairs(files) do
        if archive.entries[name] and not archive:extractToPath(name, destination) then
            archive:close()
            return nil, archive.err or ("could not extract " .. name)
        end
    end
    archive:close()
    return true
end

-- Shamela names a book database with its release number (for example
-- 1681-6.sqlite), so its exact member name is not known until the archive is
-- opened.  Extract the first regular file that matches the supplied pattern.
local function extractFirstMatching(archive_path, pattern, destination)
    local archive = Archiver.Reader:new()
    if not archive:open(archive_path) then return nil, archive.err or "invalid ZIP" end
    local selected
    for entry in archive:iterate() do
        if entry.mode == "file" and entry.path:match(pattern) then
            selected = entry.path
            break
        end
    end
    local ok, err
    if selected then ok, err = archive:extractToPath(selected, destination) else ok, err = nil, "no matching database in archive" end
    archive:close()
    return ok, err
end

local function escapeHtml(text)
    return tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function safeFilename(text)
    text = tostring(text or "book"):gsub('[\\/:*?"<>|]', "_"):gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:sub(1, 100) ~= "" and text:sub(1, 100) or "book"
end

-- lua-ljsqlite3 exposes SQLite INTEGER values as LuaJIT int64 cdata. Its
-- tostring() representation may include an "LL" suffix (e.g. "1681LL"),
-- which is not a valid Shamela book identifier in a URL.
local function bookId(value)
    return tostring(tonumber(value) or value):gsub("LL$", "")
end

local function writeEpub(output, title, author, pages)
    local writer = Archiver.Writer:new{}
    if not writer:open(output .. ".tmp", "epub") then return nil, "could not create EPUB" end
    local mtime = os.time()
    local function put(path, content)
        if not writer:addFileFromMemory(path, content, mtime) then error("could not write " .. path) end
    end
    local ok, err = pcall(function()
        writer:setZipCompression("store")
        put("mimetype", "application/epub+zip")
        writer:setZipCompression("deflate")
        put("META-INF/container.xml", [[<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]])
        local manifest, spine = {}, {}
        for i, page in ipairs(pages) do
            local id = "p" .. i
            local filename = "OEBPS/" .. id .. ".xhtml"
            local body = tostring(page.content or "")
            put(filename, [[<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" dir="rtl"><head><meta charset="utf-8"/><style>body{direction:rtl;text-align:right;font-family:serif;line-height:1.65;margin:5%}hr{border:0;border-top:1px solid #aaa}.page{color:#777;font-size:.8em}</style></head><body><div class="page">]] .. escapeHtml(page.part or "") .. " — " .. escapeHtml(page.page or i) .. "</div>" .. body .. "</body></html>")
            table.insert(manifest, '<item id="' .. id .. '" href="' .. id .. '.xhtml" media-type="application/xhtml+xml"/>')
            table.insert(spine, '<itemref idref="' .. id .. '"/>')
        end
        put("OEBPS/toc.ncx", [[<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="shamela"/></head><docTitle><text>]] .. escapeHtml(title) .. [[</text></docTitle><navMap><navPoint id="start" playOrder="1"><navLabel><text>]] .. escapeHtml(title) .. [[</text></navLabel><content src="p1.xhtml"/></navPoint></navMap></ncx>]])
        put("OEBPS/content.opf", [[<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">shamela-]] .. os.time() .. [[</dc:identifier><dc:title>]] .. escapeHtml(title) .. [[</dc:title><dc:creator>]] .. escapeHtml(author or "") .. [[</dc:creator><dc:language>ar</dc:language></metadata><manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]] .. table.concat(manifest) .. [[</manifest><spine toc="ncx">]] .. table.concat(spine) .. [[</spine></package>]])
    end)
    writer:close()
    if not ok then os.remove(output .. ".tmp"); return nil, tostring(err) end
    os.remove(output)
    if not os.rename(output .. ".tmp", output) then return nil, "could not finalize EPUB" end
    return true
end

function Shamela:ensureMaster()
    local db_path = cacheDir() .. "master.db"
    if lfs.attributes(db_path, "mode") == "file" then return db_path end
    local archive_path = cacheDir() .. "master.zip"
    local body, err = httpGet(requestUrl("/patches/master?version=0"))
    if not body then return nil, err end
    local data, json_err = decodeJson(body)
    if not data or not data.patch_url then return nil, json_err or "Shamela returned no catalog archive" end
    local ok, download_err = httpDownload(data.patch_url, archive_path)
    if not ok then return nil, download_err end
    local extracted, extract_err = extractArchive(archive_path, { ["book.sqlite"] = db_path, ["category.sqlite"] = cacheDir() .. "category.db", ["author.sqlite"] = cacheDir() .. "author.db" })
    os.remove(archive_path)
    if not extracted then return nil, extract_err end
    -- The master archive contains separate databases. Keep the extracted book database as
    -- the catalog source; categories are read from category.db below.
    return db_path
end

function Shamela:loadCategories()
    local _, err = self:ensureMaster()
    if err then return nil, err end
    return dbRows(cacheDir() .. "category.db", "SELECT id, name, `order` FROM category WHERE is_deleted != 1 ORDER BY `order`")
end

function Shamela:loadBooks(where, limit)
    local _, err = self:ensureMaster()
    if err then return nil, err end
    local sql = "SELECT id, name, author, category FROM book WHERE (is_deleted IS NULL OR is_deleted != 1)"
    if where then sql = sql .. " AND " .. where end
    return dbRows(cacheDir() .. "master.db", sql .. " ORDER BY name LIMIT " .. tostring(limit or 120))
end

function Shamela:showBookList(books, title)
    if not books or #books == 0 then UIManager:show(InfoMessage:new{ text = _("No books found.") }); return end
    local items, menu = {}, nil
    table.insert(items, { text = _("‹ Back"), callback = function() UIManager:close(menu) end })
    for _, book in ipairs(books) do
        table.insert(items, { text = book.name or ("#" .. tostring(book.id)), callback = safe(function() self:showBook(book) end) })
    end
    menu = Menu:new{ title = title, item_table = items, width = Screen:getWidth(), height = Screen:getHeight(), close_callback = function() UIManager:close(menu) end }
    UIManager:show(menu)
end

function Shamela:browseCategories()
    local msg = InfoMessage:new{ text = _("Syncing Shamela catalog…") }; UIManager:show(msg); UIManager:forceRePaint()
    local categories, err = self:loadCategories(); UIManager:close(msg)
    if not categories then UIManager:show(InfoMessage:new{ text = T(_("Could not load catalog:\n%1"), err) }); return end
    local items, menu = {}, nil
    table.insert(items, { text = _("All books (first 120)"), callback = safe(function() local b, e = self:loadBooks(); if b then self:showBookList(b, _("All books")) else UIManager:show(InfoMessage:new{ text = e }) end end) })
    for _, category in ipairs(categories) do
        table.insert(items, { text = category.name, callback = safe(function()
            local b, e = self:loadBooks("category = " .. tonumber(category.id)); if b then self:showBookList(b, category.name) else UIManager:show(InfoMessage:new{ text = e }) end
        end) })
    end
    table.insert(items, 1, { text = _("‹ Back"), callback = function() UIManager:close(menu) end })
    menu = Menu:new{ title = _("Shamela categories — التصنيفات"), item_table = items, width = Screen:getWidth(), height = Screen:getHeight(), close_callback = function() UIManager:close(menu) end }
    UIManager:show(menu)
end

function Shamela:convertBook(book)
    local msg = InfoMessage:new{ text = _("Downloading and converting book…") }; UIManager:show(msg); UIManager:forceRePaint()
    local id = bookId(book.id)
    -- A book's internal page IDs are not guaranteed to begin with 1. Read its
    -- public index first and use the first actual page link it contains.
    local index_html, index_err = httpGet(PUBLIC_SITE_URL .. "/book/" .. id)
    if not index_html then
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{ text = T(_("Could not load public book index:\n%1"), index_err) })
        return
    end
    local current_id = index_html:match("/book/" .. id .. "/(%d+)")
    if not current_id then
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{ text = _("This book has no readable public pages.") })
        return
    end
    local pages, seen = {}, {}
    -- The public Shamela reader exposes a key-free JSON endpoint used by its
    -- own “load next page” button. Follow nextId rather than assuming IDs are
    -- consecutive: page IDs can have gaps after editorial updates.
    for page_index = 1, MAX_PUBLIC_PAGES do
        if seen[current_id] then break end
        seen[current_id] = true
        local body, err = httpGet(PUBLIC_SITE_URL .. "/ajax/pageContent/" .. id .. "/" .. current_id)
        if not body then
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = T(_("Could not load public book page:\n%1"), err) })
            return
        end
        local data, json_err = decodeJson(body)
        if not data or not data.nass then
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = T(_("The public reader returned no text:\n%1"), json_err or "") })
            return
        end
        table.insert(pages, { page = data.pageNum, content = data.nass })
        if not data.nextId or tostring(data.nextId) == "" then break end
        current_id = tostring(data.nextId)
    end
    if #pages == 0 then UIManager:close(msg); UIManager:show(InfoMessage:new{ text = _("No readable pages were found.") }); return end
    local path = getDownloadDir() .. safeFilename(book.name) .. ".epub"
    local written, write_err = writeEpub(path, book.name, "", pages)
    UIManager:close(msg)
    if not written then UIManager:show(InfoMessage:new{ text = T(_("Could not create EPUB:\n%1"), write_err) }); return end
    UIManager:show(ConfirmBox:new{ text = T(_("Saved to:\n%1\n\nOpen it now?"), path), ok_text = _("Open"), cancel_text = _("Later"), ok_callback = function()
        if self.ui.document then self.ui:switchDocument(path) else self.ui:openFile(path) end
    end })
end

function Shamela:showBook(book)
    local dialog
    dialog = ButtonDialog:new{ title = (book.name or "") .. "\n#" .. tostring(book.id), buttons = {
        {{ text = _("Download as EPUB"), callback = safe(function() UIManager:close(dialog); self:convertBook(book) end) }},
        {{ text = _("‹ Back"), callback = function() UIManager:close(dialog) end }},
    } }
    UIManager:show(dialog)
end

function Shamela:promptSearch()
    local dialog
    dialog = InputDialog:new{ title = _("Search Shamela"), input_hint = _("Book title…"), buttons = {{
        { text = _("‹ Back"), callback = function() UIManager:close(dialog) end },
        { text = _("Search"), is_enter_default = true, callback = safe(function()
            local term = dialog:getInputText(); UIManager:close(dialog)
            if term and term ~= "" then
                local msg = InfoMessage:new{ text = _("Searching…") }; UIManager:show(msg); UIManager:forceRePaint()
                local books, err = self:loadBooks("name LIKE " .. sqlQuote("%" .. term .. "%")); UIManager:close(msg)
                if books then self:showBookList(books, T(_("Search: %1"), term)) else UIManager:show(InfoMessage:new{ text = err }) end
            end
        end) },
    }} }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Shamela:promptSetting(key, title, default)
    local dialog
    dialog = InputDialog:new{ title = title, input = G_reader_settings:readSetting(key) or default, buttons = {{
        { text = _("‹ Back"), callback = function() UIManager:close(dialog) end },
        { text = _("Save"), is_enter_default = true, callback = function() local v = dialog:getInputText(); UIManager:close(dialog); if v and v ~= "" then G_reader_settings:saveSetting(key, v) end end },
    }} }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Shamela:openHome()
    local dialog
    dialog = ButtonDialog:new{ title = _("Shamela Library — المكتبة الشاملة"), buttons = {
        {{ text = _("Browse catalog"), callback = safe(function() self:browseCategories() end) }},
        {{ text = _("Search by title"), callback = safe(function() self:promptSearch() end) }},
        {{ text = _("Download folder…"), callback = function() self:promptSetting("shamela_download_dir", _("Download folder"), getDownloadDir()) end }},
        {{ text = _("API settings…"), callback = function() self:promptSetting("shamela_api_url", _("Shamela API URL"), DEFAULT_API_URL) end }},
        {{ text = _("API key…"), callback = function() self:promptSetting("shamela_api_key", _("Shamela API key (required)"), DEFAULT_API_KEY) end }},
        {{ text = _("‹ Back"), callback = function() UIManager:close(dialog) end }},
    } }
    UIManager:show(dialog)
end

function Shamela:init() self.ui.menu:registerToMainMenu(self) end
function Shamela:addToMainMenu(menu_items)
    menu_items.shamela_library = { text = _("Shamela Library"), sorting_hint = "search", callback = function() self:openHome() end }
end

return Shamela
