.PHONY: help all setup deps build fmt fmt-check lint test coverage security-audit admin-test ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, security-audit, admin-test, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

admin-test:
	bash ../deploy/tests/symphony-admin-test.sh

security-audit:
	$(MIX) hex.audit

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) admin-test
	$(MAKE) security-audit
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
