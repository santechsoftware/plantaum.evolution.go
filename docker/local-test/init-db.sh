#!/bin/bash
# Runs once, on first Postgres boot (empty pgdata volume).
#
# Each server gets its own role with its OWN connection budget, and its own
# auth/users databases owned by that role. Two consequences that matter:
#
#   * a server that leaks connections exhausts only its own budget, so the
#     leaking baseline cannot starve the fixed server and muddy the result;
#   * the `postgres` superuser is never part of either budget, so the measuring
#     psql can always get in, even mid-exhaustion.
set -e

LIMIT="${PG_ROLE_CONN_LIMIT:-60}"

for side in fixed baseline; do
  echo "creating role evo_$side (connection limit $LIMIT) + databases"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE ROLE evo_$side LOGIN PASSWORD 'evo_$side' CONNECTION LIMIT $LIMIT;
    CREATE DATABASE auth_$side  OWNER evo_$side;
    CREATE DATABASE users_$side OWNER evo_$side;
EOSQL
done
