SHELL := /bin/bash

.PHONY: test-smoke test-concurrency test-concurrency-overdraw test-integration test-all

test-smoke:
	./scripts/tests/smoke.sh

test-concurrency:
	./scripts/tests/concurrency.sh

test-concurrency-overdraw:
	./scripts/tests/concurrency_overdraw.sh

test-integration:
	./scripts/tests/integration.sh

test-all: test-smoke test-concurrency test-concurrency-overdraw test-integration
