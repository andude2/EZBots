-- peercommands.lua - centralized actor-based command system
local mq = require('mq')
local actors = require('actors')
local json = require('commons.dkjson')

local M = {}

local alias_file_path = mq.configDir .. '/peer_aliases.ini'

local aliases = {}

local MAILBOX_NAME = 'peer_command'
local actor = nil
local connectedPeers = {}
local last_peer_refresh = 0
local PEER_REFRESH_INTERVAL = 60
local initialized = false

local chase_mode = false
local chase_target = nil

local function peer_id()
    return mq.TLO.EverQuest.Server() .. '_' .. mq.TLO.Me.CleanName()
end

local function peer_name()
    return mq.TLO.Me.CleanName()
end

local function extract_peer_name(peer_id)
    local _, _, name = string.find(peer_id, "([^_]+)$")
    return name
end

local function check_remove_peer(peer)
    return function(status, content)
        if status < 0 then
            print("[PeerCommand] Lost connection to peer: " .. peer)
            connectedPeers[peer] = nil
        end
    end
end

local function announce_presence()
    --print("[PeerCommand] Broadcasting presence announcement")
    actor:send({type = 'Announce', from = peer_name()})
end

local function handle_message(message)
    local data = message()
    
    if not data or type(data) ~= 'table' then
        print('\ar[PeerCommand] Invalid message received\ax')
        return
    end
    
    if data.type == 'Announce' then
        if data.from then
            --print(string.format('\ag[PeerCommand] Peer %s announced presence\ax', data.from))
            connectedPeers[data.from] = mq.gettime()
            message:send({type = 'Register', from = peer_name()})
        end
    elseif data.type == 'Register' then
        if data.from then
            --print(string.format('\ag[PeerCommand] Registered peer %s\ax', data.from))
            connectedPeers[data.from] = mq.gettime()
        end
    elseif data.type == 'Command' then
        local cmd = data.command
        local intended = data.target
        local me_name = peer_name()
        
        if not intended or intended == me_name then
            print(string.format('\ag[PeerCommand] Executing: \ay%s\ax', cmd))
            mq.cmd(cmd)
        else
            print(string.format('[PeerCommand] Ignoring command intended for %s', tostring(intended)))
        end
    end
end

function M.debug_aliases()
    print("\ay[PeerCommand] DEBUG: Dumping raw aliases table\ax")
    for k, v in pairs(aliases) do
        print(string.format("  Key: '%s' Type: %s", k, type(v)))
        if type(v) == "table" then
            print("  Members: " .. table.concat(v, ", "))
        else
            print("  Value: " .. tostring(v))
        end
    end
end

