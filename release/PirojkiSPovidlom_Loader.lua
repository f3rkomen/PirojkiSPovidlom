-- File encoding: ASCII
script_name("PirojkiSPovidlom Loader")
script_author("f3rkomen")
script_version("1.0.1")
script_properties("work-in-pause")

local LOADER_VERSION = "1.0.1"
local MANIFEST_URL = "https://raw.githubusercontent.com/f3rkomen/PirojkiSPovidlom/main/release/updateArzMarket.js"
local TRUSTED_PREFIX = "https://raw.githubusercontent.com/f3rkomen/PirojkiSPovidlom/main/release/"

local json_ok, json = pcall(require, "cjson")
local lfs_ok, lfs = pcall(require, "lfs")
local download_status = require("moonloader").download_status
local working_directory = getWorkingDirectory()
local state_directory = working_directory .. "\\PirojkiSPovidlom"
local manifest_path = state_directory .. "\\update-manifest.json"

local function log(message)
    print("[PirojkiSPovidlom] " .. tostring(message))
    if isSampAvailable() then
        sampAddChatMessage("[PirojkiSPovidlom] {FFFFFF}" .. tostring(message), 0x6AA6FF)
    end
end

local function starts_with(value, prefix)
    return type(value) == "string" and value:sub(1, #prefix) == prefix
end

local function read_all(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function normalise_version(value)
    return tostring(value):gsub("[^%w%._%-]", "_"):gsub("%.", "_")
end

local function market_path(version)
    return working_directory .. "\\#PirojkiArzMarket[" .. normalise_version(version) .. "].lua"
end

local function version_is_newer(remote, current)
    local remote_parts, current_parts = {}, {}
    for value in tostring(remote):gmatch("%d+") do
        table.insert(remote_parts, tonumber(value))
    end
    for value in tostring(current):gmatch("%d+") do
        table.insert(current_parts, tonumber(value))
    end
    local length = math.max(#remote_parts, #current_parts)
    for index = 1, length do
        local remote_value = remote_parts[index] or 0
        local current_value = current_parts[index] or 0
        if remote_value ~= current_value then
            return remote_value > current_value
        end
    end
    return false
end

local function unload_and_remove_old_markets(keep_path)
    for _, entry in pairs(script.list()) do
        if entry.filename and entry.filename:match("^#PirojkiArzMarket%[") then
            local entry_path = working_directory .. "\\" .. entry.filename
            if entry_path ~= keep_path then
                entry:unload()
            end
        end
    end

    if not lfs_ok then
        return
    end
    for filename in lfs.dir(working_directory) do
        if filename:match("^#PirojkiArzMarket%[.*%]%.lua$") then
            local path = working_directory .. "\\" .. filename
            if path ~= keep_path and doesFileExist(path) then
                os.remove(path)
            end
        end
    end
end

local function download_to(url, path, on_success, on_error)
    local request_id
    local finished = false

    local function finish_success()
        if finished then
            return
        end
        finished = true
        lua_thread.create(function()
            -- MoonLoader signals data reception before the file handle is always
            -- observable to Lua. Wait a frame before reading/replacing it.
            wait(75)
            if doesFileExist(path) then
                on_success()
            else
                on_error("download data was not written")
            end
        end)
    end

    request_id = downloadUrlToFile(url, path, function(id, status)
        if id ~= request_id then
            return
        end
        if status == download_status.STATUS_ENDDOWNLOADDATA then
            finish_success()
        elseif status == download_status.STATUSEX_ENDDOWNLOAD then
            -- The final event follows STATUS_ENDDOWNLOADDATA on a successful
            -- download. It is an error only when no payload arrived.
            if not finished then
                if doesFileExist(path) then
                    finish_success()
                else
                    finished = true
                    on_error("download failed")
                end
            end
        end
    end)
end

local function update_loader(url)
    if not starts_with(url, TRUSTED_PREFIX) then
        log("Loader update URL was rejected")
        return
    end
    local temporary = thisScript().path .. ".new"
    log("Updating loader")
    download_to(url, temporary, function()
        if not doesFileExist(temporary) then
            log("Loader update was not written")
            return
        end
        local backup = thisScript().path .. ".bak"
        os.remove(backup)
        local moved_old, old_reason = os.rename(thisScript().path, backup)
        if not moved_old then
            log("Could not prepare loader update: " .. tostring(old_reason))
            return
        end
        local moved, reason = os.rename(temporary, thisScript().path)
        if not moved then
            os.rename(backup, thisScript().path)
            log("Could not install loader update: " .. tostring(reason))
            return
        end
        os.remove(backup)
        log("Loader updated; reloading")
        thisScript():reload()
    end, function(reason)
        log("Loader update error: " .. tostring(reason))
    end)
end

local function install_market(manifest)
    if not starts_with(manifest.updateurl, TRUSTED_PREFIX) then
        log("Market update URL was rejected")
        return
    end
    local destination = market_path(manifest.latest)
    if doesFileExist(destination) then
        unload_and_remove_old_markets(destination)
        log("Market is current: " .. tostring(manifest.latest))
        return
    end
    log("Downloading Market " .. tostring(manifest.latest))
    download_to(manifest.updateurl, destination, function()
        if not doesFileExist(destination) then
            log("Market file was not written")
            return
        end
        unload_and_remove_old_markets(destination)
        script.load(destination)
        log("Market installed: " .. tostring(manifest.latest))
    end, function(reason)
        log("Market update error: " .. tostring(reason))
    end)
end

local function process_manifest()
    local raw = read_all(manifest_path)
    if doesFileExist(manifest_path) then
        os.remove(manifest_path)
    end
    if not json_ok then
        log("cjson library is unavailable")
        return
    end
    if not raw then
        log("Manifest file was not written")
        return
    end
    local ok, manifest = pcall(json.decode, raw)
    if not ok or type(manifest) ~= "table" or not manifest.latest or not manifest.updateurl then
        log("Invalid update manifest")
        return
    end
    if manifest.loaderLatest and manifest.loaderUpdateUrl and version_is_newer(manifest.loaderLatest, LOADER_VERSION) then
        update_loader(manifest.loaderUpdateUrl)
        return
    end
    install_market(manifest)
end

function main()
    if not json_ok then
        return log("cjson library is unavailable")
    end
    if not isSampLoaded() then
        return
    end
    while not isSampAvailable() do
        wait(100)
    end
    if not doesDirectoryExist(state_directory) then
        createDirectory(state_directory)
    end
    if doesFileExist(manifest_path) then
        os.remove(manifest_path)
    end
    log("Checking own release channel")
    download_to(MANIFEST_URL, manifest_path, process_manifest, function(reason)
        log("Manifest check error: " .. tostring(reason))
    end)
    while true do
        wait(1000)
    end
end
