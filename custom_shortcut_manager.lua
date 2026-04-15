--[[
Custom Shortcut Manager
=======================
Manages user-defined toolbar shortcuts. Each shortcut has a name, an optional
icon (path to an SVG/PNG file), and either:
  - a patch-registered callback
  - a recorded menu navigation path
  - a dispatcher-backed system action

Shortcuts are stored separately for the reader, while the file browser and
SimpleUI share a single custom-shortcut list:
  G_reader_settings["shortcutstoolbar_custom_shortcuts_reader"]
  G_reader_settings["shortcutstoolbar_custom_shortcuts_fb"]

Each entry:
    { key="cs_xxx", id="patch.hello", name="Hello", icon_file="/path/icon.svg", patch_callback=true }
    { key="cs_xxx", name="My shortcut", icon_file="/path/icon.svg", path_record={...} }
    { key="cs_xxx", name="Sleep", icon_file="/path/icon.svg", dispatcher_action="suspend", dispatcher_label="Sleep" }

Public API
----------
  M.loadAll(view)                                    -> list of shortcut tables
  M.upsert(shortcut, view)                           - create or update by key
  M.find(key, view)                                  -> shortcut table or nil
  M.findById(id, view)                               -> shortcut table or nil
  M.delete(key, view)                                - removes shortcut and its settings keys
  M.ensureShortcut(spec)                             - idempotent patch helper using a callback
  M.upsertShortcut(spec)                             - alias of ensureShortcut
  M.deleteShortcut(id_or_spec, view)                 - patch-friendly delete helper
  M.getBundledIcon(name)                             - absolute path to a bundled icon
  M.clearAll(view)                                   - wipe everything for a view (for reset)
  M.getShortcutDataItems(view)                       -> list in shortcuts_data format
  M.getActionDescription(shortcut)                   -> human-readable action source + label
  M.execute(shortcut, menu)                          - run the stored action via callback, menu replay, or dispatcher
  M.buildSubItems(on_refresh, view)                  -> sub_item_table for the menu
  M.openEditDialog(shortcut, menu, on_close, view)   - show create/edit dialog
--]]

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")
local ICON_DIR = PLUGIN_DIR .. "/icons"
local PATCH_CALLBACKS_KEY = "__shortcutstoolbar_patch_shortcut_callbacks"
local PATCH_VIEWS = { "reader", "fb", "simpleui" }

if not package.path:find(PLUGIN_DIR, 1, true) then
    package.path = string.format("%s/?.lua;%s", PLUGIN_DIR, package.path)
end

local function storageView(view)
    if view == "reader" then
        return "reader"
    end
    return "fb"
end

local function settingsKey(view)
    return "shortcutstoolbar_custom_shortcuts_" .. storageView(view)
end

local function viewSettingsKey(view)
    return "shortcutstoolbar_" .. ((view == "filebrowser") and "fb" or (view or "reader"))
end

local IconBrowser = require("icon_browser")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local DispatcherActions = require("dispatcher_actions")
local Picker = require("custom_shortcut_picker")

local M = {}

local function fail(message)
    error("shortcutstoolbar custom shortcut: " .. message, 2)
end

local function cloneTable(value)
    if type(value) ~= "table" then return value end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = cloneTable(item)
    end
    return copy
end

function M.normalizeView(view)
    if view == nil then return "reader" end
    if view == "filebrowser" then return "fb" end
    if type(view) ~= "string" or view == "" then
        fail("view must be a non-empty string")
    end
    return view
end

