--- Watch a file for changes, tolerating the many ways tools rewrite PDFs (truncate+write, write-then-rename).
local M = {}

local uv = vim.uv

---@class PdfView.Watcher
---@field stop fun()

---@param handle uv.uv_fs_event_t|uv.uv_timer_t
local function close(handle)
  handle:stop()
  if not handle:is_closing() then
    handle:close()
  end
end

--- Call `on_change` once the file has stopped changing for `delay` ms.
---
--- The containing directory is watched rather than the file: a compiler that replaces the PDF by renaming a
--- temporary file over it would otherwise leave a watch on the old, deleted inode. When `path` is a symbolic link,
--- the file it points to is watched as well, wherever that is.
---@param path string
---@param delay integer
---@param on_change fun()
---@return PdfView.Watcher?
function M.start(path, delay, on_change)
  local timer = uv.new_timer()
  if not timer then
    return nil
  end

  local stopped = false
  local changed ---@type fun()

  --- Watch `file` through its directory.
  ---@param file string
  ---@return uv.uv_fs_event_t? events nil when the directory cannot be watched
  local function watch(file)
    local events = uv.new_fs_event()
    if not events then
      return nil
    end
    local name = vim.fs.basename(file)
    local ok = events:start(vim.fs.dirname(file), {}, function(err, filename)
      if err or stopped or (filename and filename ~= name) then
        return
      end
      timer:stop()
      timer:start(delay, 0, changed)
    end)
    if not ok then
      events:close()
      return nil
    end
    return events
  end

  local own = watch(path)
  if not own then
    timer:close()
    return nil
  end

  local target, target_events ---@type string?, uv.uv_fs_event_t?

  --- Watch what `path` points to now, if it is a symbolic link.
  local function follow()
    local stat = uv.fs_lstat(path)
    local real = stat and stat.type == "link" and uv.fs_realpath(path) or nil
    if real == target then
      return
    end
    if target_events then
      close(target_events)
    end
    target, target_events = real, real and watch(real) or nil
  end
  follow()

  changed = vim.schedule_wrap(function()
    if stopped then
      return
    end
    follow() -- the change may have been the link itself, now pointing somewhere else
    on_change()
  end)

  return {
    stop = function()
      if stopped then
        return
      end
      stopped = true
      close(own)
      if target_events then
        close(target_events)
      end
      close(timer)
    end,
  }
end

return M
