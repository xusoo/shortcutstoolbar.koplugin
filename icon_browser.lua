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

local BD              = require("ui/bidi")
local Device          = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local ImageWidget     = require("ui/widget/imagewidget")
local InputText       = require("ui/widget/inputtext")
local Menu            = require("ui/widget/menu")
local PathChooser     = require("ui/widget/pathchooser")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil         = require("ffi/util")
local util            = require("util")
local _               = require("gettext")
local Screen          = Device.screen

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")

local THUMB_SIZE = Screen:scaleBySize(32)
local THUMB_GAP  = Screen:scaleBySize(6)

-- ---------------------------------------------------------------------------
-- _InnerChooser: PathChooser subclass
-- Handles sorting, thumbnail injection, filtering and tap-to-select.
-- The outer IconBrowser wrapper owns the filter bar and passes a reduced
-- height here so PathChooser's own layout math is never touched.
-- ---------------------------------------------------------------------------
local _InnerChooser = PathChooser:extend{
    select_directory = false,
    select_file      = true,
    state_w          = THUMB_SIZE + THUMB_GAP,
    path             = PLUGIN_DIR .. "/icons",
    onConfirm        = nil,
    _filter_text     = "",
    _all_items       = nil,
    -- Consume all gesture events not handled by children.  Without this flag,
    -- a tap on empty screen space would fall through InputContainer:onGesture
    -- and reach InputDialog's is_always_active Tap handler, closing the
    -- shortcut-editor dialog that lives behind us on the window stack.
    stop_events_propagation  = true,
}

function _InnerChooser:init()
    self.title = _('Choose icon')
    -- Show only SVG files; directories are always shown for navigation.
    self.file_filter = function(filename)
        return filename:lower():match('%.svg$') ~= nil
    end
    -- state_w must be set before PathChooser.init() triggers the first
    -- updateItems() call so that MenuItem reserves the correct left padding.
    self.state_w = Screen:scaleBySize(32) + Screen:scaleBySize(6)
    self._recalculateDimen = _InnerChooser._recalculateDimen
    PathChooser.init(self)
    if not self._all_items then
        self:refreshPath()
    end
end

function _InnerChooser:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    if not self.item_dimen then return end
    -- If a filter bar has been injected into content_group, subtract its height
    -- so items stay clear of the footer.  Menu._recalculateDimen always resets
    -- available_height from scratch on full recalcs, so this is idempotent.
    -- Page-nav passes no_recalculate_dimen=true and Menu returns early, leaving
    -- available_height already correct; we skip in that case too.
    if self._filter_bar_height and self._filter_bar_height > 0
            and not no_recalculate_dimen then
        self.available_height = self.available_height - self._filter_bar_height
        self.item_dimen.h = math.floor(self.available_height / self.perpage)
    end
    local content_w = math.max(0, self.item_dimen.w - 2 * Size.padding.fullscreen)
    local max_state_w = math.max(1, math.floor(content_w / 4))
    local ts = Screen:scaleBySize(32)
    local tg = Screen:scaleBySize(6)
    self.state_w     = math.min(ts + tg, max_state_w)
    self._thumb_size = math.max(0, math.min(ts, self.state_w - tg))
end

function _InnerChooser:getCollate()
    return self.collates.strcoll, "strcoll"
end

function _InnerChooser:refreshPath()
    local _, folder_name = util.splitFilePathName(self.path)
    Screen:setWindowTitle(folder_name)
    self._all_items = self:genItemTableFromPath(self.path)
    self:_applyCurrentFilter()
end

function _InnerChooser:_applyCurrentFilter()
    local filter_text = self._filter_text or ""
    local items
    if filter_text == "" then
        items = self._all_items
    else
        items = {}
        local pattern = filter_text:lower()
        for _, item in ipairs(self._all_items) do
            if item.is_go_up or (item.text and item.text:lower():find(pattern, 1, true)) then
                table.insert(items, item)
            end
        end
    end
    local itemmatch
    if self.focused_path then
        itemmatch = {path = self.focused_path}
        self.focused_path = nil
    end
    local subtitle = BD.directory(filemanagerutil.abbreviate(self.path))
    self:switchItemTable(nil, items, filter_text == "" and self.path_items[self.path] or 1, itemmatch, subtitle)
end

