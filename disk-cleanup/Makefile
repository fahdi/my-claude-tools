.PHONY: test lint install uninstall dry-run force status log

test:
	@echo "=== bats ==="
	bats tests/test_disk_cleanup.bats tests/test_install.bats

lint:
	shellcheck bin/disk-cleanup.sh install.sh

install:
	./install.sh

uninstall:
	./install.sh --uninstall

dry-run:
	./bin/disk-cleanup.sh --dry-run

force:
	./bin/disk-cleanup.sh --force

status:
	@launchctl list | grep disk-cleanup || echo "agent not loaded"

log:
	tail -n 50 "$$HOME/Library/Logs/disk-cleanup.log"
