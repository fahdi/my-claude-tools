.PHONY: test validate test-python test-bats install-deps

test: validate test-python test-bats

validate:
	@echo "=== manifests ==="
	claude plugin validate .. --strict
	claude plugin validate . --strict
	claude plugin validate ./commands --strict

test-python:
	@echo "=== pytest ==="
	~/.local/bin/pytest tests/test_parse_transcript.py -v

test-bats:
	@echo "=== bats ==="
	bats tests/test_hook.bats

install-deps:
	brew install bats-core
	uv tool install pytest
