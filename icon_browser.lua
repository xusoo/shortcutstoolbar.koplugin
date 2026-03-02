--[[
Icon Browser
============
A PathChooser subclass that shows inline SVG thumbnails for every icon file
while browsing, and selects a file immediately on tap (no confirmation
dialog required).

Thumbnails are injected directly into each MenuItem's OverlapGroup after the
standard updateItems() builds the rows — the same technique used by the
CoverBrowser's MosaicMenu for book-cover injection.

Callers provide:
  path      – starting directory (optional; defaults to the plugin's icons/)
  onConfirm – function(file_path) called with the chosen absolute path

Usage:
  local IconBrowser = require("icon_browser")
  UIManager:show(IconBrowser:new{
      path      = "/path/to/start",
      onConfirm = function(p) ... end,
  })
--]]

local Device      = require("device")
local ImageWidget = require("ui/widget/imagewidget")
local Menu        = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local UIManager   = require("ui/uimanager")
local ffiUtil     = require("ffi/util")
local _           = require("gettext")

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")

-- Size of the inline thumbnail rendered next to each icon filename.
local THUMB_SIZE = Device.screen:scaleBySize(32)
-- Gap between the thumbnail and the filename text.
local THUMB_GAP  = Device.screen:scaleBySize(6)

local IconBrowser = PathChooser:extend{
    -- Allow files only; directories are still shown for navigation.
    select_directory = false,
    select_file      = true,
    -- Reserve horizontal space for the thumbnail column so that text on
    -- all rows (including directory rows) is consistently indented.
    state_w          = THUMB_SIZE + THUMB_GAP,
    -- Default starting path; caller may override with a different directory.
    path             = PLUGIN_DIR .. "/icons",
    -- Must be provided by the caller.
    onConfirm        = nil,
}

function IconBrowser:init()
    self.title = _("Choose icon")
    -- Show only SVG files; directories are always shown for navigation.
    self.file_filter = function(filename)
        return filename:lower():match("%.svg$") ~= nil
    end
    -- state_w must be set before PathChooser.init() triggers the first
    -- updateItems() call so that MenuItem reserves the correct left padding.
    self.state_w = THUMB_SIZE + THUMB_GAP
    -- CoverBrowser may patch FileChooser._recalculateDimen with a version
    -- (e.g. MosaicMenu._recalculateDimen) that does not set self.font_size.
    -- Since updateItems() bypasses FileChooser and calls Menu.updateItems
    -- directly, ensure we always use the standard Menu._recalculateDimen.
    self._recalculateDimen = Menu._recalculateDimen
    PathChooser.init(self)
end

-- ---------------------------------------------------------------------------
-- Inline thumbnail injection (MosaicMenu-style)
-- ---------------------------------------------------------------------------
-- After the standard updateItems() creates MenuItem widgets, we walk the
-- item_group and, for every SVG row, insert an ImageWidget directly into
-- the OverlapGroup that lives inside _underline_container.
--
-- MenuItem widget tree:
--   FrameContainer
--     HorizontalGroup (hgroup)
--       HorizontalSpan (items_padding)
--       UnderlineContainer  (_underline_container)
--         HorizontalGroup            [1]
--           OverlapGroup             [1][1]
--             state_container        – left panel, sized to state_w
--             text_container         – text, indented by state_w via HSpan
--             mandatory_container    – right panel (file size / date)
--       HorizontalSpan (padding)
--
-- We insert our ImageWidget at position 1 of the OverlapGroup (painted
-- first, i.e., behind the text) with overlap_offset to centre it
-- vertically in the row.
function IconBrowser:updateItems(select_number, no_recalculate_dimen)
    -- Call Menu:updateItems directly.  CoverBrowser patches FileChooser.updateItems
    -- on the class to use its tile renderer; bypassing that keeps us in standard
    -- single-column list mode so the OverlapGroup injection below works correctly.
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    -- Replicate the one extra line FileChooser.updateItems normally appends.
    self.path_items[self.path] = (self.page - 1) * self.perpage + (select_number or 1)

    local item_h   = self.item_dimen and self.item_dimen.h or THUMB_SIZE
    local center_y = math.max(0, math.floor((item_h - THUMB_SIZE) / 2))

    for _, item_widget in ipairs(self.item_group) do
        local entry = item_widget.entry
        if not entry then goto continue end
        local filepath = entry.path or ""
        if not filepath:lower():match("%.svg$") then goto continue end

        -- Navigate to the OverlapGroup: _underline_container[1][1]
        local uc = item_widget._underline_container
        if not uc then goto continue end
        local hg = uc[1]       -- HorizontalGroup
        if not hg then goto continue end
        local og = hg[1]       -- OverlapGroup
        if not og then goto continue end

        -- Insert the thumbnail at index 1 so it is painted behind the text.
        table.insert(og, 1, ImageWidget:new{
            file           = filepath,
            width          = THUMB_SIZE,
            height         = THUMB_SIZE,
            alpha          = true,
            overlap_offset = { 0, center_y },
        })
        -- Invalidate the OverlapGroup's cached size so getSize() recomputes
        -- on the next paintTo call (harmless; max dims won't change).
        og._size = nil

        ::continue::
    end
end

-- ---------------------------------------------------------------------------
-- Direct tap-to-select (no confirmation dialog)
-- ---------------------------------------------------------------------------
-- Tapping an SVG file immediately calls onConfirm and closes the browser.
-- Tapping a directory navigates into it as usual.
function IconBrowser:onMenuSelect(item)
    local path = item.path or ""
    if path:lower():match("%.svg$") then
        local real_path = ffiUtil.realpath(path) or path
        UIManager:close(self)
        if self.onConfirm then
            self.onConfirm(real_path)
        end
        return true
    end
    -- Directory – delegate to PathChooser's navigation logic.
    return PathChooser.onMenuSelect(self, item)
end

-- Swallow hold events on SVG files so no PathChooser confirmation appears.
function IconBrowser:onMenuHold(item)
    if (item.path or ""):lower():match("%.svg$") then
        return true
    end
    return PathChooser.onMenuHold(self, item)
end

return IconBrowser
