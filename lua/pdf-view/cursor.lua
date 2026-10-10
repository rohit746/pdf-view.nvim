--- Hides the cursor while a viewer is focused. The buffer's cursor is parked on its first cell, so without this
--- a cursor block is drawn on top of the page image.
local config = require("pdf-view.config")

local M = {}

local GROUP = "PdfViewCursor"

local owner ---@type integer? the viewer buffer the cursor is hidden for
local saved ---@type string? 'guicursor' as it was before hiding

--- Neovim hides the cursor for a 'guicursor' highlight group with `blend = 100`, but only when the group also has
--- colours: a group with nothing but a blend is ignored. Colorschemes clear highlights, so this is re-run after one.
function M.define()
  vim.api.nvim_set_hl(0, GROUP, { blend = 100, fg = "#000000", bg = "#000000", nocombine = true })
end

--- Hide the cursor on behalf of viewer buffer `buf`.
---@param buf integer
function M.hide(buf)
  if not config.options.hide_cursor then
    return
  end
  if owner then
    owner = buf -- already hidden: another viewer took the focus
    return
  end
  M.define()
  owner, saved = buf, vim.o.guicursor
  -- Normal, visual and operator-pending modes only, so the cursor is still there when typing a `:` command.
  vim.o.guicursor = (saved ~= "" and (saved .. ",") or "") .. "n-v-o:" .. GROUP
end

--- Bring the cursor back. With `buf`, only if it was hidden for that buffer.
---@param buf? integer
function M.show(buf)
  if not owner or (buf and buf ~= owner) then
    return
  end
  vim.o.guicursor = saved
  owner, saved = nil, nil
end

return M
