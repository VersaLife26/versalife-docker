#!/usr/bin/env bash
#
# Update the running stack. Runs ON the VPS, as `deploy`, from the deploy
# workflow over SSH or by hand.
#
# There is no rolling replacement: the box cannot hold two copies of the API
# alongside Postgres. Expect a short gap while telemed-api is recreated and
# applies any new EF migrations.
set -euo pipefail

cd "$(dirname "$0")/.."

# One deploy at a time, and never during the nightly dump, which takes the same
# lock. Beside the compose file, not in root-owned /var/lock.
exec 9>./.deploy.lock
flock -n 9 || { echo "a deploy is already running"; exit 1; }

COMPOSE=${COMPOSE:-docker compose}

echo "==> pulling"
# Explicit, so a registry outage fails here rather than half way through a
# restart.
$COMPOSE pull --quiet

echo "==> role and database"
# Before the backup: on a first deploy there is no telemed_api database to dump.
$COMPOSE up --no-deps --exit-code-from db-init db-init

echo "==> backing up before migrations touch the schema"
# The same root-owned script the nightly timer runs; `deploy` cannot read the
# dumps it produces. --no-lock because this script already holds the lock.
sudo -n /usr/local/bin/versalife-backup --no-lock

echo "==> recreating containers"
$COMPOSE up -d --remove-orphans

echo "==> waiting for health"
deadline=$((SECONDS + 240))
health=""
while (( SECONDS < deadline )); do
  health=$($COMPOSE ps --format '{{.Health}}' telemed-api 2>/dev/null || true)
  [[ "$health" == "healthy" ]] && break
  sleep 5
done
if [[ "$health" != "healthy" ]]; then
  echo "telemed-api not healthy after 240s (${health:-missing})"
  $COMPOSE logs --tail=80 telemed-api
  exit 1
fi
echo "    telemed-api healthy"

echo "==> pruning images older than a week"
docker image prune -af --filter 'until=168h' >/dev/null

echo "done"
