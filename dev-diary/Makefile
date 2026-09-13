.PHONY: test validate test-python test-bats

test: validate test-python test-bats

validate:
	@echo "=== manifests ==="
	claude plugin validate .. --strict
	claude plugin validate . --strict

test-python:
	@echo "=== pytest ==="
	pytest tests/test_diary.py -v

test-bats:
	@echo "=== bats ==="
	bats tests/test_hook.bats
