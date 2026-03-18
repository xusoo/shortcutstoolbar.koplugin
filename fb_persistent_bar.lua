--[[
File-Browser Persistent Bar
===========================
Manages the "Persistent bar at top" placement for the file-browser toolbar.

The bar is inserted directly into the FileChooser's content_group VerticalGroup,
between the title bar (position 1) and the item list (position 2).  This keeps
it within the normal widget tree so positioning and repaints work automatically.

  content_group = VerticalGroup{
    [1] title_bar
    [2] ← our bar widget (when active)
    [3] item_group (file list)
  }

To compensate for the reduced available area, Menu.inner_dimen.h is shrunk by
the bar height and _recalculateDimen + updateItems are called to reflow the list.

Public API:
  M.inject(fb_config)  – activate / refresh bar (idempotent)
  M.remove()           – deactivate bar and restore list
--]]

local Device    = require("device")
local Screen    = Device.screen
local UIManager = require("ui/uimanager")

local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer     = require("ffi/blitbuffer")

local M = {}

-- Module-level state.
local _saved_inner_h = nil -- original inner_dimen.h before shrinking

-- ==========================================================================
-- Helpers
-- ==========================================================================

--- Build bar content by reusing createHomeContent with a minimal fake menu.
local function buildBarContent(fc, fb_config)
    local HomeContent = require("home_content")
    local width = fc.inner_dimen and fc.inner_dimen.w or fc.dimen and fc.dimen.w or Screen:getWidth()
    local fake_menu = {
        width            = width,
        dimen            = { w = width },
        inner_dimen      = { w = width },
        tab_item_table   = {},
        item_table       = {},
        item_table_stack = {},
        page             = 1,
        close_callback   = nil,
        _is_fb_context   = true,
    }
    local on_refresh = function()
        M.inject(fb_config)
    end
    local ok, content = pcall(HomeContent.createHomeContent, fake_menu, fb_config, on_refresh)
    return ok and content or nil
end

--- Return the live FileChooser, or nil.
local function getFileChooser()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok then return nil end
    local fm = FileManager.instance
    if not (fm and fm.file_chooser and fm.file_chooser.content_group) then
        return nil
    end
    return fm.file_chooser
end

--- Remove any existing bar widget from content_group (by sentinel flag).
local function removeFromContentGroup(fc)
    local cg = fc.content_group
    if not cg then return end
    for i = #cg, 1, -1 do
        if cg[i] and cg[i]._is_persistent_bar then
            table.remove(cg, i)
        end
    end
end

--- Restore inner_dimen.h and reflow the file list.
local function restoreLayout(fc)
    if _saved_inner_h then
        fc.inner_dimen.h = _saved_inner_h
        _saved_inner_h   = nil
    end
    fc:_recalculateDimen()
    fc:updateItems()
    UIManager:setDirty(fc, "ui")
end

-- ==========================================================================
-- Public API
-- ==========================================================================

--- Activate or refresh the persistent bar.
-- Safe to call repeatedly – removes any existing bar first.
function M.inject(fb_config)
    M.remove()

    local fc = getFileChooser()
    if not fc then return end  -- FM not ready yet; main.lua schedules a retry

    local content = buildBarContent(fc, fb_config)
    if not content then return end

    -- Wrap in a FrameContainer for a clean white background.
    local frame = FrameContainer:new{
        padding    = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        _is_persistent_bar = true,
        content,
    }
    frame._is_persistent_bar = true

    local bar_h = frame:getSize().h

    -- Shrink inner_dimen so _recalculateDimen computes fewer rows.
    if _saved_inner_h == nil then
        _saved_inner_h = fc.inner_dimen.h
    end
    fc.inner_dimen.h = _saved_inner_h - bar_h

    -- Insert between title_bar (idx 1) and item_group (idx 2).
    local cg = fc.content_group
    table.insert(cg, 2, frame)

    fc:_recalculateDimen()
    fc:updateItems()
    UIManager:setDirty(fc, "ui")
end

--- Deactivate the persistent bar and restore the file list.
function M.remove()
    local fc = getFileChooser()
    if fc then
        removeFromContentGroup(fc)
        restoreLayout(fc)
    end
    _saved_inner_h = nil
end

return M
