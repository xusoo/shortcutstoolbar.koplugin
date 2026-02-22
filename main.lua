--[[
 Reader Toolbar Plugin for KOReader
=======================================
Adds a home panel to the reader menu (shown when no tab is selected) with:
  • Book cover, title, author and reading progress (left)
  • Current time and battery level (top-right)
  • Quick-access icon shortcuts (bottom-right)
  • "Back to library" button (bottom-left)

All options are configurable from the menu:
  Tools → Reader Toolbar
--]]

local _ = require("gettext")
local T = require("ffi/util").template

-- ==========================================================================
-- Configuration
-- ==========================================================================

-- Horizontal padding (px, before scaling) between icon buttons.
local ITEM_SPACING = 8

-- Single source of truth for all available shortcuts (key, label, icon, default).
local SHORTCUT_ITEMS = require("shortcuts_data")

-- ==========================================================================
-- Helpers
-- ==========================================================================

local TouchMenu       = require("ui/widget/touchmenu")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox      = require("ui/widget/confirmbox")
local SpinWidget      = require("ui/widget/spinwidget")

local createHomeContent = require("home_content")

-- ==========================================================================
-- Settings
-- ==========================================================================

-- Module-level config table. All three TouchMenu patches close over this by
-- reference, so changes in the settings-menu callbacks take effect immediately.
local config = {}

-- Returns whether a shortcut item is enabled, respecting its default value.
local function isShortcutEnabled(item)
    local setting = "readertoolbar_item_" .. item.key
    if item.default then
        return G_reader_settings:nilOrTrue(setting)
    else
        return G_reader_settings:isTrue(setting)
    end
end

local function readConfig()
    config.enabled               = G_reader_settings:nilOrTrue("readertoolbar_enabled")
    config.spacing               = ITEM_SPACING
    config.show_time_and_battery = G_reader_settings:nilOrTrue("readertoolbar_show_time_battery")
    config.show_book_info        = G_reader_settings:nilOrTrue("readertoolbar_show_book_info")
    config.show_back_button      = G_reader_settings:nilOrTrue("readertoolbar_show_back_button")
    local icon_size_raw = G_reader_settings:readSetting("readertoolbar_icon_size")
    config.icon_size = tonumber(icon_size_raw) or 26
    -- Build the active items list, respecting the user's saved ordering.
    -- readertoolbar_item_order is a CSV of ALL keys (enabled + disabled) in preferred order.
    local saved_order = G_reader_settings:readSetting("readertoolbar_item_order")
    local order_pos   = {}
    if saved_order then
        local pos = 1
        for key in saved_order:gmatch("([^,]+)") do
            order_pos[key] = pos
            pos = pos + 1
        end
    end
    -- Sort SHORTCUT_ITEMS by saved position; unseen items keep their original order at the end.
    local sorted = {}
    for i, item in ipairs(SHORTCUT_ITEMS) do
        table.insert(sorted, { item = item, sort_key = order_pos[item.key] or (1000 + i) })
    end
    table.sort(sorted, function(a, b) return a.sort_key < b.sort_key end)
    local active = {}
    for _, entry in ipairs(sorted) do
        if isShortcutEnabled(entry.item) then
            table.insert(active, entry.item.key)
        end
    end
    config.items = table.concat(active, ",")
end

-- Identifies whether a TouchMenu instance belongs to the reader (not the
-- file manager or any other context).
local function isReaderMenu(menu)
    local ReaderUI = require("apps/reader/readerui")
    if not (ReaderUI.instance and not ReaderUI.instance.tearing_down) then
        return false
    end
    if not menu.tab_item_table then return false end
    for _, tab in ipairs(menu.tab_item_table) do
        if tab.icon == "appbar.navigation" or tab.icon == "appbar.typeset" then
            return true
        end
    end
    return false
end

