#!/usr/bin/env bash
# Drive hydradb-application's PUBLIC connector interface through the whole flow:
#   add a connector -> trigger a sync -> (scheduler drains Lance) -> data shows up.
#
# The base URL and API key are variables, so the SAME suite runs against a local
# stack or a staging deployment — just swap BASE / API_KEY:
#
#   Local, full stack (connector-test up.sh green) with a real token:
#     BASE=http://localhost:8080 API_KEY=<key> PROVIDER_TOKEN=<notion> ./run.sh
#   Local/staging contract check (no worker / no real token needed):
#     BASE=https://<staging-api> API_KEY=<key> ./run.sh
#
# Modes (auto): if PROVIDER_TOKEN is set -> LIVE (adds the drain wait + read-side
# verification, phase 3). Otherwise -> contract-only (phases 1/2/4/5): proves the
# HTTP contract without a MOVEIT worker or a real provider credential.
#
# Why no explicit "drain" call: POST /connectors/:id/sync drives the CLASSIC
# pipeline; the MOVEIT Lance drain is scheduler-driven (no HTTP trigger). A freshly
# created moveit connector is immediately "due", so we wait one scheduler cycle and
# then poll the read side until the ingested source appears / completes.
#
# Requires: hurl, curl, jq. Local dev creds only — never commit real secrets.
set -uo pipefail
cd "$(dirname "$0")"

# ---- variables (env in, sensible local defaults) ----------------------------
BASE="${BASE:-http://localhost:8080}"
API_KEY="${API_KEY:?set API_KEY (a HydraDB API key; works for both /connectors and /context)}"
PROVIDER="${PROVIDER:-notion}"
PROVIDER_TOKEN="${PROVIDER_TOKEN:-}"           # real token => LIVE; empty => contract-only
LIVE="${LIVE:-$([ -n "$PROVIDER_TOKEN" ] && echo 1 || echo 0)}"

STAMP="${STAMP:-$(date +%s)}"
TENANT="${TENANT:-conn-test-$STAMP}"
CONN_NAME="${CONN_NAME:-conn-test-$PROVIDER-$STAMP}"
RESOURCE_ID="${RESOURCE_ID:-workspace-1}"
RESOURCE_NAME="${RESOURCE_NAME:-connector-test workspace}"

READY_TIMEOUT="${READY_TIMEOUT:-180}"          # tenant infra readiness (LIVE)
SCHEDULER_WAIT="${SCHEDULER_WAIT:-35}"         # >= one scheduler tick (~30s)
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"          # source appears + completes (LIVE)
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# The token baked into the connector. In contract mode a well-formed dummy passes
# ValidateStatic (the sync won't actually extract, but create/sync/delete still
# assert their contracts).
CONN_TOKEN="${PROVIDER_TOKEN:-contract-dummy-token}"

auth=(-H "Authorization: Bearer $API_KEY")
created_tenant=""
connector_id=""

# HURL_VERBOSE=1 makes hurl print the full real HTTP exchange (request line,
# headers, body, response) for an auditable trail. Default off (concise --test).
HURL_BIN=(hurl --test)
[ -n "${HURL_VERBOSE:-}" ] && HURL_BIN+=(--very-verbose)

# ---- preflight --------------------------------------------------------------
for bin in hurl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required command: $bin"; exit 127; }
done
if ! curl -sf -o /dev/null --max-time 5 "$BASE/health"; then
  echo "FATAL: $BASE/health not reachable — is the API up? (connector-test up.sh)"; exit 1
fi
echo "== connector flow =="
echo "   base=$BASE provider=$PROVIDER tenant=$TENANT mode=$([ "$LIVE" = 1 ] && echo LIVE || echo contract)"

# ---- cleanup (always) -------------------------------------------------------
cleanup() {
  echo "== cleanup =="
  if [ -n "$connector_id" ]; then
    "${HURL_BIN[@]}" \
      --variable base="$BASE" --variable api_key="$API_KEY" \
      --variable connector_id="$connector_id" \
      04_cleanup.hurl >/dev/null 2>&1 \
      && echo "   connector $connector_id deleted" \
      || echo "   connector cleanup skipped/failed (id=$connector_id)"
  fi
  if [ -n "$created_tenant" ]; then
    curl -s -X DELETE "${auth[@]}" "$BASE/tenants?tenant_id=$created_tenant" >/dev/null 2>&1 \
      && echo "   tenant $created_tenant deleted" || true
  fi
}
trap cleanup EXIT

