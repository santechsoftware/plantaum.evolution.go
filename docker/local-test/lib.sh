#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, not run directly.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$HERE/.env" ]; then
  echo "error: $HERE/.env is missing — copy .env.example to .env and fill it in" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. "$HERE/.env"
set +a

: "${GLOBAL_API_KEY:?GLOBAL_API_KEY is empty in .env}"
FIXED_PORT="${FIXED_PORT:-8080}"
FIXED_PORT_2="${FIXED_PORT_2:-8082}"
BASELINE_PORT="${BASELINE_PORT:-8081}"
BASELINE_PORT_2="${BASELINE_PORT_2:-8083}"

# The two replicas of each side, as "service:port" pairs.
FIXED_REPLICAS=("evo-1:$FIXED_PORT" "evo-2:$FIXED_PORT_2")
BASE_REPLICAS=("evo-base-1:$BASELINE_PORT" "evo-base-2:$BASELINE_PORT_2")
ALL_SERVICES=(evo-1 evo-2 evo-base-1 evo-base-2)

dc() {
  docker compose -f "$HERE/docker-compose.yml" --env-file "$HERE/.env" "$@"
}

# psql against the local Postgres, quiet and unaligned.
psqlq() {
  local db="$1"; shift
  dc exec -T postgres psql -U postgres -d "$db" -tAqc "$*"
}

# Backend connections currently open against a database. Prints ERR rather than
# failing when Postgres itself has run out of slots — that is a result, not a
# crash, and the caller decides what it means.
conns() {
  local out
  out="$(psqlq postgres \
    "SELECT count(*) FROM pg_stat_activity WHERE datname = '$1'" 2>/dev/null \
    | tr -d '[:space:]')" || true
  case "$out" in
    '' | *[!0-9]*) echo "ERR" ;;
    *)             echo "$out" ;;
  esac
}

# Same, but for a single replica — replicas share a database and a role, so
# application_name (set per-service in the compose DSNs) is what tells them
# apart.
conns_by_app() {
  local out
  out="$(psqlq postgres \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$1'" 2>/dev/null \
    | tr -d '[:space:]')" || true
  case "$out" in
    '' | *[!0-9]*) echo "ERR" ;;
    *)             echo "$out" ;;
  esac
}

# Times a server logged a Postgres "out of connection slots" error. Postgres
# words it differently for the global cap and the per-role cap, so match both.
#
# $2 is an optional RFC3339 cutoff. Docker keeps a container's logs across
# restarts, so without it an earlier run's errors are counted again.
exhaustion_hits() {
  local since_args=()
  [ -n "${2:-}" ] && since_args=(--since "$2")
  dc logs "${since_args[@]}" "$1" 2>/dev/null \
    | grep -cE 'too many clients already|too many connections for role' || true
}

# Summed over a side's replicas. $1 is the cutoff, rest are "service:port" pairs.
exhaustion_hits_side() {
  local since="$1"; shift
  local total=0 pair
  for pair in "$@"; do
    total=$((total + $(exhaustion_hits "${pair%%:*}" "$since")))
  done
  echo "$total"
}

now_rfc3339() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

running() {
  dc ps --services --status running 2>/dev/null | grep -qx "$1"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return
  fi
  local h
  h="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  printf '%s-%s-4%s-a%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# curl that prints only the HTTP status code.
http_code() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}
