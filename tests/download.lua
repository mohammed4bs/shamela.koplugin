-- Run from the plugin root with: lua tests/download.lua
-- Exercises the real convertBook/writeEpub code with mocked KOReader services.
-- The JSON mock reproduces luajson's default function sentinel for JSON null.
local shown, requests, files, responses = {}, {}, {}, {}
local simple = {}
local null = function() end
local decode = setmetatable({ simple = simple }, { __call = function(_, body, mode)
    local source = assert(responses[body], "unexpected JSON body")
    local result = {}
    for k, v in pairs(source) do
        if v ~= null or mode ~= simple then result[k] = v end
    end
    return result
end })
package.loaded.json = { decode = decode }
local widget = { new = function(_, opts) return opts end }
for _, name in ipairs({ "buttondialog", "confirmbox", "infomessage", "inputdialog", "menu" }) do
    package.loaded["ui/widget/" .. name] = widget
end
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(_, opts) return opts end,
}
package.loaded["ui/uimanager"] = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function() end, forceRePaint = function() end,
}
package.loaded.device = { screen = {} }
package.loaded.datastorage = {}
package.loaded["lua-ljsqlite3/init"] = {}
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }
package.loaded.util = {}
package.loaded.gettext = function(s) return s end
package.loaded["ffi/util"] = { template = function(s, ...)
    local args = {...}
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end }
package.loaded.socketutil = { set_timeout = function() end, reset_timeout = function() end }
package.loaded["socket.url"] = {}
package.loaded.ltn12 = { sink = { table = function(t)
    return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
end } }
local http = { request = function(req)
    requests[#requests + 1] = req.url
    if req.url == "https://shamela.ws/book/21528" then
        req.sink('<a href="/book/21528/1">Start</a>')
        return 1, 200
    end
    local id = req.url:match("/ajax/pageContent/21528/(%d+)$")
    if not id or not responses[id] then return 1, 404 end
    req.sink(id)
    return 1, 200
end }
package.loaded["socket.http"], package.loaded["ssl.https"] = http, http
package.loaded["ffi/archiver"] = { Writer = { new = function()
    return {
        open = function() return true end,
        setZipCompression = function() end,
        addFileFromMemory = function(_, name, content) files[name] = content return true end,
        close = function() end,
    }
end } }
G_reader_settings = { readSetting = function() return "/mock/" end }
local old_remove, old_rename = os.remove, os.rename
os.remove = function() return true end
os.rename = function() return true end
local plugin = dofile("main.lua")
local function run(next_id)
    shown, requests, files, responses = {}, {}, {}, {}
    -- Verified live sequence for book 21528: 1..40, then nextId:null.
    for i = 1, 40 do
        responses[tostring(i)] = { nass = "<p>Page " .. i .. "</p>",
            pageNum = i, nextId = i < 40 and tostring(i + 1) or next_id }
    end
    plugin:convertBook({ id = 21528, name = "48 questions" })
end
run(null)
assert(#requests == 41, "must stop after index + 40 pages, without requesting null sentinel")
assert(files["OEBPS/p40.xhtml"], "must include the last page")
assert(not files["OEBPS/p41.xhtml"])
assert(shown[#shown].text:find("Saved to:", 1, true), "must complete EPUB save")
run("")
assert(files["OEBPS/p40.xhtml"], "empty nextId must also end the book")
run({})
assert(#requests == 41 and next(files) == nil, "invalid IDs must not be requested or saved")
assert(shown[#shown].text:find("invalid next-page ID", 1, true))
run("999")
assert(next(files) == nil, "HTTP errors must not save a partial book")
assert(shown[#shown].text:find("book 21528, page 999", 1, true))
assert(shown[#shown].text:find("HTTP 404", 1, true))
os.remove, os.rename = old_remove, old_rename
print("PASS: null/empty end markers, invalid IDs, 40-page EPUB content, HTTP error context")
