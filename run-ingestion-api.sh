#!/usr/bin/env bash
# cortex-ingestion FastAPI + inbox drainer on :8000. Delegates to hydradb's
# run-ingestion-api.sh (pins the poetry venv, sources cortex-ingestion's
# .env.local.e2e → shared :8082/:9002/:7233).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"
exec bash "$HYDRA_ROOT/scripts/local-e2e/run-ingestion-api.sh"
