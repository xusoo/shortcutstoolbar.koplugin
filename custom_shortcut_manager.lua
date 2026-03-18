--[[
Custom Shortcut Manager
=======================
Manages user-defined toolbar shortcuts. Each shortcut has a name, an optional
icon (path to an SVG/PNG file), and either a recorded menu navigation path or
a dispatcher-backed system action.

Shortcuts are stored separately per view:
  G_reader_settings["shortcutstoolbar_custom_shortcuts_reader"]
  G_reader_settings["shortcutstoolbar_custom_shortcuts_fb"]

Each entry:
    { key="cs_xxx", name="My shortcut", icon_file="/path/icon.svg", path_record={...} }
    { key="cs_xxx", name="Sleep", icon_file="/path/icon.svg", dispatcher_action="suspend", dispatcher_label="Sleep" }

Public API  (all functions take a `view` parameter: "reader" or "fb")
----------
  M.loadAll(view)                                    → list of shortcut tables
  M.upsert(shortcut, view)                           – create or update by key
  M.find(key, view)                                  → shortcut table or nil
  M.delete(key, view)                                – removes shortcut and its settings keys
  M.clearAll(view)                                   – wipe everything for a view (for reset)
  M.getShortcutDataItems(view)                       → list in shortcuts_data format
    M.getActionDescription(shortcut)                   → human-readable action source + label
    M.execute(shortcut, menu)                          – run the stored action via menu replay or dispatcher
  M.buildSubItems(on_refresh, view)                  → sub_item_table for the menu
  M.openEditDialog(shortcut, menu, on_close, view)   – show create/edit dialog
--]]

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")
local ICON_DIR   = PLUGIN_DIR .. "/icons"

local function settingsKey(view)
    return "shortcutstoolbar_custom_shortcuts_" .. (view or "reader")
end

local IconBrowser = require("icon_browser")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")
local T           = require("ffi/util").template

local DispatcherActions = require("dispatcher_actions")
local Picker = require("custom_shortcut_picker")

local M = {}

local function isMenuVisible(menu)
    local target = menu and menu.show_parent
    if not target then return false end
    for _, win in ipairs(UIManager._window_stack) do
        if win.widget == target then return true end
    end
    return false
end

local function snapshotMenuState(menu)
    local item_table_stack = {}
    for i, item_table in ipairs(menu.item_table_stack or {}) do
        item_table_stack[i] = item_table
    end
    return {
        cur_tab = menu.cur_tab,
        item_table = menu.item_table,
        item_table_stack = item_table_stack,
        page = menu.page,
    }
end

local function restoreMenuState(menu, state)
    if not menu or not state then return end

    menu.item_table_stack = {}
    for i, item_table in ipairs(state.item_table_stack or {}) do
        menu.item_table_stack[i] = item_table
    end
    menu.item_table = state.item_table
    menu.cur_tab = state.cur_tab
    menu.page = state.page or 1
    menu:updateItems(menu.page)
end

local function finishPicking(menu, saved_state, reopen_dialog)
    UIManager:scheduleIn(0, function()
        if isMenuVisible(menu) then
            restoreMenuState(menu, saved_state)
            if isMenuVisible(menu) then
                menu:closeMenu()
            end
        end
        reopen_dialog()
    end)
end

-- ==========================================================================
-- Key generation
-- ==========================================================================

local _counter = 0
local function newKey()
    _counter = _counter + 1
    return string.format("cs_%d_%d", math.floor(os.time()), _counter)
end

-- ==========================================================================
-- Data model
-- ==========================================================================

function M.loadAll(view)
    return G_reader_settings:readSetting(settingsKey(view)) or {}
end

function M.saveAll(items, view)
    G_reader_settings:saveSetting(settingsKey(view), items)
end

--- Create or update a shortcut entry (matched by key).
function M.upsert(shortcut, view)
    local all = M.loadAll(view)
    for i, s in ipairs(all) do
        if s.key == shortcut.key then
            all[i] = shortcut
            M.saveAll(all, view)
            return
        end
    end
    table.insert(all, shortcut)
    M.saveAll(all, view)
end

--- Find a shortcut by key, or nil.
function M.find(key, view)
    for _i, s in ipairs(M.loadAll(view)) do
        if s.key == key then return s end
    end
    return nil
end

