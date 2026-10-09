--- Search results: parsing `scripts/search.js` output, stepping between matches, and describing the matches on
--- one page as highlight rectangles. Pure data handling, no editor state.
local M = {}

---@class PdfView.Match
---@field page integer 1-based
---@field width number page width in points
---@field height number
---@field rects number[][] one `{ x0, y0, x1, y1 }` per line the match covers, in points from the page's top-left
---@field cx number centre of the match as a fraction of the page width
---@field cy number centre as a fraction of the page height

---@class PdfView.Search
---@field id integer distinguishes one search from the next, for cache keys
---@field needle string
---@field matches PdfView.Match[] in reading order
---@field by_page table<integer, integer[]> indices into `matches`, per page
---@field truncated boolean the hit limit was reached, so there may be more matches
---@field dir 1|-1 the direction of the search, `n` repeats it and `N` reverses it
---@field current? integer index of the match on screen

local next_id = 0

--- Parse the output of `scripts/search.js`.
---@param stdout string
---@return PdfView.Match[] matches, boolean truncated
function M.parse(stdout)
  local matches, truncated = {}, false
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    if line == "truncated" then
      truncated = true
    else
      local page, width, height, quads = line:match("^(%d+) %d+ ([%d%.]+) ([%d%.]+) (.+)$")
      if page then
        local rects = {}
        for x0, y0, x1, y1 in quads:gmatch("(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)") do
          rects[#rects + 1] = { tonumber(x0), tonumber(y0), tonumber(x1), tonumber(y1) }
        end
        width, height = tonumber(width), tonumber(height)
        if #rects > 0 and width > 0 and height > 0 then
          local first = rects[1]
          matches[#matches + 1] = {
            page = tonumber(page),
            width = width,
            height = height,
            rects = rects,
            cx = (first[1] + first[3]) / 2 / width,
            cy = (first[2] + first[4]) / 2 / height,
          }
        end
      end
    end
  end
  return matches, truncated
end

---@param needle string
---@param matches PdfView.Match[]
---@param truncated boolean
---@param dir? 1|-1
---@return PdfView.Search
function M.new(needle, matches, truncated, dir)
  next_id = next_id + 1
  local by_page = {}
  for index, match in ipairs(matches) do
    local list = by_page[match.page]
    if not list then
      list = {}
      by_page[match.page] = list
    end
    list[#list + 1] = index
  end
  return {
    id = next_id,
    needle = needle,
    matches = matches,
    by_page = by_page,
    truncated = truncated,
    dir = dir or 1,
  }
end

--- The match to start from when a search is issued on `page`: the first one on that page or after it (going
--- forward), or the last one on that page or before it (going backward), wrapping around the document.
---@param search PdfView.Search
---@param page integer
---@param dir 1|-1
---@return integer? index nil when there are no matches
function M.start(search, page, dir)
  local matches = search.matches
  if #matches == 0 then
    return nil
  end
  if dir > 0 then
    for index, match in ipairs(matches) do
      if match.page >= page then
        return index
      end
    end
    return 1
  end
  for index = #matches, 1, -1 do
    if matches[index].page <= page then
      return index
    end
  end
  return #matches
end

--- The match after (`dir` 1) or before (`dir` -1) `current`, wrapping around the document.
---@param search PdfView.Search
---@param current integer
---@param dir 1|-1
---@return integer? index nil when there are no matches
---@return boolean wrapped whether the step passed the end (or start) of the document
function M.step(search, current, dir)
  local count = #search.matches
  if count == 0 then
    return nil, false
  end
  local index = current + dir
  if index > count then
    return 1, true
  elseif index < 1 then
    return count, true
  end
  return index, false
end

--- Highlight rectangles for the matches on `page`, in the form `scripts/render-clip.js` takes.
---@param search PdfView.Search
---@param page integer
---@param colors { match: string, current: string } hex colours without the leading `#`
---@return string? highlights nil when the page has no matches
---@return string key changes whenever the highlights for this page would, for render caches
function M.highlights(search, page, colors)
  local indices = search.by_page[page]
  if not indices then
    return nil, ""
  end
  local parts = {}
  local current_here = 0
  for _, index in ipairs(indices) do
    local color = colors.match
    if index == search.current then
      color = colors.current
      current_here = index
    end
    for _, rect in ipairs(search.matches[index].rects) do
      parts[#parts + 1] = ("%.2f,%.2f,%.2f,%.2f,%s"):format(rect[1], rect[2], rect[3], rect[4], color)
    end
  end
  return table.concat(parts, ";"), ("%d:%d:%s:%s"):format(search.id, current_here, colors.match, colors.current)
end

--- "3/17" for the winbar: the position of the current match, with "+" when the hit limit cut the list short.
---@param search PdfView.Search
---@return string
function M.progress(search)
  local total = #search.matches
  if total == 0 then
    return "no matches"
  end
  return ("%d/%d%s"):format(search.current or 0, total, search.truncated and "+" or "")
end

return M
