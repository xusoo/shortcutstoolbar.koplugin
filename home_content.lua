--[[
Home Content
============
Builds the reader-menu "home" area shown when no tab is selected:
  • Top row   – book info panel (left) and time/battery (right)
  • Bottom row – "Back to library" button (left) and shortcuts icons (right)

Exports:
  createHomeContent(menu, config)
--]]

local BD       = require("ui/bidi")
local Device   = require("device")
local Event    = require("ui/event")
local Font     = require("ui/font")
local Geom     = require("ui/geometry")
local Size     = require("ui/size")
local UIManager = require("ui/uimanager")
local Screen   = Device.screen
local datetime = require("datetime")
local _        = require("gettext")

local createBookInfoPanel = require("book_info_panel")

local Button          = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local InfoMessage     = require("ui/widget/infomessage")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local NetworkMgr      = require("ui/network/manager")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

-- ==========================================================================
-- Helpers
-- ==========================================================================

local function getTimeText()
    return BD.wrap(datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")))
end

local function getBatteryText()
    if not Device:hasBattery() then return "" end
    local powerd    = Device:getPowerDevice()
    local lvl       = powerd:getCapacity()
    local symbol    = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), lvl)
    local text      = BD.wrap("⌁") .. BD.wrap(symbol) .. BD.wrap(lvl .. "%")
    if Device:hasAuxBattery() and powerd:isAuxBatteryConnected() then
        local aux_lvl    = powerd:getAuxCapacity()
        local aux_symbol = powerd:getBatterySymbol(powerd:isAuxCharged(), powerd:isAuxCharging(), aux_lvl)
        text = text .. " " .. BD.wrap("+") .. BD.wrap(aux_symbol) .. BD.wrap(aux_lvl .. "%")
    end
    return text
end

--- Navigate a TouchMenu into a sub-item identified by ID string or predicate.
-- Returns true on success.
local function drillDownToItem(menu, matcher)
    if not menu.item_table then return false end

    local found
    for _, item in ipairs(menu.item_table) do
        if type(matcher) == "string" then
            if item.menu_item_id == matcher then
                found = item; break
            end
        elseif type(matcher) == "function" then
            if matcher(item) then
                found = item; break
            end
        end
    end
    if not found then return false end

    local sub_table = found.sub_item_table
        or (found.sub_item_table_func and found.sub_item_table_func())
    if not sub_table then return false end

    if not menu.item_table_stack then menu.item_table_stack = {} end
    table.insert(menu.item_table_stack, {
        item_table = menu.item_table,
        last_page  = menu.page or 1,
        title      = menu.input_title and menu.input_title:getText() or "",
    })

    menu.item_table = sub_table
    menu.cur_item   = nil
    menu.page       = 1

    local target_id = sub_table.open_on_menu_item_id_func
        and sub_table.open_on_menu_item_id_func()
    menu:updateItems(nil, target_id)
    return true
end

-- ==========================================================================
-- Shortcut definitions
-- ==========================================================================

--- Build the table of available shortcut icon definitions for the given menu.
local function buildShortcutDefs(menu)
    return {
        font = {
            icon        = "appbar.textsize",
            description = _("Font"),
            callback    = function()
                -- Switch to the Typeset tab first
                if menu.tab_item_table then
                    local found = false
                    for i, tab in ipairs(menu.tab_item_table) do
                        if tab.icon == "appbar.typeset" or tab.menu_item_id == "typeset" then
                            menu:switchMenuTab(i)
                            found = true
                            break
                        end
                    end
                    if not found and #menu.tab_item_table >= 2 then
                        menu:switchMenuTab(2)
                    end
                end
                -- Drill down to the font submenu
                local ok = drillDownToItem(menu, "change_font")
                if not ok then
                    drillDownToItem(menu, function(item)
                        local text = item.text or (item.text_func and item.text_func())
                        return type(text) == "string"
                            and (text:find("Font") or text:find("font"))
                    end)
                end
            end,
        },
        frontlight = {
            icon        = "appbar.contrast",
            description = _("Frontlight"),
            callback    = function()
                UIManager:broadcastEvent(Event:new("ShowFlDialog"))
            end,
        },
        wifi = {
            icon        = NetworkMgr:isWifiOn() and "wifi" or "wifi.open.0",
            description = _("Wi-Fi"),
            callback    = function(btn)
                UIManager:broadcastEvent(Event:new("ToggleWifi"))
                btn:setIcon(btn.icon == "wifi" and "wifi.open.0" or "wifi")
                UIManager:setDirty(btn, "ui")
            end,
        },
        bookmarks = {
            icon        = "appbar.navigation",
            description = _("Bookmarks"),
            callback    = function()
                if menu.close_callback then menu.close_callback() end
                UIManager:broadcastEvent(Event:new("ShowBookmark"))
            end,
        },
        toc = {
            icon        = "appbar.pageview",
            description = _("Table of Contents"),
            callback    = function()
                if menu.close_callback then menu.close_callback() end
                UIManager:broadcastEvent(Event:new("ShowToc"))
            end,
        },
        search = {
            icon        = "appbar.search",
            description = _("Search"),
            callback    = function()
                if menu.close_callback then menu.close_callback() end
                UIManager:broadcastEvent(Event:new("ShowFulltextSearchInput"))
            end,
        },
        skim = {
            icon        = "chevron.last",
            description = _("Skim document"),
            callback    = function()
                if menu.close_callback then menu.close_callback() end
                UIManager:broadcastEvent(Event:new("ShowSkimtoDialog"))
            end,
        },
        page_browser = {
            icon        = "book.opened",
            description = _("Page browser"),
            callback    = function()
                if menu.close_callback then menu.close_callback() end
                UIManager:broadcastEvent(Event:new("ShowPageBrowser"))
            end,
        },
        book_status = {
            icon        = "notice-info",
            description = _("Book status"),
            callback    = function()
                if menu.close_callback then menu.close_callback() end
                UIManager:broadcastEvent(Event:new("ShowBookStatus"))
            end,
        },
    }