--- Delete a shortcut and clean up its associated settings keys.
function M.delete(key, view)
    local all = M.loadAll(view)
    for i, s in ipairs(all) do
        if s.key == key then
            table.remove(all, i)
            M.saveAll(all, view)
            -- Remove per-item flag and prune order CSV from the view table.
            local stored = G_reader_settings:readSetting("shortcutstoolbar_" .. view) or {}
            if stored.items then stored.items[key] = nil end
            if stored.item_order then
                local parts = {}
                for k in stored.item_order:gmatch("([^,]+)") do
                    if k ~= key then table.insert(parts, k) end
                end
                stored.item_order = table.concat(parts, ",")
            end
            G_reader_settings:saveSetting("shortcutstoolbar_" .. view, stored)
            return
        end
    end
end

--- Wipe all custom shortcuts for a view and remove them from its per-view table.
function M.clearAll(view)
    local all  = M.loadAll(view)
    local keys = {}
    for _i, s in ipairs(all) do keys[s.key] = true end
    local stored = G_reader_settings:readSetting("shortcutstoolbar_" .. view) or {}
    if stored.items then
        for k in pairs(keys) do stored.items[k] = nil end
    end
    if stored.item_order then
        local parts = {}
        for k in stored.item_order:gmatch("([^,]+)") do
            if not keys[k] then table.insert(parts, k) end
        end
        stored.item_order = table.concat(parts, ",")
    end
    G_reader_settings:saveSetting("shortcutstoolbar_" .. view, stored)
    G_reader_settings:delSetting(settingsKey(view))
end

--- Return custom shortcuts in shortcuts_data item format for ITEM_BY_KEY /
-- readConfig ingestion.
function M.getShortcutDataItems(view)
    local result = {}
    for _i, s in ipairs(M.loadAll(view)) do
        table.insert(result, {
            key       = s.key,
            label     = (s.name and s.name ~= "") and s.name or _("Custom shortcut"),
            icon      = "appbar.settings",
            icon_file = s.icon_file,
            default   = false,
            is_custom = true,
        })
    end
    return result
end

function M.getActionSource(shortcut)
    if shortcut and shortcut.dispatcher_action and shortcut.dispatcher_action ~= "" then
        return "system"
    end
    if shortcut and shortcut.path_record then
        return "menu"
    end
    return nil
end

function M.getActionLabel(shortcut)
    local source = M.getActionSource(shortcut)
    if source == "system" then
        return shortcut.dispatcher_label or shortcut.dispatcher_action
    end
    if source == "menu" then
        return shortcut.path_record.display_label
    end
    return _("Not set")
end

function M.getActionDescription(shortcut)
    local source = M.getActionSource(shortcut)
    if source == "system" then
        return T(_("%1 | %2"), _("System action"), M.getActionLabel(shortcut))
    end
    if source == "menu" then
        return T(_("%1 | %2"), _("Menu action"), M.getActionLabel(shortcut))
    end
    return _("Not set")
end

function M.hasAction(shortcut)
    return M.getActionSource(shortcut) ~= nil
end

function M.execute(shortcut, menu)
    if not shortcut then return false end

    local source = M.getActionSource(shortcut)
    if source == "system" then
        local ok, err = DispatcherActions.execute(shortcut.dispatcher_action)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = err,
                timeout = 3,
            })
        end
        return ok
    end
    if source == "menu" then
        return Picker.replayShortcut(menu, shortcut.path_record)
    end

    UIManager:show(InfoMessage:new{
        text = _("Long-press to set up this shortcut."),
        timeout = 2,
    })
    return false
end

-- ==========================================================================
-- Edit dialog
-- ==========================================================================

