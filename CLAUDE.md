# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> This is a **fork** of Vexa-ai/vexa used for experimentation (currently: improving
> Turkish STT quality). Work directly in the codebase — no special release/stage protocol
> applies here. Commit per logical change; keep things pragmatic.

## Architecture (the big picture)

Vexa is a **self-hostable meeting bot + transcription platform** — a dozen single-concern
services that communicate over **REST and Redis**, not tight coupling. Three layers:

- **Intelligence layer** — `agent-api` (chat sessions, TTS, in-process scheduler, workspaces).
- **Data layer** — `meeting-api` (bot lifecycle, recordings, callbacks, webhooks; the
  transcription **collector** is built in — it consumes Redis streams and writes segments
  to PostgreSQL). `admin-api` owns users, API tokens, meeting CRUD.
- **Infrastructure layer** — `runtime-api` is the container-orchestration API. It spawns
  containers across three interchangeable backends (Docker socket / K8s pods / child
  process) from YAML profiles, handling idle management, exit callbacks, and concurrency.

Everything fronts through **`api-gateway`** (port 8000): auth middleware, routing, CORS.
`dashboard` (Next.js) is the web UI. `mcp` exposes meeting tools to AI agents.

Peripheral services (not on the core transcription path): `calendar-service` (calendar
sync → scheduled bot joins), `qwen-transcription` (alternative transcription backend to
the default Whisper `transcription-service`), `transcribe-ui` (standalone transcription
front-end), `telegram-bot` (Telegram entry point). `services/README.md` is the
authoritative, complete wiring diagram.

**Key data flows:**
- *Transcription* — `meeting-api` join request → `runtime-api` spawns a `vexa-bot`
  container → bot joins via browser (CDP + Playwright), captures per-speaker audio →
  HTTP to `transcription-service` (Whisper / faster-whisper, OpenAI-compatible
  `/v1/audio/transcriptions`) → segments to Redis streams → collector in `meeting-api`
  writes to PostgreSQL → `dashboard` reads via gateway.
- *Agent chat* — `agent-api` → `runtime-api` spawns a `vexa-agent` container (runs Claude
  Code with workspace context) → responses streamed back via SSE.
- *Scheduler* — not standalone; an in-process worker (Redis sorted sets) that queues timed
  HTTP calls. Code in `runtime-api/runtime_api/scheduler.py`.

**Service ports:** gateway 8000, admin-api 8001, mcp 8010, runtime-api 8090, agent-api
8100, transcription-service 8083, tts-service 8084, dashboard 3000. The public meeting API
is at `http://localhost:8056` (self-hosted) or `https://api.cloud.vexa.ai` (hosted).

**Infra deps:** PostgreSQL (meetings, transcripts, users, tokens), Redis (streams,
pub/sub bot commands, scheduler sorted sets), S3/MinIO (recordings).

The runtime is polyglot: Python (FastAPI services, `requirements.txt` / `pyproject.toml`),
TypeScript/Node (`vexa-bot`, `dashboard`, `packages/*`).

## Repository layout

- `services/` — deployable services (one container each). `services/README.md` is the wiring diagram.
- `features/<name>/` — cross-service feature docs (`README.md` + sidecar `dods.yaml`).
- `packages/` — publishable npm libs (`vexa-cli`, `vexa-client`, `transcript-rendering`).
- `libs/` — shared Python (`admin-models`, `schema-sync`).
- `deploy/` — `compose/` (full stack), `lite/` (single container), `helm/` (K8s).
- `tests3/` — integration test + quality harness (see below).

## Common commands

### Deploy / run locally
```bash
make all          # full stack via Docker Compose (each service separate)
make lite         # single-container deploy (Vexa Lite) — quick eval
make build        # build all images from source
make down         # stop the compose stack
```

### Test
```bash
make smoke                       # run all fast checks (~30s)
make test                        # resolve changed files → run only affected tests
make what-changed                # dry-run: show which tests `make test` would run
make full                        # run everything

# Single integration test, directly (best for local dev):
./tests3/tests/webhooks.sh
make -C tests3 run-test TEST=webhooks MODE=compose
```
`make test` diffs against `main` (override with `BASE=<ref>`), pipes changed paths through
`tests3/resolve.py` to pick affected targets, and falls back to `smoke` when nothing maps.

**Per-service unit tests** (what CI runs on PRs, see `.github/workflows/test-*.yml`):
```bash
# Python services (FastAPI) — install editable, then pytest the service's tests/ dir.
# Skip live-integration files (they need a running stack):
pip install -e libs/admin-models/ -e services/meeting-api/
pytest services/meeting-api/tests/ -v --ignore=services/meeting-api/tests/test_integration_live.py
pytest services/meeting-api/tests/test_webhooks.py::test_name   # a single test

# Node packages:
cd packages/transcript-rendering && npm ci && npm test
```
Per-service CI workflows are **path-triggered** — only `admin-api`, `api-gateway`,
`meeting-api`, and `packages/*` have dedicated test workflows.

### Transcription quality harness (Turkish STT work)
The STT quality tooling lives in `services/transcription-service/tests/quality/` —
synthetic TTS-generated datasets with WER/CER metrics and a quality gate:
```bash
cd services/transcription-service
python -m tests.quality.dataset_generate --languages tr   # build TTS dataset
python -m tests.quality.run_quality --languages tr        # score WER/CER
```
Supported languages are declared in `tests/quality/phrases.py` (`LANGUAGES` / `PHRASES`);
text normalization for metrics is in `tests/quality/metrics.py`.

### Docs
```bash
make docs        # static drift check (0s)
make docs-dev    # mintlify dev server on localhost:3000
```
