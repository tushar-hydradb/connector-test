# HANDOFF — LIVE end-to-end connector test (Notion)

**Status: BLOCKED on host disk full.** Everything is built and running; the LIVE run cannot
complete because MinIO is out of disk. Read "To resume" first.

## Goal
Drive the whole connector pipeline **end-to-end on LOCAL shared infra** and prove data lands and
becomes queryable:

```
POST /connectors (sync_engine=moveit, KMS-encrypted creds)  ── hydradb Go API :8080
   → connectors-SCHEDULER ticks the due connector (~30s)     ── cmd/connectors-scheduler
   → connectors-WORKER runs MoveitSyncWorkflow               ── cmd/connectors-worker (queue connector-orchestrator)
       → MOVEIT :8090  provision + notion tap → S3/Lance (moveit-lake)
       → child LanceDrainWorkflow → writes JSON batch to shared S3
   → cortex-ingestion worker (queue shared-all) AppSourceBatchWorkflow
       → embed → Milvus + writes indexing status
   → GET /context/status → indexing_status=completed ; POST /context/list ; POST /v2/query
```

Everything points at **local containers only** (no cloud/staging): DynamoDB `:8082`, MinIO/S3
`:9002`, Temporal `:7233`, moto KMS `:4566`, Milvus `:19530`, FalkorDB `:6379`.

## The test driver (this repo)
`hurl/` — hurl suite + `run.sh` orchestrator. `BASE` + `API_KEY` are variables so the same suite
runs against local or staging. See `hurl/README.md` for the full contract. Two modes:
- **contract** (no `PROVIDER_TOKEN`): phases 01/02/04/05, no worker/real token needed. **Verified GREEN**
  against the live Go API this session.
- **LIVE** (`PROVIDER_TOKEN=<real notion>`): adds phase 03 — waits for the scheduler-driven drain,
  then asserts the source reaches `completed` and is queryable. **This is what is blocked.**

`HURL_VERBOSE=1` makes `run.sh` emit the full real HTTP exchange (for an audit trail).

## What is running right now (tmux session `connector-test`)
`tmux attach -t connector-test` — one window per process, also tee'd to `logs/<name>.log`:

| Window | Command (run-script) | Port | Task queue | State |
|---|---|---|---|---|
| moveit | `run-moveit.sh` | 8090 | moveit-sync | UP (500s on Lance write — disk) |
| go-api | `run-go-api.sh` | 8080 | connector-orchestrator (in-proc) | UP, /health ok |
| go-scheduler | `run-go-connectors-scheduler.sh` **(new)** | — | connector-orchestrator | running |
| go-conn-worker | `run-go-connectors-worker.sh` | — | connector-orchestrator | running |
| ingestion-worker | uvicorn **no --reload** (see gotcha) | 8001 | shared-all | UP |

## Root-cause of the block
Host root disk is **100% full** (`/dev/nvme1n1p2 239G, ~2.4G free`). MinIO lives under `/` and
rejects writes: `XMinioStorageFull: Storage backend has reached its minimum free drive threshold`.
So MOVEIT `ProvisionMoveit` cannot write the Lance table to `s3://moveit-lake/...` → **HTTP 500**,
retried by the worker. MinIO's own data is 2.6 MB; the disk is eaten by build artifacts:
`MOVEIT/target` = **40 GB**, `moveit-parallel-work` = 8.7 GB, `MOVEIT/meltano-scratchpad` = 3.5 GB,
docker reclaimable ≈ 2 GB.

## To resume (do these in order)
1. **Free disk** so MinIO has headroom (aim for >5 GB free). Biggest safe win:
   `cd ~/code/MOVEIT && cargo clean` (frees ~40 GB; MOVEIT is already running so no immediate impact,
   but a later MOVEIT restart recompiles). Or free space another way. Confirm with `df -h /`.
2. **Delete the stale connector** that the scheduler keeps retrying (leftover from a prior session,
   resource `workspace-1`, id begins `aaee44c2`):
   `curl -XDELETE -H "Authorization: Bearer $API_KEY" http://localhost:8080/connectors/aaee44c2-06ac-40cc-81d0-613323a99f2f`
   (or list `GET /connectors` and delete whatever is not from your run).
