--- Watch a file for changes, tolerating the many ways tools rewrite PDFs (truncate+write, write-then-rename).
local M = {}

local uv = vim.uv

---@class PdfView.Watcher
---@field stop fun()

--- Call `on_change` once the file has stopped changing for `delay` ms.
---
--- The containing directory is watched rather than the file: a compiler that replaces the PDF by renaming a
--- temporary file over it would otherwise leave a watch on the old, deleted inode.
---@param path string
---@param delay integer
---@param on_change fun()
---@return PdfView.Watcher?
function M.start(path, delay, on_change)
  local dir = vim.fs.dirname(path)
  local name = vim.fs.basename(path)

  local events = uv.new_fs_event()
  local timer = uv.new_timer()
  if not events or not timer then
    return nil
  end

  local stopped = false
  local ok = events:start(dir, {}, function(err, filename)
    if err or stopped or (filename and filename ~= name) then
      return
    end
    timer:stop()
    timer:start(
      delay,
      0,
      vim.schedule_wrap(function()
        if not stopped then
          on_change()
        end
      end)
    )
  end)
  if not ok then
    events:close()
    timer:close()
    return nil
  end

  return {
    stop = function()
      if stopped then
        return
      end
      stopped = true
      events:stop()
      timer:stop()
      if not events:is_closing() then
        events:close()
      end
      if not timer:is_closing() then
        timer:close()
      end
    end,
  }
end

return M
