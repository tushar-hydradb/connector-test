#!/usr/bin/env bash
# hydradb-application Go API on :8080 (its in-process connector-orchestrator
# Temporal worker starts too, now that KMS is wired into .env.local.e2e by
# 10-infra-up.sh). Delegates to hydradb's own run-go.sh (sources .env.local.e2e).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

# RUN_MODE=run: `go run` (no hot reload, no stale binary). Use gow for reload.
export RUN_MODE="${RUN_MODE:-run}"
exec bash "$HYDRA_ROOT/scripts/local-e2e/run-go.sh"