function _InnerChooser:applyFilter(text)
    self._filter_text = text or ""
    if self._all_items then
        self:_applyCurrentFilter()
    end
end

function _InnerChooser:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    self.path_items[self.path] = (self.page - 1) * self.perpage + (select_number or 1)

    local eff_thumb = self._thumb_size or 0
    if eff_thumb <= 0 then return end  -- no thumbnails to inject on very narrow screens

    local item_h   = self.item_dimen and self.item_dimen.h or eff_thumb
    local center_y = math.max(0, math.floor((item_h - eff_thumb) / 2))

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
            width          = eff_thumb,
            height         = eff_thumb,
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
function _InnerChooser:onMenuSelect(item)
    local path = item.path or ""
    if path:lower():match("%.svg$") then
        local real_path = ffiUtil.realpath(path) or path
        UIManager:close(self.show_parent or self)
        if self.onConfirm then
            self.onConfirm(real_path)
        end
        return true
    end
    return PathChooser.onMenuSelect(self, item)
end

function _InnerChooser:onMenuHold(item)
    if (item.path or ""):lower():match("%.svg$") then
        return true
    end
    return PathChooser.onMenuHold(self, item)
end

function _InnerChooser:onClose()
    UIManager:close(self.show_parent or self)
end

-- ---------------------------------------------------------------------------
-- IconBrowser: outer wrapper widget
-- Stacks a filter bar above _InnerChooser.  Pass this to UIManager:show().
-- ---------------------------------------------------------------------------
local IconBrowser = WidgetContainer:extend{
    path      = PLUGIN_DIR .. "/icons",
    onConfirm = nil,
    -- NOTE: covers_fullscreen is intentionally NOT set here.
    -- SimpleUI patches UIManager.close and re-opens its homescreen whenever a
    -- covers_fullscreen widget closes (when "Start with Homescreen" is on).
    -- IconBrowser is a transient overlay, not a navigation destination, so we
    -- must not trigger that logic.  The minor overhead of UIManager repainting
    -- the InputDialog that sits below us is perfectly acceptable.
}

function IconBrowser:init()
    self.dimen = Geom:new{x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()}

    self._filter_input = InputText:new{
        text      = "",
        hint      = _("Filter by name\226\128\166"),
        width     = self.dimen.w - 2 * Size.padding.default,
        height    = nil,
        face      = Font:getFace("smallinfofont"),
        padding   = Size.padding.small,
        margin    = 0,
        bordersize = Size.border.inputtext,
        parent    = self,
        scroll    = false,
        focused   = false,
        edit_callback = function()
            self:_applyFilter()
        end,
    }
    self._filter_bar = FrameContainer:new{
        padding        = Size.padding.default,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        bordersize     = 0,
        self._filter_input,
    }
    local filter_h = self._filter_bar:getSize().h

    -- Give _InnerChooser the full screen height.  We insert the filter bar
    -- into its content_group below; _InnerChooser._recalculateDimen will
    -- subtract filter_h so item rows always stay clear of the footer.
    -- close_callback uses Menu's standard hook so X closes IconBrowser
    -- without any onClose override.
    self._chooser = _InnerChooser:new{
        show_parent    = self,
        path           = self.path,
        onConfirm      = self.onConfirm,
        height         = self.dimen.h,
        close_callback = function() self:onClose() end,
    }
    -- Insert the filter bar between the title bar and the item list.
    -- content_group[1] = title bar, content_group[2] = item_group.
    -- Set _filter_bar_height AFTER insertion so the initial refreshPath
    -- (called inside _InnerChooser:init) sizes items without the deduction;
    -- we then reload below with the correct sizing.
    table.insert(self._chooser.content_group, 2, self._filter_bar)
    self._chooser._filter_bar_height = filter_h
    self._chooser:refreshPath()

    self[1] = self._chooser
end

function IconBrowser:_applyFilter()
    if not self._chooser then return end
    local text = self._filter_input and self._filter_input:getText() or ""
    self._chooser:applyFilter(text)
end

-- InputText calls this on the parent when a DPad is available.
-- IconBrowser is a plain WidgetContainer with no FocusManager, so stub it out.
function IconBrowser:getFocusableWidgetXY()
    return nil, nil
end

function IconBrowser:onClose()
    if self._filter_input then
        self._filter_input:onCloseKeyboard()
    end
    UIManager:close(self)
end

return IconBrowser
