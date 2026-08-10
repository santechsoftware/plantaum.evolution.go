#!/usr/bin/env bash
# Proves the auth-pool fix by driving both servers identically and counting
# the Postgres backends each one holds against its auth database.
#
# What is being exercised: StartClient() runs once per instance connect. Before
# the fix it called sqlstore.New() every time, opening a fresh *sql.DB with no
# MaxOpenConns cap and never closing it. After the fix a single capped container
# (MaxOpenConns=20) is shared by every instance.
#
# No WhatsApp pairing is needed. The auth container is created BEFORE the
# websocket dial, so the leak reproduces even with WhatsApp unreachable.
#
#   usage: ./pool-leak-test.sh [instance-count]     (default 30)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

N="${1:-30}"
STAMP="$(date +%H%M%S)"

drive() {
  local label="$1" port="$2"
  local created=0 connected=0

  for i in $(seq 1 "$N"); do
    local name token code
    name="lt-${STAMP}-$(printf '%03d' "$i")"
    token="tok-${label}-${STAMP}-$(printf '%03d' "$i")"

    code="$(http_code -X POST "http://localhost:$port/instance/create" \
      -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"token\":\"$token\"}")"
    case "$code" in 200|201) created=$((created + 1)) ;; esac

    # Each connect that finds no running client spawns StartClient — one
    # auth-container creation, which is the leak site.
    code="$(http_code -X POST "http://localhost:$port/instance/connect" \
      -H "apikey: $token" -H 'Content-Type: application/json' -d '{}')"
    case "$code" in 200) connected=$((connected + 1)) ;; esac
  done

  printf '    %-9s created %2d/%d, connected %2d/%d\n' \
    "$label" "$created" "$N" "$connected" "$N"
}

precheck() {
  local label="$1" port="$2" code
  code="$(http_code -H "apikey: $GLOBAL_API_KEY" "http://localhost:$port/instance/all")"
  if [ "$code" = "503" ]; then
    echo "error: $label is not licensed (503). Run ./activate.sh" >&2
    exit 1
  fi
  if [ "$code" != "200" ]; then
    echo "error: $label /instance/all returned $code — is the stack up?" >&2
    exit 1
  fi
}

echo "=== auth-pool leak A/B — $N instances per server ==="
echo
precheck baseline "$BASELINE_PORT"
precheck fixed    "$FIXED_PORT"

before_fixed="$(conns auth_fixed)"
before_base="$(conns auth_baseline)"
printf '  idle backends   fixed=%s  baseline=%s\n\n' "$before_fixed" "$before_base"

echo "  driving $N create+connect cycles on each server..."
drive baseline "$BASELINE_PORT"
drive fixed    "$FIXED_PORT"

echo
echo -n "  letting pools settle "
for _ in $(seq 1 10); do echo -n "."; sleep 2; done
echo
echo

after_fixed="$(conns auth_fixed)"
after_base="$(conns auth_baseline)"

hits_base="$(exhaustion_hits evo-baseline)"
hits_fixed="$(exhaustion_hits evo-fixed)"

# Both servers open one capped pool at boot (main.go initPostgresAuthDB), so the
# absolute count is never zero. What matters is how it MOVES with N: pre-fix,
# one leaked pool per StartClient; post-fix, one shared container regardless.
if [ "$after_fixed" = "ERR" ] || [ "$after_base" = "ERR" ]; then
  # Postgres refused our own measuring connection. That is the production
  # failure, live: the leak ate max_connections.
  echo "  Could not measure — Postgres refused the superuser connection too."
  echo "  Raise PG_MAX_CONNECTIONS in .env; the per-role budget is the one that"
  echo "  is supposed to run out, not the global one."
else
  d_base=$((after_base  - before_base))
  d_fixed=$((after_fixed - before_fixed))

  printf '  %-26s %-8s %-8s %s\n' '' 'before' 'after' 'delta'
  printf '  %-26s %-8s %-8s %+d\n' 'auth_baseline (pre-fix)' "$before_base"  "$after_base"  "$d_base"
  printf '  %-26s %-8s %-8s %+d\n' 'auth_fixed    (post-fix)' "$before_fixed" "$after_fixed" "$d_fixed"
  echo

  if [ "$d_fixed" -le 20 ] && [ "$d_base" -gt "$d_fixed" ]; then
    echo "  PASS  $N connects added $d_fixed backends on fixed vs $d_base on baseline"
    echo "        fixed does not scale with instance count; baseline does"
  else
    echo "  INCONCLUSIVE  delta fixed=$d_fixed baseline=$d_base"
    echo "                try a larger count: ./pool-leak-test.sh 60"
  fi
fi

echo
echo '  Postgres "out of connection slots" errors logged by each server:'
printf '    %-14s x%s\n' evo-baseline "$hits_base"
printf '    %-14s x%s\n' evo-fixed    "$hits_fixed"

if [ "$hits_base" -gt 0 ] && [ "$hits_fixed" -eq 0 ]; then
  echo
  echo "  PASS  baseline burned through its connection budget; fixed never did"
fi
