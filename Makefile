# =============================================================================
# Vexa Lite (meetings-only) — top-level deploy entrypoint
# =============================================================================
# A meeting-bot-only fork of Vexa: a bot joins Meet/Teams/Zoom/Jitsi, transcribes, and exposes
# that over a REST API — no agent/copilot domain, no web UI. Single-container deploy only.
.PHONY: lite down help

help:
	@echo "Vexa Lite (meetings-only) deploy:"
	@echo "  make lite  single-container build + run (provisions Postgres + MinIO, builds the image, verifies)"
	@echo "  make down  stop the container + sidecars (data volumes are kept)"

lite:                ## single-container Vexa Lite (provision + build + run + verify) — see deploy/lite
	@$(MAKE) --no-print-directory -C deploy/lite all

down:                ## stop the lite stack
	@$(MAKE) --no-print-directory -C deploy/lite down