3. **Bring the stack back if any window died** (see "How the stack was started" below).
4. **Run the LIVE suite** (real Notion token supplied at runtime — never commit it):
   ```sh
   cd ~/code/connector-test/hurl
   HURL_VERBOSE=1 \
   BASE=http://localhost:8080 \
   API_KEY='sk_test_localdevkey.localsecret1234567890abcdefghijklmnopqrst' \
   TENANT=e2e-test-tenant TENANT_PREEXISTS=1 \
   PROVIDER=notion \
   PROVIDER_TOKEN='<REAL_NOTION_TOKEN>' \
   SCHEDULER_WAIT=35 POLL_INTERVAL=10 DRAIN_TIMEOUT=600 \
   ./run.sh 2>&1 | tee LIVE-audit-$(date +%s).log
   ```
5. Watch progress in the `go-conn-worker`, `moveit`, and `ingestion-worker` tmux windows.

## How the stack was started (repro from scratch)
1. Shared infra already up. If not: `~/code/connector-test/10-infra-up.sh`. KMS specifically:
   `bash ~/code/hydradb-application/scripts/local-secrets-bootstrap.sh` (moto on :4566).
2. Seed all tables: `~/code/connector-test/20-seed.sh`. This creates `cortex_api_keys_v2_local` with
   the local dev key, tenant mapping `e2e-test-tenant`, `oauth_connectors_local` (+ GSI
   `ConnectorsByStatusNextSyncAt`), MOVEIT tables, ingestion tables. (cortex-application poetry venv
   needs `boto3`+`argon2-cffi`.)
3. **Inject real embedding keys** into `~/code/hydradb-application/.env.local.e2e` (the Go API needs
   `GEMINI/GROQ/GOOGLE` present at boot — `config.MustLoad` — and for `/v2/query` embeddings). This
   session copied the active `GEMINI/GROQ/OPENAI/COHERE` values from
   `~/code/cortex-ingestion/.env.local` under a `# ---- connector-test LIVE LLM keys ----` marker.
4. Launch tmux windows (see table). `up.sh` in this repo launches most of them; the **scheduler is
   not in it** — use `run-go-connectors-scheduler.sh` (added this session).

## Gotchas discovered (do not relearn the hard way)
- **ingestion worker must NOT use `uvicorn --reload`** — watchfiles breaks the Temporal worker so it
  never registers on `shared-all`. Run:
  `cd ~/code/cortex-ingestion && RUN_TEMPORAL_WORKER=true poetry run uvicorn app:app --host 0.0.0.0 --port 8001 --env-file .env.local`
  (hydradb's `make worker` uses `--reload` — override it). The ingestion API (:8000), if needed:
  `WATCHFILES_IGNORE_PERMISSION_DENIED=1 poetry run uvicorn app:app --port 8000 --env-file .env.local`.
- **The scheduler is a separate binary** (`cmd/connectors-scheduler`), not in the Go API or the
  worker. Without it, a moveit connector never syncs. Its dynamo client uses `AWS_ENDPOINT_URL` as the
  **DynamoDB** endpoint — `run-go-connectors-scheduler.sh` forces it to `:8082`.
- **`resource_id` must be a real Notion database/page id** for the Go classic fetcher — `workspace-1`
  gives `404 Could not find database with ID: workspace-1`. For the MOVEIT tap this was NOT confirmed
  (disk blocked us before ProvisionMoveit succeeded). Get real ids via `GET /connectors/:id/discover`
  or `POST /connector-discovery`, and set `RESOURCE_ID`/edit `01_add_connector.hurl` accordingly.
- **`sync_engine` is not echoed by GET/List** (`store.connectorProjection` omits it); only the create
  response and the scheduler's read include it. Assert it on create, not on GET.
- **Local dev API key** (seeded, not secret): `sk_test_localdevkey.localsecret1234567890abcdefghijklmnopqrst`
  (org `pv6jfg3zw5`, user `local-dev-user-001`). The **Notion token is real and user-supplied** — pass
  it via `PROVIDER_TOKEN` at runtime; never commit it. `logs/` and `hurl/*.log` are gitignored.

## Verified vs pending
- ✅ Contract mode green against the live Go API (create → sync 202 → delete → 404 → negatives).
- ✅ Full local stack boots and interconnects (5 services, Temporal queues, KMS decrypt path).
- ⏳ LIVE end-to-end to a `completed` source: **blocked at MOVEIT Lance write by disk-full**. No
  completed source produced yet. Resume at "To resume" once disk is freed.
