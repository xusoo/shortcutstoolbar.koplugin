local UIManager = require("ui/uimanager")
local SHORTCUT_ITEMS = require("shortcuts_data")

local M = {}

local function getManager()
    return require("custom_shortcut_manager")
end

local function getDefaults(view, options)
    if options and options.default_items then
        return options.default_items
    end
    if view == "reader" then
        return SHORTCUT_ITEMS.reader_defaults
    end
    return SHORTCUT_ITEMS.fb_defaults
end

function M.isReaderView(view)
    return view == "reader"
end

function M.isFileBrowserView(view)
    return view == "fb"
end

function M.settingsKey(view)
    return "shortcutstoolbar_" .. view
end

function M.readConfig(view, options)
    local stored = G_reader_settings:readSetting(M.settingsKey(view)) or {}
    local result = {
        view = view,
        spacing = SHORTCUT_ITEMS.ITEM_SPACING,
        enabled = stored.enabled ~= false,
        icon_size = stored.icon_size or (options and options.default_icon_size) or 26,
    }

    if view == "reader" then
        result.show_book_info = stored.show_book_info ~= false
        result.show_time_and_battery = stored.show_time_and_battery ~= false
        result.show_back_button = stored.show_back_button ~= false
    elseif view == "fb" then
        result.placement = stored.placement or "persistent"
        result.align = "center"
    end

    local order_pos = {}
    if stored.item_order then
        local pos = 1
        for key in stored.item_order:gmatch("([^,]+)") do
            order_pos[key] = pos
            pos = pos + 1
        end
    end

    local defaults_list = getDefaults(view, options)
    local defaults_pos = {}
    for pos, key in ipairs(defaults_list) do
        defaults_pos[key] = pos
    end

    local all_items = M.getAllItems(view, options)
    local sorted = {}
    for idx, item in ipairs(all_items) do
        sorted[#sorted + 1] = {
            item = item,
            sort_key = order_pos[item.key] or defaults_pos[item.key] or (1000 + idx),
        }
    end
    table.sort(sorted, function(a, b) return a.sort_key < b.sort_key end)

    local active = {}
    for _, entry in ipairs(sorted) do
        local item = entry.item
        local item_cfg = stored.items and stored.items[item.key]
        local item_enabled
        if item_cfg ~= nil then
            item_enabled = item_cfg
        else
            item_enabled = defaults_pos[item.key] ~= nil
        end
        if item_enabled then active[#active + 1] = item.key end
    end
    result.items = table.concat(active, ",")
    return result
end

function M.saveConfig(view, cfg)
    local stored = G_reader_settings:readSetting(M.settingsKey(view)) or {}
    stored.enabled = cfg.enabled
    stored.icon_size = cfg.icon_size
    if view == "reader" then
        stored.show_book_info = cfg.show_book_info
        stored.show_time_and_battery = cfg.show_time_and_battery
        stored.show_back_button = cfg.show_back_button
    elseif view == "fb" then
        stored.placement = cfg.placement
    end
    G_reader_settings:saveSetting(M.settingsKey(view), stored)
end

function M.refreshInto(target, view, options)
    local cfg = M.readConfig(view, options)
    for key, value in pairs(cfg) do
        target[key] = value
    end
    return target
end

function M.getAllItems(view, options)
    local filter_view = options and options.item_filter_view or view
    local Manager = getManager()
    local all_items = {}
    for _, item in ipairs(SHORTCUT_ITEMS) do
        if not ((filter_view == "fb" and item.reader_only) or (filter_view == "reader" and item.fb_only)) then
            all_items[#all_items + 1] = item
        end
    end
    for _, item in ipairs(Manager.getShortcutDataItems(view)) do
        if not ((filter_view == "fb" and item.reader_only) or (filter_view == "reader" and item.fb_only)) then
            all_items[#all_items + 1] = item
        end
    end
    return all_items
end

function M.saveShortcutSelection(view, all_items, new_enabled, new_disabled)
    local stored = G_reader_settings:readSetting(M.settingsKey(view)) or {}
    local items_map = stored.items or {}
    for _, item in ipairs(all_items) do items_map[item.key] = false end
    for _, key in ipairs(new_enabled) do items_map[key] = true end
    stored.items = items_map

    local full_order = {}
    for _, key in ipairs(new_enabled) do full_order[#full_order + 1] = key end
    for _, key in ipairs(new_disabled) do full_order[#full_order + 1] = key end
    stored.item_order = table.concat(full_order, ",")
    G_reader_settings:saveSetting(M.settingsKey(view), stored)
end

function M.openShortcutsConfig(view, on_save_done, options)
    local cfg = M.readConfig(view, options)
    local ShortcutsConfigDialog = require("shortcuts_config")
    local enabled_keys, in_enabled, disabled_keys = {}, {}, {}

    for key in (cfg.items or ""):gmatch("([^,]+)") do
        enabled_keys[#enabled_keys + 1] = key
        in_enabled[key] = true
    end

    local all_items = M.getAllItems(view, options)
    for _, item in ipairs(all_items) do
        if not in_enabled[item.key] then
            disabled_keys[#disabled_keys + 1] = item.key
        end
    end

    UIManager:show(ShortcutsConfigDialog:new{
        enabled_keys = enabled_keys,
        disabled_keys = disabled_keys,
        view = view,
        on_save = function(new_enabled, new_disabled)
            M.saveShortcutSelection(view, all_items, new_enabled, new_disabled)
            if on_save_done then on_save_done() end
        end,
    })
end

return M