--[[
Shortcuts Config Dialog
========================
Two-bar dialog: INACTIVE (top) and ACTIVE (bottom).
Tap an icon to select it, then use Enable/Disable to move between bars
and the arrow buttons to reorder within the active bar.
--]]

local Blitbuffer       = require("ffi/blitbuffer")
local Button           = require("ui/widget/button")
local CenterContainer  = require("ui/widget/container/centercontainer")
local IconWidget       = require("ui/widget/iconwidget")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local InputContainer   = require("ui/widget/container/inputcontainer")
local LineWidget       = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local Size             = require("ui/size")
local Screen           = Device.screen
local BD               = require("ui/bidi")
local datetime         = require("datetime")
local _                = require("gettext")

local SHORTCUT_DATA    = require("shortcuts_data")
local packIntoRows     = require("shared_layout")

local ITEM_BY_KEY = {}
for _, item in ipairs(SHORTCUT_DATA) do
    ITEM_BY_KEY[item.key] = item
end

-- sizes
local CELL_ICON         = Screen:scaleBySize(22)
local CELL_PAD          = Screen:scaleBySize(SHORTCUT_DATA.ITEM_SPACING)
local CELL_GAP          = 0                        -- icons are flush, padding provides the gap
local CELL_SIZE         = CELL_ICON + 2 * CELL_PAD
local SPACER_W_DISABLED = CELL_SIZE
local V_GAP             = Screen:scaleBySize(8)
local MARGIN            = Screen:scaleBySize(12)
local BTN_W             = Screen:scaleBySize(96)

local function vspace(w, h)
    return LineWidget:new{
        dimen      = Geom:new{ w = w, h = h },
        background = Blitbuffer.COLOR_WHITE,
    }
end

--- Thin horizontal spacer for use inside HorizontalGroup rows.
local function hspace(px) return vspace(Screen:scaleBySize(px), 1) end

--- Horizontal divider line at full dialog width.
-- Pass dlg_width explicitly so this can live at module level.
local function separator(dlg_width, size, color)
    return LineWidget:new{
        dimen      = Geom:new{ w = dlg_width, h = Screen:scaleBySize(size or 1) },
        background = color or Blitbuffer.COLOR_DARK_GRAY,
    }
end

