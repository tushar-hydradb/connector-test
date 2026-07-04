# connector-test — one shared local stack for the whole connector flow

Stands up **one** set of backing infra with **shared credentials** and starts every
service + Temporal worker so the full pipeline can be exercised end-to-end across four repos:

```
dashboard-2.0 (:3000) ─▶ hydradb-application Go API (:8080)   create connector (sync_engine=moveit),
                              │                                 encrypt secret via moto KMS,
                              │                                 write oauth_connectors_local
                              ▼ Temporal (connector-orchestrator, in-process worker)
                         connectors-worker (Go)   MoveitSyncWorkflow / LanceDrainWorkflow
                              │  MOVEIT_BASE_URL=http://localhost:8090
                              ▼
                         MOVEIT (:8090)   resolve creds (moto KMS decrypt) → meltano tap → S3/Lance
                              │           Temporal queue: moveit-sync
                              ▼  Go drains MOVEIT /data → writes connector batches (JSON) to shared S3
                         cortex-ingestion worker (Temporal: shared-all)   AppSourceBatchWorkflow
                              │  reads S3 batch → chunk / embed / graph
                              ▼
                         Milvus + FalkorDB   ◀── cortex-ingestion API (:8000) drainer
```

This harness is a **thin orchestrator**: the shared backing stack is
`hydradb-application/scripts/local-e2e/docker-compose.shared.yml` (+ moto KMS). connector-test
delegates to hydradb's own scripts and adds only the MOVEIT + cortex-ingestion wiring.

## Quick start
```sh
cd ~/code/connector-test
./up.sh                       # preflight → infra → seed → tmux session with every process
tmux attach -t connector-test # watch the windows (Ctrl-b n / p to switch)
./status.sh                   # health of infra + apps + temporal queues
./down.sh                     # stop the apps (keep infra);  ./down.sh --infra also stops containers
```
Variants: `./up.sh --infra-only` (stack + seed, no apps), `./up.sh --skip-infra` (relaunch apps only),
`./up.sh --skip-seed`.

## Port map
| Process | Port | Repo |
|---|---|---|
| dashboard (Next.js) | 3000 | dashboard-2.0/next-app |
| Go API (+ in-proc connector-orchestrator worker) | 8080 | hydradb-application |
| **MOVEIT** server (+ in-proc `moveit-sync` worker) | **8090** | MOVEIT (this repo) |
| cortex-ingestion API + inbox drainer | 8000 | cortex-ingestion |
| cortex-ingestion Temporal worker (`shared-all`) | 8001 | cortex-ingestion |
| Go `connectors-worker` (drives MOVEIT) | — (no port) | hydradb-application |
| DynamoDB `8082` · MinIO `9002/9003` · Temporal `7233` · Temporal-UI `8088` · moto-KMS `4566` · Milvus `19530` · FalkorDB `6379` · Mongo `27017` · Kafka `9092` | | shared-net |

MOVEIT runs on **8090** because Go owns 8080; that URL is what feeds `MOVEIT_BASE_URL`.

## Shared credentials (one set — see `env/shared.env`)
- AWS: `minioadmin` / `minioadmin`, region `us-east-1`. MinIO needs these; DynamoDB-local
  (`-sharedDb`) and moto KMS ignore creds, so the single set serves MOVEIT's DDB + S3 + KMS.
- Endpoints: DynamoDB `:8082`, S3→MinIO `:9002`, KMS→moto `:4566`, Temporal `:7233`.
- KMS: alias `alias/hydradb-local-connectors`, encryption context `{secret_id, org_id, user_id}`
  (byte-identical between hydradb's `dynamokms.go` and MOVEIT's resolver — so MOVEIT decrypts
  exactly what the Go API encrypted).
- Golang tables: `oauth_connectors_local`, `oauth_connector_resources_local`,
  `connector_credentials_local`. MOVEIT tables: `moveit_cursors`, `moveit_state`. Lake bucket
  `moveit-lake`; connector-batch/handoff bucket `documents`.
- Dashboard auth: `NEXTAUTH_SECRET=some-secret-next-auth`, DynamoDB table `cortex-users-local`.
- FalkorDB runtime password is `falkordb!` (with the bang).

## Files
| File | Role |
|---|---|
| `env/shared.env` | canonical creds + endpoints + table/bucket names + port map |
| `00-preflight.sh` | verify tools (docker/go/poetry/node/cargo/meltano/uvx/tmux/…) + checkouts |
| `10-infra-up.sh` | hydradb `infra-up.sh` + moto `local-secrets-bootstrap.sh` + `prepare-env.sh` + **KMS patch** |
| `20-seed.sh` | hydradb `seed-local.sh` + MOVEIT tables/bucket + cortex-ingestion tables |
| `run-*.sh` | one per process (MOVEIT, go-api, go-connectors-worker, ingestion-api/worker, dashboard) |
| `up.sh` / `status.sh` / `down.sh` | tmux launcher · health doctor · teardown |

