#!/usr/bin/env bash
# dashboard-2.0 (Next.js) dev server on :3000. Its committed .env.local already
# points at the local Go backend (CORTEX_URL/BACKEND_URL=http://localhost:8080)
# and the shared DynamoDB auth store — we do NOT overwrite it (it holds secrets).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

cd "$DASHBOARD_ROOT"
if [[ ! -d node_modules ]]; then
  echo ">>> installing dashboard deps (npm install)…"
  npm install
fi
echo ">>> dashboard dev server on :$DASHBOARD_PORT (backend: see next-app/.env.local CORTEX_URL)"
exec npm run dev
