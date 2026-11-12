# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org).

## [Unreleased]

### Fixed

- With an input plugin that prompts asynchronously (snacks.nvim, dressing.nvim, noice.nvim), confirming `/` or `?`
  after the viewer was closed searched the closed document again. The answer is ignored now.
- `setup()` changing `hide_cursor` while a viewer is focused now shows or hides the cursor right away. Before, the
  change only took effect after leaving the viewer and entering it again.
- In a terminal that cannot show pages, a password-protected PDF now asks for its password and shows the page's text.
  Before, it showed only why the pages could not be drawn.
- Live reload stopped after the PDF's directory was deleted and created again, as a clean build does
  (`rm -rf build && latexmk -outdir=build`). The viewer watches the new directory now, and polls the file while the
  directory is missing.
- `:PdfView` and forward search opened the PDF in an unlisted buffer, missing from `:ls`, `:bnext` and bufferline
  plugins. The buffer is listed now, as with `:edit`.
- With positioned placements (zellij, or tmux after a window switch), a page the terminal had lost and that could
  not be sent again (its cached PNG unreadable) stayed blank with no message. The page is rendered again now, or a
  message says why it cannot be shown.

## [0.7.0] - 2026-11-09

### Fixed

- The cursor no longer stays hidden after leaving a viewer when `guicursor` is empty.
- `G` pressed before the page count is known (a large document still opening, a cancelled password prompt) no
  longer asks for page NaN with facing pages on. It does nothing until the first page is on screen.
- The render cache dropped the pages rendered first, even ones just shown again from it, so the page on screen could
  be deleted by the next page drawn ahead of time and rendered again. It drops the least recently shown ones now.
- In a terminal that can show no images, the text of a page taller than the window could not be scrolled past its
  first screen: `<C-e>`, `<C-y>`, `<C-d>` and `<C-u>` scroll it now. Switching windows no longer reads the text
  of every such viewer again.
- Inverse search (a double-click on a page) could open another file whose name contains the source's path, like a
  backup copy under `/mnt/backup`, instead of the source itself. It opens the buffer of that exact file now.
- Saving a reading position could misorder the stored positions or fail with "invalid order function for sorting",
  because their sort called the position just written less than itself.

## [0.6.0] - 2026-11-08

### Added

- SyncTeX, for LaTeX documents built with it: `:PdfViewForward` in a `.tex` buffer shows where the cursor's line is
  typeset, highlighted, in a split if the PDF is not on screen, and a double-click on a page opens the source at the
  line that point was typeset from. Works with vimtex.
- Continuous scrolling: with `continuous = true`, `j` and `k` on a zoomed or width-fitted page go on past its end
  into the next page, showing the bottom of one and the top of the next together.
- Facing pages: `d` shows two pages side by side, fitted, zoomed and turned as one, and `spread = "on"` or `"cover"`
  (page 1 alone, as a book opens) starts documents that way.

### Fixed

- Every page turn and scroll step set about 15 window options again, firing `OptionSet` for other plugins
  (statuslines and the like) each time. Only options whose value differs are set now.
- A request that the worker drawing a document could not read was never answered, and every later request for the
  document waited behind it until the document was closed. It now fails with the worker's message, and the next
  request goes ahead.
- A key mapped to an action that a default action also used, like `keymaps = { next = { "n" } }` with `search_next`'s
  `n`, did either action at random. The user's action gets the key now, and the default action loses it. One key
  given to two actions in `keymaps` is an error naming both.
- Following a link (`f`) or a bookmark (`gO`) to a figure, a citation or a section in the middle of a page went to the
  top of that page, so the target still had to be found by scrolling. A zoomed or width-fitted page now starts with the
  point the link or bookmark leads to at the top of the window.
- An e-book (EPUB, FB2, MOBI) laid out again for a window of another size went to the page with the same share of the
  page count, which is a page or more away from the text that was on screen when chapter starts, pictures or short
  pages fill some pages with less text than others. It now goes to the page that holds the text the page on screen
  started with.
- `setup({ winbar = false })` called again while a viewer was open left the last winbar text in its window, where it
  stopped following the page, and a new `recolor` or `highlight` only reached a page already on screen at the next
  page turn. Open viewers now clear their winbar and draw their page again.
