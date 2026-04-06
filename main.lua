--[[
 Shortcuts Toolbar Plugin for KOReader
=======================================
Adds a home panel to both the reader and file-browser menus with:
  • Book cover, title, author and reading progress (left)
  • Current time and battery level (top-right)
  • Quick-access icon shortcuts (bottom-right)
  • "Back to library" button (bottom-left, reader only)

All options are configurable from the menu:
  Settings → Shortcuts toolbar
--]]

local _ = require("gettext")
local T = require("ffi/util").template

-- ==========================================================================
-- Helpers
-- ==========================================================================

local TouchMenu       = require("ui/widget/touchmenu")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox      = require("ui/widget/confirmbox")
local InfoMessage     = require("ui/widget/infomessage")
local SpinWidget      = require("ui/widget/spinwidget")
local Manager         = require("custom_shortcut_manager")
local ToolbarSettings = require("toolbar_settings")
local SimpleUIIntegration = require("simpleui_integration")

local HomeContent = require("home_content")

-- ==========================================================================
-- Settings
-- ==========================================================================

-- Per-view config tables (populated at first init, mutated in-place by settings
-- callbacks so all closures always see current values).
local reader_config = {}
local fb_config     = {}

local function syncFileBrowserPersistentBar()
    local PersistentBar = require("fb_persistent_bar")
    if fb_config.enabled and fb_config.placement == "persistent" then
        PersistentBar.inject(fb_config)
    else
        PersistentBar.remove()
    end
end

--- Refresh both in-place config tables from stored settings.
-- Call this after any change that may affect item lists (e.g. custom-shortcut
-- add/delete) so all closures remain in sync.
local function refreshAllConfigs()
    ToolbarSettings.refreshInto(reader_config, "reader")
    ToolbarSettings.refreshInto(fb_config, "fb")
    syncFileBrowserPersistentBar()
end

-- Identifies whether a TouchMenu instance belongs to the reader.
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

-- Identifies whether a TouchMenu instance belongs to the file manager.
local function isFileBrowserMenu(menu)
    local FileManager = require("apps/filemanager/filemanager")
    if not (FileManager.instance and not FileManager.instance.tearing_down) then
        return false
    end
    if not menu.tab_item_table then return false end
    for _, tab in ipairs(menu.tab_item_table) do
        -- Reader-specific tabs → not the file-manager menu.
        if tab.icon == "appbar.navigation" or tab.icon == "appbar.typeset" then
            return false
        end
    end
    for _, tab in ipairs(menu.tab_item_table) do
        if tab.icon == "appbar.filebrowser" then return true end
    end
    return false
end

--- Return the applicable config for a menu, or nil if it belongs to neither view.
local function menuConfig(menu)
    if isReaderMenu(menu)      then return reader_config end
    if isFileBrowserMenu(menu) then return fb_config     end
    return nil
end

-- Collapses the menu back to the home state (bar only + home content).
local function resetToHomeState(menu, cfg)
    if not isReaderMenu(menu) and not isFileBrowserMenu(menu) then return end

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
        if menu.bar.bar_sep   then menu.bar.bar_sep.empty_segments = nil; menu.bar.bar_sep.style = "none" end
        if menu.bar.icon_seps then
            for _, sep in ipairs(menu.bar.icon_seps) do sep.style = "none" end
        end
        UIManager:setDirty(menu.bar, "ui")
    end

    -- Reset menu state
    menu.cur_tab          = nil
    menu.page             = 1
    menu.item_table       = {}
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
    local ok, home = pcall(HomeContent.createHomeContent, menu, cfg, resetToHomeState)
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
-- Shortcuts config helper
-- ==========================================================================

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

    -- Ensure configs are populated before any logic that reads them.
    -- This may be the first init (populate) or a subsequent one (already set).
    if not reader_config.view then
        ToolbarSettings.refreshInto(reader_config, "reader")
        ToolbarSettings.refreshInto(fb_config, "fb")
    end

    -- Set up SimpleUI integration (if available) so that the shortcuts bar 
    -- can also be added as a module on the homescreen.
    SimpleUIIntegration.install()

    -- Re-inject the persistent bar every time a FileManager is initialized.
    -- NOTE: FileManager.instance is assigned *after* plugins are loaded, so we
    -- cannot check it here. inject() calls getFileChooser() internally, which
    -- returns nil when no FM is active, making this safe in all contexts.
    if fb_config.enabled and fb_config.placement == "persistent" then
        local PersistentBar = require("fb_persistent_bar")
        -- Schedule so FileManager finishes its layout before we inject.
        UIManager:scheduleIn(0, function()
            PersistentBar.inject(fb_config)
        end)
    end

    -- Guard against double-patching if the plugin is somehow re-initialised.
    if TouchMenu._shortcutstoolbar_patched then return end
    TouchMenu._shortcutstoolbar_patched = true

    self:_applyMenuPatches()
