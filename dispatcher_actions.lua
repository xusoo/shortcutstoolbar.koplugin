local _ = require("gettext")

local M = {}

local function getDispatcherState()
    local ok_dispatcher, Dispatcher = pcall(require, "dispatcher")
    if not ok_dispatcher or not Dispatcher then
        return nil
    end

    pcall(function() Dispatcher:init() end)

    local settings_list, dispatcher_menu_order
    local fn_idx = 1
    while true do
        local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
        if not name then break end
        if name == "settingsList" then settings_list = val end
        if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
        fn_idx = fn_idx + 1
    end

    return Dispatcher, settings_list, dispatcher_menu_order
end

function M.list()
    local settings_list, dispatcher_menu_order = select(2, getDispatcherState())
    if type(settings_list) ~= "table" then return {} end

    local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
        or (function()
            local keys = {}
            for key in pairs(settings_list) do
                keys[#keys + 1] = key
            end
            table.sort(keys)
            return keys
        end)()

    local results = {}
    for _i, action_id in ipairs(order) do
        local def = settings_list[action_id]
        if type(def) == "table" and def.title and def.category == "none"
                and (def.condition == nil or def.condition == true) then
            results[#results + 1] = {
                id = action_id,
                title = tostring(def.title),
            }
        end
    end

    table.sort(results, function(a, b)
        return a.title:lower() < b.title:lower()
    end)
    return results
end

function M.execute(action_id)
    local ok_dispatcher, Dispatcher = pcall(require, "dispatcher")
    if not ok_dispatcher or not Dispatcher then
        return false, _("Dispatcher not available.")
    end

    local ok, err = pcall(function()
        Dispatcher:execute({ [action_id] = true })
    end)
    if not ok then
        return false, string.format(_("System action error: %s"), tostring(err))
    end

    return true
end

return M