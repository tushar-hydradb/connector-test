#!/usr/bin/env bash
# Shared wait helpers. Source this: `. "$(dirname "$0")/lib/wait.sh"`.

# wait_tcp <label> <host> <port> [max_secs]
wait_tcp() {
  local label="$1" host="$2" port="$3" max="${4:-90}"
  printf 'waiting for %s (%s:%s)' "$label" "$host" "$port"
  for _ in $(seq 1 "$max"); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      printf ' ok\n'; return 0
    fi
    printf '.'; sleep 1
  done
  printf ' TIMEOUT\n' >&2; return 1
}

# wait_http <label> <url> [max_secs] [accept_regex]
wait_http() {
  local label="$1" url="$2" max="${3:-90}" re="${4:-200|204|301|302|400|403|404}"
  printf 'waiting for %s (%s)' "$label" "$url"
  for _ in $(seq 1 "$max"); do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || echo 000)"
    if printf '%s' "$code" | grep -qE "^(${re})$"; then
      printf ' ok (%s)\n' "$code"; return 0
    fi
    printf '.'; sleep 1
  done
  printf ' TIMEOUT\n' >&2; return 1
}
