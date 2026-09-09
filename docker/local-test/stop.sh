#!/usr/bin/env bash
# Stops the stack. Pass --clean to also drop the Postgres volume, which throws
# away every instance AND the seeded licence (activate.sh re-seeds it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

# --remove-orphans so containers from an older revision of this compose file
# (renamed services) cannot linger and hold the published ports.
if [ "${1:-}" = "--clean" ]; then
  dc down -v --remove-orphans
  echo "stack down, pgdata volume removed"
else
  dc down --remove-orphans
  echo "stack down (pgdata volume kept — use --clean to wipe)"
fi
