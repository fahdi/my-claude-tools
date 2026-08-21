PLUGINS := captains-log

.PHONY: test validate

# Validate the marketplace manifest and every plugin it ships.
validate:
	claude plugin validate . --strict
	@for p in $(PLUGINS); do claude plugin validate ./$$p --strict || exit 1; done

# Run each plugin's own suite.
test: validate
	@for p in $(PLUGINS); do $(MAKE) -C $$p test-python test-bats || exit 1; done
