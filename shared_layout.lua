--[[
Shared Layout Utilities
=======================
Row-packing helper shared by home_content.lua and shortcuts_config.lua.
--]]

--- Splits an item list into rows that each fit within max_width.
--
-- Each item must be a table with either:
--   item.width (number)       for fixed-width items, or
--   item.is_spacer = true     for elastic/spacer items.
--
-- spacer_layout_w controls how spacers count toward overflow:
--   0  → elastic spacers that never cause a line-break (default)
--   N  → spacers counted as N px (e.g. disabled-bar fixed spacers)
--
-- Returns an array of rows; each row is an array slice of the original items.
-- Guaranteed to return at least one row ({{}} when items is empty).
local function packIntoRows(items, max_width, spacer_layout_w)
    spacer_layout_w = spacer_layout_w or 0
    local rows    = {}
    local cur_row = {}
    local cur_w   = 0
    for _, item in ipairs(items) do
        local iw = item.is_spacer and spacer_layout_w or item.width
        if not item.is_spacer and cur_w + iw > max_width and #cur_row > 0 then
            table.insert(rows, cur_row)
            cur_row = {}
            cur_w   = 0
        end
        table.insert(cur_row, item)
        cur_w = cur_w + iw
    end
    if #cur_row > 0 then table.insert(rows, cur_row) end
    return #rows > 0 and rows or {{}}
end

return packIntoRows
