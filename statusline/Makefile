.PHONY: test install uninstall show

test:
	@echo "=== bats ==="
	bats tests/test_tool_status.bats

install:
	./install.sh

uninstall:
	./install.sh --uninstall

show:
	./bin/tool-status.sh --full --no-cache
