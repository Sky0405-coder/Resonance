-- Full-screen list browser: library, catalog search, requests.
local Api = require("api")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")

local val = Api.val

local PAGE_SIZE = 50

local STATUS = {
    pending_approval = "Wartet auf Freigabe",
    queued = "In der Warteschlange",
    searching = "Wird gesucht",
    downloading = "Lädt",
    importing = "Wird importiert",
    done = "Fertig",
    failed = "Fehlgeschlagen",
    cancelled = "Abgebrochen",
    rejected = "Abgelehnt",
}

local LANGUAGES = { de = "Deutsch", en = "Englisch", any = "Egal" }
local LANGUAGE_NAMES = { de = "Deutsch", en = "Englisch", fr = "Französisch", es = "Spanisch", it = "Italienisch",
                         nl = "Niederländisch" }

local Browser = Menu:extend{
    plugin = nil,
}

-- Shows a message while fn runs (network calls block the UI) and returns fn's results.
function Browser.busy(text, fn)
    local message = InfoMessage:new{ text = text }
    UIManager:show(message)
    UIManager:forceRePaint()
    -- LuaJIT (Lua 5.1): no table.pack/table.unpack.
    local results = { pcall(fn) }
    UIManager:close(message)
    if not results[1] then
        return false, "Fehler: " .. tostring(results[2])
    end
    return unpack(results, 2, table.maxn(results))
end

local function authors_text(authors)
    authors = val(authors)
    if not authors or #authors == 0 then return "" end
    return table.concat(authors, ", ")
end

local function series_text(entry)
    local series = val(entry.series)
    if not series then return nil end
    local index = val(entry.series_index)
    if index then
        if index == math.floor(index) then index = string.format("%d", index) end
        return series .. " " .. index
    end
    return series
end