end

-- ==========================================================================
-- Shortcuts bar
-- ==========================================================================

--- Build the horizontal shortcuts icon row.
local function createShortcutsBar(menu, config)
    local icon_size    = Screen:scaleBySize(26)
    local padding_h    = Screen:scaleBySize(config.spacing)
    local shortcut_defs = buildShortcutDefs(menu)

    -- Parse the CSV config string and build the list of widgets/markers
    local row_items = { HorizontalSpan:new{ width = Size.padding.fullscreen } }

    for token in string.gmatch(config.items, "([^,]+)") do
        local key = token:match("^%s*(.-)%s*$")

        if key == "spacer" then
            table.insert(row_items, { is_spacer = true })
        elseif key == "time" then
            table.insert(row_items, Button:new{
                text           = getTimeText(),
                face           = Font:getFace("ffont"),
                text_font_bold = false,
                padding_h      = padding_h,
                bordersize     = 0,
                callback       = function()
                    UIManager:show(InfoMessage:new{
                        text = datetime.secondsToDateTime(nil, nil, true),
                    })
                end,
            })
        elseif key == "battery" then
            table.insert(row_items, Button:new{
                text           = getBatteryText(),
                face           = Font:getFace("ffont"),
                text_font_bold = false,
                padding_h      = padding_h,
                bordersize     = 0,
                callback       = function()
                    UIManager:broadcastEvent(Event:new("ShowBatteryStatistics"))
                end,
            })
        else
            local def = shortcut_defs[key]
            if def then
                local btn
                btn = IconButton:new{
                    icon          = def.icon,
                    width         = icon_size,
                    height        = icon_size,
                    padding_top   = Screen:scaleBySize(2),
                    padding_left  = padding_h,
                    padding_right = padding_h,
                    callback      = function() def.callback(btn) end,
                    hold_callback = function()
                        UIManager:show(InfoMessage:new{
                            text    = def.description,
                            timeout = 1,
                        })
                    end,
                }
                table.insert(row_items, btn)
            end
        end
    end

    table.insert(row_items, HorizontalSpan:new{ width = Size.padding.fullscreen })

    -- Replace spacer markers with actual HorizontalSpans sized to fill remaining width
    local fixed_w    = 0
    local spacer_cnt = 0
    for _, item in ipairs(row_items) do
        if item.is_spacer then
            spacer_cnt = spacer_cnt + 1
        elseif item.getSize then
            fixed_w = fixed_w + item:getSize().w
        end
    end
    local spacer_w = (spacer_cnt > 0)
        and math.max(Size.padding.default, (menu.width - fixed_w) / spacer_cnt)
        or  Size.padding.default

    local resolved = {}
    for _, item in ipairs(row_items) do
        table.insert(resolved, item.is_spacer
            and HorizontalSpan:new{ width = spacer_w }
            or  item)
    end

    local v_pad = Screen:scaleBySize(6)
    local bar = VerticalGroup:new{
        align             = "right",
        is_shortcuts_bar  = true,
        VerticalSpan:new{ width = v_pad },
        HorizontalGroup:new{ align = "center", unpack(resolved) },
        VerticalSpan:new{ width = v_pad },
    }
    return bar
