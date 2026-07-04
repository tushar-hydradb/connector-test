#!/usr/bin/env bash
# Seed all tables + buckets across the stack, on the shared DynamoDB (:8082) and
# MinIO (:9002). Idempotent — existing tables/buckets are left as-is.
#
#   1. hydradb seed-local.sh  -> golang connector tables + auth/user/tenant
#      (imports ../cortex-application seed) + buckets `documents`,`hydradb-e2e-tests`.
#   2. MOVEIT's own tables (moveit_cursors, moveit_state) + the `moveit-lake` bucket.
#   3. cortex-ingestion tables (inbox, api_protector, ...) the drain needs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

ddb() { aws dynamodb --endpoint-url "$DDB_ENDPOINT" "$@"; }
s3()  { aws s3api    --endpoint-url "$S3_ENDPOINT"  "$@"; }

ensure_pk_table() {  # <table> <pk_attr>
  local t="$1" pk="$2"
  if ddb describe-table --table-name "$t" >/dev/null 2>&1; then
    echo "  table exists: $t"; return 0
  fi
  ddb create-table --table-name "$t" --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName="$pk",AttributeType=S \
    --key-schema AttributeName="$pk",KeyType=HASH >/dev/null
  ddb wait table-exists --table-name "$t"
  echo "  table created: $t (PK $pk)"
}
ensure_bucket() {  # <bucket>
  if s3 head-bucket --bucket "$1" >/dev/null 2>&1; then echo "  bucket exists: $1"
  else s3 create-bucket --bucket "$1" >/dev/null; echo "  bucket created: $1"; fi
}

echo "== [1/3] hydradb seed-local.sh (golang + auth tables + buckets) =="
# seed-local.sh hardcodes its own endpoints (:8082 / :9002) and `local` creds.
DDB_ENDPOINT="$DDB_ENDPOINT" S3_ENDPOINT="$S3_ENDPOINT" \
  bash "$HYDRA_ROOT/scripts/local-e2e/seed-local.sh"

echo "== [2/3] MOVEIT tables + lake bucket =="
# Reuse MOVEIT's own seed scripts, pointed at the shared DynamoDB.
DDB_ENDPOINT="$DDB_ENDPOINT" MOVEIT_STATE_TABLE="$MOVEIT_STATE_TABLE" \
  bash "$MOVEIT_ROOT/scripts/seed-state-table.sh"
DDB_ENDPOINT="$DDB_ENDPOINT" MOVEIT_CURSOR_TABLE="$MOVEIT_CURSOR_TABLE" \
  bash "$MOVEIT_ROOT/scripts/seed-cursor-table.sh"
ensure_bucket "$MOVEIT_LAKE_BUCKET"

echo "== [3/3] cortex-ingestion tables =="
# api_protector has a bespoke (api_type HASH, ttl RANGE) schema — use its script.
if [[ -f "$INGESTION_ROOT/scripts/create_api_protector_table.py" ]]; then
  ( cd "$INGESTION_ROOT" && \
    DYNAMODB_ENDPOINT="$DDB_ENDPOINT" AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION="$AWS_REGION" \
    poetry run python scripts/create_api_protector_table.py ) \
    && echo "  api_protector_local ensured" \
    || echo "  WARN: api_protector script failed (non-fatal); create it manually if the API needs it"
fi
# Inbox is get_item by doc_id (temporal/activities/app_source_batch.py); status
# table keys on composite_pk (local-setup.md). Others: single-PK best-effort —
# adjust if the ingestion service reports a schema mismatch at runtime.
ensure_pk_table "$INGESTION_INBOX_TABLE"           doc_id
ensure_pk_table "$USER_INDEXED_DATA_TABLE"         composite_pk
ensure_pk_table token_bucket_rate_limiter_local    pk
ensure_pk_table ingestion_pipeline_events_local    pk
ensure_pk_table token_usage_local                  pk

echo "seed complete."
