#!/usr/bin/env bash
# Brings the stack up and licenses it. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

if ! docker image inspect evogo-localtest:fixed >/dev/null 2>&1 ||
   ! docker image inspect evogo-localtest:baseline >/dev/null 2>&1; then
  echo "==> images missing, building them first"
  "$HERE/build-images.sh"
fi

echo "==> starting postgres + evo-fixed + evo-baseline"
dc up -d

echo -n "==> waiting for both servers to answer "
for _ in $(seq 1 60); do
  a="$(http_code "http://localhost:$FIXED_PORT/server/ok"    || true)"
  b="$(http_code "http://localhost:$BASELINE_PORT/server/ok" || true)"
  if [ "$a" = "200" ] && [ "$b" = "200" ]; then echo "ok"; break; fi
  echo -n "."
  sleep 2
done
echo

"$HERE/activate.sh"

cat <<EOF

Ready.
  fixed     http://localhost:$FIXED_PORT      (working tree, has the pool fix)
  baseline  http://localhost:$BASELINE_PORT      (pre-fix, for comparison)
  postgres  localhost:${POSTGRES_PORT:-55432}    (postgres/postgres)

Next:
  ./pool-leak-test.sh      prove the leak fix
  ./setpresence-test.sh    exercise POST /instance/setPresence
EOF