--- Small uppercase section label in dark gray.
local function sectionLabel(txt)
    return TextWidget:new{
        text    = txt,
        face    = Font:getFace("infofont", 11),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
end

-- ==========================================================================

local ShortcutsConfigDialog = InputContainer:extend{
    enabled_keys  = nil,   -- ordered list of active shortcut keys
    disabled_keys = nil,   -- list of inactive shortcut keys
    view          = nil,   -- "reader" or "fb" – used to load custom shortcuts
    on_save       = nil,   -- function(enabled_keys, disabled_keys)
    _sel          = nil,   -- { bar = "enabled"|"disabled", idx = N } or nil
    _movable      = nil,
    _item_lookup  = nil,   -- merged ITEM_BY_KEY + custom shortcuts for this view
}

function ShortcutsConfigDialog:_buildCell(bar, idx, override_w)
    local keys = (bar == "enabled") and self.enabled_keys or self.disabled_keys
    local key  = keys[idx]
    local info = (self._item_lookup or ITEM_BY_KEY)[key] or { label = key, icon = nil }
    local sel  = self._sel and self._sel.bar == bar and self._sel.idx == idx
    local border_thick = Screen:scaleBySize(sel and 1 or 0)

    local function on_tap()
        if self._sel and self._sel.bar == bar and self._sel.idx == idx then
            self._sel = nil
        else
            self._sel = { bar = bar, idx = idx }
        end
        self:_rebuild()
    end

    -- Spacer: always visible light border, expand arrow
    if key == "spacer" or key == "spacer2" then
        local w = override_w or SPACER_W_DISABLED
        return Button:new{
            text           = "\xe2\x86\x94",  -- ↔
            text_font_size = 14,
            width          = w,
            height         = CELL_SIZE,
            radius         = 0,
            bordersize     = border_thick,
            border_color   = sel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
            callback       = on_tap,
        }
    end

    if info.icon or info.icon_file then
        -- Build Button in icon-mode (named icon, or a placeholder for geometry)
        local btn = Button:new{
            icon        = info.icon or "notice-info",
            icon_width  = CELL_ICON,
            icon_height = CELL_ICON,
            width       = CELL_SIZE,
            height      = CELL_SIZE,
            radius      = 0,
            bordersize  = border_thick,
            callback    = on_tap,
        }
        -- For file-based icons, swap out the internal IconWidget so the correct image shows.
        if info.icon_file then
            local img = IconWidget:new{ file = info.icon_file, width = CELL_ICON, height = CELL_ICON }
            if btn.label_widget then btn.label_widget:free() end
            btn.label_widget = img
            if btn.label_container then btn.label_container[1] = img end
        end
        return btn
    else
        -- Build a stable explicit width based on the WIDEST possible text,
        -- so row-splitting is consistent no matter what the current time/battery is.
        local preview
        if key == "time" then
            local twelve = G_reader_settings:isTrue("twelve_hour_clock")
            preview  = BD.wrap(datetime.secondsToHour(os.time(), twelve))
        elseif key == "battery" then
            if Device:hasBattery() then
                local powerd = Device:getPowerDevice()
                local lvl    = powerd:getCapacity()
                local symbol = powerd:getBatterySymbol(
                    powerd:isCharged(), powerd:isCharging(), lvl)
                preview = BD.wrap("⌁") .. BD.wrap(symbol) .. BD.wrap(lvl .. "%")
            else
                preview = "—"
            end
        else
            preview  = info.label:sub(1, 4)
        end

        -- Measure text at the same font Button will actually use,
        -- then set an explicit width so getSize().w is deterministic.
        local pad = Screen:scaleBySize(6)
        local tmp = TextWidget:new{
            text = preview,
            face = Font:getFace("cfont", 18),
            bold = false,
        }
        local btn_width = tmp:getSize().w + 2 * pad + 2
        tmp:free()

        return Button:new{
            text           = preview,
            text_font_face = "cfont",
            text_font_size = 18,
            text_font_bold = false,
            width          = btn_width,
            padding_h      = pad,
            height         = CELL_SIZE,
            radius         = 0,
            bordersize     = border_thick,
            callback       = on_tap,
        }
    end
end

function ShortcutsConfigDialog:_buildBar(bar, bar_width)
    local keys = (bar == "enabled") and self.enabled_keys or self.disabled_keys

    if #keys == 0 then
        local msg = (bar == "enabled")
            and _("No active shortcuts")
             or _("No inactive shortcuts")
        return CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = CELL_SIZE },
            TextWidget:new{
                text    = msg,
                face    = Font:getFace("infofont", 14),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end

    -- 1. Pre-build non-spacer cells so we know their widths.
    local cells = {}
    for idx = 1, #keys do
        local k = keys[idx]
        if k == "spacer" or k == "spacer2" then
            table.insert(cells, { idx = idx, is_spacer = true })
        else
            local widget = self:_buildCell(bar, idx, nil)
            table.insert(cells, { idx = idx, widget = widget, width = widget:getSize().w })
        end
    end

    -- Disabled bar: spacers count as SPACER_W_DISABLED toward overflow.
    -- Enabled bar:  spacers are elastic (count as 0, never cause overflow).
    local spacer_layout_w = (bar == "disabled") and SPACER_W_DISABLED or 0
    local rows = packIntoRows(cells, bar_width, spacer_layout_w)

    -- 3. Build each row, expanding spacers to fill remaining width (enabled bar)
    --    or using SPACER_W_DISABLED (inactive bar).
    local vg = VerticalGroup:new{ align = "center" }
    for ri, row in ipairs(rows) do
        local fixed_w, spacer_cnt = 0, 0
        for _, cell in ipairs(row) do
            if cell.is_spacer then spacer_cnt = spacer_cnt + 1
            else fixed_w = fixed_w + cell.width end
        end
        local row_spacer_w = (bar == "enabled" and spacer_cnt > 0)
            and math.max(CELL_SIZE, math.floor((bar_width - fixed_w) / spacer_cnt))
            or  SPACER_W_DISABLED

        local hg = HorizontalGroup:new{ align = "center" }
        for _, cell in ipairs(row) do
            if cell.is_spacer then
                hg[#hg + 1] = self:_buildCell(bar, cell.idx, row_spacer_w)
            else
                hg[#hg + 1] = cell.widget
            end
        end
        vg[#vg + 1] = CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = CELL_SIZE + 4 },
            hg,
        }
        if ri < #rows then
            vg[#vg + 1] = vspace(1, Screen:scaleBySize(4))
        end
    end

    return #rows == 1 and vg[1] or vg
end

function ShortcutsConfigDialog:init()
    -- Build a per-instance item lookup merging static shortcuts with custom
    -- shortcuts for the relevant view ("reader" or "fb").
    local ok, Manager = pcall(require, "custom_shortcut_manager")
    if ok then
        self._item_lookup = setmetatable({}, { __index = ITEM_BY_KEY })
        for _i, item in ipairs(Manager.getShortcutDataItems(self.view)) do
            self._item_lookup[item.key] = item
        end
    else
        self._item_lookup = ITEM_BY_KEY
    end

    self.dimen = Screen:getSize()

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    local dlg_width    = sw - MARGIN * 2
    local BAR_PADDING  = Screen:scaleBySize(6)
    local bar_inner_w  = dlg_width - 2 * BAR_PADDING

    -- selected item label / hint
    local sel_label
    local sel_is_hint = false
    if self._sel then
        local key = (self._sel.bar == "enabled")
            and self.enabled_keys[self._sel.idx]
            or  self.disabled_keys[self._sel.idx]
        sel_label = (self._item_lookup[key] or { label = key }).label
    else
        sel_label   = _("Tap an icon to select it")
        sel_is_hint = true
    end

    local sel_text = CenterContainer:new{
        dimen = Geom:new{
            w = bar_inner_w / 2,
            h = Screen:scaleBySize(28),
        },
        TextWidget:new{
            text    = sel_label,
            face    = Font:getFace("infofont", 14),
            fgcolor = sel_is_hint and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
        },
    }

    local sel_enabled  = self._sel and self._sel.bar == "enabled"
    local sel_disabled = self._sel and self._sel.bar == "disabled"

    local btn_enable = Button:new{
        text     = _("Enable") .. " \xe2\x86\x93",
        enabled  = sel_disabled == true,
        width    = BTN_W,
        bordersize = Size.border.default,
        callback = function() self:_move("enable") end,
    }
    local btn_disable = Button:new{
        text     = "\xe2\x86\x91 " .. _("Disable"),
        enabled  = sel_enabled == true,
        width    = BTN_W,
        bordersize = Size.border.default,
        callback = function() self:_move("disable") end,
    }

    local middle_row = HorizontalGroup:new{ align = "center" }
    middle_row[1] = btn_enable
    middle_row[2] = FrameContainer:new{
        bordersize    = 0,
        padding_left  = Screen:scaleBySize(4),
        padding_right = Screen:scaleBySize(4),
        sel_text,
    }
    middle_row[3] = btn_disable

    local NAV_W = Screen:scaleBySize(56)
    local function navBtn(icon, dir)
        return Button:new{
            icon     = icon,
            icon_width = Screen:scaleBySize(20),
            icon_height = Screen:scaleBySize(32),
            enabled  = sel_enabled,
            width    = NAV_W,
            bordersize = Size.border.default,
            callback = function() self:_move(dir) end,
        }
    end
    local reorder_row = HorizontalGroup:new{ align = "center" }
    reorder_row[#reorder_row + 1] = navBtn("chevron.first", "first")
    reorder_row[#reorder_row + 1] = hspace(6)
    reorder_row[#reorder_row + 1] = navBtn("chevron.left", "left")
    reorder_row[#reorder_row + 1] = hspace(24)
    reorder_row[#reorder_row + 1] = navBtn("chevron.right", "right")
    reorder_row[#reorder_row + 1] = hspace(6)
    reorder_row[#reorder_row + 1] = navBtn("chevron.last", "last")

    local function barFrame(bar)
        return FrameContainer:new{
            bordersize = 0,
            padding    = BAR_PADDING,
            width      = dlg_width,
            self:_buildBar(bar, bar_inner_w),
        }
    end

    -- Padded wrapper: full dialog width, content centered, no border
    local function padded(vg, pad_top, pad_bottom)
        local vg_h = vg:getSize().h
        return FrameContainer:new{
            bordersize     = 0,
            width          = dlg_width,
            padding_left   = 0,
            padding_right  = 0,
            padding_top    = pad_top    or 0,
            padding_bottom = pad_bottom or 0,
            CenterContainer:new{
                dimen = Geom:new{ w = dlg_width, h = vg_h },
                vg,
            },
        }
    end

    -- Section above the INACTIVE bar
    local top_section = padded(sectionLabel(_("INACTIVE")),
        Screen:scaleBySize(10), Screen:scaleBySize(4))

    -- Middle section between bars: enable/disable buttons + ACTIVE label
    local mid_vg = VerticalGroup:new{ align = "center" }
    mid_vg[#mid_vg + 1] = vspace(1, V_GAP)
    mid_vg[#mid_vg + 1] = vspace(1, V_GAP)
    mid_vg[#mid_vg + 1] = middle_row
    mid_vg[#mid_vg + 1] = vspace(1, V_GAP)
    mid_vg[#mid_vg + 1] = vspace(1, V_GAP)
    mid_vg[#mid_vg + 1] = sectionLabel(_("ACTIVE"))
    local mid_section = padded(mid_vg, 0, Screen:scaleBySize(4))

    -- Bottom section below the ACTIVE bar: reorder buttons
    local bot_vg = VerticalGroup:new{ align = "center" }
    bot_vg[#bot_vg + 1] = vspace(1, V_GAP)
    bot_vg[#bot_vg + 1] = reorder_row
    local bot_section = padded(bot_vg, 0, Screen:scaleBySize(18))

    local title_bar = TitleBar:new{
        width            = dlg_width,
        align            = "left",
        title            = _("Configure shortcuts"),
        with_bottom_line = true,
        close_callback   = function() self:_close() end,
    }

    -- Bars go directly into dialog_body at full dlg_width (no side margins)
    local dialog_body = VerticalGroup:new{ align = "left" }
    dialog_body[#dialog_body + 1] = title_bar
    dialog_body[#dialog_body + 1] = top_section
    dialog_body[#dialog_body + 1] = separator(dlg_width)
    dialog_body[#dialog_body + 1] = barFrame("disabled")
    dialog_body[#dialog_body + 1] = separator(dlg_width)
    dialog_body[#dialog_body + 1] = mid_section
    dialog_body[#dialog_body + 1] = separator(dlg_width)
    dialog_body[#dialog_body + 1] = barFrame("enabled")
    dialog_body[#dialog_body + 1] = separator(dlg_width)
    dialog_body[#dialog_body + 1] = bot_section

    local frame = FrameContainer:new{
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        background = Blitbuffer.COLOR_WHITE,
        padding    = 0,
        dialog_body,
    }

    self._movable = MovableContainer:new{ frame }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        self._movable,
    }

    self.ges_events.TapClose = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
end

function ShortcutsConfigDialog:_rebuild()
    self:free()
    self:init()
    UIManager:setDirty(self, function()
        return "ui", self._movable and self._movable.dimen
    end)
end

function ShortcutsConfigDialog:_move(action)
    if action == "enable" then
        if not (self._sel and self._sel.bar == "disabled") then return end
        local key = table.remove(self.disabled_keys, self._sel.idx)
        table.insert(self.enabled_keys, key)
        self._sel = { bar = "enabled", idx = #self.enabled_keys }
        self:_rebuild()

    elseif action == "disable" then
        if not (self._sel and self._sel.bar == "enabled") then return end
        local key = table.remove(self.enabled_keys, self._sel.idx)
        table.insert(self.disabled_keys, key)
        self._sel = { bar = "disabled", idx = #self.disabled_keys }
        self:_rebuild()

    else
        if not (self._sel and self._sel.bar == "enabled") then return end
        local n   = #self.enabled_keys
        local sel = self._sel.idx
        local new_pos
        if     action == "left"  then new_pos = sel - 1
        elseif action == "right" then new_pos = sel + 1
        elseif action == "first" then new_pos = 1
        elseif action == "last"  then new_pos = n
        end
        if not new_pos then return end
        new_pos = math.max(1, math.min(n, new_pos))
        if new_pos == sel then return end
        local key = table.remove(self.enabled_keys, sel)
        table.insert(self.enabled_keys, new_pos, key)
        self._sel = { bar = "enabled", idx = new_pos }
        self:_rebuild()
    end
end

function ShortcutsConfigDialog:_close()
    if self.on_save then
        self.on_save(self.enabled_keys, self.disabled_keys)
    end
    UIManager:close(self)
end

-- UIManager / event callbacks

function ShortcutsConfigDialog:onClose()
    self:_close()
    return true
end

-- Called for taps anywhere on screen (full-screen gesture range).
function ShortcutsConfigDialog:onTapClose(_, ges)
    if self._movable and self._movable.dimen
            and not ges.pos:intersectWith(self._movable.dimen) then
        self:_close()
    end
    return true
end

function ShortcutsConfigDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self._movable and self._movable.dimen
    end)
end

function ShortcutsConfigDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "flashui", self._movable and self._movable.dimen
    end)
end

function ShortcutsConfigDialog:paintTo(...)
    InputContainer.paintTo(self, ...)
    if self._movable then
        self.dimen = self._movable.dimen
    end
end

return ShortcutsConfigDialog
