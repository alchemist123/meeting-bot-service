# =============================================================================
# Bot Service Lite (meetings-only) — single-container build + deploy
# =============================================================================
# `make lite` (from repo root) → this Makefile's `all`: provisions PostgreSQL + MinIO + Redis
# sidecar containers, pulls/builds the all-in-one image, runs it on the host network with the
# process backend, and verifies the front door. The app image is lean; postgres/minio/redis
# stay external (redis as its own container means it survives an app-container rebuild/restart,
# unlike an in-container redis).
.PHONY: all up down init-db test env preflight build push build-and-push set-latest set-dev setup-builder help stt-smoke

# --- Paths ---
ROOT       := $(shell git rev-parse --show-toplevel)
ENV_FILE   := $(ROOT)/.env
DOCKERFILE := $(ROOT)/deploy/lite/Dockerfile.lite
CONTEXT    := $(ROOT)

# --- DockerHub / image ---
DOCKERHUB_USER ?= vexaai
IMAGE_NAME     ?= bot-service-lite
TAG            ?= dev
LOCAL_TAG      := $(IMAGE_NAME):$(TAG)
PLATFORMS      ?= linux/amd64,linux/arm64
BUILDER_NAME   ?= bot-service-multiarch
UNIQUE_TAG     := $(shell date +%y%m%d-%H%M)
UNIQUE_DOCKERHUB_TAG := $(DOCKERHUB_USER)/$(IMAGE_NAME):$(UNIQUE_TAG)
LAST_TAG_FILE  := $(ROOT)/deploy/lite/.last-tag

# --- Network + sidecars + storage defaults ---
# A user-defined bridge so the app's INTERNAL services live on the container's own loopback (no host
# port collisions); only the front doors are published. postgres/minio join the same bridge and the
# app reaches them by container name. Override HOST_*_PORT to avoid conflicts on a busy host.
NETWORK         ?= bot-service-lite-net
PG_CONTAINER    ?= bot-service-lite-postgres
MINIO_CONTAINER ?= bot-service-lite-minio
REDIS_CONTAINER ?= bot-service-lite-redis
APP_CONTAINER   ?= bot-service-lite
HOST_GATEWAY_PORT   ?= 8056
MINIO_ACCESS_KEY ?= vexa-access-key
MINIO_SECRET_KEY ?= vexa-secret-key
MINIO_BUCKET     ?= vexa

# --- Local CPU STT (LOCAL_STT=1) ---------------------------------------------------------------
# Transcription in Vexa is always an external OpenAI-compatible /v1/audio/transcriptions service.
# For a self-host (or a witness box) with NO hosted token and NO GPU, `make up LOCAL_STT=1` runs a
# bundled faster-whisper CPU server on the tiny model and auto-wires TRANSCRIPTION_SERVICE_URL to
# it — transcripts work out of the box, slower but real. The client sends model=whisper-1 (the
# OpenAI id); faster-whisper-server accepts it and serves WHISPER_MODEL. Override for a bigger
# model (WHISPER_MODEL=Systran/faster-whisper-small.en) or a GPU image.
LOCAL_STT        ?=
WHISPER_CONTAINER ?= bot-service-lite-whisper
WHISPER_IMAGE    ?= fedirz/faster-whisper-server:latest-cpu
WHISPER_MODEL    ?= Systran/faster-whisper-tiny.en
HOST_STT_PORT    ?= 8083

define set_tag
	@echo "Setting '$(1)' → $(2)..."
	docker buildx imagetools create -t $(DOCKERHUB_USER)/$(IMAGE_NAME):$(1) $(DOCKERHUB_USER)/$(IMAGE_NAME):$(2)
endef

help:
	@echo "Bot Service Lite (meetings-only)"
	@echo "  make -C deploy/lite all     # provision + run + verify (this is `make lite` from root)"
	@echo "  make -C deploy/lite down    # stop + remove app + sidecars"
	@echo "  make -C deploy/lite build   # build the image locally (tagged :dev)"
	@echo "  make -C deploy/lite push    # multi-arch build+push, move the 'dev' tag"
	@echo "  make -C deploy/lite test    # probe the front doors"

# ── Deploy lifecycle ──────────────────────────────────────────────────────────────────────────────
all: env preflight up init-db test
	@HOST=$$(hostname -I 2>/dev/null | awk '{print $$1}'); HOST=$${HOST:-localhost}; \
	echo ""; echo "Bot Service Lite is running."; \
	echo "  API docs:  http://$$HOST:$(HOST_GATEWAY_PORT)/docs"; \
	echo "  API key:   docker logs $(APP_CONTAINER) | grep VEXA_API_KEY"

