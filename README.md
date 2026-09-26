# versalife-docker

The whole VersaLife platform on one Hetzner VPS: **3.5 GB RAM, 2 vCPU, 38 GB
root, a 10 GB volume and an 11 GB volume.**

The server is provisioned by
[versalife-ansible](https://github.com/VersaLife26/versalife-ansible), which
owns the volumes, the accounts, Docker, both Cloudflare tunnels and the
secrets. Nothing below is done by hand any more; it is kept as the description
of what that repo builds.

Nothing here builds. The image comes from GHCR, built by
[telemed-api](https://github.com/VersaLife26/telemed-api)'s `release` workflow.

---

## What runs

```
                         Cloudflare
   patient. doctor. admin.(+Access)          api.
    Worker  Worker  Worker           ┌──── Tunnel ────┐
   ══════════════════════════════════│═══════ VPS ════│═══
                                ┌────▼──────┐
                                │cloudflared│     edge network
                                └────┬──────┘
                             ┌───────▼────────┐
                             │  telemed-api   │  REST + SignalR hub
                             │   (.NET 10)    │  + background jobs
                             │    768 MB      │
                             └───────┬────────┘
                                 postgres           data network (internal: true)
                                  768 MB
```

`telemed-api` is one ASP.NET Core process with one PostgreSQL database
(`telemed_api`). It serves the REST API, the consultation SignalR hub at
`/hubs/consultation` and signed file downloads, and runs its background jobs
in-process. Postgres is the only datastore.

The Go platform's `telemed` database is still in the same Postgres instance,
untouched. Nothing reads it; it is kept so a rollback is a `git revert` of this
repo plus a deploy.

---

## Nothing is published

There is not one `ports:` key in `docker-compose.yml`. The only inbound path
is the Cloudflare tunnel, which cloudflared opens **outbound**.

Docker's port publishing installs its own iptables chain that is consulted
*before* the rules `ufw` and `firewalld` write, so `-p 5432:5432` on a VPS
exposes Postgres to the internet while the firewall truthfully reports the
port as denied. To reach the database, go through the container:

```bash
docker compose exec postgres psql -U postgres telemed_api
```

---

## First run

```bash
# 0. Volumes. Both are attached disks, not directories on the root disk.
sudo mkdir -p /mnt/data/postgres /mnt/files/{api-files,backups}
sudo chown -R 70:70 /mnt/data/postgres        # postgres:alpine runs as 70
sudo chown 1654:1654 /mnt/files/api-files     # the aspnet image's app user
# backups/ is a SIBLING of api-files/, never a child: telemed-api serves
# api-files/ through signed /api/v1/files links.

# 1. Generated secrets. Idempotent: never rewrites a value already set.
./scripts/gen-secrets.sh

# 2. The rest of secrets/secrets.env (Cloudflare Access, origins, TURN,
#    SMS/email/PayHere, the test secret). versalife-ansible writes these.
$EDITOR secrets/secrets.env

# 3. docker-compose.yml interpolates two passwords, which the compose CLI
#    reads from .env, never from an env_file.
grep -E '^(POSTGRES_PASSWORD|TELEMED_API_DB_PASSWORD)=' secrets/secrets.env > .env

# 4. The tunnel.
cloudflared tunnel create versalife
cp ~/.cloudflared/<TUNNEL_ID>.json secrets/tunnel-credentials.json
cloudflared tunnel route dns versalife api.$TELEMED_DOMAIN

# 5. Up. db-init creates the role and database; telemed-api applies its EF
#    migrations before it reports healthy.
docker compose up -d
```

Updates are `./scripts/deploy.sh`: pull, ensure the role and database, dump
the database, recreate, wait for health. It runs from the `deploy` workflow
here, which telemed-api's `release` workflow triggers after pushing an image,
or by hand with `gh workflow run deploy -R VersaLife26/versalife-docker`.

---

## Things worth knowing before you change something

**`Crypto__BankDataKey` and `Prescriptions__HmacKey` are one-way doors.**
Rotating the first orphans every stored bank account number; rotating the
second invalidates the QR on every prescription already issued.
`gen-secrets.sh` only fills empty keys, so re-running it is safe.

**The connection string is in `docker-compose.yml`, not `secrets.env`.** It
contains `;`, and anything that sources an env file with a shell would run
the pieces as commands. Only the password is secret, and it is interpolated
from `.env`.

**Test switches are on.** `env/common.env` enables the capture inbox, instant
meetings and the mock payment rail, and the API logs a TEST SWITCHES ENABLED
banner at startup. SMS goes to the capture inbox unless Dialog is configured.
`/api/v1/test/*` needs the `X-Test-Secret` header. Turn them off before real
patients arrive.

**`ForwardedHeaders__TrustCloudflare=true` is only safe because nothing is
published.** The API takes the client IP from `CF-Connecting-IP`, which the
rate limits and the admin IP allowlist depend on. Publishing a port would let
anyone set that header.

**There is no zero-downtime deploy.** The box cannot hold two copies of the
API. Expect a short gap while the container is recreated and migrations run.

**Backups are on the same box.** `deploy.sh` dumps `telemed_api` to
`/mnt/files/backups` before every deploy, and a nightly timer does the same.
That survives a dropped table, not the VPS: ship them off-host, and back up
`secrets/` separately, because losing it loses every encrypted column.

---

## Removed with the Go platform

| Was | Now |
|---|---|
| `telemed-backend`, `telemed-video`, `telemed-notification` | `telemed-api`, one process |
| Redis, NATS | nothing: Postgres advisory locks and in-process jobs |
| `migrate` image | EF migrations at startup |
| `rtc.` hostname, raw WebSocket signalling | SignalR hub on `api.` |
| Per-domain roles and `verify-db-privileges.sh` | one role owning `telemed_api` |
| RSA JWT key and compose override | HS256 `Auth__Jwt__SigningKey` in `secrets.env` |
