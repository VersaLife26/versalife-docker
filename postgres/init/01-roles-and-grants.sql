-- Roles, schemas and grants for the telemed platform.
--
-- Replaces telemed-infra/infra/postgres/init/01-init-databases.sh.
--
-- Run by the db-init one-shot, as the postgres superuser, against the telemed
-- database, BEFORE any migration:
--
--   psql -v ON_ERROR_STOP=1 -v migrator_password=... -v app_password=... \
--        -h postgres -U postgres -d telemed -f 01-roles-and-grants.sql
--
-- WHY IT RUNS ON EVERY DEPLOY, NOT FROM docker-entrypoint-initdb.d
-- initdb.d fires exactly once, when PGDATA is empty. A privilege model that is
-- only ever applied to an empty data directory cannot be corrected, rotated or
-- extended without destroying the database. Every statement below is
-- idempotent so this can run on every `docker compose up`.
--
-- WHY IT MUST RUN BEFORE MIGRATIONS
-- migrations/admin/000002_audit_log.up.sql and
-- migrations/doctor/000008_doctor_applications.up.sql each contain
--
--   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'telemed_x_app') THEN
--     CREATE ROLE telemed_x_app LOGIN PASSWORD 'changeme_in_deployment_secret_manager';
--
-- If a migration wins that race, the role exists with a password published in
-- the git history and the application cannot connect. Creating the roles here
-- first makes those blocks the no-ops they were always meant to be.

\set ON_ERROR_STOP on

-- The two passwords arrive as psql variables. Bind them to GUCs so the DO
-- blocks below -- which cannot see psql variables -- can read them.
SELECT set_config('telemed.migrator_password', :'migrator_password', false);
SELECT set_config('telemed.app_password', :'app_password', false);

-- ---------------------------------------------------------------------------
-- 1. The migration role.
--
-- Migrations used to run as the superuser. They do not need to, and a
-- container holding superuser credentials on every deploy is a standing risk.
--
-- telemed_migrator owns every svc_ schema and everything in it. That ownership
-- is what makes the append-only guarantees real: migrations/admin/000002
-- REVOKEs UPDATE and DELETE on audit_logs from telemed_admin_app, and that
-- REVOKE only means something because the app role is NOT the owner and so
-- cannot grant itself back what was taken away.
--
-- CREATEROLE because the two migrations above create roles. Database ownership
-- because migrations/bootstrap creates pgcrypto, which is a TRUSTED extension
-- in PG13+ and so creatable by the database owner without superuser.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'telemed_migrator') THEN
    CREATE ROLE telemed_migrator LOGIN CREATEROLE;
  END IF;
END $$;

DO $$
BEGIN
  EXECUTE format('ALTER ROLE telemed_migrator WITH PASSWORD %L',
                 current_setting('telemed.migrator_password'));
END $$;

ALTER DATABASE telemed OWNER TO telemed_migrator;
GRANT ALL ON DATABASE telemed TO telemed_migrator;

-- ---------------------------------------------------------------------------
-- 2. Close the door on PUBLIC.
--
-- Every role is implicitly a member of PUBLIC, which by default holds CREATE
-- and USAGE on schema public and CONNECT on every database. Without this
-- REVOKE, telemed_payment_app can create a table in public -- and, worse,
-- shadow an object another domain resolves there, because every domain's
-- search_path is 'svc_<domain>, public'. That is a live privilege escalation
-- path between domains, not a hygiene nit.
-- ---------------------------------------------------------------------------
REVOKE ALL    ON SCHEMA   public  FROM PUBLIC;
REVOKE ALL    ON DATABASE telemed FROM PUBLIC;
REVOKE CREATE ON SCHEMA   public  FROM PUBLIC;
ALTER SCHEMA public OWNER TO telemed_migrator;

-- ---------------------------------------------------------------------------
-- 3. Schemas, app roles, grants.
--
-- EIGHT schemas, THREE processes:
--
--   telemed-backend       user, doctor, scheduling, payment, record, admin
--   telemed-video         consultation
--   telemed-notification  notification
--
-- The domain -> role -> schema mapping does not change with that split.
-- cmd/telemed's dsnResolver derives telemed_<domain>_app and pins
-- search_path=svc_<domain>,public from the domain name alone, so a domain
-- carries its identity into whichever process happens to host it. The
-- privilege boundary is in Postgres, not in the process layout, which is why
-- splitting the binary did not weaken it.
--
-- All eight app roles share ONE password, because dsnResolver assumes it: it
-- takes the password from DATABASE_URL and swaps only the username. Eight
-- passwords to rotate on a box this size is worse security, not better --
-- TELEMED_DB_URL_<DOMAIN> exists for a deployment that disagrees.
--
-- ALTER DEFAULT PRIVILEGES is the load-bearing statement here. This script
-- runs BEFORE the migrations, so "GRANT ... ON ALL TABLES IN SCHEMA" would
-- grant on the empty set. And the user, scheduling, consultation, payment and
-- notification migrations contain ZERO grants -- their app roles get table
-- privileges from nowhere else. Default privileges are scoped FOR ROLE
-- telemed_migrator because that is the role that will create the objects;
-- scoped to anyone else they are inert.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  d        text;
  schema_n text;
  role_n   text;
  app_pw   text := current_setting('telemed.app_password');
  domains  text[] := ARRAY[
    'user','doctor','scheduling','consultation',
    'payment','notification','record','admin'
  ];