end

--- Installs the three TouchMenu monkey-patches.
-- Override onMenuInit / onSwitchTab / onMenuUpdateItems in a user patch to
-- customise behaviour without re-patching TouchMenu directly.
function ReaderToolbar:_applyMenuPatches()
    local plugin = self

    -- Patch 1: start every applicable menu in the home (closed) state.
    local orig_init = TouchMenu.init
    TouchMenu.init = function(menu, ...)
        orig_init(menu, ...)
        local cfg = menuConfig(menu)
        if cfg and cfg.enabled and cfg.placement ~= "persistent" then
            plugin:onMenuInit(menu, cfg)
        end
    end

    -- Patch 2: tap an already-active tab to collapse back to home.
    local orig_switchTab = TouchMenu.switchMenuTab
    TouchMenu.switchMenuTab = function(menu, tab_num)
        if plugin:onSwitchTab(menu, tab_num) then return end
        -- Restore the separator line when switching to a real tab.
        if menu.bar and menu.bar.bar_sep then
            menu.bar.bar_sep.style = "solid"
        end
        return orig_switchTab(menu, tab_num)
    end

    -- Patch 3: after updateItems re-renders, re-inject the home panel when
    -- no tab is selected (home state).
    local orig_updateItems = TouchMenu.updateItems
    TouchMenu.updateItems = function(menu, ...)
        orig_updateItems(menu, ...)
        plugin:onMenuUpdateItems(menu)
    end
end

--- Called after TouchMenu:init() for a managed menu.
-- Override in a patch to change the initial home-state behaviour.
function ReaderToolbar:onMenuInit(menu, cfg)
    resetToHomeState(menu, cfg or menuConfig(menu))
end

--- Called when the user taps a menu tab.
-- Return true to consume the event (prevent normal tab-switching).
-- Override in a patch to change tap-to-collapse logic.
function ReaderToolbar:onSwitchTab(menu, tab_num)
    local cfg = menuConfig(menu)
    if menu.cur_tab == tab_num and cfg and cfg.enabled and cfg.placement ~= "persistent" then
        resetToHomeState(menu, cfg)
        return true
    end
end

--- Called after TouchMenu:updateItems().
-- Override in a patch to change home-panel injection.
function ReaderToolbar:onMenuUpdateItems(menu)
    local cfg = menuConfig(menu)
    if not cfg or not cfg.enabled or cfg.placement == "persistent" or menu.cur_tab then return end
    -- Only inject if the home panel isn't already present.
    if not menu.item_group then return end
    for _, widget in ipairs(menu.item_group) do
        if widget and widget.is_shortcuts_bar then return end
    end
    local ok, home = pcall(HomeContent.createHomeContent, menu, cfg, resetToHomeState)
    if ok and home and #menu.item_group >= 1 then
        table.insert(menu.item_group, 2, home)
        menu.item_group:resetLayout()
        local sz = menu.item_group:getSize()
        if menu.dimen then
            menu.dimen.h = sz.h + menu.bordersize * 2 + menu.padding
        end
    end
end