local function normalizeViews(views)
    if views == nil then
        return cloneTable(PATCH_VIEWS)
    end

    if type(views) ~= "table" then
        return { M.normalizeView(views) }
    end

    local normalized = {}
    local seen = {}
    for _, view in ipairs(views) do
        local item = M.normalizeView(view)
        if not seen[item] then
            seen[item] = true
            normalized[#normalized + 1] = item
        end
    end

    if #normalized == 0 then
        fail("view list must not be empty")
    end
    return normalized
end

local function candidateViews(view)
    return normalizeViews(view)
end

local function relatedViews(view)
    view = M.normalizeView(view)
    if view == "fb" or view == "simpleui" then
        return { "fb", "simpleui" }
    end
    return { view }
end

local function clearShortcutFromSelections(key, views)
    for _, view in ipairs(views) do
        local stored = G_reader_settings:readSetting(viewSettingsKey(view)) or {}
        local changed = false

        if stored.items and stored.items[key] ~= nil then
            stored.items[key] = nil
            changed = true
        end
        if stored.item_order then
            local parts = {}
            local removed = false
            for item_key in stored.item_order:gmatch("([^,]+)") do
                if item_key ~= key then
                    table.insert(parts, item_key)
                else
                    removed = true
                end
            end
            if removed then
                stored.item_order = table.concat(parts, ",")
                changed = true
            end
        end

        if changed then
            G_reader_settings:saveSetting(viewSettingsKey(view), stored)
        end
    end
end

local function getPatchCallbackRegistry()
    local registry = rawget(_G, PATCH_CALLBACKS_KEY)
    if registry then return registry end

    registry = {}
    rawset(_G, PATCH_CALLBACKS_KEY, registry)
    return registry
end

local function registerPatchCallback(id, view, callback)
    local registry = getPatchCallbackRegistry()
    view = M.normalizeView(view)
    registry[view] = registry[view] or {}
    registry[view][id] = callback
end

local function unregisterPatchCallback(id, view)
    if not id then return end

    local registry = getPatchCallbackRegistry()
    for _, candidate in ipairs(relatedViews(view)) do
        if registry[candidate] then
            registry[candidate][id] = nil
        end
    end
end

local function getPatchCallback(shortcut, view)
    if not shortcut or not shortcut.id then return nil end

    local registry = getPatchCallbackRegistry()
    for _, candidate in ipairs(relatedViews(view)) do
        local callbacks = registry[candidate]
        if callbacks and callbacks[shortcut.id] then
            return callbacks[shortcut.id], candidate
        end
    end
    return nil
end

local function findShortcutByRef(ref, view)
    if type(ref) ~= "table" and type(ref) ~= "string" then
        return nil, nil
    end

    for _, candidate in ipairs(candidateViews(view)) do
        for _i, shortcut in ipairs(M.loadAll(candidate)) do
            if type(ref) == "table" then
                if (ref.key and shortcut.key == ref.key) or (ref.id and shortcut.id == ref.id) then
                    return shortcut, candidate
                end
            else
                if shortcut.id == ref or shortcut.key == ref then
                    return shortcut, candidate
                end
            end
        end
    end

    return nil, nil
end

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

local _counter = 0
local function newKey()
    _counter = _counter + 1
    return string.format("cs_%d_%d", math.floor(os.time()), _counter)
end

function M.loadAll(view)
    view = M.normalizeView(view)
    return G_reader_settings:readSetting(settingsKey(view)) or {}
end

function M.saveAll(items, view)
    view = M.normalizeView(view)
    G_reader_settings:saveSetting(settingsKey(view), items)
end

function M.upsert(shortcut, view)
    view = M.normalizeView(view)
    local all = M.loadAll(view)
    for i, stored in ipairs(all) do
        if stored.key == shortcut.key then
            all[i] = shortcut
            M.saveAll(all, view)
            return
        end
    end
    table.insert(all, shortcut)
    M.saveAll(all, view)
end

function M.find(key, view)
    view = M.normalizeView(view)
    for _i, shortcut in ipairs(M.loadAll(view)) do
        if shortcut.key == key then return shortcut end
    end
    return nil
end

function M.findById(id, view)
    local shortcut = select(1, findShortcutByRef({ id = id }, view))
    return shortcut
end

function M.delete(key, view)
    view = M.normalizeView(view)
    local all = M.loadAll(view)
    for i, shortcut in ipairs(all) do
        if shortcut.key == key then
            table.remove(all, i)
            M.saveAll(all, view)
            unregisterPatchCallback(shortcut.id, view)

            clearShortcutFromSelections(key, relatedViews(view))
            return
        end
    end
end

function M.clearAll(view)
    view = M.normalizeView(view)
    local all = M.loadAll(view)
    local keys = {}
    for _i, shortcut in ipairs(all) do
        keys[shortcut.key] = true
        unregisterPatchCallback(shortcut.id, view)
    end

    for key in pairs(keys) do
        clearShortcutFromSelections(key, relatedViews(view))
    end
    G_reader_settings:delSetting(settingsKey(view))
end

function M.getShortcutDataItems(view)
    local result = {}
    for _i, shortcut in ipairs(M.loadAll(view)) do
        table.insert(result, {
            key = shortcut.key,
            label = (shortcut.name and shortcut.name ~= "") and shortcut.name or _("Custom shortcut"),
            icon = shortcut.icon or "appbar.settings",
            icon_file = shortcut.icon_file,
            default = false,
            is_custom = true,
        })
    end
    return result
end

function M.getActionSource(shortcut, view)
    if getPatchCallback(shortcut, view) or (shortcut and shortcut.patch_callback) then
        return "callback"
    end
    if shortcut and shortcut.dispatcher_action and shortcut.dispatcher_action ~= "" then
        return "system"
    end
    if shortcut and shortcut.path_record then
        return "menu"
    end
    return nil
end

function M.getActionLabel(shortcut, view)
    local source = M.getActionSource(shortcut, view)
    if source == "callback" then
        return shortcut.callback_label or shortcut.name or _("Patch callback")
    end
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
    if source == "callback" then
        return T(_("%1 | %2"), _("Patch callback"), M.getActionLabel(shortcut))
    end
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
    if source == "callback" then
        local callback = getPatchCallback(shortcut)
        if not callback then
            UIManager:show(InfoMessage:new{
                text = _("Patch callback not available. Restart KOReader or reload the patch."),
                timeout = 3,
            })
            return false
        end
        local ok, err = pcall(callback, menu, shortcut)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Patch callback error: %1"), tostring(err)),
                timeout = 3,
            })
        end
        return ok
    end
    if source == "system" then
        -- Close the menu before dispatching so events reach the reader UI
        -- (sendEvent targets the top widget; the menu would intercept them).
        if menu and menu.close_callback then menu.close_callback() end
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

