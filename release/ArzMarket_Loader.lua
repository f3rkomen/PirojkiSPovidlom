-- File encoding: ASCII
script_name("ArzMarket Loader")
script_author("f3rkomen")
script_version("1.2.2")
script_properties("work-in-pause")

local LOADER_VERSION = "1.2.2"
local MANIFEST_URL = "https://raw.githubusercontent.com/f3rkomen/PirojkiSPovidlom/main/release/updateArzMarket.js"
local TRUSTED_PREFIX = "https://raw.githubusercontent.com/f3rkomen/PirojkiSPovidlom/main/release/"
local LOADER_FILENAME = "ArzMarket_Loader.lua"
local LEGACY_LOADER_FILENAME = "PirojkiSPovidlom_Loader.lua"

local json_ok, json = pcall(require, "cjson")
local lfs_ok, lfs = pcall(require, "lfs")
local download_status = require("moonloader").download_status
local working_directory = getWorkingDirectory()
local state_directory = working_directory .. "\\ArzMarketLoader"
local manifest_path = state_directory .. "\\update-manifest.json"
local market_state_path = state_directory .. "\\installed-market.txt"
local market_hash_path = state_directory .. "\\installed-market.sha256"
local force_reinstall_path = state_directory .. "\\force-reinstall.request"

local function log(message)
    print("[ArzMarket] " .. tostring(message))
    if isSampAvailable() then
        sampAddChatMessage("[ArzMarket] {FFFFFF}" .. tostring(message), 0x6AA6FF)
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

local bit_ok, bit = pcall(require, "bit")

