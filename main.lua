--[[--
Shamela Library for KOReader

Browses categories, searches titles, and downloads text through Shamela's
public website. No API key or pre-existing catalog is required.
--]]--

local Archiver = require("ffi/archiver")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local Menu = require("ui/widget/menu")
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

local function getDownloadDir()
    local path = G_reader_settings:readSetting("shamela_download_dir") or DEFAULT_DOWNLOAD_DIR
    if path:sub(-1) ~= "/" then path = path .. "/" end
    return ensureDir(path)
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


local function decodeJson(body)
    -- luajson's default null sentinel is a function (and therefore truthy).
    -- Use simple mode so the reader's final nextId:null becomes Lua nil.
    local ok, value = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok then return nil, tostring(value) end
    return value
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


-- Only accept links for the requested public listing, not navigation or
-- off-site links. Preserve site order and remove duplicate entries.
local function listingLinks(html, kind, class_name)
    local rows, seen = {}, {}
    for attrs, label in html:gmatch("<a%s+([^>]-)>(.-)</a>") do
        local href = attrs:match('href%s*=%s*"([^"]+)"') or attrs:match("href%s*=%s*'([^']+)'")
        local classes = attrs:match('class%s*=%s*"([^"]+)"') or attrs:match("class%s*=%s*'([^']+)'") or ""
        if href and (" " .. classes:gsub("%s+", " ") .. " "):find(" " .. class_name .. " ", 1, true) then
            local path = href:gsub("^https://shamela%.ws", "")
            local id = path:match("^/" .. kind .. "/(%d+)/?$")
            -- Category badges contain book counts, not part of the name.
            if kind == "category" then label = label:gsub("<span[^>]*>.-</span>", "") end
            local name = util.htmlToPlainText(label):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if kind == "category" then name = name:gsub("^%d+%.%s*", "") end
            if id and name ~= "" and not seen[id] then
                seen[id] = true
                rows[#rows + 1] = { id = id, name = name }
            end
        end
    end
    return rows
end

function Shamela:loadCategories()
    local html, err = httpGet(PUBLIC_SITE_URL .. "/")
    if not html then return nil, err end
    local categories = listingLinks(html, "category", "cat_title")
    if #categories == 0 then return nil, _("The public website returned no categories. Please try again later.") end
    return categories
end

function Shamela:loadBooks(category_id)
    local id = tostring(category_id or "")
    if not id:match("^%d+$") then return nil, _("Invalid category ID.") end
    local html, err = httpGet(PUBLIC_SITE_URL .. "/category/" .. id)
    if not html then return nil, err end
    local books = listingLinks(html, "book", "book_title")
    if #books == 0 then return nil, _("The public website returned no book listing. Please try again later.") end
    return books
end

function Shamela:searchBooks(term)
    local query = socket_url.escape(term)
    local body, err = httpGet(PUBLIC_SITE_URL .. "/ajax/book/?q=" .. query .. "&term=" .. query)
    if not body then return nil, err end
    local data = decodeJson(body)
    if type(data) ~= "table" or type(data.results) ~= "table" or type(data.results.items) ~= "table" then
        return nil, _("The public website returned an invalid search response. Please try again later.")
    end
    local books, seen = {}, {}
    for item_index, item in ipairs(data.results.items) do
        if type(item) ~= "table" or (type(item.id) ~= "string" and type(item.id) ~= "number")
                or not tostring(item.id):match("^%d+$") or type(item.text) ~= "string" then
            return nil, _("The public website returned an invalid search result.")
        end
        local id = tostring(item.id)
        if not seen[id] then
            books[#books + 1] = { id = id, name = util.htmlToPlainText(item.text) }
            seen[id] = true
        end
    end
    return books
end

function Shamela:showBookList(books, title)
    if not books or #books == 0 then UIManager:show(InfoMessage:new{ text = _("No books found.") }); return end
    local items, menu = {}, nil
    table.insert(items, { text = _("‹ Back"), callback = function() UIManager:close(menu) end })
    for book_index, book in ipairs(books) do
        table.insert(items, { text = book.name or ("#" .. tostring(book.id)), callback = safe(function() self:showBook(book) end) })
    end
    menu = Menu:new{ title = title, item_table = items, width = Screen:getWidth(), height = Screen:getHeight(), close_callback = function() UIManager:close(menu) end }
    UIManager:show(menu)
end

function Shamela:browseCategories()
    local msg = InfoMessage:new{ text = _("Loading Shamela categories…") }; UIManager:show(msg); UIManager:forceRePaint()
    local categories, err = self:loadCategories(); UIManager:close(msg)
    if not categories then UIManager:show(InfoMessage:new{ text = T(_("Could not load catalog:\n%1"), err) }); return end
    local items, menu = {}, nil
    for category_index, category in ipairs(categories) do
        table.insert(items, { text = category.name, callback = safe(function()
            local loading = InfoMessage:new{ text = _("Loading books…") }; UIManager:show(loading); UIManager:forceRePaint()
            local b, e = self:loadBooks(category.id); UIManager:close(loading)
            if b then self:showBookList(b, category.name) else UIManager:show(InfoMessage:new{ text = e }) end
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
            UIManager:show(InfoMessage:new{ text = T(_("Could not load public book page (book %1, page %2):\n%3"), id, current_id, err) })
            return
        end
        local data, json_err = decodeJson(body)
        if type(data) ~= "table" or type(data.nass) ~= "string" or data.nass == "" then
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = T(_("The public reader returned no text:\n%1"), json_err or "") })
            return
        end
        table.insert(pages, { page = data.pageNum, content = data.nass })
        if not data.nextId or tostring(data.nextId) == "" then break end
        if (type(data.nextId) ~= "string" and type(data.nextId) ~= "number")
                or not tostring(data.nextId):match("^%d+$") then
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = _("The public reader returned an invalid next-page ID. No EPUB was saved.") })
            return
        end
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
                local books, err = self:searchBooks(term); UIManager:close(msg)
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
        {{ text = _("‹ Back"), callback = function() UIManager:close(dialog) end }},
    } }
    UIManager:show(dialog)
end

function Shamela:init() self.ui.menu:registerToMainMenu(self) end
function Shamela:addToMainMenu(menu_items)
    menu_items.shamela_library = { text = _("Shamela Library"), sorting_hint = "search", callback = function() self:openHome() end }
end

return Shamela
