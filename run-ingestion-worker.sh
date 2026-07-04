#!/usr/bin/env bash
# cortex-ingestion monolith Temporal worker on :8001, queue `shared-all`
# (runs DocumentProcessingWorkflow + AppSourceBatchWorkflow, the S3 drain that
# consumes MOVEIT's connector batches). Delegates to hydradb's script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"
exec bash "$HYDRA_ROOT/scripts/local-e2e/run-ingestion-worker.sh"