--- Open the create/edit dialog.
-- @param shortcut  Existing shortcut table, or nil to create a new one.
-- @param menu      The live TouchMenu instance (needed for the action picker).
-- @param on_close  function() called after any save or delete.
-- @param view      "reader" or "fb" – which shortcut pool this belongs to.
function M.openEditDialog(shortcut, menu, on_close, view)
    view = view or "reader"
    local is_new = (shortcut == nil)
    -- Work on a shallow copy so mutations don't persist unless the user saves.
    local sc = shortcut and {
        key         = shortcut.key,
        name        = shortcut.name,
        icon_file   = shortcut.icon_file,
        path_record = shortcut.path_record,
        dispatcher_action = shortcut.dispatcher_action,
        dispatcher_label = shortcut.dispatcher_label,
    } or {
        key         = newKey(),
        name        = "",
        icon_file   = nil,
        path_record = nil,
        dispatcher_action = nil,
        dispatcher_label = nil,
    }

    local action_label = M.getActionDescription(sc)
    local icon_label   = sc.icon_file and sc.icon_file:match("[^/]+$") or _("Default")

    local dialog

    local function doSave()
        local name = dialog:getInputText()
        sc.name = (name ~= "") and name or _("Custom shortcut")
        M.upsert(sc, view)
        UIManager:close(dialog)
        if on_close then on_close() end
    end

    -- Close and reopen the dialog (e.g. after picking an icon) preserving
    -- the current name the user typed.
    local function refresh(updated_sc)
        UIManager:close(dialog)
        M.openEditDialog(updated_sc or sc, menu, on_close, view)
    end

    local function snapshotName()
        local n = dialog:getInputText()
        if n ~= "" then sc.name = n end
    end

    local function applyMenuAction(path_record)
        sc.path_record = path_record
        sc.dispatcher_action = nil
        sc.dispatcher_label = nil
        if not sc.name or sc.name == "" then
            sc.name = path_record.display_label
        end
    end

    local function applySystemAction(action)
        sc.path_record = nil
        sc.dispatcher_action = action.id
        sc.dispatcher_label = action.title
        if not sc.name or sc.name == "" then
            sc.name = action.title
        end
    end

    local function reopenCurrentDialog()
        M.openEditDialog(sc, menu, on_close, view)
    end

    local function openSystemActionPicker()
        local actions = DispatcherActions.list()
        if #actions == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No system actions found."),
                timeout = 3,
            })
            reopenCurrentDialog()
            return
        end

        local picker
        local buttons = {}
        for _i, action in ipairs(actions) do
            local action_ref = action
            buttons[#buttons + 1] = {{
                text = action_ref.title,
                callback = function()
                    UIManager:close(picker)
                    applySystemAction(action_ref)
                    reopenCurrentDialog()
                end,
            }}
        end
        buttons[#buttons + 1] = {{
            text = _("Cancel"),
            callback = function()
                UIManager:close(picker)
                reopenCurrentDialog()
            end,
        }}

        picker = ButtonDialog:new{
            title = _("System Actions"),
            buttons = buttons,
        }
        UIManager:show(picker)
    end

    local function openMenuActionPicker()
        if view == "fb" or (menu and menu._is_fb_context) then
            -- FB shortcut: open the live FM menu for picking.
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            if not (ok and FileManager.instance and not FileManager.instance.tearing_down) then
                UIManager:show(InfoMessage:new{
                    text    = _("Open the file browser first to set this shortcut action."),
                    timeout = 3,
                })
                reopenCurrentDialog()
                return
            end
            FileManager.instance.menu:onShowMenu(nil)
            local mc = FileManager.instance.menu.menu_container
            local real_menu = mc and mc[1]
            if not real_menu then
                UIManager:show(InfoMessage:new{
                    text    = _("Could not open the file browser menu."),
                    timeout = 3,
                })
                reopenCurrentDialog()
                return
            end
            local saved_state = snapshotMenuState(real_menu)
            Picker.startPicking(real_menu, sc.key,
                function(path_record)
                    applyMenuAction(path_record)
                    finishPicking(real_menu, saved_state, reopenCurrentDialog)
                end,
                function()
                    finishPicking(real_menu, saved_state, function()
                        M.openEditDialog(M.find(sc.key, view) or sc, menu, on_close, view)
                    end)
                end,
                "fb")
            return
        end

        -- Reader shortcut: requires the reader menu to be open.
        if not menu or not menu.updateItems then
            UIManager:show(InfoMessage:new{
                text    = _("Open a book first to set this shortcut action."),
                timeout = 3,
            })
            reopenCurrentDialog()
            return
        end

        -- Save the full menu state so we can return here after picking.
        local saved_state = snapshotMenuState(menu)
        -- Drain any sub-menu stack so picking starts from the tab root.
        if menu.item_table_stack then
            while #menu.item_table_stack > 0 do
                menu.item_table = table.remove(menu.item_table_stack)
            end
            menu.page = 1
            menu:updateItems(1)
        end
        Picker.startPicking(menu, sc.key,
            function(path_record)
                applyMenuAction(path_record)
                finishPicking(menu, saved_state, reopenCurrentDialog)
            end,
            function()
                finishPicking(menu, saved_state, function()
                    M.openEditDialog(M.find(sc.key, view) or sc, menu, on_close, view)
                end)
            end,
            "reader")
    end

    local function openActionSourcePicker()
        local choice_dialog
        choice_dialog = ButtonDialog:new{
            title = _("Choose action source"),
            buttons = {
                
                {{
                    text = _("System action"),
                    callback = function()
                        UIManager:close(choice_dialog)
                        openSystemActionPicker()
                    end,
                }},
                {{
                    text = _("Run a built-in KOReader action directly. Safer approach if the desired action is exposed here."),
                    enabled = false,
                    font_size = 18,
                    font_bold = false,
                    callback = function() end,
                }},
                {{
                    text = _("Menu action"),
                    callback = function()
                        UIManager:close(choice_dialog)
                        openMenuActionPicker()
                    end,
                }},
                {{
                    text = _("Browse the KOReader menu to find an action by name. Less stable, but can reach actions not exposed to the dispatcher."),
                    enabled = false,
                    font_size = 18,
                    font_bold = false,
                    callback = function() end,
                }},
                {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(choice_dialog)
                        reopenCurrentDialog()
                    end,
                }},
            },
        }
        UIManager:show(choice_dialog)
    end

    local buttons = {
        -- Row 1 ── Cancel / Save
        {
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = doSave,
            },
        },
        -- Row 2 ── Set action / Choose icon
        {
            {
                text     = T(_("Action: %1"), action_label),
                callback = function()
                    snapshotName()
                    UIManager:close(dialog)

                    openActionSourcePicker()
                end,
            },
            {
                text     = T(_("Icon: %1"), icon_label),
                callback = function()
                    snapshotName()
                    UIManager:show(IconBrowser:new{
                        path      = ICON_DIR,
                        onConfirm = function(file_path)
                            sc.icon_file = file_path
                            UIManager:scheduleIn(0, function() refresh(sc) end)
                        end,
                    })
                end,
            },
        },
    }

    -- Row 3 ── Delete (only for existing shortcuts)
    if not is_new then
        local ConfirmBox = require("ui/widget/confirmbox")
        table.insert(buttons, {
            {
                text     = _("Delete shortcut"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = T(_("Delete \"%1\"?"), sc.name or sc.key),
                        ok_text     = _("Delete"),
                        ok_callback = function()
                            UIManager:close(dialog)
                            M.delete(sc.key, view)
                            if on_close then on_close() end
                        end,
                    })
                end,
            },
        })
    end

    dialog = InputDialog:new{
        title      = is_new and _("New custom shortcut") or _("Edit custom shortcut"),
        input      = sc.name or "",
        input_hint = _("Shortcut name"),
        buttons    = buttons,
    }
    UIManager:show(dialog)