BEGIN
  FOREACH d IN ARRAY domains LOOP
    schema_n := 'svc_' || d;
    role_n   := 'telemed_' || d || '_app';

    -- 3a. The role.
    --
    -- NOINHERIT so that granting one app role to another later cannot quietly
    -- widen access. NOCREATEDB/NOCREATEROLE/NOSUPERUSER are the defaults and
    -- are stated so a reader need not know that.
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_n) THEN
      EXECUTE format(
        'CREATE ROLE %I LOGIN NOINHERIT NOCREATEDB NOCREATEROLE NOSUPERUSER', role_n);
    END IF;

    -- Unconditional, so rotating TELEMED_APP_DB_PASSWORD and redeploying is
    -- the whole rotation procedure.
    EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', role_n, app_pw);

    -- A backstop against a misconfigured DB_MAX_CONNS_PER_DOMAIN exhausting
    -- max_connections and locking every other domain out. Must exceed the
    -- configured pool size (4) with room for the migration run.
    EXECUTE format('ALTER ROLE %I CONNECTION LIMIT 8', role_n);

    -- 3b. The schema, owned by the migrator.
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION telemed_migrator', schema_n);
    EXECUTE format('ALTER SCHEMA %I OWNER TO telemed_migrator', schema_n);

    -- 3c. PUBLIC gets USAGE on a newly created schema by default. Take it
    -- back before granting anything deliberately.
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', schema_n);

    -- 3d. USAGE on its OWN schema and nothing else.
    --
    -- THIS IS THE WHOLE PRIVILEGE MODEL. telemed_payment_app has no USAGE on
    -- svc_user, so a bug in the payment domain cannot read the patient
    -- directory even though, inside telemed-backend, the two now share an
    -- address space.
    EXECUTE format('GRANT CONNECT ON DATABASE telemed TO %I', role_n);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_n, role_n);

    -- TEMPORARY, for scheduling ALONE.
    --
    -- Slot generation stages a night's slots in a CREATE TEMP TABLE ... ON
    -- COMMIT DROP and merges them with ON CONFLICT DO NOTHING (CopySlots in
    -- telemed-backend). Without this grant that CREATE fails with "permission
    -- denied to create temporary tables", every generation run aborts, and the
    -- platform quietly stops materialising slots -- which is not a visible
    -- outage, it is a booking calendar that silently stops growing. It ran for
    -- a week: 485 slots, all created on the day of the first deploy, and every
    -- doctor who opened up a new day afterwards got nothing.
    --
    -- Granted to ONE role rather than to all eight in the loop. pg_temp is
    -- per-session and dropped at disconnect, so this is the narrowest
    -- exception to "the app role must never do DDL" that makes the scheduler
    -- work, and the other seven domains keep the property intact.
    IF d = 'scheduling' THEN
      EXECUTE format('GRANT TEMPORARY ON DATABASE telemed TO %I', role_n);
    END IF;

    -- 3e. USAGE on public, for pgcrypto. NOT CREATE: public is on every
    -- domain's search_path, so CREATE there is a shadowing attack against all
    -- eight domains at once.
    EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', role_n);

    -- 3f. Default privileges: DML on tables the migrator has not created yet.
    EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE telemed_migrator IN SCHEMA %I '
      'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', schema_n, role_n);
    EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE telemed_migrator IN SCHEMA %I '
      'GRANT USAGE, SELECT ON SEQUENCES TO %I', schema_n, role_n);
    EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE telemed_migrator IN SCHEMA %I '
      'GRANT EXECUTE ON FUNCTIONS TO %I', schema_n, role_n);

    -- Deliberately absent: any CREATE on the schema. The app role must never
    -- do DDL. That is what keeps the append-only REVOKEs in section 4
    -- unforgeable -- a role that can CREATE can also DROP and recreate.

    -- 3g. Catch-up for a database that already has tables, i.e. every deploy
    -- after the first. Default privileges only bind at CREATE time, so an
    -- object created before this script first ran would otherwise be
    -- invisible to the app role. Idempotent and cheap.
    EXECUTE format(
      'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I',
      schema_n, role_n);
    EXECUTE format(
      'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I',
      schema_n, role_n);
  END LOOP;
END $$;

-- pgcrypto is a database-global object living in public; a second CREATE in
-- another schema errors rather than duplicating. Created here as superuser so
-- the bootstrap migration's CREATE EXTENSION IF NOT EXISTS is a no-op.
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ---------------------------------------------------------------------------
-- 4. Re-apply the append-only REVOKEs.
--
-- Section 3g's blanket "GRANT ... ON ALL TABLES" would hand UPDATE and DELETE
-- straight back on the tables whose migrations deliberately revoked them --
-- the audit log and the medical-record access log, both of which are evidence
-- and neither of which the application may rewrite.
--
-- Guarded by to_regclass so this runs cleanly before those migrations have
-- ever executed.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('svc_admin.audit_logs') IS NOT NULL THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON svc_admin.audit_logs FROM telemed_admin_app;
  END IF;
  IF to_regclass('svc_admin.audit_chain_state') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON svc_admin.audit_chain_state FROM telemed_admin_app;
  END IF;
  IF to_regclass('svc_record.document_access_log') IS NOT NULL THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON svc_record.document_access_log FROM telemed_record_app;
  END IF;
  IF to_regclass('svc_record.clinical_note_revisions') IS NOT NULL THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON svc_record.clinical_note_revisions FROM telemed_record_app;
  END IF;
END $$;
