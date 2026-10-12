# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org).

## [Unreleased]

## [0.2.0] - 2026-10-12

### Added

- The cursor is hidden while a viewer is focused, so it no longer sits on top of the page. It stays visible on the
  command line and in prompts, and comes back when you leave the viewer. Turn it off with `hide_cursor = false`.

### Changed

- A page's size is read from the file once instead of before every render, so turning back to a page, zooming and
  scrolling start one `mutool` process less.
- `:edit` on a viewer comes back to the page, fit and zoom it had instead of the first page.

### Fixed

- Nothing was drawn on Neovim 0.11: images were sent with `nvim_ui_send()`, which only exists from Neovim 0.12, so
  every render ended in an error. On 0.11 they are now written to the terminal through Neovim's stderr channel.
- Stopping a search with `<Esc>`, or starting another one before it had finished, warned that the abandoned search had
  no matches. A search that was stopped or replaced no longer reports anything.
- When the PDF changed twice in quick succession, the active search could end up with no matches until the next
  change. A search that is still running when the file changes now starts over on the new file.
- An error shown in the buffer (an unsupported terminal, a missing `mutool`) was cut off at the window's edge. It is
  now wrapped to the window.
- With `foldmethod=indent` a page centred in its window was folded away. Folding is off in viewer windows.
- Live reload did not notice changes to a PDF opened through a symbolic link. The file the link points to is watched
  as well, and followed when the link is pointed somewhere else.
- `:PdfView` and `open()` could not open files with `{`, `$` or a backtick in their name.
- `<C-e>` and the mouse wheel scrolled the page partly out of its window. The window now stays on the page.
- When Neovim's temp directory was removed under a long-running session, every render failed until a restart.
- 'hlsearch' with a pattern that matched the page's placeholder cells (`/.`, for one) recoloured them, and a cell in
  another colour no longer belongs to the page image. Search highlighting is off in viewer windows.

## [0.1.1] - 2026-10-10

### Fixed

- Zoom, fit width/height and search highlights drew a blank page on MuPDF 1.23 (the package in Ubuntu 24.04), where
  running a page straight into a draw device silently draws nothing. Pages are now rendered from their display list,
  which works on every version.
- Search found nothing on MuPDF 1.27.0 and 1.28.0, where `Page.search()` returns no hits at all. It now searches the
  page's structured text, which gives the same results on every version.
- MuPDF before 1.27 ignores JavaScript blend groups, so multiplied highlights vanished there. The script now tests for
  that and draws a translucent highlight instead; `:checkhealth pdf-view` says which one applies.

### Changed

- `:checkhealth pdf-view` warns when highlights fall back to the translucent style.
- The test suite accepts either highlight style, and has been run against MuPDF 1.23.10, 1.24.0, 1.25.0, 1.26.0, 1.27.0,
  1.28.0 and 1.28.5.

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

[Unreleased]: https://github.com/rohit746/pdf-view.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/rohit746/pdf-view.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/rohit746/pdf-view.nvim/releases/tag/v0.1.0
