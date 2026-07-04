#!/usr/bin/env bash
# Verify every tool + sibling checkout the harness needs, before we touch infra.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

fail=0
need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  ok   %-8s %s\n' "$1" "$(command -v "$1")"
  else
    printf '  MISS %-8s (%s)\n' "$1" "$2"; fail=1
  fi
}
need_dir() {
  if [[ -d "$1" ]]; then printf '  ok   %s\n' "$1"
  else printf '  MISS %s (%s)\n' "$1" "$2"; fail=1; fi
}

echo "== tools =="
need_cmd docker  "container runtime"
need_cmd aws     "awscli — table/bucket seeding"
need_cmd cargo   "build MOVEIT"
need_cmd go      "run hydradb-application"
need_cmd poetry  "run cortex-ingestion"
need_cmd node    "run dashboard"
need_cmd npm     "run dashboard"
need_cmd meltano "MOVEIT tap runner"
need_cmd uvx     "MOVEIT dynamic-tap installs"
need_cmd tmux    "process launcher"
need_cmd just    "hydradb recipes"
need_cmd make    "cortex-ingestion recipes"
need_cmd jq      "status/doctor JSON"
need_cmd lsof    "port guards"

echo "== checkouts =="
need_dir "$MOVEIT_ROOT"       "this repo"
need_dir "$HYDRA_ROOT"        "Go backend + shared infra scripts"
need_dir "$INGESTION_ROOT"    "Python drain"
need_dir "$CORTEX_APP_ROOT"   "seed-only (seed-local.sh imports its seed script)"
need_dir "$DASHBOARD_ROOT"    "Next.js dashboard"

echo "== key scripts =="
for f in \
  "$HYDRA_ROOT/scripts/local-e2e/infra-up.sh" \
  "$HYDRA_ROOT/scripts/local-secrets-bootstrap.sh" \
  "$HYDRA_ROOT/scripts/local-e2e/prepare-env.sh" \
  "$HYDRA_ROOT/scripts/local-e2e/seed-local.sh" \
  "$HYDRA_ROOT/scripts/local-e2e/run-go.sh" \
  "$HYDRA_ROOT/scripts/local-e2e/run-ingestion-api.sh" \
  "$HYDRA_ROOT/scripts/local-e2e/run-ingestion-worker.sh" ; do
  if [[ -f "$f" ]]; then printf '  ok   %s\n' "$f"; else printf '  MISS %s\n' "$f"; fail=1; fi
done

if [[ "$fail" != 0 ]]; then
  echo "preflight FAILED — install the missing tools / fix checkouts above." >&2
  exit 1
fi
echo "preflight ok."