# ---- tenant provisioning ----------------------------------------------------
# Connector-create needs the tenant MAPPING to resolve (not full infra readiness),
# which POST /tenants creates synchronously. In LIVE mode we additionally wait for
# ingestion readiness before expecting a drain.
if [ -z "${TENANT_PREEXISTS:-}" ]; then
  echo "== provision tenant $TENANT =="
  resp=$(curl -s -X POST "${auth[@]}" -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$TENANT\"}" "$BASE/tenants")
  if ! echo "$resp" | jq -e '(.success == true) or (.status == "accepted") or (.data != null)' >/dev/null 2>&1; then
    echo "tenant create failed: $resp"; exit 1
  fi
  created_tenant="$TENANT"
  if [ "$LIVE" = 1 ]; then
    echo "   waiting for ingestion readiness (<= ${READY_TIMEOUT}s) ..."
    ready_jq='(.data.infra.ready_for_ingestion == true) or (.vectorstore_status == [true,true]) or ((.infra.vectorstore_status // empty) == [true,true])'
    deadline=$((SECONDS + READY_TIMEOUT))
    until curl -s "${auth[@]}" "$BASE/tenants/status?tenant_id=$TENANT" | jq -e "$ready_jq" >/dev/null 2>&1; do
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "   WARN: tenant not confirmed ready after ${READY_TIMEOUT}s; continuing"; break
      fi
      sleep "$POLL_INTERVAL"
    done
  fi
fi

rc=0

# ---- Phase 5 first: negative/contract guards (no token/worker needed) -------
echo "== negatives (auth / validation / not-found) =="
"${HURL_BIN[@]}" \
  --variable base="$BASE" --variable api_key="$API_KEY" \
  --variable tenant="$TENANT" --variable provider="$PROVIDER" \
  05_negatives.hurl || rc=1

# ---- Phase 1: add the connector (+ resources + configure) -------------------
echo "== add connector =="
"${HURL_BIN[@]}" \
  --variable base="$BASE" --variable api_key="$API_KEY" \
  --variable tenant="$TENANT" --variable provider="$PROVIDER" \
  --variable provider_token="$CONN_TOKEN" --variable conn_name="$CONN_NAME" \
  --variable resource_id="$RESOURCE_ID" --variable resource_name="$RESOURCE_NAME" \
  01_add_connector.hurl || rc=1

# Recover the connector id for the async steps by listing and matching our unique
# name (decouples the later phases from hurl's per-file capture scope).
connector_id=$(curl -s "${auth[@]}" "$BASE/connectors?provider=$PROVIDER" \
  | jq -r --arg n "$CONN_NAME" '.connectors[]? | select(.name == $n) | .connector_id' | head -n1)
if [ -z "$connector_id" ]; then
  echo "FATAL: could not recover connector_id for name=$CONN_NAME (create failed?)"; exit 1
fi
echo "   connector_id=$connector_id"

# ---- Phase 2: trigger a sync (202 contract) ---------------------------------
echo "== trigger sync =="
"${HURL_BIN[@]}" \
  --variable base="$BASE" --variable api_key="$API_KEY" \
  --variable connector_id="$connector_id" \
  02_trigger_sync.hurl || rc=1

# ---- Phase 3: LIVE only — wait for the scheduler-driven drain, then verify ---
if [ "$LIVE" = 1 ]; then
  echo "== wait for MOVEIT scheduler drain (tick ~30s, timeout ${DRAIN_TIMEOUT}s) =="
  sleep "$SCHEDULER_WAIT"
  source_id=""
  deadline=$((SECONDS + DRAIN_TIMEOUT))
  while :; do
    # First source listed for the tenant, once the drain has landed anything.
    source_id=$(curl -s -X POST "${auth[@]}" -H "Content-Type: application/json" \
      -d "{\"database\":\"$TENANT\",\"type\":\"knowledge\",\"page_size\":1}" \
      "$BASE/context/list" | jq -r '.data.sources[0].id // empty')
    if [ -n "$source_id" ]; then
      state=$(curl -s "${auth[@]}" "$BASE/context/status?id=$source_id" \
        | jq -r '.data.statuses[0].indexing_status // empty')
      echo "   source=$source_id status=${state:-<none>}"
      case "$state" in completed|indexed|done) break ;; failed|errored)
        echo "   FATAL: source ingestion terminal-failed"; rc=1; break ;; esac
    else
      echo "   no source yet ..."
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "   FATAL: no completed source after ${DRAIN_TIMEOUT}s (worker/token/stack?)"; rc=1; break
    fi
    sleep "$POLL_INTERVAL"
  done

  if [ -n "$source_id" ] && [ "$rc" = 0 ]; then
    echo "== verify drained data shows up (read side) =="
    "${HURL_BIN[@]}" \
      --variable base="$BASE" --variable api_key="$API_KEY" \
      --variable tenant="$TENANT" --variable source_id="$source_id" \
      03_verify_data.hurl || rc=1
  fi
else
  echo "== (contract mode) skipping drain wait + read-side verify — set PROVIDER_TOKEN for LIVE =="
fi

echo
if [ "$rc" = 0 ]; then echo "RESULT: PASS ($([ "$LIVE" = 1 ] && echo LIVE || echo contract) mode)";
else echo "RESULT: FAIL"; fi
exit "$rc"
