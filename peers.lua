-- peers.lua
-- Handles peer status and switching logic
-- Enhanced with AA capture and number formatting

-- ALGAR Edits: Endurance, PetHP

local mq                   = require('mq')
local Set                  = require('mq.set')
local imgui                = require('ImGui')
local actors               = require('actors')
local utils                = require('commons.utils') -- Assuming utils.lua is available
local json                 = require('commons.dkjson')
local config               = {}
local config_path          = string.format('%s/peer_ui_config.json', mq.configDir)
local myName               = mq.TLO.Me.CleanName() or "Unknown"
local enduranceUsers       = Set.new({ "BRD", "BST", "BER", "MNK", "PAL", "RNG", "ROG", "SHD", "WAR", })
local manaUsers            = Set.new({ "BRD", "BST", "CLR", "DRU", "ENC", "MAG", "NEC", "PAL", "RNG", "SHD", "SHM", "WIZ", })
local petClasses           = Set.new({ "BST", "DRU", "ENC", "MAG", "NEC", "SHD", "SHM", })

local M                    = {} -- Module table

-- Configuration
local REFRESH_INTERVAL_MS  = 1        -- How often to run the update loop (in ms)
local PUBLISH_INTERVAL_S   = 0.2      -- How often to publish own status (in seconds)
local STALE_DATA_TIMEOUT_S = 30       -- How long before peer data is considered stale (in seconds)
local FG_REFRESH_MS        = 1        -- when we're foregrounded, run every millisecond
local BG_REFRESH_MS        = 200      -- background only needs 5Hz updates (200ms)
local lastRefreshTime      = 0        -- track in mq's high‐res clock
local elapsed              = os.clock -- or mq.clock, whichever you use

-- State Variables
M.peers                    = {}         -- Stores data received from other peers [id] = {data}
M.peer_list                = {}         -- Filtered and processed list of peers for display
M.options                  = {          -- Options controlled by the main UI menu
    sort_mode         = "Alphabetical", -- or "HP", "Distance", "Group" (Add sorting logic if needed)
    show_name         = true,
    show_hp           = true,
    show_endurance    = true,
    show_mana         = true,
    show_pethp        = true,
    show_distance     = true,
    show_target       = true,
    show_combat       = true,
    show_casting      = true,
    show_group        = true,
    borderless        = false,
    show_player_stats = true,
    use_class         = false,
    font_scale        = 1.0,
    filler_char       = "~ ~ ~ ~ ~",
}
M.show_aa_window           = { value = false, } -- Control the visibility of the AA window
M.show_sort_editor         = { value = false, }

local lastPeerCount        = 0
local cachedPeerHeight     = 300 -- Default height
local lastUpdateTime       = {}  -- [id] = timestamp of last message received
local lastPublishTime      = 0   -- Timestamp of last published message
local actor_mailbox        = nil
local MyName               = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
local MyServer             = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown")

-- AA Tracking Variables (NEW)
local actualAAPoints       = nil -- Stores the actual AA from chat, nil if not captured yet
local lastAACheckTime      = 0   -- Timestamp of last AA check
local AA_CHECK_INTERVAL    = 300 -- Check AA every 5 minutes (300 seconds)
local aa_said              = false


-------------------------------------------
---AA Functions with Server-Specific Logic (NEW)
-------------------------------------------

local function isEZLinuxServer()
    local serverName = utils.safeTLO(mq.TLO.EverQuest.Server, "")
    return serverName == "EZ (Linux) x4 Exp"
end

local function aaGainCallback(line, totalAmount)
    local cleanTotal = string.gsub(totalAmount, ",", "") -- Remove commas
    local total = tonumber(cleanTotal)                   -- Convert to number

    if total then
        actualAAPoints = total
        --print(string.format("[Peers] AA Update: Gained, now have %d total AA points", total))
    else
        print(string.format("[Peers] Warning: Could not parse AA total from: %s", totalAmount or "nil"))
    end
end

local function aaDisplayCallback(line, aaAmount)
    local cleanAmount = string.gsub(aaAmount, ",", "")
    local points = tonumber(cleanAmount)
    if points then
        actualAAPoints = points
        print(string.format("[Peers] Captured actual AA points: %s", aaAmount))
    else
        print(string.format("[Peers] Warning: Could not parse AA amount from: %s", aaAmount or "nil"))
    end
end

local function getActualAAPoints()
    if isEZLinuxServer() then
        -- Use captured AA from chat for EZ Linux server
        if actualAAPoints then
            return actualAAPoints
        end
        return utils.safeTLO(mq.TLO.Me.AAPoints, 0) -- Fallback to TLO if no chat capture yet
    else
        -- Use TLO directly for all other servers
        return utils.safeTLO(mq.TLO.Me.AAPoints, 0)
    end
