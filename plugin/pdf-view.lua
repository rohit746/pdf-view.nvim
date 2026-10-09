if vim.g.loaded_pdf_view then
  return
end
vim.g.loaded_pdf_view = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("pdf-view.nvim requires Neovim 0.11 or newer", vim.log.levels.ERROR)
  return
end

require("pdf-view")._init()