## env — ensure a repo-root .env exists (seed from .env.example if present, else a minimal template).
env:
	@if [ ! -f "$(ENV_FILE)" ]; then \
		if [ -f "$(ROOT)/.env.example" ]; then \
			echo "Seeding $(ENV_FILE) from .env.example"; cp "$(ROOT)/.env.example" "$(ENV_FILE)"; \
		else \
			echo "Creating minimal $(ENV_FILE) (edit TRANSCRIPTION_SERVICE_* for transcripts)"; \
			printf 'ADMIN_TOKEN=changeme\nTRANSCRIPTION_SERVICE_URL=\nTRANSCRIPTION_SERVICE_TOKEN=\nIMAGE_TAG=v012\n' > "$(ENV_FILE)"; \
		fi; \
	fi

## preflight — Docker must be up.
preflight:
	@docker info > /dev/null 2>&1 || { echo "ERROR: Docker is not running."; exit 1; }

## up — a bridge network, postgres + minio + redis sidecars (by name), then the all-in-one
## container with only the front door published. Internal services live on the container's own
## loopback.
##
## The recipe is ONE `\`-continued shell command: a bare `#` line inside it (no trailing `\`) ends
## the continuation, so make runs the rest in a SEPARATE shell where IMG/ADMIN_TK/… are already
## lost — which once shipped `docker run … $IMG` with an EMPTY image (bot-service-lite never created,
## every front door down). Keep all commentary OUT of the recipe body; annotate here instead.
##
## `envv` strips an INLINE COMMENT and trailing space from a .env value. `.env.example` once shipped
## `ADMIN_TOKEN=dev-admin-token   # admin-api auth…`; a bare `cut -d= -f2-` kept the comment, and the
## unquoted `-e ADMIN_API_TOKEN=$ADMIN_TK` then word-split it so a lone `#` landed in the IMAGE slot
## — `docker: invalid reference format`, the v0.12.5 witness's finding #3. Values interpolated into
## `docker run` are QUOTED for the same reason. `$$CLAUDE_MOUNT` is the deliberate exception: it
## carries multiple argv words and MUST stay unquoted — do not "fix" it.
##
## Note this recipe does NOT `-e` the spawn-default flags (TRANSCRIBE_ENABLED/RECORDING_ENABLED);
## they ride `--env-file`, where an empty value must keep the default. That is enforced in code
## (bot_spawn/env_flags.py), not here — compose's `${VAR:-true}` has no `--env-file` equivalent.
up: preflight
	@set -e; \
	docker network inspect $(NETWORK) >/dev/null 2>&1 || docker network create $(NETWORK) >/dev/null; \
	envv() { grep -E "^$$1=" "$(ENV_FILE)" 2>/dev/null | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$$//; s/[[:space:]]+$$//'; }; \
	ADMIN_TK=$$(envv ADMIN_TOKEN); ADMIN_TK=$${ADMIN_TK:-changeme}; \
	TX_URL=$$(envv TRANSCRIPTION_SERVICE_URL); \
	TX_TOKEN=$$(envv TRANSCRIPTION_SERVICE_TOKEN); \
	IMAGE_TAG=$$(envv IMAGE_TAG); IMAGE_TAG=$${IMAGE_TAG:-v012}; \
	IMG=$$(docker image inspect $(LOCAL_TAG) >/dev/null 2>&1 && echo $(LOCAL_TAG) || echo $(DOCKERHUB_USER)/$(IMAGE_NAME):$$IMAGE_TAG); \
	echo "Starting PostgreSQL ($(PG_CONTAINER))..."; \
	if ! docker ps -q -f name=$(PG_CONTAINER) | grep -q .; then \
		docker rm -f $(PG_CONTAINER) 2>/dev/null || true; \
		docker run -d --name $(PG_CONTAINER) --network $(NETWORK) --restart unless-stopped \
			-e POSTGRES_DB=vexa -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
			-e TZ=UTC -e PGTZ=UTC \
			-v bot-service-lite-pgdata:/var/lib/postgresql/data \
			postgres:17-alpine -c idle_in_transaction_session_timeout=60000 > /dev/null; \
		for i in $$(seq 1 24); do docker exec $(PG_CONTAINER) pg_isready -U postgres -d vexa -q 2>/dev/null && break; sleep 2; done; \
	fi; echo "  ✓ PostgreSQL ready"; \
	echo "Starting MinIO ($(MINIO_CONTAINER))..."; \
	if ! docker ps -q -f name=$(MINIO_CONTAINER) | grep -q .; then \
		docker rm -f $(MINIO_CONTAINER) 2>/dev/null || true; \
		docker run -d --name $(MINIO_CONTAINER) --network $(NETWORK) --restart unless-stopped \
			-e MINIO_ROOT_USER=$(MINIO_ACCESS_KEY) -e MINIO_ROOT_PASSWORD=$(MINIO_SECRET_KEY) \
			-v bot-service-lite-miniodata:/data \
			minio/minio:latest server /data --console-address ":9001" > /dev/null; \
		sleep 4; \
		docker run --rm --network $(NETWORK) --entrypoint sh minio/mc:latest -c \
			"mc alias set vexa http://$(MINIO_CONTAINER):9000 $(MINIO_ACCESS_KEY) $(MINIO_SECRET_KEY) && mc mb --ignore-existing vexa/$(MINIO_BUCKET)" >/dev/null 2>&1 || true; \
	fi; echo "  ✓ MinIO ready"; \
	echo "Starting Redis ($(REDIS_CONTAINER))..."; \
	if ! docker ps -q -f name=$(REDIS_CONTAINER) | grep -q .; then \
		docker rm -f $(REDIS_CONTAINER) 2>/dev/null || true; \
		docker run -d --name $(REDIS_CONTAINER) --network $(NETWORK) --restart unless-stopped \
			-v bot-service-lite-redisdata:/data \
			redis:7-alpine redis-server --appendonly yes --appendfsync everysec > /dev/null; \
		for i in $$(seq 1 24); do docker exec $(REDIS_CONTAINER) redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 2; done; \
	fi; echo "  ✓ Redis ready"; \
	if [ -n "$(LOCAL_STT)" ]; then \
		echo "Starting local CPU STT ($(WHISPER_CONTAINER), $(WHISPER_MODEL))..."; \
		if ! docker ps -q -f name=$(WHISPER_CONTAINER) | grep -q .; then \
			docker rm -f $(WHISPER_CONTAINER) 2>/dev/null || true; \
			docker run -d --name $(WHISPER_CONTAINER) --network $(NETWORK) --restart unless-stopped \
				-e WHISPER__MODEL=$(WHISPER_MODEL) -e WHISPER__INFERENCE_DEVICE=cpu -e WHISPER__TTL=-1 \
				-p $(HOST_STT_PORT):8000 \
				$(WHISPER_IMAGE) > /dev/null; \
		fi; \
		echo "  Waiting for the STT model to load (up to 3 min)..."; \
		for i in $$(seq 1 36); do curl -sf -o /dev/null http://localhost:$(HOST_STT_PORT)/health 2>/dev/null && break; sleep 5; done; \
		TX_URL=http://$(WHISPER_CONTAINER):8000; TX_TOKEN=; \
		echo "  ✓ local STT ready — routing transcription to $$TX_URL (model $(WHISPER_MODEL))"; \
	fi; \
	echo "Starting Bot Service Lite ($$IMG)..."; \
	docker rm -f $(APP_CONTAINER) 2>/dev/null || true; \
	docker run -d --name $(APP_CONTAINER) --shm-size=2g --network $(NETWORK) --restart unless-stopped \
		--env-file "$(ENV_FILE)" \
		-p $(HOST_GATEWAY_PORT):8056 \
		-e DB_HOST=$(PG_CONTAINER) -e DB_PORT=5432 -e DB_NAME=vexa -e DB_USER=postgres -e DB_PASSWORD=postgres \
		-e REDIS_HOST=$(REDIS_CONTAINER) -e REDIS_PORT=6379 \
		-e ADMIN_API_TOKEN="$$ADMIN_TK" -e ADMIN_TOKEN="$$ADMIN_TK" \
		-e TRANSCRIPTION_SERVICE_URL="$$TX_URL" -e TRANSCRIPTION_SERVICE_TOKEN="$$TX_TOKEN" \
		-e MINIO_ENDPOINT=$(MINIO_CONTAINER):9000 -e MINIO_ACCESS_KEY=$(MINIO_ACCESS_KEY) \
		-e MINIO_SECRET_KEY=$(MINIO_SECRET_KEY) -e MINIO_BUCKET=$(MINIO_BUCKET) -e MINIO_SECURE=false \
		-e VEXA_PUBLIC_API_URL=http://localhost:$(HOST_GATEWAY_PORT) \
		"$$IMG" > /dev/null; \
	echo "  Waiting for the gateway (up to 3 min)..."; \
	for i in $$(seq 1 36); do curl -sf -o /dev/null http://localhost:$(HOST_GATEWAY_PORT)/health 2>/dev/null && break; sleep 5; done; \
	echo "  ✓ Bot Service Lite running"

## init-db — schema converges on each service's startup (admin/meeting ensure_schema); no-op hook.
init-db:
	@echo "  ✓ Schema converges in-process on service startup"

## test — probe the published front door.
test:
	@if curl -sf -o /dev/null http://localhost:$(HOST_GATEWAY_PORT)/health 2>/dev/null; then \
		echo "  ✓ gateway (:$(HOST_GATEWAY_PORT))"; else echo "  ✗ gateway not responding (:$(HOST_GATEWAY_PORT))"; exit 1; fi

## down — stop + remove app + sidecars + network (volumes persist; `docker volume rm
## bot-service-lite-pgdata bot-service-lite-miniodata bot-service-lite-redisdata` to wipe).
down:
	@echo "Stopping Bot Service Lite..."
	@docker rm -f $(APP_CONTAINER) $(PG_CONTAINER) $(MINIO_CONTAINER) $(REDIS_CONTAINER) $(WHISPER_CONTAINER) 2>/dev/null || true
	@docker network rm $(NETWORK) 2>/dev/null || true
	@echo "  ✓ Stopped (data volumes kept)"

## stt-smoke — prove the local STT actually transcribes: synthesize speech, POST it as the client
## does (model=whisper-1, verbose_json), and assert non-empty text. The machine check that the
## witness box will transcribe BEFORE a human is asked to speak (validation ladder: machine first).
## Requires LOCAL_STT to be up (HOST_STT_PORT published). Uses containers for espeak/ffmpeg — no
## host tools needed.
stt-smoke:
	@set -e; \
	echo "Synthesizing test speech + transcribing via local STT (:$(HOST_STT_PORT), model=whisper-1)..."; \
	docker run --rm -v /tmp:/out --entrypoint sh $(WHISPER_IMAGE) -c 'exit 0' 2>/dev/null || true; \
	TMP=$$(mktemp -d); \
	docker run --rm -v $$TMP:/out debian:stable-slim sh -c \
		'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq espeak-ng ffmpeg >/dev/null 2>&1 && \
		 espeak-ng "the quick brown fox jumps over the lazy dog" -w /tmp/s.wav 2>/dev/null && \
		 ffmpeg -y -i /tmp/s.wav -ar 16000 -ac 1 /out/speech.wav >/dev/null 2>&1'; \
	OUT=$$(curl -s --max-time 90 http://localhost:$(HOST_STT_PORT)/v1/audio/transcriptions \
		-F file=@$$TMP/speech.wav -F model=whisper-1 -F response_format=verbose_json); \
	rm -rf $$TMP; \
	echo "  STT response: $$OUT" | head -c 300; echo; \
	echo "$$OUT" | grep -qiE 'quick brown fox|lazy dog' \
		&& echo "  ✓ local STT transcribes (model=whisper-1 → words)" \
		|| { echo "  ✗ local STT returned no expected words — check $(WHISPER_CONTAINER) logs"; exit 1; }

# ── Image build / publish ──────────────────────────────────────────────────────────────────────────
build: preflight
	docker build -f "$(DOCKERFILE)" -t $(LOCAL_TAG) "$(CONTEXT)"
	@echo "Built $(LOCAL_TAG)"

setup-builder:
	@docker buildx inspect $(BUILDER_NAME) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDER_NAME) --driver docker-container --bootstrap

push: setup-builder
	docker buildx build --builder $(BUILDER_NAME) --platform $(PLATFORMS) \
		-f "$(DOCKERFILE)" -t $(UNIQUE_DOCKERHUB_TAG) --push "$(CONTEXT)"
	@echo "$(UNIQUE_TAG)" > "$(LAST_TAG_FILE)"
	$(call set_tag,dev,$(UNIQUE_TAG))

build-and-push: push

set-latest:
	@T=$${TAG:-$$(cat $(LAST_TAG_FILE) 2>/dev/null)}; [ -n "$$T" ] || { echo "No TAG / .last-tag"; exit 1; }; \
	docker buildx imagetools create -t $(DOCKERHUB_USER)/$(IMAGE_NAME):latest $(DOCKERHUB_USER)/$(IMAGE_NAME):$$T

set-dev:
	@T=$${TAG:-$$(cat $(LAST_TAG_FILE) 2>/dev/null)}; [ -n "$$T" ] || { echo "No TAG / .last-tag"; exit 1; }; \
	docker buildx imagetools create -t $(DOCKERHUB_USER)/$(IMAGE_NAME):dev $(DOCKERHUB_USER)/$(IMAGE_NAME):$$T