## End-to-end smoke (after `up.sh`, once `status.sh` is green)
1. Create a Notion connector through the **Go API** (`sync_engine=moveit`) with a real token — the
   Go API KMS-encrypts it into `connector_credentials_local`.
2. The Go `connectors-worker` calls MOVEIT `/provision` + `/trigger`; MOVEIT resolves + decrypts the
   token, runs the tap, lands rows in Lance (verify: `curl -XPOST localhost:8090/<cid>/data -d '{"sql":"SELECT count(*) AS n"}'`).
3. The Go `LanceDrainWorkflow` reads MOVEIT `/data`, writes a JSON batch to shared S3;
   cortex-ingestion's `AppSourceBatchWorkflow` (queue `shared-all`) consumes it → Milvus/FalkorDB.
4. `./down.sh` stops the apps; infra + volumes stay up for a fast restart.

## Important wiring notes / caveats
- **MOVEIT↔cortex is S3-mediated**, driven by hydradb's `connectors-worker` (`LanceDrainWorkflow`) —
  NOT MOVEIT's `MOVEIT_INBOX_TABLE` path (that's off in MOVEIT today). The worker isn't in hydradb's
  tmux harness, so this harness runs it (`run-go-connectors-worker.sh`) with `MOVEIT_BASE_URL`.
- **KMS gap filled here**: hydradb has no base `.env.local`, so its `prepare-env.sh` produces an e2e
  env WITHOUT KMS keys → the Go connector feature would be silently disabled. `10-infra-up.sh`
  patches `KMS_KEY_ID` / `KMS_ENDPOINT_URL` / `SECRETS_MANAGER_ENDPOINT_URL` / `MOVEIT_BASE_URL`
  into `hydradb-application/.env.local.e2e`.
- **DynamoDB endpoint** standardized on **`:8082`** (the shared-net stack). The repos also carry a
  `:8100` convention in their non-e2e envs — not used here.
- **Do NOT run cortex-ingestion's own `make local-up`** — it would start a second Milvus/FalkorDB/
  MinIO that collide with the shared stack. This harness points ingestion at the shared endpoints.
- `seed-local.sh` imports `../cortex-application/scripts/seed_local_dynamo.py`; a cortex-application
  checkout must exist (preflight checks it). cortex-application is **not run** (its :8080 collides
  with Go); Go is the sole backend.
- cortex-ingestion table schemas beyond the inbox (`doc_id`) and status (`composite_pk`) tables are
  created best-effort single-PK; if the ingestion service reports a schema mismatch, fix in
  `20-seed.sh`.
- The repos' committed `.env.local` files contain real-looking secrets — this harness supplies its
  own local overrides and never prints or commits them.

## Verified & host prerequisites (found while bringing this up)
- **Clean host**: bring up ONE stack. If cortex-*/ingestion-*/moveit-* containers from other local
  harnesses are running they collide on 7233/9091/19530 — stop them + `docker compose -f
  hydradb-application/scripts/local-e2e/docker-compose.shared.yml down` first (named volumes kept),
  which is what a clean `up.sh` assumes.
- **`nc` not required**: hydradb's `infra-up.sh` waits with `nc -z` (absent on some hosts → false
  timeout). `10-infra-up.sh` deliberately calls `docker compose up -d` directly + waits over
  `/dev/tcp` instead, so it doesn't need `nc`.
- **cortex-application venv**: `seed-local.sh` runs cortex-application's `seed_local_dynamo.py`
  (creates the auth/user/tenant + ingestion tables). That venv needs `boto3` + `argon2-cffi`:
  `cd ../cortex-application && poetry run pip install boto3 argon2-cffi` (or a full `poetry install`).
- **api_protector table**: cortex-ingestion's `create_api_protector_table.py` rejects the local dummy
  creds (`UnrecognizedClientException`) — non-fatal; `20-seed.sh` continues. Create `api_protector_local`
  by hand only if the ingestion API needs it.
- **`connector_credentials_local`** is auto-created by the Go server at boot (`EnsureTable`); it isn't
  pre-seeded. MOVEIT only reads it during a resolve, which happens after the Go API has created a
  connector, so the ordering is safe.
- **Verified this session**: infra (9/9 endpoints), all 19 tables + buckets seeded, and MOVEIT booting
  against the shared stack (golang-table resolver on `oauth_connectors_local`, Temporal `:7233` queue
  `moveit-sync`, `/health` ok on `:8090`).
