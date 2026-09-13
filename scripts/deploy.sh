#!/usr/bin/env bash
#
# Update the running stack. Runs ON the VPS.
#
# There is no rolling replacement here, deliberately: 4 GB cannot hold two
# copies of telemed-backend (1 GB each) alongside everything else. The stack
# takes a ~20 second gap while containers are recreated, and SHUTDOWN_GRACE
# drains in-flight requests into it. If that is unacceptable the answer is a
# second VPS, not a cleverer script.
set -euo pipefail

cd "$(dirname "$0")/.."

# One deploy at a time. Two concurrent `docker compose up -d` runs against the
# same project is how you get a half-recreated stack.
#
# Beside the compose file, not in /var/lock: that directory is root-owned, and
# this script runs as `deploy` -- both from the CI deploy over SSH and by hand.
# The redirection is what creates the file, so it failed before flock was ever
# reached, with "Permission denied" and no deploy.
exec 9>./.deploy.lock
flock -n 9 || { echo "a deploy is already running"; exit 1; }

COMPOSE=${COMPOSE:-docker compose}

# The files volume, NOT the data volume, and NOT under $OBJECTS_VOLUME.
#
# telemed-backend bind-mounts the objects directory and serves it from
# /api/v1/files behind presigned URLs. A backup directory inside that tree is
# every pg_dump of the patient database sitting behind a public file endpoint.
# They are siblings on the same volume for that reason.
BACKUP_DIR=${BACKUP_DIR:-/mnt/files/backups}

# docker-compose.yml interpolates five datastore passwords with ${...}, and the
# compose CLI resolves those from ITS OWN environment and .env -- never from an
# env_file, which only reaches the process inside a container. Without this the
# very first command below dies with
#
#   error while interpolating services.postgres.environment.POSTGRES_PASSWORD:
#   required variable POSTGRES_PASSWORD is missing a value
#
# .env already carries them, so this is belt and braces for anyone running the
# script with a .env that predates that change.
if [[ -f ./secrets/secrets.env ]]; then
  set -a; . ./secrets/secrets.env; set +a
fi

echo "==> pulling"
# Explicit, so a registry outage fails here rather than half way through a
# restart with some containers new and some old.
$COMPOSE pull --quiet

echo "==> backing up before any migration touches the schema"
mkdir -p "$BACKUP_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
$COMPOSE exec -T postgres pg_dump -U postgres -Fc telemed > "$BACKUP_DIR/telemed-$stamp.dump"
# Same box as the data. This survives a dropped table; it does not survive the
# VPS. Ship these off-host separately.
find "$BACKUP_DIR" -name '*.dump' -mtime +14 -delete
echo "    $BACKUP_DIR/telemed-$stamp.dump"

echo "==> roles and grants"
$COMPOSE up --no-deps --exit-code-from db-init db-init

echo "==> migrations"
# A dirty migration exits non-zero forever and the apps never start. That is
# the right failure -- serving against a half-migrated schema is worse -- but
# it needs a remedy printed rather than an operator staring at a dependency
# error.
if ! $COMPOSE up --no-deps --exit-code-from migrate migrate; then
  cat <<'DIRTY'

Migrations failed. If the version is marked dirty, find it with:

  docker compose run --rm --entrypoint migrate migrate \
    -path /app/migrations/<domain> -database "$DATABASE_URL" version

and, ONLY after establishing what actually applied:

  docker compose run --rm --entrypoint migrate migrate \
    -path /app/migrations/<domain> -database "$DATABASE_URL" force <version>

DIRTY
  exit 1
fi

echo "==> recreating application containers"
$COMPOSE up -d --remove-orphans

echo "==> waiting for health"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  unhealthy=$($COMPOSE ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
    | awk '$1 ~ /^telemed-/ && $2 != "healthy" {print $1}' || true)
  [[ -z "$unhealthy" ]] && break
  sleep 5
done
if [[ -n "${unhealthy:-}" ]]; then
  echo "not healthy after 180s: $unhealthy"
  $COMPOSE logs --tail=50 $unhealthy
  exit 1
fi
echo "    all application containers healthy"

echo "==> verifying the privilege boundary still holds"
# secrets.env is already in the environment, sourced at the top.
./scripts/verify-db-privileges.sh

echo "==> pruning images older than a week"
docker image prune -af --filter 'until=168h' >/dev/null

echo "done"
