SHELL := /bin/bash

.PHONY: test-smoke test-concurrency test-integration test-all

test-smoke:
	./scripts/tests/smoke.sh

test-concurrency:
	./scripts/tests/concurrency.sh

test-integration:
	./scripts/tests/integration.sh

test-all: test-smoke test-concurrency test-integration
