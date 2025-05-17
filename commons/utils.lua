-- utils.lua
-- Shared utility functions

local utils = {}

-- Safely access TLO members, returning a default value if nil
function utils.safeTLO(fn, default)
    local status, result = pcall(fn)
    if status and result ~= nil then
        return result
    else
        return default
    end
end

-- Format numbers with suffixes (k, m, b)
function utils.cleanNumber(num, precision, percAlways)
    if num == nil then return "0" end
    precision = precision or 0
    percAlways = percAlways or false
    local label = ""
    local floatNum = 0

    if num >= 1000000000 then
        floatNum = num / 1000000000 -- Corrected divisor for billion
        label = string.format("%." .. precision .. "f b", floatNum)
    elseif num >= 1000000 then
        floatNum = num / 1000000
        label = string.format("%." .. precision .. "f m", floatNum)
    elseif num >= 1000 then
        floatNum = num / 1000
        label = string.format("%." .. precision .. "f k", floatNum)
    else
        if not percAlways then
            label = string.format("%.0f", num)
        else
            label = string.format("%." .. precision .. "f", num)
        end
    end
    return label
end


-- Deep copy utility (simple version, may not handle all cases like metatables perfectly)
function utils.deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[utils.deepcopy(orig_key)] = utils.deepcopy(orig_value)
        end
        setmetatable(copy, utils.deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end


return utils