#!/usr/bin/env bash
# hydradb-application standalone connectors-SCHEDULER (cmd/connectors-scheduler).
# This is the process that TICKS due connectors (~30s) and routes each on its
# sync_engine: moveit -> StartMoveitSync on the `connector-orchestrator` task
# queue, which the connectors-worker then executes. Without this, a moveit
# connector never syncs. Not in hydradb's harness, so connector-test runs it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

cd "$HYDRA_ROOT"
[[ -f .env.local.e2e ]] || bash scripts/local-e2e/prepare-env.sh

set -a
# shellcheck disable=SC1091
source .env.local.e2e
set +a

# The scheduler's dynamo client uses AWS_ENDPOINT_URL as the DynamoDB endpoint
# (cmd/connectors-scheduler: dynamo.New(region, AWS_ENDPOINT_URL)). The e2e env
# may set AWS_ENDPOINT_URL to S3 — force it to the shared DynamoDB here.
export AWS_ENDPOINT_URL="$DDB_ENDPOINT"
export ENV="${ENV:-local}"
export TEMPORAL_HOST_PORT="${TEMPORAL_HOST_PORT:-$TEMPORAL_HOST_PORT}"
export CONNECTORS_TASK_QUEUE="${CONNECTORS_TASK_QUEUE:-connector-orchestrator}"
export CONNECTORS_SCHEDULER_POLL_INTERVAL="${CONNECTORS_SCHEDULER_POLL_INTERVAL:-30s}"
export CONNECTORS_SCHEDULER_OWNER="${CONNECTORS_SCHEDULER_OWNER:-connector-test}"

echo ">>> connectors-scheduler  DDB=$AWS_ENDPOINT_URL  Temporal=$TEMPORAL_HOST_PORT  queue=$CONNECTORS_TASK_QUEUE  poll=$CONNECTORS_SCHEDULER_POLL_INTERVAL"
exec go run ./cmd/connectors-scheduler/