- A viewer switched away from (`:bnext`, `:enew`) kept its pages in the terminal, which drops the oldest images
  without a word once it holds too many (kitty and Ghostty keep about 320 MB), and switching back could show a blank
  page. A viewer in no window now frees its images, and sends its page again when a window shows it.
- `<C-o>` in a viewer did nothing once its own jump list had no earlier entry, so it could not go back to the file the
  PDF was opened from (`gf`, `:edit`). Past either end of the viewer's jump list, `<C-o>` and `<C-i>` now go on through
  Vim's jump list with the rest of the count.

## [0.5.1] - 2026-11-08

### Fixed

- In VS Code without `"terminal.integrated.enableImages": true`, or without the WebGL renderer that VS Code draws
  images with, a PDF opened to a blank window. VS Code is now asked whether it shows images (its device attributes
  list sixel graphics when it does, Neovim 0.12), and when it does not, the viewer says how to turn them on and shows
  the text of the page. `:checkhealth pdf-view` reports it too.
- A remembered position saved before `max_zoom` was lowered, or a hand-edited `positions.json`, opened the PDF zoomed
  past what `+` allows, or with its centre off the page. A restored zoom is now kept within `1..max_zoom` and its
  centre within the page.

## [0.5.0] - 2026-11-08

### Added