-- Collapses the menu back to the home state (bar only + home content).
local function resetToHomeState(menu, config)
    if not isReaderMenu(menu) then return end

    -- Rebuild item_group with only the tab bar
    if menu.item_group then
        menu.item_group:clear()
        table.insert(menu.item_group, menu.bar)
    end

    -- Clear tab highlight
    if menu.bar then
        if menu.bar.icon_widgets then
            for _, w in ipairs(menu.bar.icon_widgets) do
                w.invert = false
                w.state  = "normal"
            end
        end
        if menu.bar.bar_sep   then menu.bar.bar_sep.empty_segments = nil end
        if menu.bar.icon_seps then
            for _, sep in ipairs(menu.bar.icon_seps) do sep.style = "none" end
        end
        UIManager:setDirty(menu.bar, "ui")
    end

    -- Reset menu state
    menu.cur_tab         = nil
    menu.page            = 1
    menu.item_table      = {}
    menu.item_table_stack = {}

    -- Recalculate dimensions after clearing
    if menu.item_group then
        menu.item_group:resetLayout()
        local sz = menu.item_group:getSize()
        if menu.dimen then
            menu.dimen.h = sz.h + menu.bordersize * 2 + menu.padding
        end
    end

    -- Inject the home content panel
    local ok, home = pcall(createHomeContent, menu, config)
    if ok and home and menu.item_group then
        table.insert(menu.item_group, 2, home)
        menu.item_group:resetLayout()
        local sz = menu.item_group:getSize()
        if menu.dimen then
            menu.dimen.h = sz.h + menu.bordersize * 2 + menu.padding
        end
    end

    UIManager:setDirty("all", "ui")
end

-- ==========================================================================
-- Plugin
-- ==========================================================================

local ReaderToolbar = WidgetContainer:extend{
    name        = "readertoolbar",
    is_doc_only = false,
}

function ReaderToolbar:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Guard against double-patching if the plugin is somehow re-initialised.
    if TouchMenu._readertoolbar_patched then return end
    TouchMenu._readertoolbar_patched = true

    readConfig()

    -- DEV: auto-open the configure dialog on startup for quick iteration.
    UIManager:scheduleIn(0, function()
        local ShortcutsConfigDialog = require("shortcuts_config")
        local enabled_keys, in_enabled, disabled_keys = {}, {}, {}
        for key in (config.items or ""):gmatch("([^,]+)") do
            table.insert(enabled_keys, key)
            in_enabled[key] = true
        end
        for _, item in ipairs(SHORTCUT_ITEMS) do
            if not in_enabled[item.key] then
                table.insert(disabled_keys, item.key)
            end
        end
        UIManager:show(ShortcutsConfigDialog:new{
            enabled_keys  = enabled_keys,
            disabled_keys = disabled_keys,
            on_save       = function(new_enabled, new_disabled)
                local is_enabled = {}
                for _, k in ipairs(new_enabled) do is_enabled[k] = true end
                for _, item in ipairs(SHORTCUT_ITEMS) do
                    G_reader_settings:saveSetting(
                        "readertoolbar_item_" .. item.key,
                        is_enabled[item.key] and true or false)
                end
                local full_order = {}
                for _, k in ipairs(new_enabled)  do table.insert(full_order, k) end
                for _, k in ipairs(new_disabled) do table.insert(full_order, k) end
                G_reader_settings:saveSetting("readertoolbar_item_order",
                    table.concat(full_order, ","))
                readConfig()
            end,
        })
    end)

    -- Patch 1: start every reader menu in the home (closed) state.
    local orig_init = TouchMenu.init
    TouchMenu.init = function(self_menu, ...)
        orig_init(self_menu, ...)
        if config.enabled then resetToHomeState(self_menu, config) end
    end

    -- Patch 2: tap an already-active tab to collapse back to home.
    local orig_switchTab = TouchMenu.switchMenuTab
    TouchMenu.switchMenuTab = function(self_menu, tab_num)
        if self_menu.cur_tab == tab_num and isReaderMenu(self_menu) and config.enabled then
            resetToHomeState(self_menu, config)
            return
        end
        return orig_switchTab(self_menu, tab_num)
    end

    -- Patch 3: after updateItems re-renders, re-inject the home panel when
    -- no tab is selected (home state).
    local orig_updateItems = TouchMenu.updateItems
    TouchMenu.updateItems = function(self_menu, target_page, target_item_id)
        orig_updateItems(self_menu, target_page, target_item_id)
        if not config.enabled or not isReaderMenu(self_menu) or self_menu.cur_tab then return end

        -- Only inject if the home panel isn't already present.
        if not self_menu.item_group then return end
        for _, widget in ipairs(self_menu.item_group) do
            if widget and widget.is_shortcuts_bar then return end
        end

        local ok, home = pcall(createHomeContent, self_menu, config)
        if ok and home and #self_menu.item_group >= 1 then
            table.insert(self_menu.item_group, 2, home)
            self_menu.item_group:resetLayout()
            local sz = self_menu.item_group:getSize()
            if self_menu.dimen then
                self_menu.dimen.h = sz.h + self_menu.bordersize * 2 + self_menu.padding
            end
        end
    end
end

