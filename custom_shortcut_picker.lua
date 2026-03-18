--[[
Custom Shortcut Picker
======================
Enables "selection mode": the user browses the reader TouchMenu normally and
taps any leaf item to record its navigation path instead of executing it.
The stored path is later replayed to trigger the same item on demand.

Persistence is owned by custom_shortcut_manager; this module only handles
picking and replaying.

Public API
----------
  startPicking(menu, slot_key, on_done, on_cancel)
      Enter selection mode.  on_done(path_record) is called when a leaf item
      is tapped; on_cancel() when the user backs out to root.

  replayShortcut(menu, path_record)
      Replay a stored path_record: switch to the recorded tab, drill through
      sub-menus, and execute the final leaf item.

  isPicking()   → bool
  cancelPicking()

path_record format
------------------
Leaf-item shortcut (executes a specific menu action):
  {
    tab_index     = 2,           -- 1-based tab index
    display_label = "Font",      -- human-readable label for the shortcut button
    nav_path      = {            -- intermediate sub-menus to enter (may be empty)
      { id = "change_font", index = 3, text = "Font" },
    },
    view          = "reader",    -- "reader" or "fb"
    item = {
      id    = "font_size",        -- item.menu_item_id (nil when not set)
      index = 5,                  -- positional index (language-independent)
      text  = "Font size",        -- display text (last-resort fallback)
    },
  }

Menu shortcut (opens a menu or sub-menu and leaves it open):
  {
    tab_index     = 2,
    display_label = "Font settings",
    nav_path      = { ... },     -- sub-menus to enter; empty = open at tab root
    view          = "reader",
    is_menu       = true,        -- no 'item' field
  }
--]]

local Blitbuffer   = require("ffi/blitbuffer")
local Button       = require("ui/widget/button")
local InfoMessage  = require("ui/widget/infomessage")
local Size         = require("ui/size")
local TouchMenu    = require("ui/widget/touchmenu")
local UIManager    = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local _            = require("gettext")

-- ==========================================================================
-- Module-level picking state
-- ==========================================================================

local _state = {
    active          = false,
    menu            = nil,
    slot_key        = nil,
    tab_index       = nil,
    nav_path        = nil,   -- list of { id=..., text=... }
    view            = nil,   -- "reader" or "fb"
    on_done         = nil,
    on_cancel       = nil,
    cancel_bar      = nil,   -- Button appended to item_group (cancel picking)
    select_menu_bar = nil,   -- Button appended above cancel_bar (select current menu)
    bars_span       = nil,   -- VerticalSpan between the two bars
}

-- Patching helpers (forward-declared; defined after _installPatches below)
local _stopPicking

-- Originals saved before patching
local _orig_onMenuSelect    = nil
local _orig_backToUpperMenu = nil
local _orig_switchMenuTab   = nil
local _orig_closeMenu       = nil
local _orig_updateItems     = nil

-- ==========================================================================
-- Helpers
-- ==========================================================================

--- Returns true if menu.show_parent is currently in UIManager's window stack.
local function isMenuVisible(menu)
    local target = menu.show_parent
    for _, win in ipairs(UIManager._window_stack) do
        if win.widget == target then return true end
    end
    return false
end

--- Get the display text of a menu item, handling text_func.
local function itemText(item)
    local t = item.text
    if type(t) == "function" then t = t() end
    if not t and item.text_func then t = item.text_func() end
    return type(t) == "string" and t or ""
end

-- Replay temporarily mutates TouchMenu navigation state; snapshot it so we can
-- restore a consistent menu before closing or after partial navigation failures.
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

    menu.cur_tab = state.cur_tab
    menu.item_table = state.item_table
    menu.item_table_stack = {}
    for i, item_table in ipairs(state.item_table_stack or {}) do
        menu.item_table_stack[i] = item_table
    end
    menu.parent_id = nil
    menu.page = state.page or 1
    menu:updateItems(menu.page)
end