end

-- ==========================================================================
-- Sub-menu items for the "Custom shortcuts" reader-menu entry
-- ==========================================================================

--- Build the dynamic sub_item_table for the "Custom shortcuts" menu entry.
-- Each item's callback receives the touchmenu_instance so the edit dialog
-- gets access to the live menu for the action picker.
-- @param on_refresh  function() called after any save/delete (e.g. readConfig).
-- @param view        "reader" or "fb"
function M.buildSubItems(on_refresh, view)
    view = view or "reader"
    local all = M.loadAll(view)
    local items = {}

    -- Wrapper: after save/delete, call on_refresh then rebuild the sub-menu
    -- inside the live TouchMenu instance so the list stays in sync.
    local function make_on_close(tm)
        return function()
            if on_refresh then on_refresh() end
            tm.item_table = M.buildSubItems(on_refresh, view)
            tm:updateItems()
        end
    end

    table.insert(items, {
        text           = _("Add new shortcut"),
        callback       = function(tm)
            M.openEditDialog(nil, tm, make_on_close(tm), view)
        end,
        keep_menu_open = true,
        separator      = #all > 0,
    })

    for _i, sc in ipairs(all) do
        local sc_ref = sc  -- capture
        local action = M.getActionDescription(sc_ref):lower()
        table.insert(items, {
            text           = (sc.name and sc.name ~= "") and sc.name or _("Unnamed shortcut"),
            mandatory      = action,
            keep_menu_open = true,
            callback       = function(tm)
                M.openEditDialog(sc_ref, tm, make_on_close(tm), view)
            end,
        })
    end

    return items
end

return M
