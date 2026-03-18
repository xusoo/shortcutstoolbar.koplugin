--[[
Shortcut Item Definitions
=========================
Single source of truth for all available toolbar shortcut items.
Each entry has:
  key         – internal identifier (used in settings and CSV)
  label       – translated display name (settings menu & reorder dialog)
  icon        – named icon (nil for text-only items like time/battery/spacer)
  icon_file   – optional absolute path to a bundled SVG/PNG; overrides `icon` when set
  reader_only – true = hidden from the file-browser shortcuts config
  fb_only     – true = hidden from the reader shortcuts config

Default items and their initial display order are declared separately as:
  items.reader_defaults – ordered list of keys enabled by default in the reader toolbar
  items.fb_defaults     – ordered list of keys enabled by default in the file-browser toolbar
--]]

local _ = require("gettext")

-- Absolute path to this plugin's directory, used to resolve bundled icon files.
local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")

local ITEM_SPACING = 8

-- reader_only = true  → hidden from the file-browser shortcuts config
-- fb_only     = true  → hidden from the reader shortcuts config
local items = {
    { key = "font",         label = _("Font"),              reader_only = true,  icon = "appbar.textsize" },
    { key = "frontlight",   label = _("Frontlight"),                             icon_file = PLUGIN_DIR .. "/icons/frontlight.svg" },
    { key = "night_mode",   label = _("Night mode"),                             icon_file = PLUGIN_DIR .. "/icons/nightmode.svg" },
    { key = "wifi",         label = _("Wi-Fi"),                                  icon = "wifi" },
    { key = "bookmarks",    label = _("Bookmarks"),         reader_only = true,  icon_file = PLUGIN_DIR .. "/icons/bookmark.svg" },
    { key = "search",       label = _("Search"),            reader_only = true,  icon = "appbar.search" },
    { key = "toc",          label = _("Table of contents"), reader_only = true,  icon_file = PLUGIN_DIR .. "/icons/toc.svg" },
    { key = "page_browser", label = _("Page browser"),      reader_only = true,  icon_file = PLUGIN_DIR .. "/icons/grid.svg" },
    { key = "book_status",  label = _("Book status"),       reader_only = true,  icon = "notice-info" },
    { key = "time",         label = _("Time"),                                   icon = nil },
    { key = "battery",      label = _("Battery"),                                icon = nil },
    { key = "cloud_storage",  label = _("Cloud storage"),  fb_only = true,       icon_file = PLUGIN_DIR .. "/icons/cloud.svg" },
    { key = "calendar_stats", label = _("Calendar statistics"),                  icon_file = PLUGIN_DIR .. "/icons/calendar.svg" },
    { key = "favorites",      label = _("Favorites"),      fb_only = true,       icon_file = PLUGIN_DIR .. "/icons/heart.svg" },
    { key = "collections",    label = _("Collections"),    fb_only = true,       icon_file = PLUGIN_DIR .. "/icons/folder.svg" },
    { key = "file_search",    label = _("File search"),    fb_only = true,       icon = "appbar.search" },
    { key = "restart",        label = _("Restart KOReader"),                     icon_file = PLUGIN_DIR .. "/icons/power.svg" },
    { key = "spacer",         label = _("Spacer"),                               icon = nil },
    { key = "spacer2",        label = _("Spacer"),                               icon = nil },
}

-- Ordered list of keys enabled by default in the reader toolbar.
-- The order here also defines the initial display order on first run.
items.reader_defaults = {
    "font",
    "frontlight",
    "night_mode",
    "bookmarks",
    "search",
}

-- Ordered list of keys enabled by default in the file-browser toolbar.
-- The order here also defines the initial display order on first run.
items.fb_defaults = {
    "file_search",
    "collections",
    "favorites",
    "cloud_storage",
    "spacer",
    "wifi",
    "time",
    "battery",
}

items.ITEM_SPACING = ITEM_SPACING
return items
