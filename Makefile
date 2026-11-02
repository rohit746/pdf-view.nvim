.PHONY: test typecheck lint format

test:
	NVIM_LOG_FILE=/tmp/pdf-view-nvim.log nvim --headless -u NONE -i NONE -l tests/run.lua

# lua-language-server reads the annotations, with the types of the Neovim runtime that `nvim` runs
typecheck:
	VIMRUNTIME="$$(nvim --clean --headless +'lua io.write(vim.env.VIMRUNTIME)' +q)" \
	  lua-language-server --check lua --checklevel=Warning --configpath "$(CURDIR)/.luarc.json" \
	  --logpath "$${TMPDIR:-/tmp}/pdf-view-luals"

lint:
	selene lua plugin

format:
	stylua lua plugin tests
