#!/usr/bin/env bash
# Bring up the ONE shared backing stack (reusing hydradb-application's local-e2e
# harness) + moto KMS, generate the e2e env files, and patch in the KMS wiring
# that hydradb's e2e env omits (without it, the Go connector feature is silently
# disabled — see run-go-connectors-worker.sh). Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"
# shellcheck disable=SC1091
. "$HERE/lib/wait.sh"

echo "== [1/4] shared infra (hydradb docker-compose.shared.yml) =="
# NOTE: we call `docker compose up -d` directly rather than hydradb's infra-up.sh,
# because that script's readiness wait uses `nc -z` — absent on some hosts, where
# it times out and exits 1 even though the containers are healthy. Our own
# /dev/tcp waits (lib/wait.sh, step 4) don't need nc.
docker compose -f "$HYDRA_ROOT/scripts/local-e2e/docker-compose.shared.yml" up -d

echo "== [2/4] moto KMS (cortex-secrets :4566) =="
bash "$HYDRA_ROOT/scripts/local-secrets-bootstrap.sh"

echo "== [3/4] generate .env.local.e2e for hydradb + cortex-ingestion =="
bash "$HYDRA_ROOT/scripts/local-e2e/prepare-env.sh"

echo "== [4/4] patch KMS + MOVEIT wiring into hydradb .env.local.e2e =="
# prepare-env.sh omits KMS keys (hydradb has no base .env.local), so the Go
# server's in-process connector worker + cmd/connectors-worker would find no KMS
# key and disable connectors. Append the local KMS wiring idempotently.
E2E="$HYDRA_ROOT/.env.local.e2e"
patch_kv() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$E2E" 2>/dev/null; then return 0; fi
  printf '%s=%s\n' "$key" "$val" >> "$E2E"
  echo "  + $key"
}
{ grep -q '# ---- connector-test KMS/MOVEIT wiring ----' "$E2E" 2>/dev/null || \
  printf '\n# ---- connector-test KMS/MOVEIT wiring ----\n' >> "$E2E"; }
patch_kv KMS_KEY_ID "$KMS_ALIAS"
patch_kv KMS_ENDPOINT_URL "$KMS_ENDPOINT"
patch_kv SECRETS_MANAGER_ENDPOINT_URL "$KMS_ENDPOINT"
patch_kv MOVEIT_BASE_URL "$MOVEIT_BASE_URL"
patch_kv S3_FREE_BUCKET documents
patch_kv S3_SHIP_BUCKET documents

echo "== waiting for endpoints =="
wait_tcp  dynamodb localhost 8082
wait_tcp  minio    localhost 9002
wait_tcp  temporal localhost 7233
wait_http moto     "$KMS_ENDPOINT/" 60
echo "infra up."