function ReaderToolbar:addToMainMenu(menu_items)
    menu_items.readertoolbar = {
        text         = _("Shortcuts toolbar"),
        sorting_hint = "setting",
        sub_item_table = {
            -- ---- Top-level enable toggles ----
            {
                text         = _("Enable toolbar in reader"),
                checked_func = function() return reader_config.enabled end,
                callback     = function()
                    reader_config.enabled = not reader_config.enabled
                    ToolbarSettings.saveConfig("reader", reader_config)
                end,
            },
            {
                text         = _("Enable toolbar in file browser"),
                checked_func = function() return fb_config.enabled end,
                callback     = function()
                    fb_config.enabled = not fb_config.enabled
                    ToolbarSettings.saveConfig("fb", fb_config)
                    local PersistentBar = require("fb_persistent_bar")
                    if fb_config.enabled and fb_config.placement == "persistent" then
                        PersistentBar.inject(fb_config)
                    elseif not fb_config.enabled then
                        PersistentBar.remove()
                    end
                end,
                separator = true,
            },
            -- ---- Reader settings submenu ----
            {
                text         = _("Reader settings"),
                enabled_func = function() return reader_config.enabled end,
                sub_item_table = {
                    {
                        text         = _("Show book info"),
                        checked_func = function() return reader_config.show_book_info end,
                        callback     = function()
                            reader_config.show_book_info = not reader_config.show_book_info
                            ToolbarSettings.saveConfig("reader", reader_config)
                        end,
                    },
                    {
                        text         = _("Show time and battery"),
                        checked_func = function() return reader_config.show_time_and_battery end,
                        callback     = function()
                            reader_config.show_time_and_battery = not reader_config.show_time_and_battery
                            ToolbarSettings.saveConfig("reader", reader_config)
                        end,
                    },
                    {
                        text         = _("Show back button"),
                        checked_func = function() return reader_config.show_back_button end,
                        callback     = function()
                            reader_config.show_back_button = not reader_config.show_back_button
                            ToolbarSettings.saveConfig("reader", reader_config)
                        end,
                    },
                    {
                        text_func      = function()
                            return T(_("Icon size: %1"), reader_config.icon_size)
                        end,
                        keep_menu_open = true,
                        callback       = function(touchmenu_instance)
                            UIManager:show(SpinWidget:new{
                                title_text    = _("Icon size"),
                                value         = reader_config.icon_size,
                                value_min     = 14,
                                value_max     = 48,
                                value_step    = 2,
                                default_value = 26,
                                callback      = function(spin)
                                    reader_config.icon_size = spin.value
                                    ToolbarSettings.saveConfig("reader", reader_config)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text     = _("Configure shortcuts"),
                        callback = function() ToolbarSettings.openShortcutsConfig("reader", refreshAllConfigs) end,
                    },
                    {
                        text                = _("Custom shortcuts"),
                        separator           = true,
                        sub_item_table_func = function(tm)
                            local ok, ReaderUI = pcall(require, "apps/reader/readerui")
                            if not (ok and ReaderUI.instance and not ReaderUI.instance.tearing_down) then
                                UIManager:show(InfoMessage:new{
                                    text    = _("Open a book to manage reader custom shortcuts."),
                                    timeout = 3,
                                })
                                return {}
                            end
                            return Manager.buildSubItems(refreshAllConfigs, "reader")
                        end,
                    },
                },
            },
            -- ---- File browser settings submenu ----
            {
                text         = _("File browser settings"),
                enabled_func = function() return fb_config.enabled end,
                sub_item_table = {
                    {
                        text_func      = function()
                            return T(_("Icon size: %1"), fb_config.icon_size)
                        end,
                        keep_menu_open = true,
                        callback       = function(touchmenu_instance)
                            UIManager:show(SpinWidget:new{
                                title_text    = _("Icon size"),
                                value         = fb_config.icon_size,
                                value_min     = 14,
                                value_max     = 48,
                                value_step    = 2,
                                default_value = 26,
                                callback      = function(spin)
                                    fb_config.icon_size = spin.value
                                    ToolbarSettings.saveConfig("fb", fb_config)
                                    if fb_config.placement == "persistent" then
                                        require("fb_persistent_bar").inject(fb_config)
                                    end
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local pl = fb_config.placement or "menu"
                            return T(_("Toolbar placement: %1"),
                                pl == "persistent" and _("Persistent bar") or _("In menu"))
                        end,
                        sub_item_table = {
                            {
                                text         = _("In menu"),
                                checked_func = function()
                                    return (fb_config.placement or "menu") ~= "persistent"
                                end,
                                callback     = function()
                                    require("fb_persistent_bar").remove()
                                    fb_config.placement = "menu"
                                    ToolbarSettings.saveConfig("fb", fb_config)
                                end,
                            },
                            {
                                text         = _("Persistent bar at top"),
                                checked_func = function()
                                    return fb_config.placement == "persistent"
                                end,
                                callback     = function()
                                    fb_config.placement = "persistent"
                                    ToolbarSettings.saveConfig("fb", fb_config)
                                    require("fb_persistent_bar").inject(fb_config)
                                end,
                            },
                        },
                    },
                    {
                        text      = _("Configure shortcuts"),
                        callback  = function() ToolbarSettings.openShortcutsConfig("fb", refreshAllConfigs) end,
                    },
                    {
                        text                = _("Custom shortcuts"),
                        sub_item_table_func = function()
                            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                            if not (ok and FileManager.instance and not FileManager.instance.tearing_down) then
                                UIManager:show(InfoMessage:new{
                                    text    = _("Go to the file browser to manage file browser custom shortcuts."),
                                    timeout = 3,
                                })
                                return {}
                            end
                            return Manager.buildSubItems(refreshAllConfigs, "fb")
                        end,
                    },
                },
            },
            -- ---- Global settings ----
            {
                text     = _("Reset settings"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text    = _("Reset all Shortcuts Toolbar settings to defaults?\n\nCustom shortcuts will not be deleted."),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            G_reader_settings:delSetting("shortcutstoolbar_reader")
                            G_reader_settings:delSetting("shortcutstoolbar_fb")
                            refreshAllConfigs()
                        end,
                    })
                end,
            },
        },
    }
end

return ReaderToolbar
