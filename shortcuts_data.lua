--[[
Shortcut Item Definitions
=========================
Single source of truth for all available toolbar shortcut items.
Each entry has:
  key     – internal identifier (used in settings and CSV)
  label   – translated display name (settings menu & reorder dialog)
  icon    – icon filename (nil for text-only items like time/battery/spacer)
  default – true = shown by default, false = opt-in
--]]

local _ = require("gettext")

-- Single source of truth for icon-button horizontal padding (px, before scaling).
-- Both main.lua (ITEM_SPACING) and shortcuts_config.lua (CELL_PAD) read this value
-- so they never silently drift apart.
local ITEM_SPACING = 8

local items = {
    { key = "font",         label = _("Font"),              icon = "appbar.textsize",   default = true  },
    { key = "frontlight",   label = _("Frontlight"),        icon = "appbar.contrast",   default = true  },
    { key = "wifi",         label = _("Wi-Fi"),             icon = "wifi",              default = true  },
    { key = "bookmarks",    label = _("Bookmarks"),         icon = "appbar.navigation", default = true  },
    { key = "toc",          label = _("Table of contents"), icon = "appbar.pageview",   default = true  },
    { key = "search",       label = _("Search"),            icon = "appbar.search",     default = true  },
    { key = "skim",         label = _("Skim"),              icon = "chevron.last",      default = false },
    { key = "page_browser", label = _("Pages"),             icon = "book.opened",       default = false },
    { key = "book_status",  label = _("Status"),            icon = "notice-info",       default = false },
    { key = "time",         label = _("Time"),              icon = nil,                 default = false },
    { key = "battery",      label = _("Battery"),           icon = nil,                 default = false },
    { key = "spacer",       label = _("Spacer"),            icon = nil,                 default = false },
}

items.ITEM_SPACING = ITEM_SPACING
return items
