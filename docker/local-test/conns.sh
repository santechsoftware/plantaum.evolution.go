#!/usr/bin/env bash
# Current Postgres backend connections, per database.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

dc exec -T postgres psql -U postgres -d postgres -c "
SELECT datname AS database,
       count(*) AS backends
  FROM pg_stat_activity
 WHERE datname IS NOT NULL
 GROUP BY datname
 ORDER BY backends DESC;"

dc exec -T postgres psql -U postgres -d postgres -tAc \
  "SELECT 'max_connections = ' || setting FROM pg_settings WHERE name = 'max_connections'"
