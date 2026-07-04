# hurl — exercise hydradb-application's connector flow end-to-end

HTTP tests that drive hydradb-application's **public connector interface** through the whole
lifecycle — **add a connector → trigger a sync → (Lance drains) → data shows up** — using [hurl].
The **API base URL** and the **API key** are variables, so the same suite runs against a **local**
stack or a **staging** deployment.

```
BASE ─┐                       ┌ POST /connectors            (add, sync_engine=moveit)
      ├─ Authorization:       ├ POST /connectors/:id/resources · /configure
API_KEY  Bearer <API_KEY> ───▶├ POST /connectors/:id/sync   (202 workflow_id/run_id)
      │  (one credential)     │      … scheduler drains Lance → ingestion …
      └─                      ├ POST /context/list          (source shows up — dashboard reads this)
                              ├ GET  /context/status?id=…    (indexing_status == completed)
                              └ POST /v2/query               (drained content is retrievable)
```

## Run it
```sh
cd ~/code/connector-test/hurl

# Contract mode — no worker or real token needed. Proves the HTTP contract
# (create → sync 202 → delete → 404, plus auth/validation negatives).
BASE=http://localhost:8080 API_KEY=<key> ./run.sh

# LIVE mode — full stack (connector-test ../up.sh green) + a real provider token.
# Adds the drain wait + read-side verification.
BASE=http://localhost:8080 API_KEY=<key> PROVIDER=notion PROVIDER_TOKEN=<notion-token> ./run.sh

# Staging — same files, different target.
BASE=https://<staging-api> API_KEY=<staging-key> ./run.sh
```
Exit code is `0` on PASS, non-zero on any failed assertion. A cleanup trap always deletes the
connector (and the tenant, if this run created it).

## Variables
| Env | Default | Meaning |
|---|---|---|
| `BASE` | `http://localhost:8080` | API base URL (local Go API, or staging) |
| `API_KEY` | *(required)* | HydraDB API key — `Authorization: Bearer`. Covers **both** `/connectors/*` and `/context/*` / `/v2/query` / `/tenants` |
| `PROVIDER` | `notion` | Connector provider |
| `PROVIDER_TOKEN` | *(empty)* | Real provider token. Set ⇒ **LIVE** mode; empty ⇒ contract-only (dummy token) |
| `LIVE` | auto | `1` iff `PROVIDER_TOKEN` set; force with `LIVE=1/0` |
| `TENANT` | `conn-test-<stamp>` | Tenant/database scope. Set + `TENANT_PREEXISTS=1` to reuse an existing one (no create/delete) |
| `READY_TIMEOUT` | `180` | LIVE: wait for tenant ingestion readiness |
| `SCHEDULER_WAIT` | `35` | Wait ≥ one scheduler tick before polling the drain |
| `DRAIN_TIMEOUT` | `300` | LIVE: wait for the source to appear + reach `completed` |
| `POLL_INTERVAL` | `5` | Poll cadence |

Getting an API key locally: mint one via `POST /v2/api-keys/create_api_key` (needs a NextAuth JWT
once — see `hydradb-application/scripts/workspace/run.sh` for the JWT-minting helper), or reuse a key
seeded by the harness. On staging, use a real key. Never commit keys or tokens.

## Files
| File | Phase |
|---|---|
| `run.sh` | orchestrator: provision tenant → drive hurl → (LIVE) poll drain → verify → cleanup |
| `01_add_connector.hurl` | **add** — create (moveit) 201, get, list?provider, resources create/list, configure |
| `02_trigger_sync.hurl` | **sync** — `POST /connectors/:id/sync` → 202 `{workflow_id, run_id}` |
| `03_verify_data.hurl` | **drain shows up** (LIVE) — `/context/status` completed, `/context/list` lists it, `/v2/query` returns it |
| `04_cleanup.hurl` | delete connector → 200, then get → 404 |
| `05_negatives.hurl` | no-auth → 401, bad `sync_engine` → 400, missing provider → 400, unknown id → 404 |

## Why "drain lance" isn't an HTTP call — read this
- `POST /connectors/:id/sync` always drives the **classic** pipeline. The **MOVEIT** Lance-drain path
  is **scheduler-driven** (`internal/connectors/scheduler/engine.go`, ~30s tick): the scheduler picks
  up a *due* connector whose `sync_engine == "moveit"` → `MoveitSyncWorkflow` → child
  `LanceDrainWorkflow`. There is **no endpoint to trigger a drain**. A freshly created moveit connector
  is immediately due, so `run.sh` waits one tick and then polls the read side.
- **MOVEIT connectors never update `sync_status`** (only the classic workflow does). Completion is
  detected on the read side — `/context/status` → `indexing_status == completed` — not via the
  connector record.
- The literal dashboard docs table `GET /dashboard/resources/list/knowledge` needs a **NextAuth JWT**
  (not portable to staging). We assert the same ingested sources via the **API-key** `/context/*`
  surface instead — same data, one portable credential.

[hurl]: https://hurl.dev
