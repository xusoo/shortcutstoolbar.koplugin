--[[
 Reader Toolbar Plugin for KOReader
=======================================
Adds a home panel to the reader menu (shown when no tab is selected) with:
  • Book cover, title, author and reading progress (left)
  • Current time and battery level (top-right)
  • Quick-access icon shortcuts (bottom-right)
  • "Back to library" button (bottom-left)

Configuration
-------------
Edit the constants below to customise the shortcuts bar.

Available shortcut keys:
  font, frontlight, wifi, bookmarks, toc, search, skim, page_browser, book_status, time, battery, spacer
--]]

-- ==========================================================================
-- Configuration
-- ==========================================================================

-- Comma-separated list of shortcuts shown in the bar (right side, bottom row).
local MENUBAR_ITEMS = "font,frontlight,wifi,bookmarks,toc,search"
-- Horizontal padding (px, before scaling) between icon buttons.
local ITEM_SPACING  = 8

-- ==========================================================================
-- Helpers
-- ==========================================================================

local TouchMenu       = require("ui/widget/touchmenu")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")

local createHomeContent = require("home_content")

-- ==========================================================================
-- Settings
-- ==========================================================================

-- Module-level config table. All three TouchMenu patches close over this by
-- reference, so changes in the settings-menu callbacks take effect immediately.
local config = {}

local function readConfig()
    config.enabled               = G_reader_settings:nilOrTrue("readertoolbar_enabled")
    config.items                 = G_reader_settings:readSetting("readertoolbar_items") or MENUBAR_ITEMS
    config.spacing               = ITEM_SPACING
    config.show_time_and_battery = G_reader_settings:nilOrTrue("readertoolbar_show_time_battery")
    config.show_book_info        = G_reader_settings:nilOrTrue("readertoolbar_show_book_info")
    config.show_back_button      = G_reader_settings:nilOrTrue("readertoolbar_show_back_button")
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
        },
    }
end

return ReaderToolbar
