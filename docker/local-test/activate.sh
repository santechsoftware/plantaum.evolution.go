#!/usr/bin/env bash
# Licenses every local server OFFLINE, by writing your existing licence into
# each SIDE's users database and restarting the containers.
#
# Only two seeds are needed for four servers: the replicas of a side share one
# users database, so they share the licence row too.
#
# Why not just let them self-register? Each fresh container would mint its own
# identity and call the licensing server, so this stack would burn FOUR new
# activations against your account — and four more on every volume wipe.
# Seeding one shared api_key + instance_id collapses the whole stack to a single
# identity that is reused across runs. Point EVOLUTION_INSTANCE_ID at an install
# you have already activated to register nothing new at all.
#
# Requires the stack to have booted once (that is what creates the
# runtime_configs table), which start.sh does for you.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

: "${EVOLUTION_LICENSE_KEY:?EVOLUTION_LICENSE_KEY is empty in .env — see .env.example}"

# Reuse the stored instance id, or mint one and persist it for later runs.
if [ -z "${EVOLUTION_INSTANCE_ID:-}" ]; then
  EVOLUTION_INSTANCE_ID="$(gen_uuid)"
  tmp="$HERE/.env.tmp"
  sed "s|^EVOLUTION_INSTANCE_ID=.*|EVOLUTION_INSTANCE_ID=$EVOLUTION_INSTANCE_ID|" \
    "$HERE/.env" > "$tmp" && mv "$tmp" "$HERE/.env"
  echo "==> minted instance id $EVOLUTION_INSTANCE_ID (saved to .env)"
fi

seed_db() {
  local db="$1"

  echo -n "==> $db: waiting for runtime_configs "
  for _ in $(seq 1 60); do
    if [ "$(psqlq "$db" "SELECT to_regclass('public.runtime_configs') IS NOT NULL")" = "t" ]; then
      echo "ok"
      break
    fi
    echo -n "."
    sleep 2
  done

  if [ "$(psqlq "$db" "SELECT to_regclass('public.runtime_configs') IS NOT NULL")" != "t" ]; then
    echo
    echo "error: runtime_configs never appeared in $db — did the server boot?" >&2
    exit 1
  fi

  psqlq "$db" "$(cat <<SQL
INSERT INTO runtime_configs ("key","value",created_at,updated_at) VALUES
  ('api_key',     '$EVOLUTION_LICENSE_KEY', NOW(), NOW()),
  ('instance_id', '$EVOLUTION_INSTANCE_ID', NOW(), NOW()),
  ('tier',        'evolution-go',           NOW(), NOW())
ON CONFLICT ("key") DO UPDATE
  SET "value" = EXCLUDED."value", updated_at = NOW();
SQL
)" >/dev/null
  echo "==> $db: licence seeded"
}

seed_db users_fixed
seed_db users_baseline

echo "==> restarting all servers so they pick the licence up"
for svc in "${ALL_SERVICES[@]}"; do
  running "$svc" && dc restart "$svc" >/dev/null || true
done

echo
for pair in "${FIXED_REPLICAS[@]}" "${BASE_REPLICAS[@]}"; do
  svc="${pair%%:*}"; port="${pair##*:}"
  echo -n "==> $svc licence status: "
  s=""
  for _ in $(seq 1 45); do
    s="$(curl -s "http://localhost:$port/license/status" 2>/dev/null || true)"
    case "$s" in
      *'"active"'*) break ;;
      *)            echo -n "." ; sleep 2 ;;
    esac
  done
  case "$s" in
    *'"active"'*) echo "ACTIVE" ;;
    *)            echo " STILL INACTIVE — check: ./dc.sh logs $svc" ;;
  esac
done
