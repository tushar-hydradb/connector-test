#!/usr/bin/env bash
# Tear down the harness. By default only kills the app processes (tmux session);
# the shared docker infra + its volumes are LEFT UP for a fast restart.
#
#   down.sh              stop the apps (tmux session), keep infra
#   down.sh --infra      also `docker stop` the shared containers (keep volumes)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

STOP_INFRA=0
for a in "$@"; do case "$a" in --infra) STOP_INFRA=1;; *) echo "unknown flag: $a" >&2; exit 2;; esac; done

echo "== killing app processes =="
tmux kill-session -t "$CT_TMUX_SESSION" 2>/dev/null && echo "  tmux session '$CT_TMUX_SESSION' killed" || echo "  no tmux session"
# Belt-and-suspenders: kill anything still bound to our app ports.
for p in "$MOVEIT_PORT" "$GO_API_PORT" "$INGESTION_API_PORT" "$INGESTION_WORKER_PORT" "$DASHBOARD_PORT"; do
  pids="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null || true)"
  [[ -n "$pids" ]] && { kill $pids 2>/dev/null || true; echo "  freed :$p"; }
done
# The go connectors-worker binds no port — kill it by command.
pkill -f 'cmd/connectors-worker' 2>/dev/null && echo "  killed connectors-worker" || true

if [[ "$STOP_INFRA" == 1 ]]; then
  echo "== stopping shared docker infra (volumes kept) =="
  docker stop shared-dynamodb shared-minio shared-milvus shared-etcd shared-falkordb \
    shared-mongodb shared-kafka guru-team-temporal guru-team-temporal-ui guru-team-postgres \
    cortex-secrets 2>/dev/null || true
  echo "  (restart with: $HERE/10-infra-up.sh)"
fi
echo "down."
