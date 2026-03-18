--[[
Book Info Panel
===============
Renders a tappable panel with book cover, title, author and reading progress.
Tapping the panel fires a ShowBookStatus event.
--]]

local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Event         = require("ui/event")
local Font          = require("ui/font")
local Geom          = require("ui/geometry")
local GestureRange  = require("ui/gesturerange")
local Size          = require("ui/size")
local UIManager     = require("ui/uimanager")
local T             = require("ffi/util").template
local _             = require("gettext")
local Screen        = Device.screen

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local RenderImage     = require("ui/renderimage")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

-- Scaled layout constants
local COVER_W    = Screen:scaleBySize(84)
local COVER_H    = Screen:scaleBySize(119)
local LEADING    = Screen:scaleBySize(10)
local GAP        = Screen:scaleBySize(8)
local V_PAD_TOP  = Screen:scaleBySize(12)
local V_PAD_BOT  = Screen:scaleBySize(6)
local META_V_GAP = Screen:scaleBySize(3)
local META_V_SEP = Screen:scaleBySize(5)

--- Build a scaled cover ImageWidget from a cover BlitBuffer, or return nil.
local function buildCoverWidget(ui)
    local ok, thumbnail = pcall(function()
        return ui.bookinfo:getCoverImage(ui.document)
    end)
    if not (ok and thumbnail) then return nil end

    local cbb_w   = thumbnail:getWidth()
    local cbb_h   = thumbnail:getHeight()
    local scale   = math.min(COVER_W / cbb_w, COVER_H / cbb_h)
    cbb_w = math.min(math.floor(cbb_w * scale) + 1, COVER_W)
    cbb_h = math.min(math.floor(cbb_h * scale) + 1, COVER_H)
    thumbnail = RenderImage:scaleBlitBuffer(thumbnail, cbb_w, cbb_h, true)

    return FrameContainer:new{
        bordersize = Size.border.thin,
        color      = Blitbuffer.COLOR_LIGHT_GRAY,
        padding    = 0,
        ImageWidget:new{ image = thumbnail, width = cbb_w, height = cbb_h },
    }
end

--- Create the book metadata text column.
local function buildMetaGroup(props, ui, text_w)
    local progress_text
    local percent

    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        -- Use stable (physical) page labels when the book has a page map
        local label_cur, idx, count = ui.pagemap:getCurrentPageLabel(false)
        local label_last = ui.pagemap:getLastPageLabel(true)
        percent = (count and count > 0)
            and math.floor(idx / count * 100) or 0
        progress_text = T(_("Page %1 of %2 (%3%)"), label_cur, label_last, percent)
    else
        local current_page = ui:getCurrentPage() or 0
        local total_pages  = ui.document:getPageCount() or 0
        percent = (total_pages > 0)
            and math.floor(current_page / total_pages * 100) or 0
        progress_text = T(_("Page %1 of %2 (%3%)"), current_page, total_pages, percent)
    end

    local small_face  = Font:getFace("smallffont")
    local medium_face = Font:getFace("ffont")

    return VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text  = props.display_title or props.title or _("Unknown title"),
            face  = medium_face,
            bold  = true,
            width = text_w,
        },
        VerticalSpan:new{ width = META_V_GAP },
        TextBoxWidget:new{
            text  = props.authors or _("Unknown author"),
            face  = small_face,
            width = text_w,
        },
        VerticalSpan:new{ width = META_V_SEP },
        TextWidget:new{
            text = progress_text,
            face = small_face,
        },
    }
end

