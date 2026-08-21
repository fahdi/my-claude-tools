PLUGINS := captains-log dev-diary claude-workflows

.PHONY: test validate

# Validate the marketplace manifest and every plugin it ships.
validate:
	claude plugin validate . --strict
	@for p in $(PLUGINS); do claude plugin validate ./$$p --strict || exit 1; done

# Run each plugin's own suite.
test: validate
	$(MAKE) -C captains-log test-python test-bats
	$(MAKE) -C dev-diary test-python test-bats
	@echo "=== bootstrap ==="
	bash -n scripts/bootstrap.sh && ./scripts/bootstrap.sh --dry-run >/dev/null && echo "bootstrap.sh OK"
