#!/usr/bin/env bash
# MOVEIT server on :8090 against the shared stack (production golang-resolver +
# moto-KMS + Temporal path — NO inline-sync feature). In-process Temporal worker
# on queue `moveit-sync`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

cd "$MOVEIT_ROOT"

if lsof -nP -iTCP:"$MOVEIT_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "FATAL: :$MOVEIT_PORT already bound. Stop it first (down.sh)." >&2; exit 1
fi

echo ">>> building MOVEIT (release-less prod build, no inline-sync)…"
cargo build

echo ">>> starting MOVEIT on :$MOVEIT_PORT (shared DDB $DDB_ENDPOINT, S3 $S3_ENDPOINT, KMS $KMS_ENDPOINT, Temporal $TEMPORAL_ENDPOINT)"
exec env \
  AWS_REGION="$AWS_REGION" \
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_ALLOW_HTTP="$AWS_ALLOW_HTTP" \
  AWS_ENDPOINT_URL="$S3_ENDPOINT" \
  AWS_ENDPOINT_URL_DYNAMODB="$DDB_ENDPOINT" \
  AWS_ENDPOINT_URL_KMS="$KMS_ENDPOINT" \
  MELTANO_BIN=meltano \
  MOVEIT_BIND_ADDR="127.0.0.1:${MOVEIT_PORT}" \
  MOVEIT_LAKE_BUCKET="$MOVEIT_LAKE_BUCKET" \
  MOVEIT_CURSOR_TABLE="$MOVEIT_CURSOR_TABLE" \
  MOVEIT_STATE_TABLE="$MOVEIT_STATE_TABLE" \
  MOVEIT_CONNECTORS_TABLE="$OAUTH_CONNECTORS_TABLE" \
  MOVEIT_RESOURCES_TABLE="$OAUTH_CONNECTOR_RESOURCES_TABLE" \
  MOVEIT_SECRETS_TABLE="$CONNECTOR_CREDENTIALS_TABLE" \
  MOVEIT_USE_TEMPORAL=true \
  MOVEIT_TEMPORAL_ENDPOINT="$TEMPORAL_ENDPOINT" \
  MOVEIT_TEMPORAL_TASK_QUEUE=moveit-sync \
  RUST_LOG="MOVEIT=info,meltano=info,tower_http=info" \
  ./target/debug/MOVEIT