end

-- ==========================================================================
-- Home content (top + bottom rows combined)
-- ==========================================================================

--- Build the full home-state content widget inserted into the reader menu.
local function createHomeContent(menu, config)
    local total_w = menu.width

    -- ---- Top row: book info (left) + time / battery (right) ----
    local top_right
    if config.show_time_and_battery then
        local batt_text = getBatteryText()
        top_right = HorizontalGroup:new{
            align = "center",
            Button:new{
                text           = getTimeText(),
                face           = Font:getFace("ffont"),
                text_font_bold = false,
                padding_h      = Screen:scaleBySize(config.spacing),
                bordersize     = 0,
                callback       = function()
                    UIManager:show(InfoMessage:new{
                        text = datetime.secondsToDateTime(nil, nil, true),
                    })
                end,
            },
            Button:new{
                text           = batt_text,
                face           = Font:getFace("ffont"),
                text_font_bold = false,
                padding_h      = Screen:scaleBySize(config.spacing),
                bordersize     = 0,
                callback       = function()
                    UIManager:broadcastEvent(Event:new("ShowBatteryStatistics"))
                end,
            },
            HorizontalSpan:new{ width = Size.padding.fullscreen },
        }
    end

    local book_panel
    if config.show_book_info then
        local ok, panel = pcall(createBookInfoPanel, math.floor(total_w * 0.7))
        if ok then book_panel = panel end
    end

    local top_row
    if book_panel or top_right then
        local top_h = math.max(
            top_right  and top_right:getSize().h  or 0,
            book_panel and book_panel:getSize().h or 0,
            Screen:scaleBySize(20)
        )
        top_row = OverlapGroup:new{ dimen = Geom:new{ w = total_w, h = top_h } }

        if book_panel then
            table.insert(top_row, LeftContainer:new{
                dimen = Geom:new{ w = total_w, h = top_h },
                book_panel,
            })
        end

        if top_right then
            local top_pad = Screen:scaleBySize(6)
            local tr_h    = top_right:getSize().h
            table.insert(top_row, RightContainer:new{
                dimen = Geom:new{ w = total_w, h = top_h },
                VerticalGroup:new{
                    align = "right",
                    VerticalSpan:new{ width = top_pad },
                    top_right,
                    VerticalSpan:new{ width = math.max(0, top_h - tr_h - top_pad) },
                },
            })
        end
    end

    -- ---- Bottom row: shortcuts icons (right) + optional back button (left) ----
    local shortcuts_bar = createShortcutsBar(menu, config)

    local bottom_row
    if config.show_back_button ~= false then
        local icon_size     = Screen:scaleBySize(14)
        local back_callback = function()
            if menu.close_callback then menu.close_callback() end
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance then
                local file = ReaderUI.instance.document and ReaderUI.instance.document.file
                ReaderUI.instance:showFileManager(file)
            end
        end

        local back_btn = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = Size.padding.fullscreen },
            IconButton:new{
                icon          = "chevron.left",
                width         = icon_size,
                height        = icon_size,
                padding_top   = Screen:scaleBySize(2),
                padding_left  = 0,
                padding_right = Screen:scaleBySize(4),
                callback      = back_callback,
            },
            Button:new{
                text           = _("Back to library"),
                face           = Font:getFace("smallffont"),
                text_font_bold = false,
                text_font_size = 18,
                padding_h      = 0,
                bordersize     = 0,
                callback       = back_callback,
            },
        }

        local bottom_h = math.max(shortcuts_bar:getSize().h, back_btn:getSize().h)
        bottom_row = OverlapGroup:new{
            dimen = Geom:new{ w = total_w, h = bottom_h },
            LeftContainer:new{
                dimen = Geom:new{ w = total_w, h = bottom_h },
                back_btn,
            },
            RightContainer:new{
                dimen = Geom:new{ w = total_w, h = bottom_h },
                shortcuts_bar,
            },
        }
    else
        local bar_h = shortcuts_bar:getSize().h
        bottom_row = OverlapGroup:new{
            dimen = Geom:new{ w = total_w, h = bar_h },
            RightContainer:new{
                dimen = Geom:new{ w = total_w, h = bar_h },
                shortcuts_bar,
            },
        }
    end

    -- ---- Combine rows ----
    local combined = VerticalGroup:new{
        align            = "left",
        is_shortcuts_bar = true,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
    }
    if top_row then table.insert(combined, top_row) end
    table.insert(combined, bottom_row)
    return combined
end

return createHomeContent
