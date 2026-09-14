.PHONY: test lint install uninstall dry-run log

test:
	@echo "=== bats ==="
	bats tests/test_brew_upgrade.bats

lint:
	shellcheck bin/brew-upgrade.sh install.sh

install:
	./install.sh

uninstall:
	./install.sh --uninstall

dry-run:
	./bin/brew-upgrade.sh --dry-run

log:
	tail -n 50 "$$HOME/Library/Logs/brew-upgrade.log"
