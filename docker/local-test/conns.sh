#!/usr/bin/env bash
# Current Postgres backend connections, per database and per replica.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

dc exec -T postgres psql -U postgres -d postgres -c "
SELECT datname AS database,
       usename AS role,
       count(*) AS backends
  FROM pg_stat_activity
 WHERE datname IS NOT NULL
 GROUP BY datname, usename
 ORDER BY backends DESC;"

dc exec -T postgres psql -U postgres -d postgres -c "
SELECT COALESCE(NULLIF(application_name, ''), '(unset)') AS replica,
       datname AS database,
       count(*) AS backends
  FROM pg_stat_activity
 WHERE datname IS NOT NULL
 GROUP BY 1, 2
 ORDER BY backends DESC;"

dc exec -T postgres psql -U postgres -d postgres -c "
SELECT rolname AS role,
       rolconnlimit AS connection_limit
  FROM pg_roles
 WHERE rolname LIKE 'evo/_%' ESCAPE '/'
 ORDER BY rolname;"

dc exec -T postgres psql -U postgres -d postgres -tAc \
  "SELECT 'global max_connections = ' || setting FROM pg_settings WHERE name = 'max_connections'"