- WezTerm and Konsole, which have the Kitty graphics protocol but not its Unicode placeholders, are recognised (also
  inside tmux) and get positioned placements, as zellij does: the page is placed at its window's position. They are
  asked once whether they have Kitty graphics, and a WezTerm without `enable_kitty_graphics` gets a message saying so
  instead of a blank page. In Konsole the page is drawn over the text, which is the only place Konsole shows it, and
  sent as bytes. Inside tmux the page is placed at the position of Neovim's pane and taken off the screen while its
  tmux window is not shown (with tmux's `focus-events` on). `placement = "positioned"` no longer needs `force = true`
  as well: any terminal that answers the Kitty graphics query is accepted.
- iTerm2 and VS Code's terminal, which have no Kitty graphics, show pages as iTerm2 inline images (OSC 1337). They are
  recognised by `$TERM_PROGRAM` (iTerm2 also by `$LC_TERMINAL`, and inside tmux by the name it gave tmux). The page is
  printed at its window's position, in parts cut out by mutool around floats and the popup menu, and printed again
  after Neovim draws over it or a message scrolls the screen; what it leaves behind is erased. The new `protocol`
  option (`"auto"`, `"kitty"` or `"iterm2"`) chooses the image protocol by hand.
- foot, Windows Terminal, xterm (as a VT340), Contour and mlterm show pages as sixel images, which they are recognised
  by (also inside tmux); a terminal that is not recognised gets sixel when it lists it in its device attributes (DA1,
  read on Neovim 0.12). mutool cuts each part of the page out at its size on screen, and the plugin encodes it in Lua,
  so no other program is needed. The page is printed and kept in step with the screen as iTerm2 images are.
  `protocol = "sixel"` chooses it by hand. An xterm that is not a VT340 gets a message saying how to make it one.
- A terminal that can show no images now shows the text of the page under the reason, and the page keys turn the
  pages, instead of only the reason.

### Fixed

- Cancelling the password prompt of a password-protected PDF only held until the page was shown again: resizing the
  window, a split next to it, or the file changing on disk asked for the password again. The PDF now stays locked with
  its message until `:edit` (or `r`) asks again.
- Scrolling or zooming quickly with the trackpad, the mouse wheel or a held `j`/`k` started a new `mutool` for almost
  every step, which opened the document again, and nothing showed until the input stopped. A page that is being drawn
  is now finished and kept, and only the steps still waiting are dropped; `mutool` is stopped only for a page that has
  been drawing for over a second.
- `:read file.pdf` (or `.cbz`, `.epub`, ...) inserted the raw bytes of the file into the buffer. It is now refused
  with a message that points to `:PdfView`.
- With a search active, live reload searched the whole document again on every change of the file even when its
  viewer was in no window (`:bnext` away from it, say), which for a LaTeX or Typst build that writes the PDF on every
  save meant a full search per save. A hidden viewer now searches again once, when a window shows it.
- `t` opened another split for every page whose text it showed, as each page had a buffer of its own. A document now
  has one text buffer, which `t` fills with the page on screen, renames after it and focuses in the split it already
  has.

## [0.4.1] - 2026-11-02

### Fixed

- Inside tmux with `extended-keys` on (or `always`), opening a document typed stray keys into it: the terminal's
  answer to whether it can read the PNG files of pages came back as the keys `Gi=16777214;OK`, so the viewer jumped to
  the last page, recoloured it, zoomed all the way in and reported `E21: Cannot make changes` and `E349: No identifier
  under cursor`. tmux turns the answer's leading escape into the key Alt-_ once Neovim asks for extended keys, so the
  terminal is no longer asked there and the files are sent as before; `:checkhealth pdf-view` says so.

## [0.4.0] - 2026-11-01

### Added

- Links in a document could not be followed. `f` lists the links on the page, with the text under each, through
  `vim.ui.select`: a link to a page of the document jumps there (`<C-o>` comes back), a web address or an e-mail opens
  with `vim.ui.open()`. The `follow_link` keymap sets the key.
- Pages were always black on white, glaring next to a dark colorscheme. `i` recolours them: `recolor = "invert"`
  inverts their brightness but keeps their hues, and `recolor = "colorscheme"` draws them in the colours of the `Normal`
  highlight, drawing them again when the colorscheme changes. `recolor` also says whether pages start out recoloured,
  and the `recolor` keymap sets the key.
- The text of a page could only be read off the image. `y` yanks it into the register given (`"+y` for the
  clipboard), linewise, and `t` shows it in a scratch split next to the viewer, to quote from or search with Neovim's
  own tools. The `yank_text` and `show_text` keymaps set the keys.
- A password-protected PDF could not be opened. It now asks for the password with `inputsecret()` and keeps it until
  Neovim exits; a wrong one asks again. The password reaches `mutool` on standard input, so `ps` never shows it.
- EPUB, FB2 and MOBI books showed on small fixed pages of MuPDF's default layout. They are now laid out to fill the
  window, with text about the size of the terminal's (`text_scale` changes it), and laid out again when the window
  changes size, staying at the same point of the text; search matches and the outline follow the new pages.
  `*.epub`, `*.fb2` and `*.mobi` open by default.
- Only `*.pdf` and `*.PDF` opened in the viewer, although MuPDF also reads comic book archives and XPS documents.
  `*.cbz` and `*.xps` now open too, and the extension is matched in any case, so `paper.Pdf` is covered. The
  `extensions` option sets the list, for `auto_open` and for `:PdfView` without an argument.
- `gg`, `G`, `{count}G`, outline picks and search jumps could not be undone. Each viewer now keeps a jump list:
  `<C-o>` and `<C-i>` go back and forward through it, and `''` swaps with the position before the latest jump.
  `m{a-z}` marks the page with its fit, zoom and view, and `'{a-z}` or `` `{a-z} `` goes back to it. The
  `jump_back`, `jump_forward`, `mark` and `goto_mark` keymaps set the keys.
- Papers with wide margins showed small text. `c` fits the content of the page to the window and crops the margins:
  everything that is not white counts, text, images and figures alike. Each page is cropped to its own content, and
  zooming scrolls over the content only. The `fit_content` keymap sets the key.
- The mouse wheel did nothing in a viewer. While a viewer has focus, it now scrolls a zoomed page and turns pages,
  like `j` `k` `l` `h`, in the viewer under the mouse; over other windows it scrolls them as before. The
  `scroll_down`, `scroll_up`, `scroll_right` and `scroll_left` keymaps set its keys; `{}` turns one off.
- A PDF reopened after restarting Neovim started on the first page. The page, fit and zoom of the last 100 PDFs are
  now kept in `stdpath("state")/pdf-view/positions.json`, and a PDF opens where it was left. `remember_position =
  false` turns this off.
- `/` and `?` started from an empty prompt every time. Searches now go into the search history (`:history /`), and
  an empty prompt searches again for the last text, as `/<CR>` does in Vim.

### Changed

- On a long document nothing happened on screen between answering the `/` prompt and the first match. The winbar
  now shows `/needle searching…` until the search finishes.
- After a search on a fitted page, `+` zoomed in on the middle of the page, away from the match. It now zooms in
  towards the current match when it is on the page.
- Turning to a page that was not cached started `mutool` twice, and each run opened and parsed the document again;
  on a 756-page PDF that took about 200 ms. A worker process per viewer now keeps the document open and does all the
  rendering, the next and previous pages are rendered in the background while you read, and turning back to one of
  the last four pages shown does not upload its image to the terminal again, which saves the most over SSH.

### Fixed

- `{count}n` and `{count}N` did not say `search hit BOTTOM, continuing at TOP` when the search wrapped before the
  last step. After turning away from the current match, `n` and `N` also ignored the count and never reported a wrap.
  Both now count every step and report any wrap.
- With `auto_open = false`, `:edit` in a viewer left an empty buffer whose keys did nothing. The viewer now comes
  back, on the same page.
- A password-protected PDF failed with `cannot draw '<file>'`. It now says the PDF is password-protected, and other
  `mutool` failures show mutool's error instead of its closing summary line.
- A failed render left an empty PNG in Neovim's temp dir, and live reload retries a failed render several times, so
  a long compile-watch session piled them up. A failed render's file is now removed, and an empty image counts as a
  failed render.
- `:w {file}` wrote the viewer's placeholder text to a file named `.pdf`. It now saves a copy of the PDF, and
  `:saveas {file}` saves a copy and views it. Writing a range or appending is refused.
- Inside tmux without truecolor (`RGB`) for the attached terminal, pages did not show and nothing said why: tmux
  reduced the image id colours to 256. `:checkhealth pdf-view` now reports it and gives the `terminal-features` line
  to add.
- When the terminal could not read the PNG files pdf-view writes (Neovim in a container or running as another user,
  or a flatpak terminal), pages stayed blank and nothing said why. On Neovim 0.12 the terminal is now asked once
  whether it can read them; if it cannot, pages are sent as bytes instead, and `:checkhealth pdf-view` says so.
- Live reload did nothing on NFS, SMB, sshfs and WSL's `/mnt/c`, where directory events miss changes or cannot be set
  up, and nothing said so. On those filesystems, and wherever the directory cannot be watched, the file is now checked
  every 500 ms. If that fails too, a notice says live reload is off.
- With a colorscheme whose `Visual` group sets a text colour, selecting in visual mode (`v`, `V`, `<C-v>` or a mouse
  drag) broke the selected part of the page. Visual highlighting is now off in viewer windows, like search
  highlighting.
- Calling `setup()` again left viewers that were already open with their old keys and their old live reload (on,
  off, or `reload_delay`). Open viewers now take the new `keymaps`, `live_reload` and `reload_delay`.
- After tmux was detached and attached again from another terminal window, pages stayed blank until `r` was pressed:
  the new terminal held none of the images, and the old terminal's type was still assumed. When the Neovim pane gets
  focus through a different tmux client, the terminal is now detected again and pages are sent again from the render
  cache.

## [0.3.0] - 2026-11-01

### Added

- zellij support. zellij 0.45 implements the Kitty graphics protocol itself but not Unicode placeholders, so inside
  zellij no page appeared. There the buffer is now left blank and the page is placed at the screen position of its
  window. It is cut around floating windows and the popup menu, taken away while its window is hidden, and placed or
  sent again when a redraw, a long message or a suspend moves it or makes zellij forget it. The new `placement`
  option (`"placeholders"` or `"positioned"`) overrides the choice. `:checkhealth pdf-view` reports zellij's version
  and which kind of placement is used.

### Fixed

- `gg`, `G` and a bookmark picked with `gO` did nothing on a zoomed or fitted page when their page was the one already
  on screen. They now go to the top of that page.
- A search with exactly as many matches as `search_limit` warned that it had stopped early and showed a `+` in the
  winbar. Only a search with more matches than the limit says so now.

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

[Unreleased]: https://github.com/rohit746/pdf-view.nvim/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/rohit746/pdf-view.nvim/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/rohit746/pdf-view.nvim/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rohit746/pdf-view.nvim/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/rohit746/pdf-view.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/rohit746/pdf-view.nvim/releases/tag/v0.1.0