--- Derive a human-readable label for the currently displayed menu level.
-- At a sub-menu level: use the last nav_path entry's text.
-- At a tab root: derive from the tab's icon name or fall back to "Menu".
local function getMenuLabel(menu)
    if _state.nav_path and #_state.nav_path > 0 then
        return _state.nav_path[#_state.nav_path].text
    end
    -- Tab root: try to get a name from the tab icon.
    local tab_index = _state.tab_index or 1
    local tab = menu.tab_item_table and menu.tab_item_table[tab_index]
    if tab then
        local icon = tab.icon or ""
        -- Strip common "appbar." prefix, convert dots/underscores to spaces,
        -- then capitalize the first letter.
        local name = icon:gsub("^appbar%.", ""):gsub("[%._]+", " ")
        if name ~= "" then
            return name:sub(1, 1):upper() .. name:sub(2)
        end
    end
    return _("Menu")
end

-- ==========================================================================
-- Picking-mode bars
-- ==========================================================================

--- Build the "select this menu" outline Button (shown above the cancel bar).
local function _makeSelectMenuBar(menu)
    local bar = Button:new{
        text           = _("Tap here to use this menu as the action"),
        width          = menu.item_width,
        text_font_bold = false,
        bordersize     = Size.border.thick,
        show_parent    = menu.show_parent,
        callback       = function()
            if not _state.active then return end
            -- Snapshot nav_path at the moment of the tap.
            local nav_copy = {}
            for i, step in ipairs(_state.nav_path or {}) do
                nav_copy[i] = { id = step.id, index = step.index, text = step.text }
            end
            local label = getMenuLabel(menu)
            local path_record = {
                tab_index     = _state.tab_index,
                display_label = label,
                nav_path      = nav_copy,
                view          = _state.view,
                is_menu       = true,
            }
            local cb = _state.on_done
            _stopPicking()
            if cb then cb(path_record) end
        end,
    }
    -- Button:init() only applies rounded corners and colored border when a
    -- background is set (and then it matches background, hiding the border).
    -- Override the FrameContainer directly to get a gray border + same radius
    -- as the cancel bar without changing the white fill.
    if bar.frame then
        bar.frame.color  = Blitbuffer.COLOR_LIGHT_GRAY
        bar.frame.radius = Size.radius.button
    end
    return bar
end

--- Build the cancel bar Button widget (created once per picking session).
local function _makeCancelBar(menu)
    return Button:new{
        text           = _("Tap here to cancel"),
        width          = menu.item_width,
        text_font_bold = true,
        bordersize     = Size.border.thin,
        background     = Blitbuffer.COLOR_LIGHT_GRAY,
        show_parent    = menu.show_parent,
        callback       = function()
            if _state.active then
                local cb = _state.on_cancel
                _stopPicking()
                if cb then cb() end
            end
        end,
    }
end

-- ==========================================================================
-- Patch management
-- ==========================================================================

local function _installPatches()
    -- Guard against double-patching
    if _orig_onMenuSelect then return end

    _orig_onMenuSelect    = TouchMenu.onMenuSelect
    _orig_backToUpperMenu = TouchMenu.backToUpperMenu
    _orig_switchMenuTab   = TouchMenu.switchMenuTab
    _orig_closeMenu       = TouchMenu.closeMenu
    _orig_updateItems     = TouchMenu.updateItems

    -- Append the select-menu and cancel bars to item_group after every updateItems call.
    TouchMenu.updateItems = function(self, ...)
        local result = _orig_updateItems(self, ...)
        if _state.active and self == _state.menu then
            if not _state.select_menu_bar then
                _state.select_menu_bar = _makeSelectMenuBar(self)
            end
            if not _state.cancel_bar then
                _state.cancel_bar = _makeCancelBar(self)
            end
            -- Insert outline "select" bar above the gray cancel bar.
            table.insert(self.item_group, _state.select_menu_bar)
            if not _state.bars_span then
                _state.bars_span = VerticalSpan:new{ width = Size.padding.default }
            end
            table.insert(self.item_group, _state.bars_span)
            table.insert(self.item_group, _state.cancel_bar)
            -- Reset cached layout so _offsets is recomputed including both bars.
            self.item_group:resetLayout()
            -- Recalculate menu height to include both bars.
            self.dimen.h = self.item_group:getSize().h + self.bordersize * 2 + self.padding
            UIManager:setDirty(self.show_parent, function()
                return "ui", self.dimen
            end)
        end
        return result
    end

    -- Cancel picking if the menu is closed unexpectedly
    TouchMenu.closeMenu = function(self, ...)
        local orig = _orig_closeMenu  -- capture before _stopPicking clears it
        if _state.active and self == _state.menu then
            local cb = _state.on_cancel
            _stopPicking()
            if cb then cb() end
        end
        return orig(self, ...)
    end

    -- Intercept item selection during picking
    TouchMenu.onMenuSelect = function(self, item, tap_on_checkmark)
        if not (_state.active and self == _state.menu) then
            return _orig_onMenuSelect(self, item, tap_on_checkmark)
        end

        -- Determine if this item opens a sub-menu
        local sub = (item.sub_item_table_func and item.sub_item_table_func())
                 or item.sub_item_table

        -- Find the item's position in the current table (language-independent).
        local item_index
        for i, it in ipairs(self.item_table or {}) do
            if it == item then item_index = i; break end
        end

        if sub and #sub > 0 then
            -- Record this navigation step, then let the original proceed
            table.insert(_state.nav_path, {
                id    = item.menu_item_id,
                index = item_index,
                text  = itemText(item),
            })
            return _orig_onMenuSelect(self, item, tap_on_checkmark)
        end

        -- Leaf item tapped – capture it
        local label = itemText(item)
        if label == "" then label = _state.slot_key end
        local path_record = {
            tab_index     = _state.tab_index,
            display_label = label,
            nav_path      = _state.nav_path,   -- already a copy we own
            view          = _state.view,        -- "reader" or "fb"
            item          = {
                id    = item.menu_item_id,
                index = item_index,
                text  = label,
            },
        }

        local cb = _state.on_done
        _stopPicking()
        if cb then cb(path_record) end
        return true
    end

    -- Track back-navigation: pop from our nav_path mirror
    TouchMenu.backToUpperMenu = function(self, no_close)
        local orig = _orig_backToUpperMenu  -- capture before any _stopPicking call
        if _state.active and self == _state.menu then
            if #self.item_table_stack ~= 0 then
                -- Pop the step we recorded when entering this level
                if #_state.nav_path > 0 then
                    table.remove(_state.nav_path)
                end
            else
                -- Already at root → cancel picking
                local cb = _state.on_cancel
                _stopPicking()
                if cb then cb() end
            end
        end
        return orig(self, no_close)
    end

    -- Track tab switches
    TouchMenu.switchMenuTab = function(self, tab_num)
        local orig = _orig_switchMenuTab  -- capture in case _stopPicking is ever called
        if _state.active and self == _state.menu then
            _state.tab_index = tab_num
            _state.nav_path  = {}  -- reset navigation path on tab change
        end
        return orig(self, tab_num)
    end
end

_stopPicking = function()
    local menu            = _state.menu
    local cancel_bar      = _state.cancel_bar
    local select_menu_bar = _state.select_menu_bar
    local bars_span       = _state.bars_span

    _state.cancel_bar      = nil
    _state.select_menu_bar = nil
    _state.bars_span       = nil
    _state.active          = false
    _state.menu            = nil
    _state.slot_key        = nil
    _state.tab_index       = nil
    _state.nav_path        = nil
    _state.view            = nil
    _state.on_done         = nil
    _state.on_cancel       = nil

    -- Remove both bars from item_group and shrink the menu frame back.
    if menu and (cancel_bar or select_menu_bar) then
        local ig = menu.item_group
        for i = #ig, 1, -1 do
            if ig[i] == cancel_bar or ig[i] == select_menu_bar or ig[i] == bars_span then
                table.remove(ig, i)
            end
        end
        ig:resetLayout()
        menu.dimen.h = ig:getSize().h + menu.bordersize * 2 + menu.padding
        UIManager:setDirty(menu.show_parent, function()
            return "ui", menu.dimen
        end)
    end

    UIManager:setDirty("all", "flashui")

    -- Restore originals
    if _orig_onMenuSelect then
        TouchMenu.onMenuSelect    = _orig_onMenuSelect
        TouchMenu.backToUpperMenu = _orig_backToUpperMenu
        TouchMenu.switchMenuTab   = _orig_switchMenuTab
        TouchMenu.closeMenu       = _orig_closeMenu
        TouchMenu.updateItems     = _orig_updateItems
        _orig_onMenuSelect    = nil
        _orig_backToUpperMenu = nil
        _orig_switchMenuTab   = nil
        _orig_closeMenu       = nil
        _orig_updateItems     = nil
    end
end

-- ==========================================================================
-- Public API
-- ==========================================================================

local M = {}

--- Enter selection mode.
-- @param menu      The live TouchMenu instance (already open).
-- @param slot_key  e.g. "custom_1"
-- @param on_done   function(path_record) – called when user taps a leaf item.
-- @param on_cancel function() – called when user backs out to root.
-- @param view      "reader" or "fb" (default "reader") – stored in path_record.
function M.startPicking(menu, slot_key, on_done, on_cancel, view)
    if _state.active then _stopPicking() end

    _state.active    = true
    _state.menu      = menu
    _state.slot_key  = slot_key
    _state.tab_index = 1  -- we switch to tab 1 below
    _state.nav_path  = {}
    _state.view      = view or "reader"
    _state.on_done   = on_done
    _state.on_cancel = on_cancel

    -- Install patches BEFORE switchMenuTab so the first updateItems call
    -- already injects the cancel bar into item_group.
    _installPatches()

    -- If the menu was closed (e.g. user tapped outside during a previous pick),
    -- re-show it before switching tabs.
    if not isMenuVisible(menu) then
        UIManager:show(menu.show_parent)
    end

    -- Navigate to tab 1 so the user starts from a predictable place.
    -- Clear cur_tab first to bypass the "tap same tab → go home" guard in main.lua.
    -- Then use bar:switchToTab so the icon underline/separator visuals update too.
    menu.cur_tab = nil
    menu.bar:switchToTab(1)

    -- Brief informational toast – no tap needed, user sees the cancel bar.
    UIManager:show(InfoMessage:new{
        text    = _("Tap any menu item to assign it as a shortcut."),
        timeout = 3,
    })
end

--- Returns true if selection mode is currently active.
function M.isPicking()
    return _state.active
end

--- Abort an in-progress pick (e.g. when the menu closes unexpectedly).
function M.cancelPicking()
    if _state.active then
        local cb = _state.on_cancel
        _stopPicking()
        if cb then cb() end
    end
end

-- ==========================================================================
-- Replay
-- ==========================================================================

-- Find a menu item: tries explicit menu_item_id → position index → display text.
-- Using index over text makes replay language-independent.
local function findItem(menu, id, index, text)
    local tbl = menu.item_table or {}
    -- 1. Explicit developer-assigned id
    if id then
        for _i, item in ipairs(tbl) do
            if item.menu_item_id and item.menu_item_id == id then
                return item
            end
        end
    end
    -- 2. Display text (breaks on language change)
    if text then
        local text_lower = text:lower()
        for _i, item in ipairs(tbl) do
            local t = itemText(item):lower()
            if t == text_lower then return item end
        end
    end
    -- 3. Positional index (stable across language changes, but breaks if the menu structure changes)
    if index and tbl[index] then
        return tbl[index]
    end
    return nil
end

-- Enter sub-menu for a navigation step. Returns false on failure.
local function enterSubMenu(menu, step)
    local item = findItem(menu, step.id, step.index, step.text)
    if not item then return false end

    local sub = (item.sub_item_table_func and item.sub_item_table_func())
             or item.sub_item_table
    if not sub or #sub == 0 then return false end

    table.insert(menu.item_table_stack, menu.item_table)
    item.menu_item_id = item.menu_item_id or tostring(item)
    menu.parent_id    = item.menu_item_id
    menu.item_table   = sub
    menu.cur_item     = nil
    menu.page         = 1
    menu:updateItems(1)
    return true
end

--- Replay a stored path_record: switch tab, navigate sub-menus, execute leaf.
-- @param menu         The live TouchMenu instance.
-- @param path_record  Table returned by the picker (or loaded from settings).
-- @return true on success, false if navigation failed.
function M.replayShortcut(menu, path_record)
    if not path_record then return false end

    local view = path_record.view

    -- Explicit view routing -----------------------------------------------
    if view == "reader" then
        -- Must have an active ReaderUI.
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        if not (ok and ReaderUI.instance and not ReaderUI.instance.tearing_down) then
            UIManager:show(InfoMessage:new{
                text    = _("This shortcut only works while reading a book."),
                timeout = 3,
            })
            return false
        end
        -- menu should already be the live reader TouchMenu passed in by
        -- home_content; use it directly (it has a real tab_item_table).

    elseif view == "fb" then
        -- Resolve to the live FM TouchMenu.
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        if not (ok and FileManager.instance and not FileManager.instance.tearing_down) then
            UIManager:show(InfoMessage:new{
                text    = _("This shortcut only works in the file browser."),
                timeout = 3,
            })
            return false
        end
        FileManager.instance.menu:onShowMenu(path_record.tab_index)
        local mc = FileManager.instance.menu.menu_container
        if mc and mc[1] then
            menu = mc[1]
        end
        if not menu.tab_item_table or #menu.tab_item_table == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("Could not open menu to run shortcut."),
                timeout = 3,
            })
            return false
        end

    else
        -- Legacy fallback: detect by stub (old saved shortcuts without view field).
        if not menu.tab_item_table or #menu.tab_item_table == 0 then
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            if ok and FileManager.instance and not FileManager.instance.tearing_down then
                FileManager.instance.menu:onShowMenu(path_record.tab_index)
                local mc = FileManager.instance.menu.menu_container
                if mc and mc[1] then
                    menu = mc[1]
                end
            end
            if not menu.tab_item_table or #menu.tab_item_table == 0 then
                UIManager:show(InfoMessage:new{
                    text    = _("Could not open menu to run shortcut."),
                    timeout = 3,
                })
                return false
            end
        end
    end
    -------------------------------------------------------------------------

    local saved_state = snapshotMenuState(menu)

    -- 1. Switch to the recorded tab
    if path_record.tab_index then
        -- Use the raw original if available; otherwise fall through to patched
        local switch = _orig_switchMenuTab or TouchMenu.switchMenuTab
        switch(menu, path_record.tab_index)
    end

    -- 2. Navigate through sub-menus
    for _i, step in ipairs(path_record.nav_path or {}) do
        if not enterSubMenu(menu, step) then
            if isMenuVisible(menu) then
                restoreMenuState(menu, saved_state)
            end
            UIManager:show(InfoMessage:new{
                text    = _("Could not navigate to shortcut — menu layout may have changed."),
                timeout = 3,
            })
            return false
        end
    end

    -- 2b. Menu shortcut: menu is now open at the right level – nothing more to do.
    if path_record.is_menu then
        return true
    end

    -- 3. Find and execute the leaf item
    local leaf = findItem(menu,
        path_record.item and path_record.item.id,
        path_record.item and path_record.item.index,
        path_record.item and path_record.item.text)
    if not leaf then
        if isMenuVisible(menu) then
            restoreMenuState(menu, saved_state)
        end
        UIManager:show(InfoMessage:new{
            text    = _("Could not find shortcut item — menu layout may have changed."),
            timeout = 3,
        })
        return false
    end

    local callback = (leaf.callback_func and leaf.callback_func()) or leaf.callback
    if callback then
        callback(menu)
    end
    -- Close from a consistent top-level state; some callbacks may already close it.
    if isMenuVisible(menu) then
        restoreMenuState(menu, saved_state)
        if isMenuVisible(menu) then
            menu:closeMenu()
        end
    end
    return true
end

return M