local function normalizeShortcutSpec(spec, existing, existing_view)
    if type(spec) ~= "table" then
        fail("shortcut spec must be a table")
    end

    local view = M.normalizeView(existing_view or spec.view or "reader")
    local normalized = existing and cloneTable(existing) or {}

    normalized.key = (existing and existing.key) or spec.key or newKey()
    normalized.id = spec.id or spec.patch_id or normalized.id
    if not normalized.id then
        fail("shortcut spec requires id")
    end

    if spec.name ~= nil then
        normalized.name = spec.name
    elseif spec.label ~= nil then
        normalized.name = spec.label
    elseif not normalized.name or normalized.name == "" then
        normalized.name = _("Custom shortcut")
    end

    if spec.icon ~= nil or spec.icon_file ~= nil then
        normalized.icon = spec.icon or nil
        normalized.icon_file = spec.icon_file or nil
    end

    normalized.patch_callback = true
    normalized.callback_label = spec.callback_label or normalized.name or _("Patch callback")
    normalized.path_record = nil
    normalized.dispatcher_action = nil
    normalized.dispatcher_label = nil

    return normalized, view
end

function M.ensureShortcut(spec)
    if type(spec) ~= "table" then
        fail("shortcut spec must be a table")
    end
    if type(spec.callback) ~= "function" then
        fail("shortcut spec requires callback")
    end

    local results = {}
    local views = normalizeViews(spec.view)
    for _, view in ipairs(views) do
        local existing = select(1, findShortcutByRef(spec, view))
        local shortcut = select(1, normalizeShortcutSpec(spec, existing, view))

        registerPatchCallback(shortcut.id, view, spec.callback)
        M.upsert(shortcut, view)
        results[view] = M.find(shortcut.key, view)
    end

    if #views == 1 then
        return results[views[1]]
    end
    return results
end

function M.upsertShortcut(spec)
    return M.ensureShortcut(spec)
end

function M.deleteShortcut(ref, view)
    local deleted = false
    for _, candidate in ipairs(normalizeViews(view or (type(ref) == "table" and ref.view) or nil)) do
        local existing, resolved_view = findShortcutByRef(ref, candidate)
        if existing and resolved_view then
            M.delete(existing.key, resolved_view)
            deleted = true
        end
    end
    return deleted
end

function M.getBundledIcon(name)
    if type(name) ~= "string" or name == "" then
        fail("icon name must be a non-empty string")
    end
    return ICON_DIR .. "/" .. name:gsub("^/+", "")
end

