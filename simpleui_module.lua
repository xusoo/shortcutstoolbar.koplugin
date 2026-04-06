local Device = require("device")
local Screen = Device.screen
local ConfirmBox = require("ui/widget/confirmbox")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local HomeContent = require("home_content")
local Manager = require("custom_shortcut_manager")
local ToolbarSettings = require("toolbar_settings")

local VIEW = "simpleui"
local SETTINGS_OPTIONS = {
    item_filter_view = "fb",
    default_items = {
        "file_search",
        "collections",
        "favorites",
        "cloud_storage",
        "wifi",
    },
    default_icon_size = 32,
}

local function refreshHomescreen(ctx_menu)
    if ctx_menu and ctx_menu.refresh then
        ctx_menu.refresh()
        return
    end
    local HS = package.loaded["homescreen"]
    if HS and HS.refreshImmediate then HS.refreshImmediate(false) end
end

local function buildFakeMenu(width)
    return {
        width = width,
        dimen = { w = width },
        inner_dimen = { w = width },
        tab_item_table = {},
        item_table = {},
        item_table_stack = {},
        page = 1,
        close_callback = nil,
        _is_fb_context = true,
    }
end

local function buildWidget(width, on_refresh)
    local cfg = ToolbarSettings.readConfig(VIEW, SETTINGS_OPTIONS)
    cfg.align = "center"
    local fake_menu = buildFakeMenu(width)
    return HomeContent.createShortcutsBar(fake_menu, cfg, function()
        if on_refresh then on_refresh() end
    end, 0)
end

local function resetSettings()
    local enabled = ToolbarSettings.readConfig(VIEW, SETTINGS_OPTIONS).enabled
    G_reader_settings:delSetting(ToolbarSettings.settingsKey(VIEW))
    if enabled == false then
        G_reader_settings:saveSetting(ToolbarSettings.settingsKey(VIEW), { enabled = false })
    end
end

local M = {}

M.id = "shortcutstoolbar"
M.name = _("Shortcuts Toolbar")
M.label = nil
M.default_on = false

function M.isEnabled(_pfx)
    return ToolbarSettings.readConfig(VIEW, SETTINGS_OPTIONS).enabled ~= false
end

function M.setEnabled(_pfx, on)
    local cfg = ToolbarSettings.readConfig(VIEW, SETTINGS_OPTIONS)
    cfg.enabled = on
    ToolbarSettings.saveConfig(VIEW, cfg)
    refreshHomescreen()
end

M.getCountLabel = nil

function M.build(w, _ctx)
    return buildWidget(w)
end

function M.getHeight(_ctx)
    local approx_w = Screen:getWidth() - Screen:scaleBySize(24)
    return buildWidget(approx_w):getSize().h
end

function M.getMenuItems(ctx_menu)
    local refresh = function() refreshHomescreen(ctx_menu) end
    local cfg = ToolbarSettings.readConfig(VIEW, SETTINGS_OPTIONS)
    local items = {
        {
            text_func = function()
                return T(_("Icon size: %1"), cfg.icon_size)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Icon size"),
                    value = cfg.icon_size,
                    value_min = 14,
                    value_max = 48,
                    value_step = 2,
                    default_value = 32,
                    callback = function(spin)
                        cfg.icon_size = spin.value
                        ToolbarSettings.saveConfig(VIEW, cfg)
                        refresh()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
        {
            text = _("Configure shortcuts"),
            callback = function()
                ToolbarSettings.openShortcutsConfig(VIEW, refresh, SETTINGS_OPTIONS)
            end,
        },
        {
            text = _("Custom shortcuts"),
            separator = true,
            sub_item_table_func = function()
                return Manager.buildSubItems(refresh, VIEW)
            end,
        },
        {
            text = _("Reset settings"),
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset SimpleUI shortcuts module settings to defaults?\n\nCustom shortcuts will not be deleted."),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        resetSettings()
                        cfg = ToolbarSettings.readConfig(VIEW, SETTINGS_OPTIONS)
                        refresh()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
    }
    return items
end

return M