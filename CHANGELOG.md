# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org).

## [0.1.0] - 2026-10-10

First release.

### Added

- Open PDFs as ordinary buffers: `nvim file.pdf`, `:edit`, `:split`, `:PdfView {file}` and
  `require("pdf-view").open()`. The buffer is named after the file; its bytes are never read into the buffer and `:w`
  cannot overwrite the PDF.
- Pages are rendered by MuPDF's `mutool` and drawn with the Kitty graphics protocol using Unicode placeholders
  (kitty and Ghostty), so the image follows splits, tabs and resizes and works inside tmux. In tmux the plugin enables
  `allow-passthrough` for its own pane. Images are uploaded by path locally and inline over SSH.
- Page navigation with counts (`5j`, `12G`, `3<PageDown>`).
- Zoom (`+`, `-`, `0`) up to 8×, with scrolling (`j`/`k`/`h`/`l`) that turns the page at its edge. Only the visible
  part of a zoomed page is rendered.
- Fit to width (`w`) or height (`W`), applied per page and kept across resizes and page turns.
- Live reload when the PDF changes on disk (LaTeX and Typst builds), tolerant of files that are still being written.
- Text search over the whole document (`/`, `?`, `n`, `N`, `<Esc>`) with multiplied highlights, a distinct colour for the
  current match and a `3/17` counter in the winbar.
- Outline picker (`gO`) over the document's bookmarks, through `vim.ui.select`.
- Winbar with file name, page, zoom and search state; `require("pdf-view").status()` for statuslines.
- `:checkhealth pdf-view`, which exercises every `mutool` script the plugin relies on, and the terminal, tmux and
  colour setup.
- Configuration with validation: unknown or mistyped options raise immediately.

[0.1.0]: https://github.com/rohit746/pdf-view.nvim/releases/tag/v0.1.0
