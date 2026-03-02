--[[
Custom Shortcut Manager
=======================
Manages user-defined toolbar shortcuts. Each shortcut has a name, an optional
icon (path to an SVG/PNG file), and a recorded menu navigation path.

Data stored in G_reader_settings under "readertoolbar_custom_shortcuts":
  {
    { key="cs_xxx", name="My shortcut", icon_file="/path/icon.svg", path_record={...} },
    ...
  }

Public API
----------
  M.loadAll()                              → list of shortcut tables
  M.upsert(shortcut)                       – create or update by key
  M.find(key)                              → shortcut table or nil
  M.delete(key)                            – removes shortcut and its settings keys
  M.clearAll()                             – wipe everything (for reset)
  M.getShortcutDataItems()                 → list in shortcuts_data format
  M.buildSubItems(on_refresh)              → sub_item_table for the menu
  M.openEditDialog(shortcut, menu, on_close)  – show create/edit dialog
--]]

local PLUGIN_DIR   = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")
local SETTINGS_KEY = "readertoolbar_custom_shortcuts"
local ICON_DIR     = PLUGIN_DIR .. "/icons"

local IconBrowser = require("icon_browser")
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")
local T           = require("ffi/util").template

local Picker = require("custom_shortcut_picker")

local M = {}

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

function M.loadAll()
    return G_reader_settings:readSetting(SETTINGS_KEY) or {}
end

function M.saveAll(items)
    G_reader_settings:saveSetting(SETTINGS_KEY, items)
end

--- Create or update a shortcut entry (matched by key).
function M.upsert(shortcut)
    local all = M.loadAll()
    for i, s in ipairs(all) do
        if s.key == shortcut.key then
            all[i] = shortcut
            M.saveAll(all)
            return
        end
    end
    -- New shortcut: enable it in the toolbar by default.
    G_reader_settings:saveSetting("readertoolbar_item_" .. shortcut.key, true)
    table.insert(all, shortcut)
    M.saveAll(all)
end

--- Find a shortcut by key, or nil.
function M.find(key)
    for _i, s in ipairs(M.loadAll()) do
        if s.key == key then return s end
    end
    return nil
end

--- Delete a shortcut and clean up its associated settings keys.
function M.delete(key)
    local all = M.loadAll()
    for i, s in ipairs(all) do
        if s.key == key then
            table.remove(all, i)
            M.saveAll(all)
            G_reader_settings:delSetting("readertoolbar_item_" .. key)
            -- Prune the key from the item-order CSV so it doesn't linger.
            local order = G_reader_settings:readSetting("readertoolbar_item_order")
            if order then
                local parts = {}
                for k in order:gmatch("([^,]+)") do
                    if k ~= key then table.insert(parts, k) end
                end
                G_reader_settings:saveSetting("readertoolbar_item_order",
                    table.concat(parts, ","))
            end
            return
        end
    end
end

--- Wipe all custom shortcuts and their settings keys (used by "Reset settings").
function M.clearAll()
    local all = M.loadAll()
    for _i, s in ipairs(all) do
        G_reader_settings:delSetting("readertoolbar_item_" .. s.key)
    end
    G_reader_settings:delSetting(SETTINGS_KEY)
end

--- Return custom shortcuts in shortcuts_data item format for ITEM_BY_KEY /
-- readConfig ingestion.
function M.getShortcutDataItems()
    local result = {}
    for _i, s in ipairs(M.loadAll()) do
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
function M.openEditDialog(shortcut, menu, on_close)
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
        M.upsert(sc)
        UIManager:close(dialog)
        if on_close then on_close() end
    end

    -- Close and reopen the dialog (e.g. after picking an icon) preserving
    -- the current name the user typed.
    local function refresh(updated_sc)
        UIManager:close(dialog)
        M.openEditDialog(updated_sc or sc, menu, on_close)
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
                    -- Save the full menu state so we can return here after picking.
                    local saved_cur_tab   = menu.cur_tab
                    local saved_item_table = menu.item_table
                    local saved_stack = {}
                    for i, t in ipairs(menu.item_table_stack or {}) do
                        saved_stack[i] = t
                    end
                    local function restoreMenuState()
                        menu.item_table_stack = saved_stack
                        menu.item_table       = saved_item_table
                        menu.cur_tab          = saved_cur_tab
                        menu.page             = 1
                        menu:updateItems()
                    end
                    -- Drain any sub-menu stack so picking starts from the tab root.
                    -- This makes the cancel heuristic (empty stack → cancel) reliable.
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
                            -- Auto-fill name from action if still empty.
                            if not sc.name or sc.name == "" then
                                sc.name = path_record.display_label
                            end
                            -- After 1 second, restore the menu position and reopen
                            -- the edit dialog so the user can confirm and save.
                            restoreMenuState()
                            M.openEditDialog(sc, menu, on_close)
                        end,
                        function()
                            -- Cancelled: restore menu position and reopen the editor.
                            restoreMenuState()
                            M.openEditDialog(M.find(sc.key) or sc, menu, on_close)
                        end)
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
                            M.delete(sc.key)
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
function M.buildSubItems(on_refresh)
    local all = M.loadAll()
    local items = {}

    -- Wrapper: after save/delete, call on_refresh then rebuild the sub-menu
    -- inside the live TouchMenu instance so the list stays in sync.
    local function make_on_close(tm)
        return function()
            if on_refresh then on_refresh() end
            tm.item_table = M.buildSubItems(on_refresh)
            tm:updateItems()
        end
    end

    table.insert(items, {
        text           = _("Add new shortcut"),
        callback       = function(tm)
            M.openEditDialog(nil, tm, make_on_close(tm))
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
                M.openEditDialog(sc_ref, tm, make_on_close(tm))
            end,
        })
    end

    return items
end

return M
