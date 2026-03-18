--[[
Custom Shortcut Manager
=======================
Manages user-defined toolbar shortcuts. Each shortcut has a name, an optional
icon (path to an SVG/PNG file), and a recorded menu navigation path.

Shortcuts are stored separately per view:
  G_reader_settings["shortcutstoolbar_custom_shortcuts_reader"]
  G_reader_settings["shortcutstoolbar_custom_shortcuts_fb"]

Each entry:
  { key="cs_xxx", name="My shortcut", icon_file="/path/icon.svg", path_record={...} }

Public API  (all functions take a `view` parameter: "reader" or "fb")
----------
  M.loadAll(view)                                    → list of shortcut tables
  M.upsert(shortcut, view)                           – create or update by key
  M.find(key, view)                                  → shortcut table or nil
  M.delete(key, view)                                – removes shortcut and its settings keys
  M.clearAll(view)                                   – wipe everything for a view (for reset)
  M.getShortcutDataItems(view)                       → list in shortcuts_data format
  M.buildSubItems(on_refresh, view)                  → sub_item_table for the menu
  M.openEditDialog(shortcut, menu, on_close, view)   – show create/edit dialog
--]]

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")
local ICON_DIR   = PLUGIN_DIR .. "/icons"

local function settingsKey(view)
    return "shortcutstoolbar_custom_shortcuts_" .. (view or "reader")
end

local IconBrowser = require("icon_browser")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")
local T           = require("ffi/util").template

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
    } or {
        key         = newKey(),
        name        = "",
        icon_file   = nil,
        path_record = nil,
    }

    local action_label = sc.path_record and sc.path_record.display_label or _("Not set")
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

                    if view == "fb" or (menu and menu._is_fb_context) then
                        -- FB shortcut: open the live FM menu for picking.
                        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                        if not (ok and FileManager.instance and not FileManager.instance.tearing_down) then
                            UIManager:show(InfoMessage:new{
                                text    = _("Open the file browser first to set this shortcut action."),
                                timeout = 3,
                            })
                            M.openEditDialog(sc, menu, on_close, view)
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
                            M.openEditDialog(sc, menu, on_close, view)
                            return
                        end
                        local saved_state = snapshotMenuState(real_menu)
                        Picker.startPicking(real_menu, sc.key,
                            function(path_record)
                                sc.path_record = path_record
                                if not sc.name or sc.name == "" then
                                    sc.name = path_record.display_label
                                end
                                finishPicking(real_menu, saved_state, function()
                                    M.openEditDialog(sc, menu, on_close, view)
                                end)
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
                        M.openEditDialog(sc, menu, on_close, view)
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
                            sc.path_record = path_record
                            if not sc.name or sc.name == "" then
                                sc.name = path_record.display_label
                            end
                            finishPicking(menu, saved_state, function()
                                M.openEditDialog(sc, menu, on_close, view)
                            end)
                        end,
                        function()
                            finishPicking(menu, saved_state, function()
                                M.openEditDialog(M.find(sc.key, view) or sc, menu, on_close, view)
                            end)
                        end,
                        "reader")
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
        local action = sc.path_record and sc.path_record.display_label or _("not set")
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
