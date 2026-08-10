# Local test harness

Runs **two** Evolution Go servers side by side against one Postgres:

| service | image built from | why |
|---|---|---|
| `evo-fixed` | your working tree | has the auth-pool fix + `setPresence` |
| `evo-baseline` | `9337afc` (upstream 0.7.2 sync) | the same code *without* the fix |

Each gets its own `auth_*` / `users_*` database, so every Postgres backend
connection can be attributed to one server. That is what turns "the pool leak is
fixed" from a claim into a number you can read off.

## Requirements

Docker only — no Go toolchain needed. Scripts are bash; on Windows run them
from **Git Bash**.

## Setup

```bash
cd docker/local-test
cp .env.example .env
```

Put your Evolution licence key in `.env` as `EVOLUTION_LICENSE_KEY`. Without it
every `/instance/*` call answers `503 LICENSE_REQUIRED` and nothing can be
tested. It is the code you already used at
`/license/activate?code=...` on your first install.

```bash
./start.sh
```

`start.sh` builds both images, boots the stack, and licenses it.

### About the licence

`activate.sh` writes your existing `api_key` **and one shared `instance_id`**
into both servers' `runtime_configs` tables, then restarts them. The gate then
opens from the local database alone — no activation call has to succeed.

The sharing matters. Left to themselves, each container would mint its own
identity and call the licensing server, so a two-server stack would register
**two** new devices against your account, and again on every volume wipe. With
the seed, the whole stack registers **one** identity, reused across restarts
because `activate.sh` saves it back to `.env`.

To register nothing at all, set `EVOLUTION_INSTANCE_ID` in `.env` to the
`instance_id` of an install you have already activated:

```sql
-- against that install's users database
SELECT value FROM runtime_configs WHERE key = 'instance_id';
```

The server still fires a background activation notice on boot, but failures are
non-blocking, so this all works offline too.

## The pool leak test

```bash
./pool-leak-test.sh        # 30 instances per server
./pool-leak-test.sh 70     # past the 60-connection role budget: baseline dies
```

Connections leak *within* a process, so they reset when a container restarts.
Counts therefore accumulate across repeated runs until you restart or
`./stop.sh --clean`.

It creates N instances on each server and connects each one, which is N
`StartClient()` calls per server, then counts backends per auth database.

Real output from `./pool-leak-test.sh 70`:

```
                             before   after    delta
  auth_baseline (pre-fix)    1        57       +56
  auth_fixed    (post-fix)   1        1        +0

  PASS  70 connects added 0 backends on fixed vs 56 on baseline
        fixed does not scale with instance count; baseline does

  Postgres "out of connection slots" errors logged by each server:
    evo-baseline   x13
    evo-fixed      x0

  PASS  baseline burned through its connection budget; fixed never did
```

Those 13 errors are `FATAL: too many connections for role "evo_baseline"` —
the same exhaustion as the production `sorry, too many clients already`, just
worded for the per-role cap described below.

Read the **delta**, not the absolute number. Both servers open one capped pool
at boot (`main.go` `initPostgresAuthDB`), so neither ever sits at zero. The
claim under test is how the count *moves* with instance count: baseline tracks
it one-for-one, fixed does not move at all.

**Why it works without pairing a phone:** `StartClient()` builds the auth
container *before* it dials WhatsApp. The leak reproduces even when the dial
fails, so no QR scan and no real WhatsApp account is involved.

**What the numbers mean.** Pre-fix, `StartClient()` called `sqlstore.New()` on
every connect and every reconnect, each opening a fresh `*sql.DB` with no
`MaxOpenConns` cap that was never closed. Post-fix a single container with
`MaxOpenConns=20` is shared by all instances, so the count plateaus.

### Why the two servers cannot contaminate each other

Each server logs in as its own Postgres role with its own `CONNECTION LIMIT`
(`PG_ROLE_CONN_LIMIT`, default 60), set up by `init-db.sh`. So when the baseline
leaks its budget away it exhausts **itself**, and the fixed server keeps working.

Without that, both servers share one global ceiling and the baseline's leak
starves the fixed server too — which makes the fixed server log connection
errors it did not cause, and the comparison stops meaning anything.

The `postgres` superuser sits outside both budgets, so `./conns.sh` can always
get in to measure, even while a server is fully exhausted.

### Reproducing the boot storm

The original failure was a restart with many stored instances all reconnecting
at once:

```bash
sed -i 's/^CONNECT_ON_STARTUP=.*/CONNECT_ON_STARTUP=true/' .env
docker compose --profile ab --env-file .env up -d --force-recreate
./conns.sh
```

Baseline opens one pool per stored instance during boot; fixed opens one total.

## The setPresence test

```bash
./setpresence-test.sh
```

Covers auth, validation, the default-to-`unavailable` behaviour, and the
refusal paths for an instance that is not paired.

The **200 path needs a real phone** — no script can pair one for you. The script
prints the exact manual steps at the end: pair via `/manager`, POST the
endpoint, then check the log line `Global presence set to ...`.

## Handy

```bash
./conns.sh     # current backends per database
./stop.sh      # stop, keep data
./stop.sh --clean   # stop, wipe pgdata (licence must be re-seeded)
```

Direct compose access:

```bash
docker compose --profile ab --env-file .env logs -f evo-fixed
docker compose --profile ab --env-file .env exec postgres psql -U postgres
```

## Ports

| what | where |
|---|---|
| fixed | http://localhost:8080 |
| baseline | http://localhost:8081 |
| postgres | localhost:55432 (postgres/postgres) |

Change them in `.env` if they clash.
