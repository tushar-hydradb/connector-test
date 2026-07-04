#!/usr/bin/env bash
# One command: preflight -> infra -> seed -> launch every app + Temporal worker
# in a tmux session (one window per process). Attach with:
#   tmux attach -t connector-test
#
# Flags:
#   --infra-only   bring up + seed the shared stack, don't launch the apps
#   --skip-seed    skip 20-seed.sh (tables already seeded)
#   --skip-infra   skip 00/10/20 (infra already up), just (re)launch the tmux apps
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

INFRA_ONLY=0 SKIP_SEED=0 SKIP_INFRA=0
for a in "$@"; do case "$a" in
  --infra-only) INFRA_ONLY=1;;
  --skip-seed)  SKIP_SEED=1;;
  --skip-infra) SKIP_INFRA=1;;
  *) echo "unknown flag: $a" >&2; exit 2;;
esac; done

if [[ "$SKIP_INFRA" == 0 ]]; then
  bash "$HERE/00-preflight.sh"
  bash "$HERE/10-infra-up.sh"
  [[ "$SKIP_SEED" == 0 ]] && bash "$HERE/20-seed.sh"
fi

if [[ "$INFRA_ONLY" == 1 ]]; then
  echo "infra + seed done (--infra-only). Launch apps later with: $0 --skip-infra"
  exit 0
fi

S="$CT_TMUX_SESSION"
if tmux has-session -t "$S" 2>/dev/null; then
  echo "tmux session '$S' already exists — kill it first (down.sh) or attach." >&2
  exit 1
fi

# One window per process. New windows (not panes) so a crash log is easy to read.
tmux new-session  -d -s "$S" -n moveit           "bash '$HERE/run-moveit.sh'            2>&1 | tee '$HERE/logs/moveit.log'; exec bash"
tmux new-window   -t "$S":  -n go-api            "bash '$HERE/run-go-api.sh'            2>&1 | tee '$HERE/logs/go-api.log'; exec bash"
tmux new-window   -t "$S":  -n go-conn-worker    "bash '$HERE/run-go-connectors-worker.sh' 2>&1 | tee '$HERE/logs/go-conn-worker.log'; exec bash"
tmux new-window   -t "$S":  -n ingestion-api     "bash '$HERE/run-ingestion-api.sh'     2>&1 | tee '$HERE/logs/ingestion-api.log'; exec bash"
tmux new-window   -t "$S":  -n ingestion-worker  "bash '$HERE/run-ingestion-worker.sh'  2>&1 | tee '$HERE/logs/ingestion-worker.log'; exec bash"
tmux new-window   -t "$S":  -n dashboard         "bash '$HERE/run-dashboard.sh'         2>&1 | tee '$HERE/logs/dashboard.log'; exec bash"

mkdir -p "$HERE/logs"
cat <<EOF

  connector-test is starting in tmux session '$S'.
    attach:   tmux attach -t $S       (Ctrl-b n / p to switch windows)
    health:   $HERE/status.sh
    logs:     $HERE/logs/*.log
    stop:     $HERE/down.sh

  Apps take a bit: MOVEIT builds, Go compiles, ingestion spawns its venv,
  dashboard runs npm install on first boot. Give it a minute, then status.sh.
EOF
