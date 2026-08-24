# deploy/compose — the meeting-bot control-plane stack, per-service containers.
#
# Unlike deploy/lite (one container, bots as child processes), this spawns each meeting bot in
# its OWN container via the host Docker socket — the same isolation model upstream Vexa's compose
# stack uses. There is no published image registry for this fork, so `make dev` always builds
# from this checkout (no separate "pull the release" path).
PROJECT ?= bot-service-lite
COMPOSE  = docker compose -p $(PROJECT) -f docker-compose.yml
REPO_ROOT := $(abspath ../..)
BOT_IMAGE ?= bot-service-lite/bot-service-bot:dev
EMAIL ?= self-host@vexa.ai
SCOPES ?= bot,tx

.PHONY: dev bot down build ps logs provision-token _preflight _bot_check _creds_check _access

## dev — build the 4 core services + infra FROM THIS CHECKOUT and bring the stack up. Does NOT
## build the bot (a separate step — `make bot` — since it's spawned on demand, not a compose service).
dev:
	@$(MAKE) --no-print-directory _preflight
	@[ -f .env ] || { echo "→ no .env found; seeding from .env.example"; cp .env.example .env; }
	IMAGE_TAG=dev $(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory _bot_check
	@$(MAKE) --no-print-directory _creds_check
	@$(MAKE) --no-print-directory _access

## bot — build the meeting bot FROM SOURCE, tagged $(BOT_IMAGE). Builds the join-env base first
## (the bot's own Dockerfile hardcodes `FROM vexa/meet-join-env:dev` — that tag is NOT ours to
## rename). Point BROWSER_IMAGE (.env) at BOT_IMAGE (the default) so the runtime spawns your build.
bot:
	@echo "→ [1/2] join-env base: vexa/meet-join-env:dev"
	docker build -f "$(REPO_ROOT)/core/meetings/modules/join/Dockerfile.env" -t vexa/meet-join-env:dev "$(REPO_ROOT)/core/meetings/modules/join"
	@echo "→ [2/2] meeting bot: $(BOT_IMAGE)"
	docker build -t $(BOT_IMAGE) -f "$(REPO_ROOT)/core/meetings/services/bot/Dockerfile" "$(REPO_ROOT)"
	@_rt=$$($(COMPOSE) ps -q runtime 2>/dev/null); _live=""; \
	 [ -n "$$_rt" ] && _live=$$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $$_rt 2>/dev/null \
	   | grep '^BROWSER_IMAGE=' | cut -d= -f2-); \
	 if [ "$$_live" = "$(BOT_IMAGE)" ]; then \
	   echo "✓ built $(BOT_IMAGE) — the running stack spawns bots from this tag; no restart needed."; \
	 else \
	   echo "✓ built $(BOT_IMAGE) — set BROWSER_IMAGE=$(BOT_IMAGE) in .env, then: make dev"; \
	 fi

## _preflight — fail fast on a too-old Docker engine.
_preflight:
	@v=$$(docker version --format '{{.Server.Version}}' 2>/dev/null); v=$${v#v}; \
	 if [ -z "$$v" ]; then echo "✗ cannot reach the Docker engine — is Docker running?"; exit 1; fi

## _bot_check — warn loudly if BROWSER_IMAGE isn't built locally yet. Without it bots sit in
## `requested` and the meeting gets reaped with zero segments — this makes that failure visible.
_bot_check:
	@_bi=$$(grep -E '^BROWSER_IMAGE=' .env 2>/dev/null | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$$//; s/[[:space:]]+$$//'); \
	 _bi=$${_bi:-$(BOT_IMAGE)}; \
	 if ! docker image inspect "$$_bi" >/dev/null 2>&1; then \
	   echo ""; \
	   echo "═══════════════════════════════════════════════════════════"; \
	   echo "  ⚠️  meeting bot image '$$_bi' is not present on this host."; \
	   echo "      Build it:  make -C deploy/compose bot"; \
	   echo "      Bots will FAIL TO JOIN until the image exists."; \
	   echo "═══════════════════════════════════════════════════════════"; \
	   echo ""; \
	 fi

## _creds_check — warn (never fail) when .env leaves transcription unconfigured.
_creds_check:
	@_envv() { grep -E "^$$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$$//; s/[[:space:]]+$$//'; }; \
	 if [ -z "$$(_envv TRANSCRIPTION_SERVICE_URL)" ] || [ -z "$$(_envv TRANSCRIPTION_SERVICE_TOKEN)" ]; then \
	   echo ""; \
	   echo "═══════════════════════════════════════════════════════════"; \
	   echo "  ⚠️  transcription is NOT configured (TRANSCRIPTION_SERVICE_URL /"; \
	   echo "      TRANSCRIPTION_SERVICE_TOKEN empty in .env)."; \
	   echo "      Bots will join and record but produce NO transcript."; \
	   echo "      Get a free token at https://vexa.ai/account (or self-host"; \
	   echo "      deploy/transcription), set both, then: make dev"; \
	   echo "═══════════════════════════════════════════════════════════"; \
	   echo ""; \
	 fi

down:
	$(COMPOSE) down -v --remove-orphans

## provision-token — mint (idempotently) a self-host API token. Needs ADMIN_TOKEN.
provision-token:
	@ADMIN_TOKEN="$(ADMIN_TOKEN)" EMAIL="$(EMAIL)" SCOPES="$(SCOPES)" ./bin/provision-token

## _access — wait for admin-api, mint the self-host API key, print it + the URL.
_access:
	@_envv() { grep -E "^$$1=" .env | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$$//; s/[[:space:]]+$$//'; }; \
	 ADMIN_TOKEN=$$(_envv ADMIN_TOKEN); \
	 APORT=$$(_envv ADMIN_API_PORT); APORT=$${APORT:-18057}; \
	 GW=$$(_envv API_GATEWAY_HOST_PORT); GW=$${GW:-18056}; \
	 echo "⏳ minting your self-host API key..."; \
	 KEY=""; for i in $$(seq 1 60); do \
	   KEY=$$(ADMIN_TOKEN=$$ADMIN_TOKEN ADMIN_API_URL=http://127.0.0.1:$$APORT EMAIL=$(EMAIL) SCOPES=$(SCOPES) ./bin/provision-token 2>/dev/null) && [ -n "$$KEY" ] && break; \
	   sleep 2; done; \
	 echo ""; \
	 echo "═══════════════════════════════════════════════════════════"; \
	 echo "  Bot Service Lite (compose) is up."; \
	 echo "    API gateway : http://localhost:$$GW  (docs at /docs)"; \
	 if [ -n "$$KEY" ]; then echo "    API key     : $$KEY"; \
	 else echo "    API key     : admin-api not ready — mint later with:"; \
	      echo "                  make -s provision-token ADMIN_TOKEN=<your ADMIN_TOKEN>"; fi; \
	 echo "═══════════════════════════════════════════════════════════"

build:
	$(COMPOSE) build
ps:
	$(COMPOSE) ps
logs:
	$(COMPOSE) logs -f
