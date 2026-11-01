--- Watch a file for changes, tolerating the many ways tools rewrite PDFs (truncate+write, write-then-rename).
local M = {}

local uv = vim.uv

---@class PdfView.Watcher
---@field stop fun()

--- How often a file is compared with its last stat where directory events cannot be relied on.
M.poll_interval = 500

--- Linux `statfs` types of filesystems whose directory events miss changes made on another machine: NFS, SMB/CIFS,
--- FUSE (sshfs) and 9p (WSL's `/mnt/c`).
local remote_types = {
  [0x6969] = true,
  [0x517b] = true,
  [0xff534d42] = true,
  [0xfe534d42] = true,
  [0x65735546] = true,
  [0x01021997] = true,
}

---@param handle uv.uv_fs_event_t|uv.uv_fs_poll_t|uv.uv_timer_t
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
--- the file it points to is watched as well, wherever that is. Where the directory cannot be watched, or is on a network
--- filesystem, the file's stat is polled every `M.poll_interval` ms instead.
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

  local function bump()
    if stopped then
      return
    end
    timer:stop()
    timer:start(delay, 0, changed)
  end

  --- Watch `file` through its directory.
  ---@param file string
  ---@return uv.uv_fs_event_t? events nil when the directory cannot be watched, or is on a network filesystem
  local function watch_dir(file)
    local dir = vim.fs.dirname(file)
    local statfs = uv.fs_statfs(dir)
    if statfs and remote_types[statfs.type] then
      return nil
    end
    local events = uv.new_fs_event()
    if not events then
      return nil
    end
    local name = vim.fs.basename(file)
    local ok = events:start(dir, {}, function(err, filename)
      if err or (filename and filename ~= name) then
        return
      end
      bump()
    end)
    if not ok then
      events:close()
      return nil
    end
    return events
  end

  --- Compare `file` with its last stat every `M.poll_interval` ms.
  ---@param file string
  ---@return uv.uv_fs_poll_t?
  local function poll(file)
    local stats = uv.new_fs_poll()
    if not stats then
      return nil
    end
    if not stats:start(file, M.poll_interval, bump) then
      stats:close()
      return nil
    end
    return stats
  end

  ---@param file string
  ---@return (uv.uv_fs_event_t|uv.uv_fs_poll_t)? handle nil when `file` cannot be watched at all
  local function watch(file)
    return watch_dir(file) or poll(file)
  end

  local own = watch(path)
  if not own then
    timer:close()
    return nil
  end

  local target, target_events ---@type string?, (uv.uv_fs_event_t|uv.uv_fs_poll_t)?

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
