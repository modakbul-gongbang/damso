PYTHON ?= python3
SWIFT ?= swift
BACKEND_ENV = PYTHONPATH=backend
TEST_COMMAND = $(BACKEND_ENV) $(PYTHON) -m unittest discover -s backend/tests -v

.PHONY: verify-static test test-migration test-mcp test-privacy test-recovery test-scheduler-resilience test-cli-sandbox test-server-http test-audio-regression test-ssh-remnants reindex verify-portability doctor model-status install-local-models install-server install-client uninstall-server regenerate-server-credentials install-local-app verify-local-resilience verify-daily-driver verify-live-plaud verify-live-llm

verify-static:
	$(SWIFT) build
	$(PYTHON) -m compileall -q backend
	./scripts/check-no-retired-transport-security.sh
	bash scripts/check-no-ssh-remnants.sh

test: verify-static
	$(SWIFT) test --parallel
	$(TEST_COMMAND)

test-migration:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_migration backend.tests.test_duplicates -v

test-mcp:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_mcp -v

test-server-http:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_server_http -v

test-audio-regression:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_audio_regression -v

test-ssh-remnants:
	bash scripts/check-no-ssh-remnants.sh

test-privacy:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_privacy backend.tests.test_agent_boundary backend.tests.test_diagnostics backend.tests.test_processing_cli -v

test-recovery:
	$(SWIFT) test --parallel

test-scheduler-resilience:
	$(SWIFT) test --parallel

test-cli-sandbox:
	$(BACKEND_ENV) $(PYTHON) -m unittest backend.tests.test_agent_boundary -v

reindex:
	$(BACKEND_ENV) $(PYTHON) -m damso.index --store "$${DAMSO_STORE:?Set DAMSO_STORE to the canonical store root}"

verify-portability: verify-static test-privacy test-mcp

doctor:
	$(BACKEND_ENV) $(PYTHON) -m damso.diagnostics --root "$${DAMSO_STORE:-./meeting-store}"

model-status:
	$(BACKEND_ENV) $(PYTHON) -m damso.model_setup --status

install-local-models:
	$(BACKEND_ENV) $(PYTHON) -m damso.model_setup --install

# D-11: the two install units. install-server never needs Xcode or a git
# checkout of the Swift sources; install-client never needs the
# local-processing/server Python extras. A single-machine (local mode) setup
# runs both, on the same Mac.
install-server:
	./scripts/install-server.sh

install-client: install-local-app

install-local-app:
	./scripts/install-local-app.sh

uninstall-server:
	./scripts/uninstall-server.sh

# D-24: the only recovery path for a leaked or lost server access token.
regenerate-server-credentials:
	$(BACKEND_ENV) $(PYTHON) -m damso.server.credentials regenerate

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