local function show_error(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Browser:init()
    self.item_table = self:rootItems()
    self.title_bar_left_icon = "appbar.settings"
    self.onLeftButtonTap = function() self:showSettings() end
    Menu.init(self)
end

-- Navigation ----------------------------------------------------------------

function Browser:push(title, items)
    table.insert(self.paths, { title = self.title_bar and self.title_bar.title or self.title, items = self.item_table })
    self:switchItemTable(title, items, 1)
end

function Browser:replaceCurrent(items, itemnumber)
    self:switchItemTable(nil, items, itemnumber or -1)
end

function Browser:onReturn()
    local previous = table.remove(self.paths)
    if previous then
        self:switchItemTable(previous.title, previous.items, -1)
    end
    return true
end

function Browser:onMenuSelect(item)
    if item.callback then
        NetworkMgr:runWhenOnline(function() item.callback() end)
    end
    return true
end

function Browser:api()
    return self.plugin:api()
end

function Browser:rootItems()
    return {
        { text = "Suchen und anfragen", callback = function() self:askCatalogSearch() end },
        { text = "In der Bibliothek suchen", callback = function() self:askLibrarySearch() end },
        { text = "Neu in der Bibliothek", callback = function()
            self:openLibrary("Neu in der Bibliothek", { sort = "added" })
        end },
        { text = "Autoren", callback = function() self:openAuthors() end },
        { text = "Serien", callback = function() self:openSeries() end },
        { text = "Meine Anfragen", callback = function() self:openRequests() end },
        { text = "Fertige Anfragen herunterladen", callback = function() self.plugin:sync(false) end },
    }
end

-- Library -------------------------------------------------------------------

function Browser:askLibrarySearch()
    self:askText("In der Bibliothek suchen", "Titel, Autor oder Serie", function(query)
        self:openLibrary("Suche: " .. query, { q = query, sort = "title" })
    end)
end

function Browser:askText(title, hint, done, initial)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        input_hint = hint,
        buttons = {{
            { text = "Abbrechen", id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = "Suchen",
                is_enter_default = true,
                callback = function()
                    local text = util.trim(dialog:getInputText())
                    if text == "" then return end
                    UIManager:close(dialog)
                    NetworkMgr:runWhenOnline(function() done(text) end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:bookItem(book)
    local mandatory = series_text(book)
    if self.plugin:localPath(book.id) then mandatory = "✓ " .. (mandatory or "") end
    return {
        text = book.title .. (authors_text(book.authors) ~= "" and (" – " .. authors_text(book.authors)) or ""),
        mandatory = mandatory,
        callback = function() self:showBook(book) end,
    }
end

-- params: query parameters of /api/books/library (without offset/limit).
function Browser:openLibrary(title, params, items, offset)
    items = items or {}
    offset = offset or 0
    local query = { offset = offset, limit = PAGE_SIZE }
    for k, v in pairs(params) do query[k] = v end
    local ok, page = Browser.busy("Lade Bücher …", function() return self:api():get("/api/books/library", query) end)
    if not ok then return show_error(page) end
    if items[#items] and items[#items].more then table.remove(items) end
    for _, book in ipairs(page.items) do table.insert(items, self:bookItem(book)) end
    local loaded = offset + #page.items
    if loaded < page.total then
        table.insert(items, {
            text = string.format("Weitere laden … (%d von %d)", loaded, page.total),
            more = true,
            callback = function() self:openLibrary(title, params, items, loaded) end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = "Keine Bücher gefunden" })
    end
    if offset == 0 then
        self:push(title, items)
    else
        self:replaceCurrent(items, offset + 1)
    end
end

function Browser:openAuthors()
    local ok, authors = Browser.busy("Lade Autoren …", function() return self:api():get("/api/books/library/authors") end)
    if not ok then return show_error(authors) end
    local items = {}
    for _, author in ipairs(authors) do
        table.insert(items, {
            text = author.name,
            mandatory = tostring(author.count),
            callback = function() self:openLibrary(author.name, { author = author.name, sort = "author" }) end,
        })
    end
    if #items == 0 then table.insert(items, { text = "Noch keine Bücher" }) end
    self:push("Autoren", items)
end

function Browser:openSeries()
    local ok, series = Browser.busy("Lade Serien …", function() return self:api():get("/api/books/library/series") end)
    if not ok then return show_error(series) end
    local items = {}
    for _, entry in ipairs(series) do
        table.insert(items, {
            text = entry.name .. (val(entry.author) and (" – " .. entry.author) or ""),
            mandatory = tostring(entry.count),
            callback = function() self:openLibrary(entry.name, { series = entry.name, sort = "series" }) end,
        })
    end
    if #items == 0 then table.insert(items, { text = "Noch keine Serien" }) end
    self:push("Serien", items)
end

local function details_text(entry, extra)
    local lines = {}
    local function add(label, value)
        value = val(value)
        if value and value ~= "" then table.insert(lines, label .. ": " .. tostring(value)) end
    end
    add("Autor", authors_text(entry.authors))
    add("Serie", series_text(entry))
    add("Erschienen", entry.year)
    add("Verlag", entry.publisher)
    local language = val(entry.language)
    add("Sprache", language and (LANGUAGE_NAMES[language] or language))
    for _, line in ipairs(extra or {}) do table.insert(lines, line) end
    local description = val(entry.description)
    if description then
        table.insert(lines, "")
        table.insert(lines, util.htmlToPlainTextIfHtml(description))
    end
    return table.concat(lines, "\n")
end

function Browser:showBook(book)
    local viewer
    local path = self.plugin:localPath(book.id)
    local buttons = {}
    if path then
        table.insert(buttons, { text = "Lesen", callback = function()
            UIManager:close(viewer)
            self.plugin:openBook(path)
        end })
    else
        table.insert(buttons, { text = "Herunterladen", callback = function()
            UIManager:close(viewer)
            NetworkMgr:runWhenOnline(function() self:download(book) end)
        end })
    end
    table.insert(buttons, { text = "Schließen", callback = function() UIManager:close(viewer) end })
    viewer = TextViewer:new{
        title = book.title,
        text = details_text(book, {
            "Format: " .. string.upper(book.format) .. ", " .. util.getFriendlySize(book.size),
            path and ("Auf dem Gerät: " .. path) or nil,
        }),
        buttons_table = { buttons },
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

function Browser:download(book)
    local ok, result = Browser.busy("Lade „" .. book.title .. "“ …", function() return self.plugin:downloadBook(book) end)
    if not ok then return show_error(result) end
    UIManager:show(ConfirmBox:new{
        text = "„" .. book.title .. "“ wurde heruntergeladen.\nJetzt lesen?",
        ok_text = "Lesen",
        cancel_text = "Später",
        ok_callback = function() self.plugin:openBook(result) end,
    })
end

function Browser:downloadById(book_id)
    local ok, book = Browser.busy("Lade …", function() return self:api():get("/api/books/library/" .. book_id) end)
    if not ok then return show_error(book) end
    local path = self.plugin:localPath(book.id)
    if path then return self.plugin:openBook(path) end
    self:download(book)
end

-- Catalog search and requests ----------------------------------------------

function Browser:askCatalogSearch()
    self:askText("Buch suchen", "Titel und/oder Autor", function(query) self:openCatalog(query) end)
end

function Browser:requestLanguage()
    return self.plugin:get("language", nil)
end

function Browser:openCatalog(query)
    local ok, results = Browser.busy("Suche „" .. query .. "“ …", function()
        return self:api():get("/api/books/catalog/search", { q = query, language = self:requestLanguage() })
    end)
    if not ok then return show_error(results) end
    local items = {}
    for _, entry in ipairs(results) do
        local mandatory
        if val(entry.book_id) then
            mandatory = "✓ Bibliothek"
        elseif val(entry.request_status) then
            mandatory = STATUS[entry.request_status] or entry.request_status
        end
        table.insert(items, {
            text = entry.title .. (authors_text(entry.authors) ~= "" and (" – " .. authors_text(entry.authors)) or ""),
            mandatory = mandatory,
            callback = function() self:showCatalogEntry(entry) end,
        })
    end
    table.insert(items, {
        text = "Nicht dabei? Selbst anfragen …",
        callback = function() self:askFreeRequest(query) end,
    })
    self:push("Suche: " .. query, items)
end

function Browser:showCatalogEntry(entry)
    local viewer
    local buttons = {}
    local close = function() UIManager:close(viewer) end
    if val(entry.book_id) then
        table.insert(buttons, { text = "Herunterladen", callback = function()
            close()
            NetworkMgr:runWhenOnline(function() self:downloadById(entry.book_id) end)
        end })
    elseif val(entry.request_status) then
        table.insert(buttons, { text = "Meine Anfragen", callback = function()
            close()
            NetworkMgr:runWhenOnline(function() self:openRequests() end)
        end })
    else
        table.insert(buttons, { text = "Anfragen", callback = function()
            close()
            NetworkMgr:runWhenOnline(function() self:createRequest(entry) end)
        end })
    end
    table.insert(buttons, { text = "Schließen", callback = close })
    viewer = TextViewer:new{
        title = entry.title,
        text = details_text(entry),
        buttons_table = { buttons },
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

function Browser:askFreeRequest(query)
    local dialog
    dialog = MultiInputDialog:new{
        title = "Buch anfragen",
        fields = {
            { text = query or "", hint = "Titel" },
            { text = "", hint = "Autor (optional)" },
        },
        buttons = {{
            { text = "Abbrechen", id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = "Anfragen",
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local title, author = util.trim(fields[1]), util.trim(fields[2])
                    if title == "" then return end
                    UIManager:close(dialog)
                    NetworkMgr:runWhenOnline(function()
                        self:createRequest({ title = title, authors = author ~= "" and { author } or {} })
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:createRequest(entry)
    local body = { language = self:requestLanguage() }
    for _, key in ipairs({ "ref", "title", "subtitle", "authors", "series", "series_index", "isbn", "publisher",
                           "year", "description", "cover_url" }) do
        body[key] = val(entry[key])
    end
    body.authors = body.authors or {}
    local ok, request = Browser.busy("Frage an …", function() return self:api():post("/api/books/requests", body) end)
    if not ok then return show_error(request) end
    entry.request_id = request.id
    entry.request_status = request.status
    UIManager:show(InfoMessage:new{
        text = "„" .. request.title .. "“ angefragt (" .. (STATUS[request.status] or request.status) .. ").\n"
            .. "Das Buch landet automatisch auf dem Gerät, sobald es fertig ist und WLAN an ist.",
    })
end

function Browser:openRequests()
    local ok, page = Browser.busy("Lade Anfragen …", function()
        return self:api():get("/api/books/requests", { scope = "mine", limit = 100 })
    end)
    if not ok then return show_error(page) end
    local items = {}
    for _, request in ipairs(page.items) do
        local status = STATUS[request.status] or request.status
        if request.status == "downloading" then
            status = string.format("%s %d %%", status, math.floor((val(request.progress) or 0) * 100))
        end
        table.insert(items, {
            text = request.title .. (authors_text(request.authors) ~= "" and (" – " .. authors_text(request.authors)) or ""),
            mandatory = status,
            callback = function() self:showRequest(request) end,
        })
    end
    if #items == 0 then table.insert(items, { text = "Keine Anfragen" }) end
    if self.showing_requests and #self.paths > 0 then
        self:replaceCurrent(items, 1)
    else
        self.showing_requests = true
        self:push("Meine Anfragen", items)
    end
    self.showing_requests = nil
end

function Browser:showRequest(request)
    local dialog
    local close = function() UIManager:close(dialog) end
    local status = request.status
    local buttons = {}
    local book = val(request.book)
    if status == "done" and book then
        table.insert(buttons, {{ text = self.plugin:localPath(book.id) and "Lesen" or "Herunterladen", callback = function()
            close()
            NetworkMgr:runWhenOnline(function()
                local path = self.plugin:localPath(book.id)
                if path then self.plugin:openBook(path) else self:download(book) end
            end)
        end }})
    end
    if status == "failed" or status == "cancelled" then
        table.insert(buttons, {{ text = "Erneut versuchen", callback = function()
            close()
            NetworkMgr:runWhenOnline(function() self:requestAction("POST", request, "/retry") end)
        end }})
    end
    local active = not (status == "done" or status == "failed" or status == "cancelled" or status == "rejected")
    table.insert(buttons, {{ text = active and "Anfrage abbrechen" or "Aus der Liste entfernen", callback = function()
        close()
        NetworkMgr:runWhenOnline(function() self:requestAction("DELETE", request, "") end)
    end }})
    local lines = { request.title, authors_text(request.authors), "", "Status: " .. (STATUS[status] or status) }
    if val(request.torrent_name) then table.insert(lines, "Download: " .. request.torrent_name) end
    if val(request.error) then table.insert(lines, "Hinweis: " .. request.error) end
    table.insert(lines, "Sprache: " .. (LANGUAGES[request.language] or request.language))
    dialog = ButtonDialog:new{ title = table.concat(lines, "\n"), title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

function Browser:requestAction(method, request, suffix)
    local ok, err = Browser.busy("Bitte warten …", function()
        return self:api():request(method, "/api/books/requests/" .. request.id .. suffix)
    end)
    if not ok then return show_error(err) end
    self.showing_requests = true
    self:openRequests()
end

-- Settings ------------------------------------------------------------------

function Browser:showSettings()
    local plugin = self.plugin
    local dialog
    local function close() UIManager:close(dialog) end
    local language = plugin:get("language", nil)
    dialog = ButtonDialog:new{
        title = "Angemeldet als " .. (plugin:get("username", "?")) .. "\n" .. (plugin:get("server_url", "")),
        title_align = "left",
        buttons = {
            {{ text = (plugin:get("auto_sync", true) and "☑" or "☐") .. " Fertige Bücher automatisch laden",
               align = "left", callback = function()
                close()
                plugin:set("auto_sync", not plugin:get("auto_sync", true))
                self:showSettings()
            end }},
            {{ text = "Sprache für Anfragen: " .. (language and LANGUAGES[language] or "Server-Standard"),
               align = "left", callback = function()
                close()
                local order = { nil, "de", "en", "any" }
                local next_language
                for i = 1, 4 do
                    if order[i] == language then next_language = order[i % 4 + 1] break end
                end
                plugin:set("language", next_language)
                self:showSettings()
            end }},
            {{ text = "Download-Ordner: " .. plugin:downloadDir(), align = "left", callback = function()
                close()
                local PathChooser = require("ui/widget/pathchooser")
                UIManager:show(PathChooser:new{
                    select_file = false,
                    path = plugin:downloadDir(),
                    onConfirm = function(path) plugin:set("download_dir", path) end,
                })
            end }},
            {{ text = "Abmelden", align = "left", callback = function()
                close()
                plugin:logout()
            end }},
        },
    }
    UIManager:show(dialog)
end

return Browser
