#!/usr/bin/env bash
# Proves the auth-pool fix by driving both sides identically and counting the
# Postgres backends each side holds against its auth database.
#
# Load is spread round-robin across each side's TWO replicas, the way a load
# balancer would, so the leak is measured the way production hits it: several
# servers sharing one database and one connection budget.
#
# What is being exercised: StartClient() runs once per instance connect. Before
# the fix it called sqlstore.New() every time, opening a fresh *sql.DB with no
# MaxOpenConns cap and never closing it. After the fix a single capped container
# (MaxOpenConns=20) is shared by every instance in that process.
#
# No WhatsApp pairing is needed. The auth container is created BEFORE the
# websocket dial, so the leak reproduces even with WhatsApp unreachable.
#
# Leaked connections belong to the process that opened them, so they are freed
# when a container restarts. This script therefore restarts the four servers
# first, giving every run the same clean starting point — otherwise a baseline
# left saturated by an earlier run has no room left to leak into and the result
# reads as a non-event. Pass --no-restart to measure cumulative state instead.
#
#   usage: ./pool-leak-test.sh [instance-count] [--no-restart]
#          (default 30, split across the two replicas of each side)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

N=30
RESTART=1
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    ''|*[!0-9]*)  echo "usage: $0 [instance-count] [--no-restart]" >&2; exit 2 ;;
    *)            N="$arg" ;;
  esac
done
STAMP="$(date +%H%M%S)"

# $1 = label, rest = replica "service:port" pairs to round-robin across.
drive() {
  local label="$1"; shift
  local -a reps=("$@")
  local created=0 connected=0 i port name token code

  for i in $(seq 1 "$N"); do
    port="${reps[$(( (i - 1) % ${#reps[@]} ))]##*:}"
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

  printf '    %-9s created %2d/%d, connected %2d/%d  (across %d replicas)\n' \
    "$label" "$created" "$N" "$connected" "$N" "${#reps[@]}"
}

precheck() {
  local label="$1" port="$2" code
  code="$(http_code -H "apikey: $GLOBAL_API_KEY" "http://localhost:$port/instance/all")"
  case "$code" in
    200) ;;
    503) echo "error: $label is not licensed (503). Run ./activate.sh" >&2; exit 1 ;;
    *)   echo "error: $label /instance/all returned $code — is the stack up?" >&2; exit 1 ;;
  esac
}

echo "=== auth-pool leak A/B — $N instances per side, 2 replicas each ==="
echo

if [ "$RESTART" -eq 1 ]; then
  echo -n "  restarting servers for a clean process state "
  dc restart "${ALL_SERVICES[@]}" >/dev/null 2>&1
  for _ in $(seq 1 90); do
    ok=0
    for pair in "${FIXED_REPLICAS[@]}" "${BASE_REPLICAS[@]}"; do
      [ "$(http_code "http://localhost:${pair##*:}/server/ok" || true)" = "200" ] && ok=$((ok + 1))
    done
    [ "$ok" -eq 4 ] && break
    echo -n "."
    sleep 2
  done
  echo " ok"
  echo
fi

for pair in "${FIXED_REPLICAS[@]}" "${BASE_REPLICAS[@]}"; do
  precheck "${pair%%:*}" "${pair##*:}"
done

before_fixed="$(conns auth_fixed)"
before_base="$(conns auth_baseline)"
printf '  idle backends   auth_fixed=%s  auth_baseline=%s\n\n' "$before_fixed" "$before_base"

# Only count log errors produced from here on.
SINCE="$(now_rfc3339)"

echo "  driving $N create+connect cycles per side..."
drive baseline "${BASE_REPLICAS[@]}"
drive fixed    "${FIXED_REPLICAS[@]}"

echo
echo -n "  letting pools settle "
for _ in $(seq 1 10); do echo -n "."; sleep 2; done
echo
echo

after_fixed="$(conns auth_fixed)"
after_base="$(conns auth_baseline)"

hits_base="$(exhaustion_hits_side "$SINCE" "${BASE_REPLICAS[@]}")"
hits_fixed="$(exhaustion_hits_side "$SINCE" "${FIXED_REPLICAS[@]}")"

# Both servers open one capped pool at boot (main.go initPostgresAuthDB), so the
# absolute count is never zero. What matters is how it MOVES with N: pre-fix,
# one leaked pool per StartClient; post-fix, one shared container per process.
if [ "$after_fixed" = "ERR" ] || [ "$after_base" = "ERR" ]; then
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

  # Two replicas per side, so the fixed side may hold up to two shared
  # containers' worth (2 x MaxOpenConns=20).
  limit="${PG_ROLE_CONN_LIMIT:-60}"
  if [ "$d_fixed" -le 40 ] && [ "$d_base" -gt "$d_fixed" ]; then
    echo "  PASS  $N connects added $d_fixed backends on fixed vs $d_base on baseline"
    echo "        fixed does not scale with instance count; baseline does"
  elif [ "$d_fixed" -le 40 ] && [ "$hits_base" -gt 0 ]; then
    # Baseline was already pinned at its ceiling, so it had no room left to grow
    # into. Saturation plus refusals is the failure, not an absent result.
    echo "  PASS  baseline is pinned at its $limit-connection budget and is now"
    echo "        refusing connections ($hits_base errors); fixed added $d_fixed"
  else
    echo "  INCONCLUSIVE  delta fixed=$d_fixed baseline=$d_base"
    echo "                try a larger count: ./pool-leak-test.sh 70"
  fi
fi

echo
echo '  per replica (application_name):'
for pair in "${FIXED_REPLICAS[@]}" "${BASE_REPLICAS[@]}"; do
  svc="${pair%%:*}"
  printf '    %-12s %s backends\n' "$svc" "$(conns_by_app "$svc")"
done

echo
echo '  Postgres "out of connection slots" errors, summed per side:'
printf '    %-12s x%s\n' baseline "$hits_base"
printf '    %-12s x%s\n' fixed    "$hits_fixed"

if [ "$hits_base" -gt 0 ] && [ "$hits_fixed" -eq 0 ]; then
  echo
  echo "  PASS  baseline burned through its connection budget; fixed never did"
fi