end

local function requestAAUpdate()
    if not isEZLinuxServer() then
        return -- Don't request AA updates on non-EZ servers
    end

    if aa_said then
        return
    end
    mq.cmd('/say #AA')
    aa_said = true
end

-- Number formatting function (NEW)
local function formatNumberWithCommas(num)
    if not num or num == 0 then return "0" end
    local formatted = tostring(num)
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- Helper: Get health bar color
local function getHealthColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(1, 0, 0, 1) -- Red
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1) -- Yellow
    else
        return ImVec4(0, 1, 0, 1) -- Green
    end
end

local function getEnduranceColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(0.5, 0.5, 0, 1) -- Red
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1)     -- Yellow
    else
        return ImVec4(1, 0.7, 0.5, 1) -- Orangish
    end
end

local function getManaColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(0.5, 0.5, 0, 1)         -- Red
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1)             -- Yellow
    else
        return ImVec4(0.678, 0.847, 0.902, 1) -- Light Blue
    end
end

local function get_groupstatus_text(peerName)
    if peerName == MyName then
        return "F1"
    end

    if mq.TLO.Group.Members() > 0 then
        local groupMember = mq.TLO.Group.Member(peerName)
        if groupMember() then
            return "F" .. ((groupMember.Index() or 0) + 1)
        end
    end

    if mq.TLO.Raid.Members() > 0 then
        local raidMember = mq.TLO.Raid.Member(peerName)
        if raidMember() then
            return "G" .. (raidMember.Group() or 0)
        end
    end

    return "X"
end

local function publishHealthStatus()
    local currentTime = os.time()
    if os.difftime(currentTime, lastPublishTime) < PUBLISH_INTERVAL_S then
        return
    end
    if not actor_mailbox then
        print('\ar[Peers] Actor mailbox not initialized. Cannot publish status.\ax')
        return
    end

    -- Request AA update for EZ Linux servers (NEW)
    requestAAUpdate()

    local status = {
        name = MyName,
        server = MyServer,
        hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0),
        endurance = utils.safeTLO(mq.TLO.Me.PctEndurance, 0),
        mana = utils.safeTLO(mq.TLO.Me.PctMana, 0),
        pethp = utils.safeTLO(mq.TLO.Me.Pet.PctHPs, 0),
        zone = utils.safeTLO(mq.TLO.Zone.ShortName, "unknown"),
        distance = 0,
        aa = getActualAAPoints(), -- Use enhanced AA function (CHANGED)
        target = utils.safeTLO(mq.TLO.Target.CleanName, "None"),
        combat_state = utils.safeTLO(mq.TLO.Me.Combat, FALSE),
        casting = utils.safeTLO(mq.TLO.Me.Casting, "None"),
        class = utils.safeTLO(mq.TLO.Me.Class.ShortName, "Unknown"),
    }
    actor_mailbox:send({ mailbox = 'peer_status', }, status)
    lastPublishTime = currentTime
end

local function peer_message_handler(message)
    local content = message()
    if not content or type(content) ~= 'table' then
        print('\ay[Peers] Received invalid or empty message\ax')
        return
    end
    --print(string.format("[Peers] Received from %s/%s: HP=%d%% DPS=%.1f Zone=%s", content.name or "?", content.server or "?", content.hp or 0, content.dps or 0, content.zone or "?"))
    if not content.name or not content.server then
        print('\ay[Peers] Missing name or server in message\ax')
        return
    end
    local id = content.server .. "_" .. content.name
    if id == MyServer .. "_" .. MyName then return end
    local currentTime = os.time()
    M.peers[id] = {
        id = id,
        name = content.name,
        server = content.server,
        hp = content.hp or 0,
        endurance = content.endurance or 0,
        mana = content.mana or 0,
        pethp = content.pethp or 0,
        zone = content.zone or "unknown",
        aa = content.aa or 0,
        target = content.target or "None",
        combat_state = content.combat_state == true or content.combat_state == "TRUE" or false,
        casting = content.casting or "None",
        last_update = currentTime,
        distance = 0,
        inSameZone = false,
        class = content.class or "Unknown",
    }
    lastUpdateTime[id] = currentTime
end

-- Peer List Management
local function cleanupPeers()
    local currentTime = os.time()
    local idsToRemove = {}
    for id, data in pairs(M.peers) do
        if os.difftime(currentTime, data.last_update) > STALE_DATA_TIMEOUT_S then
            table.insert(idsToRemove, id)
        end
    end
    for _, id in ipairs(idsToRemove) do
        M.peers[id] = nil
        lastUpdateTime[id] = nil -- Clean up last update time as well
        -- print(string.format("[Peers] Removed stale peer: %s", id))
    end
