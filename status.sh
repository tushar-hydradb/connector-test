#!/usr/bin/env bash
# Doctor: is the shared infra reachable, are the apps healthy, are the Temporal
# task queues being polled? Non-zero exit if anything core is down.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/env/shared.env"

ok=0; bad=0
chk_tcp()  { if (exec 3<>"/dev/tcp/$2/$3") 2>/dev/null; then exec 3>&- 3<&-; printf '  UP    %-18s %s:%s\n' "$1" "$2" "$3"; ok=$((ok+1)); else printf '  DOWN  %-18s %s:%s\n' "$1" "$2" "$3"; bad=$((bad+1)); fi; }
chk_http() { local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$2" 2>/dev/null || echo 000)"; if printf '%s' "$c" | grep -qE "^(200|204|301|302|404)$"; then printf '  UP    %-18s %s (%s)\n' "$1" "$2" "$c"; ok=$((ok+1)); else printf '  DOWN  %-18s %s (%s)\n' "$1" "$2" "$c"; bad=$((bad+1)); fi; }

echo "== shared infra =="
chk_tcp dynamodb     localhost 8082
chk_tcp minio        localhost 9002
chk_tcp temporal     localhost 7233
chk_tcp milvus       localhost 19530
chk_tcp falkordb     localhost 6379
chk_tcp mongo        localhost 27017
chk_tcp kafka        localhost 9092
chk_http moto-kms    "$KMS_ENDPOINT/"
chk_http temporal-ui "http://localhost:8088/"

echo "== apps =="
chk_http moveit         "http://localhost:${MOVEIT_PORT}/health"
chk_http go-api         "http://localhost:${GO_API_PORT}/health"
chk_http ingestion-api  "http://localhost:${INGESTION_API_PORT}/health"
chk_http dashboard      "http://localhost:${DASHBOARD_PORT}/"

echo "== temporal task queues (best-effort poller check) =="
# The temporal 1.24 CLI's JSON output is unreliable here, so parse the
# human-readable describe: its "Pollers" section lists one Identity row per
# live worker. Best-effort + informational only (never affects exit code).
tq_text() {  # <queue>
  if command -v temporal >/dev/null 2>&1; then
    temporal task-queue describe --address localhost:7233 --task-queue "$1" 2>/dev/null
  else
    docker exec guru-team-temporal temporal task-queue describe --address temporal:7233 --task-queue "$1" 2>/dev/null
  fi
}
for q in moveit-sync connector-orchestrator shared-all; do
  n="$(tq_text "$q" | awk '/[Pp]ollers/{p=1} p&&/Identity|@/{c++} END{print c+0}')"
  if [[ "${n:-0}" -gt 0 ]]; then printf '  UP    %-22s pollers=%s\n' "$q" "$n"
  else printf '  IDLE  %-22s no pollers (start its worker)\n' "$q"; fi
done

echo
echo "up=$ok down=$bad"
[[ "$bad" == 0 ]]
