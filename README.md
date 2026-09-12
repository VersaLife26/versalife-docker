# versalife-docker

The whole VersaLife platform on one Hetzner VPS: **3.5 GB RAM, 2 vCPU, 38 GB
root, a 10 GB volume and an 11 GB volume.**

The server is provisioned by
[versalife-ansible](https://github.com/VersaLife26/versalife-ansible), which
owns the volumes, the accounts, Docker, both Cloudflare tunnels and the
secrets. Nothing below is done by hand any more; it is kept as the description
of what that repo builds.

Nothing here builds. Images come from GHCR, built by `telemed-backend`'s
`release` workflow. A Go build of that module peaks well over 2 GB, which on
this box means the OOM killer picks a victim and the victim is Postgres.

---

## What runs

```
                         Cloudflare
   patient. doctor. admin.(+Access)     api.          rtc.
    Worker  Worker  Worker           ┌──────── Tunnel ────────┐
   ══════════════════════════════════│═══════════ VPS ════════│═══
                                ┌────▼──────┐
                                │cloudflared│            edge network
                                └────┬──────┘
              ┌──────────────────────┼──────────────────────┐
      ┌───────▼────────┐    ┌────────▼───────┐   ┌──────────▼─────┐
      │telemed-backend │    │ telemed-video  │   │  notification  │
      │ 6 domains+edge │◄───┤  consultation  │   │                │
      │   1024 MB      │gRPC│     384 MB     │   │     320 MB     │
      └───────┬────────┘    └────────┬───────┘   └──────────┬─────┘
              └──────────────┬───────┴──────────────────────┘
                   ┌─────────┼─────────┐      data network (internal: true)
              postgres     redis      nats
               768 MB     192 MB     256 MB
```

**One image, three containers.** `telemed-backend`, `telemed-video` and
`telemed-notification` are the same `ghcr.io/versalife26/telemed-backend`
image with different `TELEMED_DOMAINS`. `cmd/telemed` composes whichever
domains it is told to at run time — that is what the nine-service
consolidation was for.

Committed limits total **3072 MB**, leaving ~1 GB for the host and page cache.

---

## Nothing is published

There is not one `ports:` key in `docker-compose.yml`. The only inbound path
is the Cloudflare tunnel, which cloudflared opens **outbound**.

This matters more than it looks. Docker's port publishing installs its own
iptables chain that is consulted *before* the rules `ufw` and `firewalld`
write, so `-p 5432:5432` on a VPS exposes Postgres to the internet while
`ufw status` truthfully reports the port as denied. That is how "we found your
patient database on Shodan" starts.

To reach a datastore, go through the container:

```bash
docker compose exec postgres psql -U postgres telemed
docker compose exec redis redis-cli -a "$REDIS_PASSWORD"
```

The host firewall still has a job — deny everything inbound, allow nothing:

```bash
sudo firewall-cmd --set-default-zone=drop     # Rocky ships firewalld, not ufw
sudo firewall-cmd --permanent --zone=drop --remove-service=ssh
sudo firewall-cmd --reload   # port 22 stays closed; SSH rides the tunnel
```

---

## First run

```bash
# 0. Volumes. Both are attached disks, not directories on the 20 GB root.
sudo mkdir -p /mnt/data/{postgres,redis,nats} /mnt/files/{objects,backups}
sudo chown -R 70:70 /mnt/data/postgres          # postgres:alpine runs as 70
# backups/ is a SIBLING of objects/, never a child: telemed-backend serves
# objects/ from /api/v1/files, and a pg_dump inside it is the patient database
# behind a presigned URL.

# 1. Secrets. Idempotent: safe to re-run, never rewrites what is already set.
./scripts/gen-secrets.sh

# 2. Fill in by hand — the script cannot generate these:
#      TELEMED_DOMAIN, TUNNEL_ID, ADMIN_ISSUER, ADMIN_JWKS_URL,
#      ICE_TURN_SECRET, ADMIN_IP_ALLOWLIST, DIALOG_*, STRIPE_*, PAYHERE_*
$EDITOR secrets/secrets.env

# 3. The tunnel.
cloudflared tunnel create versalife
cp ~/.cloudflared/<TUNNEL_ID>.json secrets/tunnel-credentials.json
cloudflared tunnel route dns versalife api.$TELEMED_DOMAIN
cloudflared tunnel route dns versalife rtc.$TELEMED_DOMAIN

# 4. The compose override carrying the multiline JWT key must always apply.
echo 'COMPOSE_FILE=docker-compose.yml:secrets/secrets.override.yml' >> .env

# 5. Up. db-init and migrate run to completion first; the apps wait on them.
docker compose up -d

# 6. Mint the mesh token telemed-notification uses to reach the user directory.
docker compose run --rm --no-deps \
  -e JWT_PRIVATE_KEY_PEM="$(cat secrets/jwt-key.pem)" \
  telemed-backend mint-service-token notification-service 8760h
# put it in MESH_STATIC_TOKEN, then: docker compose up -d telemed-notification

# 7. Prove the privilege boundary actually holds.
set -a; . ./secrets/secrets.env; set +a
./scripts/verify-db-privileges.sh
```

Updates are `./scripts/deploy.sh`, or a push to `telemed-backend`'s `main`,
which dispatches here.

---

## Things worth knowing before you change something

**`gen-secrets.sh` generates URL-safe passwords on purpose.**
`TELEMED_APP_DB_PASSWORD` ends up inside `DATABASE_URL` and `NATS_PASSWORD`
inside `NATS_URL`, and both are parsed with `net/url`. A `/` in a password
makes `url.Parse` fail with `invalid port ":ab" after host` — so a plain
base64 password breaks boot roughly every other time it is generated, with an
error naming neither the password nor the setting.

**The JWT key is not in `secrets.env`.** `pem.Decode` needs real newlines and
an `env_file` has no line-continuation syntax, so a PEM pasted into one is
truncated at the first line. The user domain then falls back to an ephemeral
key, every session dies on every deploy, and nothing logs an error.
`gen-secrets.sh` writes `secrets/secrets.override.yml` instead, a compose
override using a YAML block scalar.

**Redis runs `maxmemory-policy noeviction`, and that is not laziness.** Six of
the seven key families in it are security or correctness controls — OTP
attempt counters, rate-limit buckets, the suspension denylist, slot locks,
signalling room occupancy. Evicting any of them fails *open* and silently.
`noeviction` fails closed: the write errors, the request 5xxs, someone
notices.

**`NATS_MAX_BYTES` must be identical in all three containers.** Each creates
the `TELEMED` stream on boot, last writer wins, and JetStream refuses stream
creation outright when `MaxBytes` exceeds `max_file_store` — which took down
every publisher at once the last time the two disagreed.

**`db-init` runs on every deploy, not from `docker-entrypoint-initdb.d`.**
`initdb.d` fires once, when `PGDATA` is empty; a privilege model that can only
be applied to an empty data directory cannot be corrected or rotated. It also
*must* precede migrations: `migrations/admin/000002` and
`migrations/doctor/000008` will otherwise `CREATE ROLE ... PASSWORD
'changeme_in_deployment_secret_manager'` and lock the application out with a
password that is in the git history.

**`TRUSTED_PROXIES` is deliberately empty.** `middleware.ClientIP` trusts
`X-Forwarded-For` only from a private-range peer, and cloudflared sits on a
172.x bridge — so the real client IP already reaches the rate limiter, the
admin allowlist and the audit log. Setting `0.0.0.0/0` is a spoofing hole.

**There is no zero-downtime deploy.** 4 GB cannot hold two copies of
`telemed-backend`. Expect a ~20 second gap; `SHUTDOWN_GRACE=20s` drains
in-flight requests into it. If that is unacceptable the answer is a second
VPS, not a cleverer script.

**Backups are on the same box.** `deploy.sh` writes `pg_dump -Fc` to
`/mnt/files/backups` before migrating and prunes at 14 days. That survives a
dropped table. It does not survive the VPS — ship them off-host, and back up
`secrets/` separately, because losing it loses every encrypted column.

---

## Removed, and where it went

| Was | Now |
|---|---|
| MinIO | `STORAGE_BACKEND=filesystem`, served by `/api/v1/files` |
| Keycloak | Cloudflare Access as `ADMIN_ISSUER`; roles from `admin_users` |
| LiveKit | in-house 1:1 signalling; `VIDEO_PROVIDER=livekit` switches back |
| coturn | Cloudflare Realtime TURN |
| Caddy / nginx | Cloudflare Tunnel |
| Prometheus, Grafana | instrumentation kept, `/metrics` 404'd at the tunnel |
| ClamAV | `scan.PassthroughScanner`; uploads store `scan_status=skipped` |
| NATS | **kept** — 15 durable subscriptions and three processes need it |
