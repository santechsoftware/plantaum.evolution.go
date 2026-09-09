#!/usr/bin/env bash
# Exercises POST /instance/setPresence/{instanceId} on the fixed server.
#
# Scope note: the 200 path needs a phone actually paired to the instance, which
# no script can do for you. Everything reachable without pairing is asserted
# here; the paired check is printed at the end as a manual step.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

BASE="http://localhost:$FIXED_PORT"
pass=0; fail=0

check() {
  local want="$1" got="$2" what="$3"
  if [ "$want" = "$got" ]; then
    printf '  ok    %-52s %s\n' "$what" "$got"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-52s want %s, got %s\n' "$what" "$want" "$got"
    fail=$((fail + 1))
  fi
}

echo "=== POST /instance/setPresence — $BASE ==="
echo

# A disposable instance that exists but was never paired. Instance.BeforeCreate
# only generates an id when none is supplied, so we choose it up front and skip
# having to look it back up.
inst="sp-$(date +%H%M%S)"
tok="tok-$inst"
id="$(gen_uuid)"

code="$(http_code -X POST "$BASE/instance/create" \
  -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \
  -d "{\"instanceId\":\"$id\",\"name\":\"$inst\",\"token\":\"$tok\"}")"
case "$code" in
  200|201) echo "  instance $inst -> $id" ;;
  503)     echo "error: server is not licensed (503) — run ./activate.sh" >&2; exit 1 ;;
  *)       echo "error: create returned $code" >&2; exit 1 ;;
esac
echo

check 401 "$(http_code -X POST "$BASE/instance/setPresence/$id" \
  -H 'Content-Type: application/json' -d '{"presence":"unavailable"}')" \
  "no apikey is rejected"

check 401 "$(http_code -X POST "$BASE/instance/setPresence/$id" \
  -H 'apikey: wrong-key' -H 'Content-Type: application/json' \
  -d '{"presence":"unavailable"}')" \
  "wrong apikey is rejected"

check 400 "$(http_code -X POST "$BASE/instance/setPresence/$id" \
  -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \
  -d '{"presence":"invisible"}')" \
  "presence must be available|unavailable"

check 400 "$(http_code -X POST "$BASE/instance/setPresence/$id" \
  -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \
  -d 'not json')" \
  "malformed body is rejected"

# Not in the runtime map at all.
check 500 "$(http_code -X POST "$BASE/instance/setPresence/does-not-exist" \
  -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \
  -d '{"presence":"unavailable"}')" \
  "unknown instance reports not-in-runtime"

# Created but never paired: 500 either way, so assert the message instead.
body="$(curl -s -X POST "$BASE/instance/setPresence/$id" \
  -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \
  -d '{"presence":"available"}')"
case "$body" in
  *"not logged in"*|*"not found in runtime"*)
    printf '  ok    %-52s %s\n' "unpaired instance refuses cleanly" "$body"
    pass=$((pass + 1)) ;;
  *)
    printf '  FAIL  %-52s %s\n' "unpaired instance refuses cleanly" "$body"
    fail=$((fail + 1)) ;;
esac

# Body defaults to unavailable when presence is omitted — still refused for an
# unpaired instance, but it must fail past validation, not at it.
body="$(curl -s -X POST "$BASE/instance/setPresence/$id" \
  -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' -d '{}')"
case "$body" in
  *"presence must be"*)
    printf '  FAIL  %-52s %s\n' "omitted presence defaults to unavailable" "$body"
    fail=$((fail + 1)) ;;
  *)
    printf '  ok    %-52s %s\n' "omitted presence defaults to unavailable" "$body"
    pass=$((pass + 1)) ;;
esac

curl -s -o /dev/null -X DELETE "$BASE/instance/delete/$id" -H "apikey: $GLOBAL_API_KEY" || true

echo
echo "  $pass passed, $fail failed"
cat <<EOF

  Manual step for the 200 path (needs a real phone):
    1. open $BASE/manager and pair an instance by QR
    2. curl -X POST "$BASE/instance/setPresence/<instanceId>" \\
         -H "apikey: $GLOBAL_API_KEY" -H 'Content-Type: application/json' \\
         -d '{"presence":"unavailable"}'
       expect {"presence":"unavailable"}
    3. docker compose --env-file .env logs evo-1 evo-2 \\
         | grep "Global presence set to"
EOF

[ "$fail" -eq 0 ]
