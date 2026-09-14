.PHONY: test lint install uninstall dry-run log status

test:
	@echo "=== bats ==="
	bats tests/test_brew_upgrade.bats tests/test_install.bats

lint:
	shellcheck bin/brew-upgrade.sh install.sh

install:
	./install.sh

uninstall:
	./install.sh --uninstall

dry-run:
	./bin/brew-upgrade.sh --dry-run

status:
	@launchctl list | grep brew-upgrade || echo "agent not loaded"
	@crontab -l 2>/dev/null | grep brew-upgrade || echo "no crontab entry (expected: launchd owns this)"

log:
	tail -n 50 "$$HOME/Library/Logs/brew-upgrade.log"
