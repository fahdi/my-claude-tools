.PHONY: test test-python test-bats install-deps

test: test-python test-bats

test-python:
	@echo "=== pytest ==="
	~/.local/bin/pytest tests/test_parse_transcript.py -v

test-bats:
	@echo "=== bats ==="
	bats tests/test_hook.bats

install-deps:
	brew install bats-core
	uv tool install pytest
