# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ First action — every session: orient on the release stage

This repo runs under a **strict stage state machine** (the release protocol). Before
doing *anything* — coding, testing, shipping — run:

```bash
python3 tests3/lib/stage.py probe
```

This prints the current stage, the legal next stages, and a one-line objective. Each
stage has a contract at `tests3/stages/NN-<name>.md` (objective, inputs, outputs, exit
condition, and an explicit **may NOT** list). Read the current stage's file before acting.

**Code editing is confined to the `develop` stage** (entered from `plan` or `triage`).
If asked to do something forbidden by the current stage, refuse with a stage-aware message:

> *"Currently in `<stage>`; that action is forbidden (`<rule>`). To do it, transition
> via `<legal next stage>`."*

Don't bumble trying to make an out-of-stage request work — state the mismatch and the
legal transition path. Map of common asks → stage:

| user says | stage |
|---|---|
| "debug X / fix Y / write code" | `develop` (from `plan` or `triage`) |
| "run the tests / check the gate" | `validate` (from `deploy`) |
| "classify failures / what broke" | `triage` (from `validate` on red) |
| "validate checklist / sign off" | `human` (from `validate` on green) |
| "ship it / merge to main" | `ship` (from `human`) |
| "start a new release / groom issues" | `groom` (from `idle`) |

**You are NOT the user.** Never mark `plan-approval.yaml`, `human-approval.yaml`, or any
stage's exit condition `approved: true` without the user explicitly saying so this turn.
Approval is a human signal — your job is to prepare the material, not grant it.

The full model lives in `tests3/README.md`. Stage skills (`0-groom`, `1-plan`, `triage`,
`7-human`) are invocable and assert their stage on entry.

## Repository structure

The git repo root is the `vexa/` subdirectory (this file lives there). All commands below
run from that root.

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

**Key data flows:**
- *Transcription* — `meeting-api` join request → `runtime-api` spawns a `vexa-bot`
  container → bot joins via browser (CDP + Playwright), captures per-speaker audio →
  HTTP to `transcription-service` (Whisper) → segments to Redis streams → collector in
  `meeting-api` writes to PostgreSQL → `dashboard` reads via gateway.
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
TypeScript/Node (`vexa-bot`, `dashboard`, `packages/*`). `services/README.md` is the
authoritative wiring diagram; each service and `features/<name>/` has its own README + DoD.

### Code vs. contract layout

- `services/` — deployable services (one container each).
- `features/<name>/` — cross-service feature docs + DoD contracts (`README.md` + sidecar
  `dods.yaml`). A feature's `dods.yaml` is the machine-readable source of truth for what
  "done" means; `README.md` is the human prose.
- `packages/` — publishable npm libs (`vexa-cli`, `vexa-client`, `transcript-rendering`).
- `libs/` — shared Python (`admin-models`, `schema-sync`).
- `deploy/` — `compose/` (full stack), `lite/` (single container), `helm/` (K8s).
- `tests3/` — the entire release/validation system (see below).

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

# Single test, directly (best for local dev):
./tests3/tests/webhooks.sh
make -C tests3 run-test TEST=webhooks MODE=compose
```
`make test` diffs against `main` (override with `BASE=<ref>`), pipes changed paths through
`tests3/resolve.py` to pick affected targets, and falls back to `smoke` when nothing maps.

### Docs
```bash
make docs        # static drift check (0s)
make docs-dev    # mintlify dev server on localhost:3000
```

## The `tests3/` release system

`tests3/` is not just tests — it's a **nested-loop release protocol** built on five
primitives. Read `tests3/README.md` for the full model; the essentials:

- **Scope** (`tests3/releases/<id>/scope.yaml`) — the per-release contract: issues,
  hypotheses, and `proves[]` bindings into the Registry. Declared at `plan`, consumed by
  every downstream stage.
- **DoD** (`features/<name>/dods.yaml`) — per-feature "done" contract; `evidence` binds
  each claim to a Registry check + modes. Missing `dods.yaml` is a hard fail (opt out only
  with explicit `dods: []  # reason: X`).
- **Registry** (`tests3/registry.yaml`) — every check, one schema, a `type:` discriminator
  (`grep | http | env | script`). Grows every release, runs in full every release — that
  bidirectionality is what makes regressions impossible.
- **Fresh-infra** — every release provisions from zero (Linode VMs + LKE), validates,
  tears down. No shared staging.
- **Stage machine** — the orchestration state, enforced by `tests3/lib/stage.py`.

**Three nested loops:** INNER (`validate → triage → develop → deploy → validate`, fast,
mechanical) · MIDDLE (`validate green → human → ship`, bounded human attention) · OUTER
(`ship → market → issues → groom`, real users). Each catches what the cheaper one can't,
and writes findings back so next release's cheap loop is smarter.

**Validate has three mechanical phases:** PLAN (build execution graph from registry × scope
× modes; `state:`/`mutates:` drive parallel-vs-serial), EXECUTE (run scripts → emit
`.state/reports/<mode>/<test>.json`), RESOLVE (`lib/aggregate.py`: evidence → report
lookup → DoD status → feature confidence → Gate verdict). AI touches nothing from
plan-build to Gate verdict — that's what keeps the core cheap.

**No "flake" category.** An unreliable check is a **gap** with a root cause (race, timing,
infra fragility, misowned DoD) — never retry-mask it.

Release-cycle Makefile targets are stage-guarded (`make stage` / `release-groom`,
`release-plan`, `release-provision`, `release-deploy`, `release-validate`, `release-triage`,
`release-human`, `release-ship`, `release-teardown`). Each asserts its predecessor stage on
entry and transitions on success. Test scripts emit deterministic JSON via the
`test_begin` / `step_*` / `test_end` helpers in `tests3/lib/common.sh`.