function M.define_alias(name, members)
    if type(name) == "string" and type(members) == "table" then
        local key = name:lower()
        aliases[key] = members
        print(string.format("[PeerCommand] Alias '%s' defined with %d members", key, #members))
    else
        print("\ar[PeerCommand] Invalid alias definition\ax")
    end
end

local function write_default_alias_file()
    local file = io.open(alias_file_path, 'w')
    if not file then
        print(string.format("\ar[PeerCommand] Failed to create alias file at: %s\ax", alias_file_path))
        return
    end

    file:write("[aliases]\n")
    file:write("healers = ClericOne, ClericTwo\n")
    file:write("tanks = WarriorMain, PaladinAlt\n")
    file:write("casters = Estos, Kelythar, Lerdari\n")
    file:write("; Add more alias groups as needed\n")
    file:close()

    print(string.format("\ay[PeerCommand] Wrote default alias file to: %s\ax", alias_file_path))
end

function M.load_aliases()
    aliases = {}
    local file = io.open(alias_file_path, 'r')
    if not file then
        print(string.format("\ay[PeerCommand] Alias file not found, creating: %s\ax", alias_file_path))
        write_default_alias_file()
        file = io.open(alias_file_path, 'r')
        if not file then
            print(string.format("\ar[PeerCommand] Failed to open alias file after creating it: %s\ax", alias_file_path))
            return
        end
    end

    local in_alias_section = false
    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$") -- Trim whitespace
        if line == '' or line:sub(1, 1) == ';' then
            -- skip empty and comment lines
        elseif line:match("^%[.-%]$") then
            in_alias_section = (line:lower() == '[aliases]')
        elseif in_alias_section then
            local key, val = line:match("^(.-)=(.+)$")
            if key and val then
                key = key:match("^%s*(.-)%s*$") -- Trim key
                local members = {}
                for name in val:gmatch("([^,]+)") do
                    local trimmed = name:match("^%s*(.-)%s*$") -- trim each name
                    if trimmed and trimmed ~= "" then
                        table.insert(members, trimmed) -- Keep original case for display
                    end
                end
                if #members > 0 then
                    aliases[key:lower()] = members
                    print(string.format("[DEBUG] Added alias '%s' with %d members", key:lower(), #members))
                end
            end
        end
    end

    file:close()
    print(string.format("[PeerCommand] Loaded %d aliases", tablelength(aliases)))
end

function M.get_alias(name)
    if not name then return nil end
    local lowered = name:lower()
    local result = aliases[lowered]
    if not result then
        print(string.format("[DEBUG] get_alias('%s') -> nil", lowered))
        -- Try iterating through all keys to find a match (case insensitive)
        for k, v in pairs(aliases) do
            if k:lower() == lowered then
                print(string.format("[DEBUG] Found alias with different case: '%s'", k))
                return v
            end
        end
    end
    return result
end

function M.reload()
    M.load_aliases()
end

function M.list_aliases()
    print("\ag[PeerCommand] Alias groups:\ax")
    for k, v in pairs(aliases) do
        print(string.format("  %s: %s", k, table.concat(v, ", ")))
    end
end

-- Utility to get table length
function tablelength(tbl)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

function M.send(peer_or_list, command)
    if not peer_or_list or not command then return false end
    local debug_mode = false  -- Set this to true if you want detailed peer logs

    local function send_to_peer(peer)
        -- Direct match first
        if connectedPeers[peer] then
            if debug_mode then
                print(string.format('[PeerCommand] Sending to %s: %s', peer, command))
            end
            actor:send({character = peer}, {type = 'Command', command = command}, check_remove_peer(peer))
            return true
        else
            -- Try case-insensitive match
            for connectedPeer in pairs(connectedPeers) do
                if connectedPeer:lower() == peer:lower() then
                    if debug_mode then
                        print(string.format('[PeerCommand] Sending to %s: %s (case-insensitive match for %s)', connectedPeer, command, peer))
                    end
                    actor:send({character = connectedPeer}, {type = 'Command', command = command}, check_remove_peer(connectedPeer))
                    return true
                end
            end
            
            if debug_mode then
                print(string.format('\ar[PeerCommand] Peer %s not connected or registered\ax', peer))
            end
            return false
        end
    end

    if type(peer_or_list) == "table" then
        local sent = 0
        for _, peer in ipairs(peer_or_list) do
            if send_to_peer(peer) then sent = sent + 1 end
        end
        
        -- Only print summary message if we sent to multiple peers
        if sent > 0 then
            print(string.format('[PeerCommand] Command sent to %d peers: %s', sent, command))
        elseif debug_mode then
            print('\ar[PeerCommand] No connected peers to receive command\ax')
        end
        
        return sent
    else
        local sent = send_to_peer(peer_or_list) and 1 or 0
        
        -- For single peer sends, print a message only on success or if in debug mode
        if sent == 1 then
            print(string.format('[PeerCommand] Command sent to %s: %s', peer_or_list, command))
        elseif debug_mode then
            print(string.format('\ar[PeerCommand] Failed to send command to %s\ax', peer_or_list))
        end
        
        return sent
    end
end


function M.broadcast(command)
    if not command then return 0 end
    
    local sent = 0
    local debug_mode = false
    
    if debug_mode then
        print(string.format('[PeerCommand] Broadcasting command: %s', command))
    end
    
    for peer, _ in pairs(connectedPeers) do
        if peer ~= peer_name() then
            if debug_mode then
                print(string.format('[PeerCommand] Sending to %s: %s', peer, command))
            end
            actor:send({character = peer}, {type = 'Command', command = command}, check_remove_peer(peer))
            sent = sent + 1
        end
    end
    
    if sent > 0 then
        print(string.format('[PeerCommand] Command sent to %d peers: %s', sent, command))
    else
        print('\ay[PeerCommand] No peers connected to receive command\ax')
    end
    
    return sent
end

local function maintain_connections()
    local now = mq.gettime()
    
    for peer, last_seen in pairs(connectedPeers) do
        if now - last_seen > 300 then -- 5 minutes
            print(string.format('\ay[PeerCommand] Peer %s connection timed out\ax', peer))
            connectedPeers[peer] = nil
        end
    end
    
    if now - last_peer_refresh >= PEER_REFRESH_INTERVAL then
        announce_presence()
        last_peer_refresh = now
    end
end

function M.list_peers()
    local count = 0
    print('\ag[PeerCommand] Connected peers:\ax')
    
    for peer, _ in pairs(connectedPeers) do
        print(string.format('  - %s', peer))
        count = count + 1
    end
    
    if count == 0 then
        print('  No peers connected')
    end
    
    return count
end

-- Bind commands
mq.bind("/actexec", function(...)
    local cmd = table.concat({...}, " ")
    print(string.format('[PeerCommand] Executing locally: %s', cmd))
    mq.cmd(cmd)
end)

mq.bind("/acaa", function(...)
    local cmd = table.concat({...}, " ")
    if cmd == '' then
        print("Usage: /acaa <command>")
        return
    end
    M.broadcast(cmd)
    mq.cmdf("%s", cmd)
end)

mq.bind("/aca", function(...)
    local cmd = table.concat({...}, " ")
    if cmd == '' then
        print("Usage: /aca <command>")
        return
    end
    
    local sent = 0
    for peer, _ in pairs(connectedPeers) do
        if peer ~= peer_name() then
            M.send(peer, cmd)
            sent = sent + 1
        end
    end
    
    print(string.format('Sent to %d peers: %s', sent, cmd))
end)

mq.bind("/actell", function(...)
    local args = {...}
    if #args < 2 then
        print("Usage: /actell <peer> <command>")
        return
    end
    local peer = args[1]
    local cmd = table.concat(args, " ", 2)
    
    if not M.send(peer, cmd) then
        print(string.format('\ar[PeerCommand] Failed to send command to %s\ax', peer))
    end
end)

mq.bind("/aclist", function(...)
    M.list_peers()
end)

mq.bind("/acalias", function(...)
    local args = {...}
    if #args < 2 then
        print("Usage: /acalias <alias> <command>")
        M.list_aliases()
        return
    end

    local alias = args[1]:lower()
    local cmd = table.concat(args, " ", 2)
    local members = M.get_alias(alias)

    if not members then
        print(string.format("\ar[PeerCommand] Alias '%s' not found.\ax", alias))
        M.list_aliases()
        return
    end

    local connected = {}
    -- Case insensitive peer matching
    for _, peer in ipairs(members) do
        local found = false
        -- First try direct match
        if connectedPeers[peer] then
            found = true
            table.insert(connected, peer)
        else
            -- Try case-insensitive match
            for connectedPeer in pairs(connectedPeers) do
                if connectedPeer:lower() == peer:lower() then
                    found = true
                    table.insert(connected, connectedPeer) -- Use the actual case from connected peers
                    --print(string.format("[DEBUG] Case-insensitive match: '%s' -> '%s'", peer, connectedPeer))
                    break
                end
            end
        end
        
        if not found then
            print(string.format("[DEBUG] Peer '%s' from alias is not connected", peer))
        end
    end

    if #connected == 0 then
        print(string.format("\ar[PeerCommand] No connected peers in alias '%s'.\ax", alias))
        return
    end

    local sent = M.send(connected, cmd)
    print(string.format("[PeerCommand] Sent to %d connected members of alias '%s': %s", sent, alias, cmd))
end)

mq.bind("/acreloadaliases", function()
    M.reload()
    print("\ag[PeerCommand] Aliases successfully reloaded from INI.\ax")
end)

mq.bind("/acdebug", function()
    M.debug_aliases()
end)

function M.setup_maintenance()
    if not initialized then
        print('[PeerCommand] Setting up maintenance timer')
        mq.event('PeerCommandMaintenance', '#*#', function()
            maintain_connections()
        end)
        mq.cmdf('/timed 30 /doevents PeerCommandMaintenance')
        initialized = true
    end
end

-- Initialize the module
function M.init()
    if actor then return end

    actor = actors.register(MAILBOX_NAME, handle_message)
    print('[PeerCommand] Registered actor mailbox: ' .. MAILBOX_NAME)

    announce_presence()
    M.load_aliases()

    print('[PeerCommand] Initial setup complete')
end

M.init()

M.update_chase = update_chase

return M