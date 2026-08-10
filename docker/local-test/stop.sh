#!/usr/bin/env bash
# Stops the stack. Pass --clean to also drop the Postgres volume, which throws
# away every instance AND the seeded licence (activate.sh re-seeds it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

if [ "${1:-}" = "--clean" ]; then
  dc down -v
  echo "stack down, pgdata volume removed"
else
  dc down
  echo "stack down (pgdata volume kept — use --clean to wipe)"
fi
