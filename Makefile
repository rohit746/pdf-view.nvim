.PHONY: test format

test:
	NVIM_LOG_FILE=/tmp/pdf-view-nvim.log nvim --headless -u NONE -i NONE -l tests/run.lua

format:
	stylua lua plugin tests
