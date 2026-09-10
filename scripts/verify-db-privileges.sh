#!/usr/bin/env bash
#
# Prove the per-schema privilege boundary actually holds.
#
# A YAML file that looks right and a database that refuses the query are
# different claims, and only the second one matters. Everything asserted here
# is silent when it breaks: a role that can read another domain's schema does
# not error, it just returns rows, and nothing anywhere says so.
#
# Run after every deploy, from scripts/deploy.sh.
#
#   ./scripts/verify-db-privileges.sh
#
# Reads TELEMED_APP_DB_PASSWORD and TELEMED_MIGRATOR_PASSWORD from the
# environment (secrets/secrets.env), and runs psql inside the postgres
# container so it needs no published port.
set -euo pipefail

COMPOSE=${COMPOSE:-docker compose}
DB=${DB:-telemed}
: "${TELEMED_APP_DB_PASSWORD:?TELEMED_APP_DB_PASSWORD must be set}"

fail=0
pass() { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# psql_as ROLE PASSWORD SQL -> prints output, never fails the script
psql_as() {
  local role=$1 pw=$2 sql=$3
  $COMPOSE exec -T -e PGPASSWORD="$pw" postgres \
    psql -At -h 127.0.0.1 -U "$role" -d "$DB" -c "$sql" 2>&1 || true
}

# denied ROLE SQL DESCRIPTION -- asserts the statement is refused BY PRIVILEGE.
#
# Only "permission denied" counts. "relation does not exist" is deliberately
# NOT accepted: before migrations have run every one of these would produce it,
# and a gate that passes because the table is missing tells you nothing about
# whether the role could read it once it exists.
denied() {
  local role=$1 sql=$2 what=$3
  local out
  out=$(psql_as "$role" "$TELEMED_APP_DB_PASSWORD" "$sql")
  case "$out" in
    *"permission denied"*)
      pass "$what" ;;
    *"does not exist"*)
      bad "$what -- inconclusive, the object does not exist. Run this after migrations." ;;
    *)
      bad "$what -- statement was ALLOWED: ${out:0:120}" ;;
  esac
}

echo "roles and connection limits"
roles=$($COMPOSE exec -T -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
  psql -At -h 127.0.0.1 -U postgres -d "$DB" \
  -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'telemed\_%\_app' ORDER BY 1" 2>/dev/null || true)
count=$(grep -c . <<<"$roles" || true)
if [[ "$count" == "8" ]]; then
  pass "eight app roles exist"
else
  bad "expected 8 app roles, found $count"
fi

echo
echo "each domain reaches its own schema and no other"
# payment must not see the patient directory. This is THE assertion: inside
# telemed-backend those two domains share an address space, and Postgres is
# the only thing still separating them.
denied telemed_payment_app "SELECT 1 FROM svc_user.users LIMIT 1" \
  "payment cannot read svc_user"
denied telemed_notification_app "SELECT 1 FROM svc_payment.payments LIMIT 1" \
  "notification cannot read svc_payment"
denied telemed_consultation_app "SELECT 1 FROM svc_record.documents LIMIT 1" \
  "consultation cannot read svc_record"
denied telemed_doctor_app "SELECT 1 FROM svc_admin.audit_logs LIMIT 1" \
  "doctor cannot read svc_admin"

echo
echo "no app role may create objects"
# public is on every domain's search_path, so a table created there by one
# domain shadows an object every other domain resolves.
denied telemed_payment_app "CREATE TABLE public.shadow_test(id int)" \
  "payment cannot create in public"
# DDL in its own schema would let a role drop and recreate a table to shed the
# append-only REVOKEs below.
denied telemed_user_app "CREATE TABLE svc_user.ddl_test(id int)" \
  "user cannot create in its own schema"

echo
echo "append-only tables reject rewriting"
denied telemed_admin_app "DELETE FROM svc_admin.audit_logs WHERE false" \
  "admin cannot delete from audit_logs"
denied telemed_record_app "UPDATE svc_record.document_access_log SET id = id WHERE false" \
  "record cannot update document_access_log"

echo
if [[ "$fail" -gt 0 ]]; then
  echo "FAILED: $fail privilege assertion(s) did not hold."
  echo "The database is not enforcing the isolation the deployment assumes."
  exit 1
fi
echo "all privilege assertions hold"