local function sha256_hex(data)
    if not bit_ok then
        return nil, "LuaJIT bit library is unavailable"
    end

    local band, bxor, bnot = bit.band, bit.bxor, bit.bnot
    local rshift, rrotate = bit.rshift, bit.ror
    local modulo = 4294967296
    local constants = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    }
    local hash = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

    local function add32(...)
        local sum = 0
        for index = 1, select("#", ...) do
            sum = (sum + select(index, ...)) % modulo
        end
        return sum
    end

    local function choice(value_a, value_b, value_c)
        return bxor(band(value_a, value_b), band(bnot(value_a), value_c))
    end

    local function majority(value_a, value_b, value_c)
        return bxor(band(value_a, value_b), band(value_a, value_c), band(value_b, value_c))
    end

    local function upper_sigma_0(value)
        return bxor(rrotate(value, 2), rrotate(value, 13), rrotate(value, 22))
    end

    local function upper_sigma_1(value)
        return bxor(rrotate(value, 6), rrotate(value, 11), rrotate(value, 25))
    end

    local function lower_sigma_0(value)
        return bxor(rrotate(value, 7), rrotate(value, 18), rshift(value, 3))
    end

    local function lower_sigma_1(value)
        return bxor(rrotate(value, 17), rrotate(value, 19), rshift(value, 10))
    end

    local bit_length = #data * 8
    data = data .. string.char(0x80)
    local padding = (56 - (#data % 64)) % 64
    data = data .. string.rep("\0", padding)
    local high = math.floor(bit_length / modulo)
    local low = bit_length % modulo
    local function pack_uint32(value)
        return string.char(
            band(rshift(value, 24), 0xff),
            band(rshift(value, 16), 0xff),
            band(rshift(value, 8), 0xff),
            band(value, 0xff)
        )
    end
    data = data .. pack_uint32(high) .. pack_uint32(low)

    for offset = 1, #data, 64 do
        local words = {}
        for index = 0, 15 do
            local base = offset + index * 4
            words[index] = add32(
                string.byte(data, base) * 0x1000000,
                string.byte(data, base + 1) * 0x10000,
                string.byte(data, base + 2) * 0x100,
                string.byte(data, base + 3)
            )
        end
        for index = 16, 63 do
            words[index] = add32(lower_sigma_1(words[index - 2]), words[index - 7], lower_sigma_0(words[index - 15]), words[index - 16])
        end

        local a, b, c, d, e, f, g, h = hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8]
        for index = 0, 63 do
            local temp_1 = add32(h, upper_sigma_1(e), choice(e, f, g), constants[index + 1], words[index])
            local temp_2 = add32(upper_sigma_0(a), majority(a, b, c))
            h, g, f, e, d, c, b, a = g, f, e, add32(d, temp_1), c, b, a, add32(temp_1, temp_2)
        end
        hash[1] = add32(hash[1], a)
        hash[2] = add32(hash[2], b)
        hash[3] = add32(hash[3], c)
        hash[4] = add32(hash[4], d)
        hash[5] = add32(hash[5], e)
        hash[6] = add32(hash[6], f)
        hash[7] = add32(hash[7], g)
        hash[8] = add32(hash[8], h)
    end

    local output = {}
    for index = 1, 8 do
        local value = hash[index]
        if value < 0 then
            value = value + modulo
        end
        output[index] = string.format("%08x", value)
    end
    return table.concat(output)
end

local function verify_sha256(path, expected_hash)
    if type(expected_hash) ~= "string" or not expected_hash:match("^[0-9a-fA-F]+$") or #expected_hash ~= 64 then
        return false, "manifest SHA-256 is invalid"
    end
    local data = read_all(path)
    if not data then
        return false, "downloaded file is unavailable"
    end
    local actual_hash, reason = sha256_hex(data)
    if not actual_hash then
        return false, reason
    end
    if actual_hash:lower() ~= expected_hash:lower() then
        return false, "SHA-256 mismatch"
    end
    return true
end

local function normalise_version(value)
    return tostring(value):gsub("[^%w%._%-]", "_"):gsub("%.", "_")
end

local function market_filename(version)
    local major, minor = tostring(version):match("^(%d+)%.(%d+)")
    if major and minor then
        return "#ArzMarket[" .. major .. "_" .. minor .. "].lua"
    end
    return "#ArzMarket[" .. normalise_version(version) .. "].lua"
end

local function market_path(version)
    return working_directory .. "\\" .. market_filename(version)
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

local function path_filename(path)
    return tostring(path):match("([^\\/]+)$")
end

local function migrate_legacy_loader_filename()
    local current_path = thisScript().path
    if path_filename(current_path) ~= LEGACY_LOADER_FILENAME then
        return false
    end

    local destination = working_directory .. "\\" .. LOADER_FILENAME
    if doesFileExist(destination) then
        log("New loader filename already exists; legacy file was left untouched")
        return false
    end

    local moved, reason = os.rename(current_path, destination)
    if not moved then
        log("Could not rename the legacy loader: " .. tostring(reason))
        return false
    end
    if script.load(destination) == false then
        os.rename(destination, current_path)
        log("New loader file could not be loaded; restored the legacy filename")
        return false
    end
    log("Loader renamed to " .. LOADER_FILENAME)
    thisScript():unload()
    return true
end

local function is_managed_market_path(path)
    local filename = path_filename(path)
    return type(path) == "string" and starts_with(path, working_directory .. "\\") and filename and filename:match("^#ArzMarket%[[%w_%-]+%]%.lua$")
end

local function save_market_path(path)
    local handle = io.open(market_state_path, "wb")
    if handle then
        handle:write(path)
        handle:close()
    end
end

local function read_market_hash()
    local value = read_all(market_hash_path)
    if not value then
        return nil
    end
    value = value:match("^([0-9a-fA-F]+)")
    if value and #value == 64 then
        return value:lower()
    end
    return nil
end

local function save_market_hash(value)
    local handle = io.open(market_hash_path, "wb")
    if handle then
        handle:write(tostring(value):lower())
        handle:close()
    end
end

local function unload_script_by_filename(filename)
    for _, entry in pairs(script.list()) do
        if entry.filename == filename then
            entry:unload()
            return
        end
    end
end

local function unload_and_remove_previous_market(keep_path)
    local previous = read_all(market_state_path)
    if previous then
        previous = previous:match("^([^\r\n]+)")
    end

    if previous and previous ~= keep_path and is_managed_market_path(previous) and doesFileExist(previous) then
        unload_script_by_filename(path_filename(previous))
        os.remove(previous)
    end

    -- Versions created by the first loader used a private filename. Remove
    -- only those files; ordinary ArzMarket files are never mass-deleted.
    if lfs_ok then
        for filename in lfs.dir(working_directory) do
            if filename:match("^#PirojkiArzMarket%[.*%]%.lua$") then
                local path = working_directory .. "\\" .. filename
                unload_script_by_filename(filename)
                os.remove(path)
            end
        end
    end

    save_market_path(keep_path)
end

local function load_market_if_needed(path)
    local filename = path_filename(path)
    for _, entry in pairs(script.list()) do
        if entry.filename == filename then
            return true
        end
    end
    return script.load(path) ~= false
end

local function clear_stale_temporary_files()
    os.remove(thisScript().path .. ".new")
    os.remove(thisScript().path .. ".bak")
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

local function update_loader(url, expected_hash)
    if not starts_with(url, TRUSTED_PREFIX) then
        log("Loader update URL was rejected")
        return
    end
    local temporary = thisScript().path .. ".new"
    os.remove(temporary)
    log("Updating loader")
    download_to(url, temporary, function()
        if not doesFileExist(temporary) then
            log("Loader update was not written")
            return
        end
        local valid, validation_reason = verify_sha256(temporary, expected_hash)
        if not valid then
            os.remove(temporary)
            log("Loader update was rejected: " .. tostring(validation_reason))
            return
        end
        local backup = thisScript().path .. ".bak"
        os.remove(backup)
        local moved_old, old_reason = os.rename(thisScript().path, backup)
        if not moved_old then
            os.remove(temporary)
            log("Could not prepare loader update: " .. tostring(old_reason))
            return
        end
        local moved, reason = os.rename(temporary, thisScript().path)
        if not moved then
            os.rename(backup, thisScript().path)
            os.remove(temporary)
            log("Could not install loader update: " .. tostring(reason))
            return
        end
        os.remove(backup)
        log("Loader updated; reloading")
        thisScript():reload()
    end, function(reason)
        os.remove(temporary)
        log("Loader update error: " .. tostring(reason))
    end)
end

local function replace_market(destination, temporary)
    local backup = destination .. ".bak"
    os.remove(backup)

    if doesFileExist(destination) then
        unload_script_by_filename(path_filename(destination))
        local moved_old, old_reason = os.rename(destination, backup)
        if not moved_old then
            os.remove(temporary)
            return false, "could not prepare Market replacement: " .. tostring(old_reason)
        end
        local moved, reason = os.rename(temporary, destination)
        if not moved then
            os.rename(backup, destination)
            os.remove(temporary)
            return false, "could not install Market replacement: " .. tostring(reason)
        end
        os.remove(backup)
        return true
    end

    local moved, reason = os.rename(temporary, destination)
    if not moved then
        os.remove(temporary)
        return false, "could not install Market: " .. tostring(reason)
    end
    return true
end

local function install_market(manifest, force_reinstall)
    if not starts_with(manifest.updateurl, TRUSTED_PREFIX) then
        log("Market update URL was rejected")
        return
    end
    local destination = market_path(manifest.latest)
    if doesFileExist(destination) and not force_reinstall then
        local installed_hash = read_market_hash()
        if installed_hash == tostring(manifest.sha256):lower() then
            unload_and_remove_previous_market(destination)
            log("Market is current: " .. tostring(manifest.latest))
            return
        end
        if installed_hash then
            log("Fork update is available; use the GitHub reinstall button")
            return
        end
        local valid = verify_sha256(destination, manifest.sha256)
        if valid then
            save_market_hash(manifest.sha256)
            unload_and_remove_previous_market(destination)
            log("Market is current: " .. tostring(manifest.latest))
            return
        end
        log("Installing the verified fork release for the first time")
    end
    local temporary = destination .. ".new"
    os.remove(temporary)
    log((force_reinstall and "Reinstalling" or "Downloading") .. " Market " .. tostring(manifest.latest))
    download_to(manifest.updateurl, temporary, function()
        if not doesFileExist(temporary) then
            log("Market file was not written")
            return
        end
        local valid, validation_reason = verify_sha256(temporary, manifest.sha256)
        if not valid then
            os.remove(temporary)
            log("Market download was rejected: " .. tostring(validation_reason))
            return
        end
        local installed, reason = replace_market(destination, temporary)
        if not installed then
            log(tostring(reason))
            return
        end
        unload_and_remove_previous_market(destination)
        save_market_hash(manifest.sha256)
        if not load_market_if_needed(destination) then
            log("Market was saved, but MoonLoader could not load it")
            return
        end
        log("Market installed: " .. tostring(manifest.latest))
    end, function(reason)
        os.remove(temporary)
        log("Market update error: " .. tostring(reason))
    end)
end

local function process_manifest(force_reinstall)
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
    if not ok or type(manifest) ~= "table" or not manifest.latest or not manifest.updateurl or not manifest.sha256 then
        log("Invalid update manifest")
        return
    end
    if manifest.loaderLatest and manifest.loaderUpdateUrl and version_is_newer(manifest.loaderLatest, LOADER_VERSION) then
        if not manifest.loaderSha256 then
            log("Loader update was skipped: manifest has no SHA-256")
        else
            update_loader(manifest.loaderUpdateUrl, manifest.loaderSha256)
            return
        end
    end
    install_market(manifest, force_reinstall == true)
end

local manifest_download_active = false
local queued_manifest_force = false

local function request_manifest(force_reinstall)
    if manifest_download_active then
        queued_manifest_force = queued_manifest_force or force_reinstall == true
        return
    end
    manifest_download_active = true
    if doesFileExist(manifest_path) then
        os.remove(manifest_path)
    end
    download_to(MANIFEST_URL, manifest_path, function()
        manifest_download_active = false
        process_manifest(force_reinstall)
        if queued_manifest_force then
            queued_manifest_force = false
            request_manifest(true)
        end
    end, function(reason)
        manifest_download_active = false
        os.remove(manifest_path)
        log("Manifest check error: " .. tostring(reason))
    end)
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
    if migrate_legacy_loader_filename() then
        return
    end
    clear_stale_temporary_files()
    if doesFileExist(manifest_path) then
        os.remove(manifest_path)
    end
    log("Checking own release channel")
    request_manifest(false)
    while true do
        if doesFileExist(force_reinstall_path) then
            os.remove(force_reinstall_path)
            log("GitHub reinstall requested")
            request_manifest(true)
        end
        wait(250)
    end
end
