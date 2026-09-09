# Local test harness

Runs **four** Evolution Go servers against one Postgres — two replicas of each
side, no compose profiles, so `docker compose up -d` starts all of them:

| service | port | image built from |
|---|---|---|
| `evo-1` | 8080 | your working tree (auth-pool fix + `setPresence`) |
| `evo-2` | 8082 | same |
| `evo-base-1` | 8081 | `9337afc` (upstream 0.7.2 sync), *without* the fix |
| `evo-base-2` | 8083 | same |

The two replicas of a side **share one database pair and one Postgres role**,
which is the production shape: N replicas of the image behind a load balancer,
one database, one connection budget between them. Connections are attributed on
two axes — `datname` says which side, `application_name` says which replica.

That is what turns "the pool leak is fixed" from a claim into a number you can
read off.

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

## Receiving webhooks locally

`plantaum.service` runs on the **host**, the servers run in this stack, so the
containers reach it at `host.docker.internal` — the compose file maps that name
explicitly so the setup also works on plain Linux and in WSL, where Docker
Desktop's automatic alias does not exist.

Point the service at itself and it does the rest; it sends the URL as
`webhookUrl` on every `POST /instance/connect`:

```bash
# from plantaum.service/
dotnet user-secrets set "EvolutionGo:WebhookUrl" "http://host.docker.internal:5214/v1/whatsapp/webhooks/evolution"
```

`5214` is the API's HTTP profile port (`Properties/launchSettings.json`). Use
plain HTTP, not the `7106` HTTPS profile: the dev certificate is not trusted
inside the containers and Evolution Go does not skip verification.

### Why there is no WEBHOOK_URL here

Evolution Go has a global webhook env var, and the vendor docs say it "receives
events from every instance, in addition to the per-instance webhooks". The
second half is true and the first half is not:

- `whatsmeow.go:2348` gates the **entire** producer call on the *per-instance*
  webhook being non-empty.
- `webhook_producer.go:43-48` only then fans out to the global URL **and** the
  per-instance one.

So `WEBHOOK_URL` alone delivers nothing, and setting both delivers every event
twice. One shared URL sent through `connect.webhookUrl` is the working shape,
which is what the service does.

Two more traps worth knowing:

- **`instance.Webhook` is overwritten on every connect** (`instance_service.go:234`),
  including with an empty value. A connect that omits `webhookUrl` silently turns
  delivery off. `POST /instance/pair` does not touch it.
- **`OfflineSyncCompleted` is not delivered under `CONNECTION`**, though the docs
  list it there and tell you to expect `PairSuccess → Connected → OfflineSyncCompleted`.
  It has no case in `CallWebhook`'s switch, so it only arrives when you subscribe
  to `ALL`. `CONNECTION` really carries `Connected`, `PairSuccess`, `LoggedOut`,
  `Disconnected`, `ConnectFailure` and `TemporaryBan`.

### Webhook-related settings

| Variable | Value here | Why |
|---|---|---|
| `WEBHOOK_FILES` | `false` | The vendor default is **true**, which inlines every image, audio and video as base64. We match on text only, and a video would push megabytes at the receiver. |
| `EVENT_IGNORE_STATUS` | `true` | Status/stories broadcasts are noise for shift matching. |
| `EVENT_IGNORE_GROUP` | `false` | Must stay false — `true` drops every `@g.us` event before it reaches the webhook. Group messages are the product. |
| `WEBHOOK_URL` | *unset* | See above. |

### Checking delivery

```bash
docker logs -f evogo-lt-fixed-1 2>&1 | grep -i webhook
```

A successful POST logs `webhook sent successfully`. A non-2xx or a refused
connection logs `webhook failed` and retries **5 times, 30 s apart**, then drops
the event — there is no dead-letter. If the host is unreachable you will see
five failures per event and nothing else.

To watch payloads without the service running, point the URL at a throwaway
receiver instead:

```bash
docker run --rm -p 8888:80 mendhak/http-https-echo:31
# then set EvolutionGo:WebhookUrl to http://host.docker.internal:8888/
```

## The pool leak test

```bash
./pool-leak-test.sh        # 30 instances per side
./pool-leak-test.sh 70     # past the 60-connection role budget: baseline dies
```

It creates N instances per side and connects each one — N `StartClient()` calls,
spread round-robin across that side's two replicas the way a load balancer would
— then counts backends per auth database.

Leaked connections belong to the process that opened them, so they are freed on
container restart. The script **restarts all four servers first**, so every run
starts clean and repeats identically. Pass `--no-restart` to measure cumulative
state instead.

Real output from `./pool-leak-test.sh 70`:

```
                             before   after    delta
  auth_baseline (pre-fix)    2        57       +55
  auth_fixed    (post-fix)   2        4        +2

  PASS  70 connects added 2 backends on fixed vs 55 on baseline
        fixed does not scale with instance count; baseline does

  per replica (application_name):
    evo-1        3 backends
    evo-2        4 backends
    evo-base-1   30 backends
    evo-base-2   30 backends

  Postgres "out of connection slots" errors, summed per side:
    baseline     x16
    fixed        x0

  PASS  baseline burned through its connection budget; fixed never did
```

Note both baseline replicas leak ~30 each into the *shared* budget — that is the
compounding this harness exists to show. Those 16 errors are
`FATAL: too many connections for role "evo_baseline"`, the same exhaustion as the
production `sorry, too many clients already`, worded for the per-role cap.

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

### Why the two sides cannot contaminate each other

Each *side* logs in as its own Postgres role with its own `CONNECTION LIMIT`
(`PG_ROLE_CONN_LIMIT`, default 60), set up by `init-db.sh`, shared by that
side's two replicas. So when the baseline leaks its budget away it exhausts
**itself**, and the fixed side keeps working.

Without that, everything shares one global ceiling and the baseline's leak
starves the fixed servers too — which makes them log connection errors they did
not cause, and the comparison stops meaning anything.

The `postgres` superuser sits outside both budgets, so `./conns.sh` can always
get in to measure, even while a side is fully exhausted.

### Reproducing the boot storm

The original failure was a restart with many stored instances all reconnecting
at once:

```bash
sed -i 's/^CONNECT_ON_STARTUP=.*/CONNECT_ON_STARTUP=true/' .env
docker compose --env-file .env up -d --force-recreate
./conns.sh
```

Each baseline replica opens one pool per stored instance during boot; each fixed
replica opens one total. Run `./pool-leak-test.sh` first so there are instances
stored to reconnect.

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
./conns.sh          # backends per database, per replica, and the role limits
./stop.sh           # stop, keep data
./stop.sh --clean   # stop, wipe pgdata (licence must be re-seeded)
```

Direct compose access:

```bash
docker compose --env-file .env logs -f evo-1
docker compose --env-file .env exec postgres psql -U postgres
```

## Ports

| what | where |
|---|---|
| `evo-1` (fixed) | http://localhost:8080 |
| `evo-2` (fixed) | http://localhost:8082 |
| `evo-base-1` (baseline) | http://localhost:8081 |
| `evo-base-2` (baseline) | http://localhost:8083 |
| postgres | localhost:55432 (postgres/postgres) |

Change them in `.env` if they clash.
