-- Run from the plugin root: lua tests/catalog.lua
dofile("tests/download.lua") -- initialize mocked KOReader services; retain download coverage
local requests = {}
local home = CATALOG_HOME or [[<a class="cat_title list-group-item" href="https://shamela.ws/category/19">19. مسائل فقهية<span class="badge">429</span></a>]]
local category = CATALOG_CATEGORY or [[<a href="https://shamela.ws/book/21528" class="book_title text-primary">48 سؤالا في الصيام</a>]]
local search = CATALOG_SEARCH or { results = { items = {{ id = "21528", text = "48 سؤالا في الصيام" }} } }
local status = 200
package.loaded.util.htmlToPlainText = function(s) return (s:gsub("<[^>]+>", ""):gsub("&amp;", "&")) end
package.loaded["socket.url"].escape = function(s)
    return (s:gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end))
end
package.loaded.json.decode = setmetatable({ simple = {} }, { __call = function() return search end })
package.loaded["socket.http"].request = function(req)
    requests[#requests + 1] = req.url
    assert(not req.url:find("api_key", 1, true) and not req.url:find("dev.shamela", 1, true))
    local body
    if req.url == "https://shamela.ws/" then body = home
    elseif req.url == "https://shamela.ws/category/19" then body = category
    elseif req.url:find("https://shamela.ws/ajax/book/?", 1, true) == 1 then body = "json"
    else error("Unexpected request: " .. req.url) end
    req.sink(body)
    return 1, status
end
G_reader_settings = { readSetting = function() error("Catalog must not need saved settings") end }
package.loaded.datastorage = nil
package.loaded["lua-ljsqlite3/init"] = nil
local plugin = dofile("main.lua")
local categories = assert(plugin:loadCategories())
local found
for _, c in ipairs(categories) do if c.id == "19" then found = c end end
assert(found and found.name == "مسائل فقهية")
local books = assert(plugin:loadBooks(found.id))
found = nil
for _, b in ipairs(books) do if b.id == "21528" then found = b end end
assert(found and found.name:find("48", 1, true))
local results = assert(plugin:searchBooks("48"))
found = nil
for _, b in ipairs(results) do if b.id == "21528" then found = b end end
assert(found, "Search must find the same book as category browsing")
-- Exercise the UI callbacks as well as the data-loading methods.
local shown
package.loaded["ui/uimanager"].show = function(_, widget) shown = widget end
package.loaded.device.screen.getWidth = function() return 600 end
package.loaded.device.screen.getHeight = function() return 800 end
plugin:browseCategories()
local category_callback
for _, entry in ipairs(shown.item_table) do
    if entry.text == "مسائل فقهية" then category_callback = entry.callback end
end
assert(category_callback, "category must appear in menu")
category_callback()
assert(shown.item_table and shown.title == "مسائل فقهية", "selecting category must open books, not an error dialog")
local book_callback
for _, entry in ipairs(shown.item_table) do
    if entry.text:find("48", 1, true) then book_callback = entry.callback end
end
assert(book_callback)
book_callback()
assert(shown.buttons and shown.title:find("21528", 1, true), "selecting book must open download dialog")
plugin:searchBooks("صيام &?")
assert(requests[#requests]:find("%26%3F", 1, true), "search must escape query delimiters")
search = { results = { items = {} } }
assert(#assert(plugin:searchBooks("missing")) == 0)
search = { results = {} }
assert(plugin:searchBooks("bad") == nil)
home = "<html>Unexpected response</html>"
assert(plugin:loadCategories() == nil)
status = 503
local value, err = plugin:loadBooks("19")
assert(value == nil and err == "HTTP 503")
assert(plugin:loadBooks("../invalid") == nil)
print("PASS: fresh catalog without settings/databases/key, category and search, malformed responses and HTTP errors")
