--[[
Shortcut Item Definitions
=========================
Single source of truth for all available toolbar shortcut items.
Each entry has:
  key       – internal identifier (used in settings and CSV)
  label     – translated display name (settings menu & reorder dialog)
  icon      – named icon (nil for text-only items like time/battery/spacer)
  icon_file – optional absolute path to a bundled SVG/PNG; overrides `icon` when set
  default   – true = shown by default, false = opt-in
--]]

local _ = require("gettext")

-- Absolute path to this plugin's directory, used to resolve bundled icon files.
local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")

local ITEM_SPACING = 8

local items = {
    { key = "font",         label = _("Font"),              default = true,     icon = "appbar.textsize" },
    { key = "frontlight",   label = _("Frontlight"),        default = true,     icon_file = PLUGIN_DIR .. "/icons/frontlight.svg" },
    { key = "night_mode",   label = _("Night mode"),        default = true,     icon_file = PLUGIN_DIR .. "/icons/nightmode.svg" },
    { key = "wifi",         label = _("Wi-Fi"),             default = true,     icon = "wifi" },
    { key = "bookmarks",    label = _("Bookmarks"),         default = true,     icon_file = PLUGIN_DIR .. "/icons/ribbon.svg" },
    { key = "search",       label = _("Search"),            default = true,     icon = "appbar.search" },
    { key = "toc",          label = _("Table of contents"), default = false,    icon_file = PLUGIN_DIR .. "/icons/toc.svg" },
    { key = "page_browser", label = _("Page browser"),      default = false,    icon_file = PLUGIN_DIR .. "/icons/grid.svg" },
    { key = "book_status",  label = _("Book status"),       default = false,    icon = "notice-info" },
    { key = "time",         label = _("Time"),              default = false,    icon = nil },
    { key = "battery",      label = _("Battery"),           default = false,    icon = nil },
    { key = "spacer",       label = _("Spacer"),            default = false,    icon = nil },
    { key = "spacer2",      label = _("Spacer"),            default = false,    icon = nil },
}

items.ITEM_SPACING = ITEM_SPACING
return items