function ReaderToolbar:addToMainMenu(menu_items)
    menu_items.readertoolbar = {
        text         = _("Reader toolbar"),
        sorting_hint = "setting",
        sub_item_table = {
            {
                text         = _("Enable toolbar"),
                checked_func = function() return config.enabled end,
                callback     = function()
                    config.enabled = not config.enabled
                    G_reader_settings:saveSetting("readertoolbar_enabled", config.enabled)
                end,
                separator = true,
            },
            {
                text         = _("Show book info"),
                checked_func = function() return config.show_book_info end,
                enabled_func = function() return config.enabled end,
                callback     = function()
                    config.show_book_info = not config.show_book_info
                    G_reader_settings:saveSetting("readertoolbar_show_book_info", config.show_book_info)
                end,
            },
            {
                text         = _("Show time and battery"),
                checked_func = function() return config.show_time_and_battery end,
                enabled_func = function() return config.enabled end,
                callback     = function()
                    config.show_time_and_battery = not config.show_time_and_battery
                    G_reader_settings:saveSetting("readertoolbar_show_time_battery", config.show_time_and_battery)
                end,
            },
            {
                text         = _("Show back button"),
                checked_func = function() return config.show_back_button end,
                enabled_func = function() return config.enabled end,
                callback     = function()
                    config.show_back_button = not config.show_back_button
                    G_reader_settings:saveSetting("readertoolbar_show_back_button", config.show_back_button)
                end,
            },
            {
                text_func    = function()
                    return T(_("Icon size: %1"), config.icon_size)
                end,
                enabled_func = function() return config.enabled end,
                keep_menu_open = true,
                callback     = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Icon size"),
                        value         = config.icon_size,
                        value_min     = 14,
                        value_max     = 48,
                        value_step    = 2,
                        default_value = 26,
                        callback      = function(spin)
                            config.icon_size = spin.value
                            G_reader_settings:saveSetting("readertoolbar_icon_size", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text         = _("Configure shortcuts"),
                separator    = true,
                enabled_func = function() return config.enabled end,
                callback     = function()
                    local ShortcutsConfigDialog = require("shortcuts_config")
                    -- Build enabled_keys from current active order and
                    -- disabled_keys from all items not currently active.
                    local enabled_keys = {}
                    local in_enabled   = {}
                    for key in (config.items or ""):gmatch("([^,]+)") do
                        table.insert(enabled_keys, key)
                        in_enabled[key] = true
                    end
                    -- Disabled list: follow SHORTCUT_ITEMS order, exclude enabled items.
                    local disabled_keys = {}
                    for _, item in ipairs(SHORTCUT_ITEMS) do
                        if not in_enabled[item.key] then
                            table.insert(disabled_keys, item.key)
                        end
                    end
                    UIManager:show(ShortcutsConfigDialog:new{
                        enabled_keys  = enabled_keys,
                        disabled_keys = disabled_keys,
                        on_save       = function(new_enabled, new_disabled)
                            -- Persist enabled/disabled state per item.
                            local is_enabled = {}
                            for _, k in ipairs(new_enabled) do is_enabled[k] = true end
                            for _, item in ipairs(SHORTCUT_ITEMS) do
                                G_reader_settings:saveSetting(
                                    "readertoolbar_item_" .. item.key,
                                    is_enabled[item.key] and true or false)
                            end
                            -- Persist full order: enabled first, then disabled.
                            local full_order = {}
                            for _, k in ipairs(new_enabled)  do table.insert(full_order, k) end
                            for _, k in ipairs(new_disabled) do table.insert(full_order, k) end
                            G_reader_settings:saveSetting("readertoolbar_item_order",
                                table.concat(full_order, ","))
                            readConfig()
                        end,
                    })
                end,
            },
            {
                text      = _("Reset settings"),
                callback  = function()
                    UIManager:show(ConfirmBox:new{
                        text    = _("Reset all Reader Toolbar settings to defaults?"),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            local keys_to_del = {
                                "readertoolbar_enabled",
                                "readertoolbar_show_book_info",
                                "readertoolbar_show_time_battery",
                                "readertoolbar_show_back_button",
                                "readertoolbar_icon_size",
                                "readertoolbar_item_order",
                            }
                            for _, item in ipairs(SHORTCUT_ITEMS) do
                                table.insert(keys_to_del, "readertoolbar_item_" .. item.key)
                            end
                            for _, key in ipairs(keys_to_del) do
                                G_reader_settings:delSetting(key)
                            end
                            readConfig()
                        end,
                    })
                end,
            },
        },
    }
end

return ReaderToolbar