end

local function refreshPeers()
    local new_peer_list = {}
    local currentTime = os.time()
    local myCurrentZone = utils.safeTLO(mq.TLO.Zone.ShortName, "unknown")
    local myID = utils.safeTLO(mq.TLO.Me.ID, 0)
    local my_entry_id = MyServer .. "_" .. MyName

    -- Update self entry in peers table (always refresh the AA value) (CHANGED)
    if M.peers[my_entry_id] then
        M.peers[my_entry_id].hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0)
        M.peers[my_entry_id].endurance = utils.safeTLO(mq.TLO.Me.PctEndurance, 0)
        M.peers[my_entry_id].mana = utils.safeTLO(mq.TLO.Me.PctMana, 0)
        M.peers[my_entry_id].pethp = utils.safeTLO(mq.TLO.Me.Pet.PctHPs, 0)
        M.peers[my_entry_id].zone = myCurrentZone
        M.peers[my_entry_id].aa = getActualAAPoints() -- Use enhanced AA function
        M.peers[my_entry_id].target = utils.safeTLO(mq.TLO.Target.CleanName, "None")
        M.peers[my_entry_id].combat_state = utils.safeTLO(mq.TLO.Me.Combat, TRUE)
        M.peers[my_entry_id].casting = utils.safeTLO(mq.TLO.Me.Casting, "None")
        M.peers[my_entry_id].last_update = currentTime
        M.peers[my_entry_id].distance = 0
        M.peers[my_entry_id].inSameZone = true
        M.peers[my_entry_id].class = utils.safeTLO(mq.TLO.Me.Class.ShortName, "unknown")
    else
        -- Create new self entry
        M.peers[my_entry_id] = {
            id = my_entry_id,
            name = MyName,
            server = MyServer,
            hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0),
            endurance = utils.safeTLO(mq.TLO.Me.PctEndurance, 0),
            mana = utils.safeTLO(mq.TLO.Me.PctMana, 0),
            pethp = utils.safeTLO(mq.TLO.Me.Pet.PctHPs, 0),
            zone = myCurrentZone,
            aa = getActualAAPoints(), -- Use enhanced AA function
            target = utils.safeTLO(mq.TLO.Target.CleanName, "None"),
            combat_state = utils.safeTLO(mq.TLO.Me.Combat, TRUE),
            casting = utils.safeTLO(mq.TLO.Me.Casting, "None"),
            last_update = currentTime,
            distance = 0,
            inSameZone = true,
            class = utils.safeTLO(mq.TLO.Me.Class.ShortName, "unknown"),
        }
    end
    table.insert(new_peer_list, M.peers[my_entry_id])

    -- Process other peers (existing logic continues...)
    for id, data in pairs(M.peers) do
        -- Add group status from the local client perspective for numbering
        data.group_status = get_groupstatus_text(data.name)

        if id == my_entry_id then goto continue end
        if os.difftime(currentTime, data.last_update) <= STALE_DATA_TIMEOUT_S then
            data.inSameZone = (data.zone == myCurrentZone)
            if data.inSameZone then
                local spawn = mq.TLO.Spawn(string.format('pc "%s"', data.name))
                if spawn and spawn() and spawn.ID() and spawn.ID() ~= myID then
                    local distance = spawn.Distance3D()
                    if distance ~= nil then
                        data.distance = distance
                    else
                        data.distance = 9999
                    end
                else
                    data.distance = 9999
                end
            else
                data.distance = 9999
            end
            table.insert(new_peer_list, data)
        end
        ::continue::
    end

    -- Apply Sorting
    if M.options.sort_mode == "Alphabetical" then
        table.sort(new_peer_list, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    elseif M.options.sort_mode == "HP" then
        table.sort(new_peer_list, function(a, b) return (a.hp or 0) < (b.hp or 0) end)
    elseif M.options.sort_mode == "Distance" then
        table.sort(new_peer_list, function(a, b) return (a.distance or 9999) < (b.distance or 9999) end)
    elseif M.options.sort_mode == "Class" then
        table.sort(new_peer_list, function(a, b)
            local class_a = a.class or "Unknown"
            local class_b = b.class or "Unknown"
            if class_a:lower() == class_b:lower() then
                return (a.name or ""):lower() < (b.name or ""):lower()
            end
            return class_a:lower() < class_b:lower()
        end)
    elseif M.options.sort_mode == "Group" then
        table.sort(new_peer_list, function(a, b) return a.group_status:lower() < b.group_status:lower() end)
    elseif M.options.sort_mode == "Custom" then
        local custom_order = M.options.custom_order or {}
        local id_to_peer = {}; for _, p in ipairs(new_peer_list) do id_to_peer[p.id] = p end
        new_peer_list = {}
        for _, entry in ipairs(custom_order) do
            if entry.type == "filler" then
                table.insert(new_peer_list, {
                    type        = "filler",
                    filler_text = entry.filler_text or M.options.filler_char,
                })
            else
                local peer = id_to_peer[entry.id]
                if peer then table.insert(new_peer_list, peer) end
            end
        end
    end

    M.peer_list = new_peer_list

    local num_peer_rows = #M.peer_list
    local num_class_title_rows = 0

    if M.options.sort_mode == "Class" and num_peer_rows > 0 then
        local distinct_classes = {}
        for _, peer_entry in ipairs(M.peer_list) do
            distinct_classes[peer_entry.class or "Unknown"] = true
        end
        for _ in pairs(distinct_classes) do
            num_class_title_rows = num_class_title_rows + 1
        end
    end

    local single_data_row_height = imgui.GetTextLineHeight() + (imgui.GetStyle().CellPadding.y * 2)
    local table_header_actual_row_height = single_data_row_height + 2
    local new_calculated_height = 0
    if num_peer_rows > 0 or num_class_title_rows > 0 then
        new_calculated_height = new_calculated_height + table_header_actual_row_height
    end

    new_calculated_height = new_calculated_height + (num_peer_rows * single_data_row_height)
    new_calculated_height = new_calculated_height + (num_class_title_rows * single_data_row_height)

    if new_calculated_height > 0 then
        new_calculated_height = new_calculated_height + (imgui.GetStyle().FramePadding.y)
    end

    local min_renderable_height = table_header_actual_row_height
    if num_peer_rows == 0 and num_class_title_rows == 0 then
        min_renderable_height = 20
    end

    cachedPeerHeight = math.max(min_renderable_height, new_calculated_height)

    if num_peer_rows ~= lastPeerCount then
        lastPeerCount = num_peer_rows
    end

    cleanupPeers()
end

-- Switcher Actions
local function switchTo(name)
    if name and type(name) == 'string' and name ~= MyName then
        print(string.format("[Peers] Switching to: %s", name))
        mq.cmdf('/dex %s /foreground', name)
    end
end

local function targetCharacter(name)
    if name and type(name) == 'string' and name ~= MyName then
        print(string.format("[Peers] Targeting: %s", name))
        mq.cmdf('/target pc "%s"', name) -- Quote name for safety
    end
end

-- Drawing Functions (existing code continues...)
function M.draw_peer_list()
    -- [Existing draw_peer_list code remains the same]
    local column_count = 0
    local first_column_is_name_or_class = false
    if M.options.show_name or M.options.use_class then
        column_count = column_count + 1
        first_column_is_name_or_class = true
    end
    if M.options.show_hp then column_count = column_count + 1 end
    if M.options.show_endurance then column_count = column_count + 1 end
    if M.options.show_mana then column_count = column_count + 1 end
    if M.options.show_pethp then column_count = column_count + 1 end
    if M.options.show_distance then column_count = column_count + 1 end
    if M.options.show_target then column_count = column_count + 1 end
    if M.options.show_combat then column_count = column_count + 1 end
    if M.options.show_casting then column_count = column_count + 1 end
    if M.options.show_group then column_count = column_count + 1 end

    if column_count == 0 then
        imgui.Text("No columns selected for Peer Switcher.")
        return
    end

    local tableFlags = bit32.bor(
        ImGuiTableFlags.Reorderable,
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.NoHostExtendX
    )

    if not imgui.BeginTable("##PeerTableUnified", column_count, tableFlags) then
        return
    end

    if first_column_is_name_or_class then
        local header_text = "Name"
        if M.options.sort_mode ~= "Class" and M.options.use_class then
            header_text = "Class"
        end
        imgui.TableSetupColumn(header_text, ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 150)
    end
    if M.options.show_hp then imgui.TableSetupColumn("HP", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_endurance then imgui.TableSetupColumn("End", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_mana then imgui.TableSetupColumn("Mana", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_pethp then imgui.TableSetupColumn("PetHP", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_distance then imgui.TableSetupColumn("Dist", ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_target then imgui.TableSetupColumn("Target", ImGuiTableColumnFlags.WidthFixed, 100) end
    if M.options.show_combat then imgui.TableSetupColumn("Combat", ImGuiTableColumnFlags.WidthFixed, 70) end
    if M.options.show_casting then imgui.TableSetupColumn("Casting", ImGuiTableColumnFlags.WidthFixed, 100) end
    if M.options.show_group then imgui.TableSetupColumn("Group", ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 45) end
    imgui.TableHeadersRow()

    local current_drawn_class = nil

    for _, peer in ipairs(M.peer_list) do
        if M.options.sort_mode == "Class" and (peer.class or "Unknown") ~= current_drawn_class then
            current_drawn_class = peer.class or "Unknown"
            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.PushStyleColor(ImGuiCol.Text, ImVec4(1.0, 0.75, 0.3, 1.0))
            imgui.Text(current_drawn_class)
            imgui.PopStyleColor()
            for i = 2, column_count do
                imgui.TableNextColumn()
                imgui.Text("")
            end
        end

        if not peer then goto continue end

        if peer.type == "filler" then
            imgui.TableNextRow()
            imgui.TableNextColumn()
            local text = peer.filler_text or M.options.filler_char
            imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.4, 0.6, 0.9, 0.65))
            imgui.Text(text)
            imgui.PopStyleColor()
            for i = 2, column_count do
                imgui.TableNextColumn()
                imgui.Text("")
            end
            goto continue
        end

        imgui.TableNextRow()

        if first_column_is_name_or_class then
            imgui.TableNextColumn()
            local isSelf = (peer.name == MyName and peer.server == MyServer)
            local zoneColor = peer.inSameZone and ImVec4(0.8, 1, 0.8, 1) or ImVec4(1, 0.7, 0.7, 1)
            if isSelf then zoneColor = ImVec4(1, 1, 0.7, 1) end
            imgui.PushStyleColor(ImGuiCol.Text, zoneColor)

            local displayValue = peer.name
            if M.options.sort_mode ~= "Class" and M.options.use_class then
                displayValue = peer.class or "Unknown"
            end
            local uniqueLabel = string.format("%s##%s_peer", displayValue, peer.id)

            if imgui.Selectable(uniqueLabel, false, ImGuiSelectableFlags.SpanAllColumns) then
                if not isSelf then switchTo(peer.name) end
            end
            imgui.PopStyleColor()

            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text("Name : %s", peer.name)
                imgui.Text("Class: %s", peer.class or "Unknown")
                imgui.Text("Zone: %s", peer.zone or "Unknown")
                if not isSelf then
                    imgui.Text("Left-click : Switch to %s", peer.name)
                    imgui.Text("Right-click: Target %s", peer.name)
                end
                imgui.EndTooltip()
            end
            if imgui.BeginPopupContextItem(string.format("##PeerContext_%s", peer.id)) then
                imgui.Text(peer.name)
                imgui.Separator()

                if isSelf then
                    if imgui.MenuItem("Follow Me") then
                        mq.cmd('/aca /target id ${Me.ID}')
                        mq.cmd('/aca /afollow on')
                    end

                    if imgui.MenuItem("Follow Off") then
                        mq.cmd('/aca /afollow off')
                    end

                    imgui.Separator()

                    if imgui.MenuItem("Come to Me") then
                        mq.cmdf('/aca /nav spawn %s', peer.name)
                    end

                    if imgui.MenuItem("Stop Navigation") then
                        mq.cmd('/aca /nav stop')
                    end

                    imgui.Separator()

                    if imgui.MenuItem("Camp Here") then
                        mq.cmd('/acaa /makecamp on')
                    end

                    if imgui.MenuItem("Camp Off") then
                        mq.cmd('/acaa /makecamp off')
                    end

                    imgui.Separator()

                    if imgui.MenuItem("Pause All") then
                        mq.cmd('/acaa /mqpause on')
                    end

                    if imgui.MenuItem("Unpause All") then
                        mq.cmd('/acaa /mqpause off')
                    end
                else
                    if imgui.MenuItem("Target") then
                        targetCharacter(peer.name)
                    end

                    imgui.Separator()

                    if imgui.MenuItem("Invite to Group") then
                        mq.cmdf('/invite %s', peer.name)
                    end

                    if imgui.MenuItem("Invite to Raid") then
                        mq.cmdf('/raidinvite %s', peer.name)
                    end

                    imgui.Separator()

                    if imgui.MenuItem("Set as Main Assist") then
                        mq.cmdf('/grouproles set %s 2', peer.name)
                    end

                    if imgui.MenuItem("Set as Main Tank") then
                        mq.cmdf('/grouproles set %s 1', peer.name)
                    end

                    if imgui.MenuItem("Set as Puller") then
                        mq.cmdf('/grouproles set %s 3', peer.name)
                    end

                    if imgui.MenuItem("Remove Group Role") then
                        mq.cmdf('/grouproles unset %s', peer.name)
                    end
                end
                imgui.EndPopup()
            end
        end

        -- HP Column
        if M.options.show_hp then
            imgui.TableNextColumn()
            local hpColor = getHealthColor(peer.hp)
            imgui.PushStyleColor(ImGuiCol.Text, hpColor)
            imgui.Text("%.0f%%", peer.hp or 0)
            imgui.PopStyleColor()
        end

        -- Endurance Column
        if M.options.show_endurance then
            imgui.TableNextColumn()
            local usesEndurance = enduranceUsers:contains(peer.class)
            local enduranceColor = getEnduranceColor(usesEndurance and peer.endurance or 999)
            imgui.PushStyleColor(ImGuiCol.Text, enduranceColor)
            if usesEndurance then
                imgui.Text("%.0f%%", peer.endurance or 0)
            else
                imgui.Text("")
            end
            imgui.PopStyleColor()
        end

        -- Mana Column
        if M.options.show_mana then
            imgui.TableNextColumn()
            local usesMana = manaUsers:contains(peer.class)
            local manaColor = getManaColor(usesMana and peer.mana or 999)
            imgui.PushStyleColor(ImGuiCol.Text, manaColor)
            if usesMana then
                imgui.Text("%.0f%%", peer.mana or 0)
            else
                imgui.Text("")
            end
            imgui.PopStyleColor()
        end

        -- PetHP Column
        if M.options.show_pethp then
            imgui.TableNextColumn()
            local petClass = petClasses:contains(peer.class)
            local hpColor = (peer.pethp or 0) > 0 and getHealthColor(peer.pethp) or ImVec4(0.7, 0.7, 0.7, 1)
            imgui.PushStyleColor(ImGuiCol.Text, hpColor)
            if petClass then
                imgui.Text("%.0f%%", peer.pethp or 0)
            else
                imgui.Text("")
            end
            imgui.PopStyleColor()
        end

        -- Distance Column
        if M.options.show_distance then
            imgui.TableNextColumn()
            local distance = peer.distance or 0
            local distText = "N/A"
            local distColor = ImVec4(0.7, 0.7, 0.7, 1)
            if not peer.inSameZone then
                distText = "MIA"; distColor = ImVec4(1, 0.6, 0.6, 1)
            elseif distance >= 9999 then
                distText = "???"; distColor = ImVec4(1, 1, 0.6, 1)
            else
                distText = string.format("%.0f", distance)
                if distance < 20 then
                    distColor = ImVec4(0.6, 1, 0.6, 1)
                elseif distance < 100 then
                    distColor = ImVec4(0.8, 1, 0.8, 1)
                elseif distance < 175 then
                    distColor = ImVec4(1, 0.8, 0.6, 1)
                else
                    distColor = ImVec4(1, 0.6, 0.6, 1)
                end
            end
            imgui.PushStyleColor(ImGuiCol.Text, distColor)
            imgui.Text(distText)
            imgui.PopStyleColor()
        end

        -- Target Column
        if M.options.show_target then
            imgui.TableNextColumn()
            local targetColor
            if M.options.show_combat then
                targetColor = (peer.target == "None") and ImVec4(0.7, 0.7, 0.7, 1) or ImVec4(1, 1, 1, 1)
            else
                if peer.combat_state then
                    targetColor = ImVec4(1, 0, 0, 1)
                else
                    targetColor = (peer.target == "None") and ImVec4(0.7, 0.7, 0.7, 1) or ImVec4(1, 1, 1, 1)
                end
            end
            imgui.PushStyleColor(ImGuiCol.Text, targetColor)
            imgui.Text(peer.target or "None")
            imgui.PopStyleColor()
        end

        -- Combat State Column
        if M.options.show_combat then
            imgui.TableNextColumn()
            local peerCombat = peer.combat_state
            local combatText = peerCombat and "Fighting" or "Idle"
            local combatColor = peerCombat and ImVec4(1, 0.7, 0.7, 1) or ImVec4(1, 1, 0.7, 1)
            imgui.PushStyleColor(ImGuiCol.Text, combatColor)
            imgui.Text(combatText)
            imgui.PopStyleColor()
        end

        -- Casting Column
        if M.options.show_casting then
            imgui.TableNextColumn()
            local castingColor = (peer.casting == "None" or peer.casting == "") and ImVec4(0.7, 0.7, 0.7, 1) or ImVec4(0.8, 0.8, 1, 1)
            imgui.PushStyleColor(ImGuiCol.Text, castingColor)
            imgui.Text(peer.casting or "None")
            imgui.PopStyleColor()
        end

        -- Group Status Column
        if M.options.show_group then
            imgui.TableNextColumn()
            local statusText = peer.group_status
            local statusColor = statusText == "X" and ImVec4(1, 0.7, 0.7, 1) or ImVec4(0.8, 0.8, 1, 1)
            imgui.PushStyleColor(ImGuiCol.Text, statusColor)
            imgui.Text(statusText)
            imgui.PopStyleColor()
        end
        ::continue::
    end
    imgui.EndTable()
end

-- Enhanced AA Window with number formatting (NEW)
function M.draw_aa_window()
    if not M.show_aa_window.value then return end

    local window_open = M.show_aa_window.value
    imgui.SetNextWindowSize(ImVec2(400, 500), ImGuiCond.FirstUseEver)
    if imgui.Begin("Peer AA Totals", window_open, bit32.bor(ImGuiWindowFlags.NoCollapse)) then
        -- Header with close button and peer count
        if imgui.Button("Close") then
            M.show_aa_window.value = false
        end
        imgui.SameLine()
        imgui.TextDisabled("(" .. #M.peer_list .. " peers)")
        imgui.Separator()

        -- Sort peers alphabetically by name
        local aa_list = {}
        for _, p in ipairs(M.peer_list) do table.insert(aa_list, p) end
        table.sort(aa_list, function(a, b)
            local name_a = (a.name or "Unknown"):lower()
            local name_b = (b.name or "Unknown"):lower()
            return name_a < name_b
        end)

        local total_aa = 0
        for _, peer in ipairs(aa_list) do
            total_aa = total_aa + (peer.aa or 0)
        end
        local avg_aa = math.floor(total_aa / math.max(1, #aa_list))

        -- Stats header
        imgui.Text("Total AA: " .. formatNumberWithCommas(total_aa))
        imgui.Text("Average AA: " .. formatNumberWithCommas(avg_aa))
        imgui.Separator()

        local row_height = imgui.GetTextLineHeightWithSpacing()
        local max_rows = #aa_list
        local table_height = math.min(max_rows * row_height + 20, 400)

        -- Begin clean table with 3 columns
        local tableFlags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.ScrollY,
            ImGuiTableFlags.SizingFixedFit
        )
        if imgui.BeginTable("PeerAATable", 3, tableFlags, ImVec2(0, table_height)) then
            imgui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn("AA Points", ImGuiTableColumnFlags.WidthFixed, 90)
            imgui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed, 60) -- Empty header for suffix
            imgui.TableHeadersRow()

            for _, peer in ipairs(aa_list) do
                imgui.TableNextRow()
                local aa_val = peer.aa or 0
                local isSelf = (peer.name == MyName and peer.server == MyServer)

                -- Name Column
                imgui.TableNextColumn()
                if isSelf then
                    imgui.PushStyleColor(ImGuiCol.Text, ImVec4(1, 1, 0.7, 1))
                end
                imgui.Text(peer.name or "Unknown")
                if isSelf then
                    imgui.PopStyleColor()
                end

                -- AA Points Column
                imgui.TableNextColumn()
                local aa_text = formatNumberWithCommas(aa_val)
                local text_width = imgui.CalcTextSize(aa_text)
                local cell_width = imgui.GetColumnWidth()
                imgui.SetCursorPosX(imgui.GetCursorPosX() + (cell_width - text_width - imgui.GetStyle().ItemSpacing.x) / 2)
                imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.7, 0.9, 1.0, 1.0)) -- Light blue
                imgui.Text(aa_text)
                imgui.PopStyleColor()

                -- Suffix Column
                imgui.TableNextColumn()
                local suffix = ""
                if aa_val >= 1000000 then
                    suffix = string.format("(%.1fM)", aa_val / 1000000)
                elseif aa_val >= 1000 then
                    suffix = string.format("(%.1fK)", aa_val / 1000)
                end
                if suffix ~= "" then
                    imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.3, 1.0, 0.3, 1.0)) -- Green
                    imgui.Text(suffix)
                    imgui.PopStyleColor()
                end
            end
            imgui.EndTable()
        end
    end
    imgui.End()

    if not window_open then
        M.show_aa_window.value = false
    end
end

function M.draw_sort_editor()
    if not M.show_sort_editor or not M.show_sort_editor.value then return end
    M.options.custom_order = M.options.custom_order or {}
    local window_open = M.show_sort_editor.value
    imgui.SetNextWindowSize(ImVec2(300, 400), ImGuiCond.FirstUseEver)

    if imgui.Begin("Edit Peer Sort Order", window_open, ImGuiWindowFlags.NoCollapse) then
        imgui.Text("Custom Sort Order:")
        imgui.Separator()

        imgui.Columns(2, nil, false) -- 2 columns: Label + Buttons
        imgui.SetColumnWidth(0, 180)

        for i, entry in ipairs(M.options.custom_order) do
            imgui.PushID(i)
            if entry.type == "filler" then
                entry.filler_text = entry.filler_text or M.options.filler_char
                local new_text, changed = imgui.InputText("##fillertext_" .. i, entry.filler_text)
                if changed then
                    entry.filler_text = new_text
                end
            else
                imgui.Text(M.peers[entry.id] and M.peers[entry.id].name or entry.id)
            end
            imgui.NextColumn()
            local buttonSize = ImVec2(36, 0)

            -- Second column: buttons
            imgui.PushStyleVar(ImGuiStyleVar.FramePadding, ImVec2(3, 2)) -- More readable padding

            if imgui.SmallButton("^", buttonSize) and i > 1 then
                M.options.custom_order[i], M.options.custom_order[i - 1] = M.options.custom_order[i - 1], M.options.custom_order[i]
            end
            imgui.SameLine()
            if imgui.SmallButton("v", buttonSize) and i < #M.options.custom_order then
                M.options.custom_order[i], M.options.custom_order[i + 1] = M.options.custom_order[i + 1], M.options.custom_order[i]
            end
            imgui.SameLine()
            if imgui.SmallButton("X", buttonSize) then
                table.remove(M.options.custom_order, i)
                imgui.PopStyleVar()
                imgui.PopID()
                imgui.NextColumn()
                goto continue
            end

            imgui.PopStyleVar()
            imgui.NextColumn()
            imgui.PopID()
            ::continue::
        end

        imgui.Columns(1) -- back to single-column layout

        local new_filler, changed = imgui.InputText("Filler Characters", M.options.filler_char)
        if changed then
            M.options.filler_char = new_filler
        end

        imgui.Separator()
        imgui.Text("Add Peer/Filler Row:")

        for id, peer in pairs(M.peers) do
            local in_order = false
            for _, entry in ipairs(M.options.custom_order) do
                if entry.id == id then
                    in_order = true
                    break
                end
            end
            if not in_order then
                imgui.PushID(id)
                if imgui.SmallButton(peer.name) then
                    table.insert(M.options.custom_order, { id = id, })
                end
                imgui.PopID()
                imgui.SameLine()
            end
        end

        if imgui.SmallButton("+ Add Filler Row") then
            table.insert(M.options.custom_order, {
                type = "filler",
                filler_text = M.options.filler_char,
            })
        end

        imgui.Separator()
        if imgui.Button("Save") then
            M.save_config()
            M.show_sort_editor.value = false
            M.options.sort_mode = "Custom"
        end
        imgui.SameLine()
        if imgui.Button("Cancel") then
            M.show_sort_editor.value = false
        end

        imgui.End()
    end
end

function M.load_config()
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local parsed = json.decode(content)
        if parsed and parsed[myName] then
            for k, v in pairs(parsed[myName]) do
                M.options[k] = v
            end
        end
    end
end

function M.save_config()
    local all_config = {}
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        all_config = json.decode(content) or {}
    end

    all_config[myName] = M.options

    file = io.open(config_path, "w")
    if file then
        file:write(json.encode(all_config, { indent = true, }))
        file:close()
        print(string.format("\ay[Peers] Saved UI config to %s\ax", config_path))
    else
        print(string.format("\ar[Peers] Failed to write UI config to %s\ax", config_path))
    end
end

-- Main update function for the peer module
function M.update()
    local now = elapsed()
    local isFG = mq.TLO.EverQuest.Foreground() == true

    -- pick the interval based on focus
    local targetInterval = isFG and FG_REFRESH_MS or BG_REFRESH_MS

    if now - lastRefreshTime >= targetInterval then
        refreshPeers() -- your heavy work (publish, UI updates, etc.)
        lastRefreshTime = now
    end
    publishHealthStatus() -- Publish own status periodically
    refreshPeers()        -- Refresh peer list, distances, and sorting
end

mq.bind("/savepeerui", function()
    M.save_config()
end)

-- Initialization function
function M.init()
    print("[Peers] Initializing...")
    MyName = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
    MyServer = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown")
    if MyName == "Unknown" or MyServer == "Unknown" then
        print('\ar[Peers] Failed to get character name or server.\ax')
        return
    end
    M.load_config()
    actor_mailbox = actors.register('peer_status', peer_message_handler)
    if not actor_mailbox then
        print('\ar[Peers] Failed to register actor mailbox "peer_status".\ax')
        return
    end
    print("[Peers] Actor mailbox registered successfully.")

    lastAACheckTime = os.time()
    refreshPeers()
    print("[Peers] Initialization complete.")
end

-- Getters for main UI
function M.get_peer_data()
    return {
        list = M.peer_list,
        count = #M.peer_list,
        my_aa = getActualAAPoints(), -- Use enhanced AA function (CHANGED)
        cached_height = cachedPeerHeight,
    }
end

function M.get_refresh_interval()
    return REFRESH_INTERVAL_MS
end

-- Make formatNumberWithCommas available for external use (NEW)
M.formatNumberWithCommas = formatNumberWithCommas

return M
