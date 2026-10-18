--[[
Resonance Bücher: search the Resonance library and catalog, request books and download them.
Finished requests are downloaded automatically whenever WiFi connects (can be switched off).
]]
local Api = require("api")
local Browser = require("browser")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local val = Api.val

local Resonance = WidgetContainer:extend{
    name = "resonance",
    is_doc_only = false,
}

local AUTO_SYNC_INTERVAL = 60

function Resonance:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/resonance.lua")
    Dispatcher:registerAction("resonance_books", {
        category = "none", event = "ShowResonanceBooks", title = "Resonance Bücher", general = true,
    })
    Dispatcher:registerAction("resonance_sync", {
        category = "none", event = "ResonanceSync", title = "Resonance: Bücher synchronisieren", general = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

-- Settings ------------------------------------------------------------------

function Resonance:get(key, default)
    local value = self.settings:readSetting(key)
    if value == nil then return default end
    return value
end

function Resonance:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Resonance:isLoggedIn()
    return self:get("token") ~= nil and self:get("server_url") ~= nil
end

function Resonance:api()
    return Api.new(self:get("server_url"), self:get("token"))
end

function Resonance:downloadDir()
    local dir = self:get("download_dir")
    if dir then return dir end
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or lfs.currentdir()
    return home .. "/Resonance"
end

-- Book id -> local path of every book this device downloaded.
function Resonance:downloaded()
    return self:get("downloaded", {})
end

function Resonance:localPath(book_id)
    local path = self:downloaded()[book_id]
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

-- Menu ----------------------------------------------------------------------

function Resonance:addToMainMenu(menu_items)
    menu_items.resonance_books = {
        text = "Resonance Bücher",
        sorting_hint = "search",
        callback = function() self:onShowResonanceBooks() end,
    }
end

function Resonance:onShowResonanceBooks()
    if not self:isLoggedIn() then
        self:showLogin(function() self:onShowResonanceBooks() end)
        return true
    end
    self.browser = Browser:new{
        plugin = self,
        title = "Resonance Bücher",
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        close_callback = function()
            UIManager:close(self.browser)
            self.browser = nil
        end,
    }
    UIManager:show(self.browser)
    return true
end

-- Login ---------------------------------------------------------------------

function Resonance:showLogin(done)
    local dialog
    dialog = MultiInputDialog:new{
        title = "Bei Resonance anmelden",
        fields = {
            { text = self:get("server_url", "https://"), hint = "Server, z. B. https://resonance.example.de" },
            { text = self:get("username", ""), hint = "Benutzername" },
            { text = "", hint = "Passwort", text_type = "password" },
        },
        buttons = {{
            { text = "Abbrechen", id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = "Anmelden",
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local server = util.trim(fields[1]):gsub("/+$", "")
                    local username = util.trim(fields[2])
                    if not server:match("^https?://.+") or username == "" or fields[3] == "" then
                        UIManager:show(InfoMessage:new{ text = "Bitte Server, Benutzername und Passwort eingeben." })
                        return
                    end
                    UIManager:close(dialog)
                    NetworkMgr:runWhenOnline(function()
                        self:login(server, username, fields[3], done)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Resonance:login(server, username, password, done)
    local ok, result = Browser.busy("Anmelden …", function()
        return Api.new(server):post("/api/auth/login", {
            username = username,
            password = password,
            device_name = "KOReader (" .. (Device.model or "E-Reader") .. ")",
        })
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = result })
        return
    end
    self:set("server_url", server)
    self:set("username", username)
    self:set("token", result.token)
    local status_ok, status = self:api():get("/api/books/status")
    if status_ok and not status.enabled then
        UIManager:show(InfoMessage:new{ text = "Angemeldet, aber Bücher sind auf dem Server nicht aktiviert." })
        return
    end
    if done then done() end
end

function Resonance:logout()
    UIManager:show(ConfirmBox:new{
        text = "Von Resonance abmelden?\nHeruntergeladene Bücher bleiben auf dem Gerät.",
        ok_text = "Abmelden",
        ok_callback = function()
            if NetworkMgr:isOnline() then self:api():post("/api/auth/logout") end
            self:set("token", nil)
            if self.browser then self.browser.close_callback() end
        end,
    })
end

-- Downloads -----------------------------------------------------------------

-- Downloads one book (BookOut table) and remembers it. Returns ok, path_or_error.
function Resonance:downloadBook(book)
    local dir = self:downloadDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        util.makePath(dir)
    end
    local filename = util.getSafeFilename(book.filename or (book.title .. "." .. book.format), dir)
    local path = dir .. "/" .. filename
    local ok, err = self:api():download("/api/books/library/" .. book.id .. "/file", path)
    if not ok then return false, err end
    local downloaded = self:downloaded()
    downloaded[book.id] = path
    self:set("downloaded", downloaded)
    self:refreshFileManager()
    return true, path
end

function Resonance:refreshFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then FileManager.instance:onRefresh() end
end

function Resonance:openBook(path)
    if self.browser then self.browser.close_callback() end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

-- Downloads every finished request of this user that is not on the device yet.
-- quiet: no messages unless something was downloaded.
function Resonance:sync(quiet)
    if not self:isLoggedIn() then return end
    self.last_sync = os.time()
    local ok, page = self:api():get("/api/books/requests", { scope = "mine", status = "done", limit = 100 })
    if not ok then
        if not quiet then UIManager:show(InfoMessage:new{ text = page }) end
        return
    end
    local new_titles, failed = {}, 0
    for _, request in ipairs(page.items or {}) do
        local book = val(request.book)
        -- Only books this device never had: a book the user deleted locally stays deleted.
        if book and not self:downloaded()[book.id] then
            local done = self:downloadBook(book)
            if done then table.insert(new_titles, book.title) else failed = failed + 1 end
        end
    end
    if #new_titles > 0 then
        Notification:notify(#new_titles == 1 and ("Neues Buch: " .. new_titles[1])
            or (#new_titles .. " neue Bücher heruntergeladen"))
    elseif not quiet then
        UIManager:show(InfoMessage:new{
            text = failed > 0 and (failed .. " Bücher konnten nicht geladen werden.") or "Alles aktuell.",
            timeout = 2,
        })
    end
end

function Resonance:onResonanceSync()
    NetworkMgr:runWhenOnline(function() self:sync(false) end)
    return true
end

function Resonance:onNetworkConnected()
    if not self:get("auto_sync", true) or not self:isLoggedIn() then return end
    if self.last_sync and os.time() - self.last_sync < AUTO_SYNC_INTERVAL then return end
    -- Let the connection settle before talking to the server.
    UIManager:scheduleIn(3, function()
        local ok, err = pcall(self.sync, self, true)
        if not ok then logger.warn("Resonance: auto sync failed", err) end
    end)
end

return Resonance
