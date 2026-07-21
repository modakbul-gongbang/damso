PYTHON ?= python3
SWIFT ?= swift
BACKEND_ENV = PYTHONPATH=backend
TEST_COMMAND = $(BACKEND_ENV) $(PYTHON) -m unittest discover -s backend/tests -v

.PHONY: verify-static test test-migration test-mcp test-privacy test-recovery test-scheduler-resilience test-cli-sandbox reindex verify-portability doctor mcp model-status install-local-models install-local-app verify-local-resilience verify-daily-driver verify-live-plaud verify-live-llm

verify-static:
	$(SWIFT) build
	$(PYTHON) -m compileall -q backend

test: verify-static
	$(SWIFT) test
	$(TEST_COMMAND)

test-migration:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_migration backend.tests.test_duplicates -v

test-mcp:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_mcp -v

test-privacy:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_privacy backend.tests.test_agent_boundary backend.tests.test_diagnostics backend.tests.test_processing_cli -v

test-recovery:
	$(SWIFT) test

test-scheduler-resilience:
	$(SWIFT) test

test-cli-sandbox:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_agent_boundary -v

reindex:
	$(BACKEND_ENV) $(PYTHON) -m damso.index --store "$${DAMSO_STORE:?Set DAMSO_STORE to the canonical store root}"

verify-portability: verify-static test-privacy test-mcp

doctor:
	$(BACKEND_ENV) $(PYTHON) -m damso.diagnostics --root "$${DAMSO_STORE:-./meeting-store}"

mcp:
	$(BACKEND_ENV) $(PYTHON) -m damso.mcp --store "$${DAMSO_STORE:?Set DAMSO_STORE to the canonical store root}"

model-status:
	$(BACKEND_ENV) $(PYTHON) -m damso.model_setup --status

install-local-models:
	$(BACKEND_ENV) $(PYTHON) -m damso.model_setup --install

install-local-app:
	./scripts/install-local-app.sh

verify-local-resilience: test test-migration test-recovery test-scheduler-resilience test-cli-sandbox

verify-daily-driver:
	@echo "BLOCKED: This command requires the 2-hour local recording, device-loss, sleep/wake, and responsiveness human verification in docs/verification.md."
	@false

verify-live-plaud:
	@echo "BLOCKED: This command requires a user-approved Plaud test recording with the official Plaud CLI signed in (plaud login). It intentionally never opens a browser or uses an account by itself."
	@false

verify-live-llm:
	@test "$(DAMSO_ALLOW_LIVE_LLM)" = "1" || { echo "BLOCKED: Set DAMSO_ALLOW_LIVE_LLM=1 after approving a synthetic-fixture probe of the installed agent CLIs (claude/codex)."; exit 1; }
	$(BACKEND_ENV) $(PYTHON) backend/tests/live_llm_probe.py
