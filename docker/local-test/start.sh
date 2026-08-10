#!/usr/bin/env bash
# Brings all four servers up and licenses them. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

if ! docker image inspect evogo-localtest:fixed >/dev/null 2>&1 ||
   ! docker image inspect evogo-localtest:baseline >/dev/null 2>&1; then
  echo "==> images missing, building them first"
  "$HERE/build-images.sh"
fi

echo "==> starting postgres + 2 fixed replicas + 2 baseline replicas"
dc up -d --remove-orphans

echo -n "==> waiting for all four servers to answer "
for _ in $(seq 1 90); do
  ok=0
  for pair in "${FIXED_REPLICAS[@]}" "${BASE_REPLICAS[@]}"; do
    [ "$(http_code "http://localhost:${pair##*:}/server/ok" || true)" = "200" ] && ok=$((ok + 1))
  done
  if [ "$ok" -eq 4 ]; then echo "ok"; break; fi
  echo -n "."
  sleep 2
done
echo

"$HERE/activate.sh"

cat <<EOF

Ready — 4 API servers, 2 per side.

  fixed (working tree, has the pool fix)
    evo-1        http://localhost:$FIXED_PORT
    evo-2        http://localhost:$FIXED_PORT_2
  baseline (pre-fix, for comparison)
    evo-base-1   http://localhost:$BASELINE_PORT
    evo-base-2   http://localhost:$BASELINE_PORT_2

  postgres       localhost:${POSTGRES_PORT:-55432}  (postgres/postgres)

Each side's two replicas share one database and one connection budget —
the production shape. Next:

  ./pool-leak-test.sh      prove the leak fix
  ./setpresence-test.sh    exercise POST /instance/setPresence
  ./conns.sh               connections per database and per replica
EOF
