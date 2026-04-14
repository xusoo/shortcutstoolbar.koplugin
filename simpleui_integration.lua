local logger = require("logger")

local M = {}

local MODULE_ID = "shortcutstoolbar"
local AFTER_MODULE_ID = "clock"

local function containsById(list, id)
    for _, item in ipairs(list) do
        if item and item.id == id then return true end
    end
    return false
end

local function containsValue(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function insertAfterModule(list, value, get_id)
    local insert_at = #list + 1
    for idx, item in ipairs(list) do
        local item_id = get_id and get_id(item) or item
        if item_id == AFTER_MODULE_ID then
            insert_at = idx + 1
            break
        end
    end
    table.insert(list, insert_at, value)
end

local function getModule()
    local ok, mod = pcall(require, "simpleui_module")
    if ok then return mod end
    logger.warn("shortcutstoolbar: failed to load SimpleUI module: " .. tostring(mod))
    return nil
end

function M.install()
    local ok, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok or not Registry then return false end
    if Registry._shortcutstoolbar_patched then return true end

    local orig_list = Registry.list
    local orig_get = Registry.get
    local orig_defaultOrder = Registry.defaultOrder

    Registry.list = function(...)
        local list = orig_list(...)
        local mod = getModule()
        if mod and not containsById(list, mod.id) then
            insertAfterModule(list, mod, function(item) return item and item.id end)
        end
        return list
    end

    Registry.get = function(id, ...)
        if id == MODULE_ID then
            local mod = getModule()
            if mod then return mod end
        end
        return orig_get(id, ...)
    end

    Registry.defaultOrder = function(...)
        local order = orig_defaultOrder(...)
        local mod = getModule()
        if mod and not containsValue(order, mod.id) then
            insertAfterModule(order, mod.id)
        end
        return order
    end

    Registry._shortcutstoolbar_patched = true
    return true
end

return M