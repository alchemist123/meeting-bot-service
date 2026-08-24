# =============================================================================
# Bot Service Lite (meetings-only) — top-level deploy entrypoint
# =============================================================================
# A meeting-bot-only fork of Vexa: a bot joins Meet/Teams/Zoom/Jitsi, transcribes, and exposes
# that over a REST API — no agent/copilot domain, no web UI. Two deploy shapes:
#   make lite     single container, bots run as child processes (see deploy/lite)
#   make compose  per-service containers, each bot its own container (see deploy/compose)
.PHONY: lite down compose compose-bot compose-down help

help:
	@echo "Bot Service Lite (meetings-only) deploy:"
	@echo "  make lite          single-container build + run (provisions Postgres + MinIO, builds the image, verifies)"
	@echo "  make down          stop the lite container + sidecars (data volumes are kept)"
	@echo "  make compose-bot   build the meeting-bot image for the compose deploy"
	@echo "  make compose       per-service containers: build + run (see deploy/compose)"
	@echo "  make compose-down  stop the compose stack"

lite:                ## single-container Bot Service Lite (provision + build + run + verify) — see deploy/lite
	@$(MAKE) --no-print-directory -C deploy/lite all

down:                ## stop the lite stack
	@$(MAKE) --no-print-directory -C deploy/lite down

compose-bot:         ## build the meeting-bot image from source, for the compose deploy
	@$(MAKE) --no-print-directory -C deploy/compose bot

compose:             ## per-service containers: build the 4 core services + bring the stack up — see deploy/compose
	@$(MAKE) --no-print-directory -C deploy/compose dev

compose-down:        ## stop the compose stack
	@$(MAKE) --no-print-directory -C deploy/compose down