--- Build the metadata text column for the file-browser case (no live reader).
-- Falls back to a simple "X% read" progress line from DocSettings.
local function buildFbMetaGroup(props, lastfile, text_w)
    local small_face  = Font:getFace("smallffont")
    local medium_face = Font:getFace("ffont")

    -- Try to get progress from DocSettings cache.
    local progress_text
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and lastfile then
        local ok2, ds = pcall(DocSettings.open, DocSettings, lastfile)
        if ok2 and ds then
            local pct = ds:readSetting("percent_finished")
            if type(pct) == "number" then
                progress_text = T(_("%1% read"), math.floor(pct * 100))
            end
        end
    end

    local vg = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text  = props.display_title or props.title or _("Unknown title"),
            face  = medium_face,
            bold  = true,
            width = text_w,
        },
        VerticalSpan:new{ width = META_V_GAP },
        TextBoxWidget:new{
            text  = props.authors or _("Unknown author"),
            face  = small_face,
            width = text_w,
        },
    }
    if progress_text then
        table.insert(vg, VerticalSpan:new{ width = META_V_SEP })
        table.insert(vg, TextWidget:new{ text = progress_text, face = small_face })
    end
    return vg
end

--- Create the reader book-info panel (unchanged reader behaviour).
local function createReaderBookInfoPanel(avail_w)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if not (ui and ui.document and ui.doc_props) then return nil end

    local text_w = math.max(
        Screen:scaleBySize(80),
        avail_w - LEADING - COVER_W - GAP * 2 - Size.padding.default
    )

    local cover   = buildCoverWidget(ui)
    local meta    = buildMetaGroup(ui.doc_props, ui, text_w)

    local row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = LEADING },
        HorizontalSpan:new{ width = Size.padding.default },
    }
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = GAP })
    end
    table.insert(row, meta)

    local padded = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = V_PAD_TOP },
        row,
        VerticalSpan:new{ width = V_PAD_BOT },
    }

    local tappable
    tappable = InputContainer:new{
        ges_events = {
            Tap = { GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            }},
        },
        padded,
    }
    function tappable:onTap()
        UIManager:broadcastEvent(Event:new("ShowBookStatus"))
        return true
    end
    return tappable
end

--- Create the file-browser "current book" panel.
-- Shows the last-opened book. Tapping opens it in the reader.
-- Returns nil when no last file is recorded.
local function createFbBookInfoPanel(avail_w)
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not (lastfile and lastfile ~= "") then return nil end

    -- Prefer live reader data when the same file is open in memory.
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    local use_live = ui and ui.document
        and ui.document.file == lastfile
        and ui.doc_props

    local cover, meta
    if use_live then
        local text_w = math.max(
            Screen:scaleBySize(80),
            avail_w - LEADING - COVER_W - GAP * 2 - Size.padding.default
        )
        cover = buildCoverWidget(ui)
        meta  = buildMetaGroup(ui.doc_props, ui, text_w)
    else
        -- No live reader: load props from DocSettings cache.
        local props
        local ok, DocSettings = pcall(require, "docsettings")
        if ok then
            local ok2, ds = pcall(DocSettings.open, DocSettings, lastfile)
            if ok2 and ds then props = ds:readSetting("doc_props") end
        end
        if not props then
            -- Absolute fallback: derive title from filename.
            local util = require("util")
            local _, fname = util.splitFilePathName(lastfile)
            local name = fname:gsub("%.[^.]+$", "")
            props = { display_title = name, title = name }
        end
        local text_w = math.max(
            Screen:scaleBySize(80),
            avail_w - LEADING - Size.padding.default
        )
        meta = buildFbMetaGroup(props, lastfile, text_w)
    end

    local row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = LEADING },
        HorizontalSpan:new{ width = Size.padding.default },
    }
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = GAP })
    end
    table.insert(row, meta)

    local padded = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = V_PAD_TOP },
        row,
        VerticalSpan:new{ width = V_PAD_BOT },
    }

    local tappable
    tappable = InputContainer:new{
        ges_events = {
            Tap = { GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            }},
        },
        padded,
    }
    function tappable:onTap()
        local ReaderUI2 = require("apps/reader/readerui")
        ReaderUI2:showReader(lastfile)
        return true
    end
    return tappable
end

--- Create the book info panel for the given available width and view.
-- @param avail_w  Available width in pixels.
-- @param view     "reader" (default) or "fb".
-- Returns a tappable InputContainer, or nil if no relevant book is available.
local function createBookInfoPanel(avail_w, view)
    if view == "fb" then
        return createFbBookInfoPanel(avail_w)
    else
        return createReaderBookInfoPanel(avail_w)
    end
end

return createBookInfoPanel
