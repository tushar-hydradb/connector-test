#!/usr/bin/env bash
# hydradb-application standalone connectors-worker — this is the process that
# DRIVES MOVEIT: it registers MoveitSyncWorkflow / LanceDrainWorkflow /
# LanceBatchDispatchWorkflow and only when MOVEIT_BASE_URL is set. Not part of
# hydradb's tmux harness, so the connector-test harness runs it explicitly.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

cd "$HYDRA_ROOT"
[[ -f .env.local.e2e ]] || bash scripts/local-e2e/prepare-env.sh

set -a
# shellcheck disable=SC1091
source .env.local.e2e         # brings DDB/S3/Temporal/KMS wiring (KMS patched in by 10-infra-up)
set +a

# Belt-and-suspenders: ensure the MOVEIT + KMS knobs are present even if the
# e2e file predates the 10-infra-up patch.
export MOVEIT_BASE_URL="$MOVEIT_BASE_URL"
export KMS_KEY_ID="${KMS_KEY_ID:-$KMS_ALIAS}"
export KMS_ENDPOINT_URL="${KMS_ENDPOINT_URL:-$KMS_ENDPOINT}"
export SECRETS_MANAGER_ENDPOINT_URL="${SECRETS_MANAGER_ENDPOINT_URL:-$KMS_ENDPOINT}"
export S3_FREE_BUCKET="${S3_FREE_BUCKET:-documents}"
export S3_SHIP_BUCKET="${S3_SHIP_BUCKET:-documents}"

echo ">>> connectors-worker  MOVEIT_BASE_URL=$MOVEIT_BASE_URL  Temporal=$TEMPORAL_HOST_PORT  KMS=$KMS_ENDPOINT_URL"
exec go run ./cmd/connectors-worker/
