.PHONY: test install uninstall show

test:
	@echo "=== bats ==="
	bats tests/

install:
	./install.sh

uninstall:
	./install.sh --uninstall

show:
	./bin/tool-status.sh --full --no-cache