function M.openEditDialog(shortcut, menu, on_close, view)
    view = M.normalizeView(view or "reader")
    local is_new = (shortcut == nil)
    local original_name = shortcut and shortcut.name or nil
    local original_callback_label = shortcut and shortcut.callback_label or nil
    local sc = shortcut and {
        key = shortcut.key,
        id = shortcut.id,
        name = shortcut.name,
        icon = shortcut.icon,
        icon_file = shortcut.icon_file,
        patch_callback = shortcut.patch_callback,
        callback_label = shortcut.callback_label,
        path_record = shortcut.path_record,
        dispatcher_action = shortcut.dispatcher_action,
        dispatcher_label = shortcut.dispatcher_label,
    } or {
        key = newKey(),
        id = nil,
        name = "",
        icon = nil,
        icon_file = nil,
        patch_callback = nil,
        callback_label = nil,
        path_record = nil,
        dispatcher_action = nil,
        dispatcher_label = nil,
    }

    local action_label = M.getActionDescription(sc)
    local icon_label = sc.icon_file and sc.icon_file:match("[^/]+$") or sc.icon or _("Default")

    local dialog

    local function doSave()
        local name = dialog:getInputText()
        sc.name = (name ~= "") and name or _("Custom shortcut")
        if sc.patch_callback then
            if not original_callback_label or original_callback_label == original_name or original_callback_label == _("Patch callback") then
                sc.callback_label = sc.name
            end
        end
        M.upsert(sc, view)
        UIManager:close(dialog)
        if on_close then on_close() end
    end

    local function refresh(updated_sc)
        UIManager:close(dialog)
        M.openEditDialog(updated_sc or sc, menu, on_close, view)
    end

    local function snapshotName()
        local name = dialog:getInputText()
        if name ~= "" then sc.name = name end
    end

    local function clearPatchCallback()
        unregisterPatchCallback(sc.id, view)
        sc.patch_callback = nil
        sc.callback_label = nil
    end

    local function applyMenuAction(path_record)
        clearPatchCallback()
        sc.path_record = path_record
        sc.dispatcher_action = nil
        sc.dispatcher_label = nil
        if not sc.name or sc.name == "" then
            sc.name = path_record.display_label
        end
    end

    local function applySystemAction(action)
        clearPatchCallback()
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
        if view ~= "reader" or (menu and menu._is_fb_context) then
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            if not (ok and FileManager.instance and not FileManager.instance.tearing_down) then
                UIManager:show(InfoMessage:new{
                    text = _("Open the file browser first to set this shortcut action."),
                    timeout = 3,
                })
                reopenCurrentDialog()
                return
            end
            FileManager.instance.menu:onShowMenu(nil)
            local menu_container = FileManager.instance.menu.menu_container
            local real_menu = menu_container and menu_container[1]
            if not real_menu then
                UIManager:show(InfoMessage:new{
                    text = _("Could not open the file browser menu."),
                    timeout = 3,
                })
                reopenCurrentDialog()
                return
            end
            local saved_state = snapshotMenuState(real_menu)
            Picker.startPicking(real_menu, sc.key,
                function(path_record)
                    path_record.view = "fb"
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

        if not menu or not menu.updateItems then
            UIManager:show(InfoMessage:new{
                text = _("Open a book first to set this shortcut action."),
                timeout = 3,
            })
            reopenCurrentDialog()
            return
        end

        local saved_state = snapshotMenuState(menu)
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
        {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = doSave,
            },
        },
        {
            {
                text = T(_("Action: %1"), action_label),
                callback = function()
                    snapshotName()
                    UIManager:close(dialog)
                    openActionSourcePicker()
                end,
            },
            {
                text = T(_("Icon: %1"), icon_label),
                callback = function()
                    snapshotName()
                    UIManager:show(IconBrowser:new{
                        path = ICON_DIR,
                        onConfirm = function(file_path)
                            sc.icon = nil
                            sc.icon_file = file_path
                            UIManager:scheduleIn(0, function() refresh(sc) end)
                        end,
                    })
                end,
            },
        },
    }

    if not is_new then
        local ConfirmBox = require("ui/widget/confirmbox")
        table.insert(buttons, {
            {
                text = _("Delete shortcut"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete \"%1\"?"), sc.name or sc.key),
                        ok_text = _("Delete"),
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
        title = is_new and _("New custom shortcut") or _("Edit custom shortcut"),
        input = sc.name or "",
        input_hint = _("Shortcut name"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M.buildSubItems(on_refresh, view)
    view = M.normalizeView(view or "reader")
    local all = M.loadAll(view)
    local items = {}

    local function make_on_close(touchmenu)
        return function()
            if on_refresh then on_refresh() end
            touchmenu.item_table = M.buildSubItems(on_refresh, view)
            touchmenu:updateItems()
        end
    end

    table.insert(items, {
        text = _("Add new shortcut"),
        callback = function(touchmenu)
            M.openEditDialog(nil, touchmenu, make_on_close(touchmenu), view)
        end,
        keep_menu_open = true,
        separator = #all > 0,
    })

    for _i, shortcut in ipairs(all) do
        local shortcut_ref = shortcut
        local action = M.getActionDescription(shortcut_ref):lower()
        table.insert(items, {
            text = (shortcut.name and shortcut.name ~= "") and shortcut.name or _("Unnamed shortcut"),
            mandatory = action,
            keep_menu_open = true,
            callback = function(touchmenu)
                M.openEditDialog(shortcut_ref, touchmenu, make_on_close(touchmenu), view)
            end,
        })
    end

    return items
end

return M
