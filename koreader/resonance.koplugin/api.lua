-- Minimal JSON client for the Resonance REST API (bearer token auth).
local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")

local Api = {}
Api.__index = Api

function Api.new(server_url, token)
    return setmetatable({ server_url = (server_url or ""):gsub("/+$", ""), token = token }, Api)
end

-- LuaJSON decodes JSON null into a sentinel; turn it into nil.
function Api.val(v)
    if v == nil or v == JSON.util.null then return nil end
    return v
end

local function encode_query(params)
    if not params then return "" end
    local parts = {}
    for k, v in pairs(params) do
        if v ~= nil and v ~= "" then
            local escaped = tostring(v):gsub("([^%w%-%._~])", function(c)
                return string.format("%%%02X", string.byte(c))
            end)
            table.insert(parts, k .. "=" .. escaped)
        end
    end
    table.sort(parts)
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

local function error_message(code, content)
    if code == 401 then return "Anmeldung abgelaufen – bitte in den Einstellungen abmelden und neu anmelden" end
    if content and content:sub(1, 1) == "{" then
        local ok, body = pcall(JSON.decode, content)
        if ok and type(body) == "table" and type(body.detail) == "string" then
            return body.detail
        end
    end
    if type(code) == "number" then return "Serverfehler (HTTP " .. code .. ")" end
    return "Server nicht erreichbar"
end

-- Returns ok, result_or_error_message, http_code.
function Api:request(method, path, params, body)
    local sink = {}
    local headers = {
        ["Accept"] = "application/json",
        ["Accept-Language"] = "de",
        ["Accept-Encoding"] = "identity",
    }
    if self.token then headers["Authorization"] = "Bearer " .. self.token end
    local source
    if body ~= nil then
        local data = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#data)
        source = ltn12.source.string(data)
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = self.server_url .. path .. encode_query(params),
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local content = table.concat(sink)
    if resp_headers == nil then
        logger.warn("Resonance: network error", method, path, status or code)
        return false, "Server nicht erreichbar", nil
    end
    if code >= 200 and code < 300 then
        if code == 204 or content == "" then return true, nil, code end
        local ok, result = pcall(JSON.decode, content)
        if ok then return true, result, code end
        return false, "Ungültige Antwort vom Server", code
    end
    logger.warn("Resonance: HTTP error", method, path, code)
    return false, error_message(code, content), code
end

function Api:get(path, params) return self:request("GET", path, params) end
function Api:post(path, body) return self:request("POST", path, nil, body or {}) end
function Api:delete(path) return self:request("DELETE", path) end

-- Streams a file to local_path. Returns ok, error_message.
function Api:download(path, local_path)
    local file, err = io.open(local_path .. ".part", "wb")
    if not file then return false, "Datei kann nicht geschrieben werden: " .. tostring(err) end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, resp_headers = socket.skip(1, http.request{
        url = self.server_url .. path,
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. (self.token or ""), ["Accept-Encoding"] = "identity" },
        sink = ltn12.sink.file(file),
    })
    socketutil:reset_timeout()
    if resp_headers ~= nil and code == 200 then
        os.rename(local_path .. ".part", local_path)
        return true
    end
    os.remove(local_path .. ".part")
    return false, error_message(resp_headers and code or nil, nil)
end

return Api
