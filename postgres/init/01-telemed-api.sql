-- The telemed-api role and database. Run by the db-init one-shot on every deploy, as the postgres superuser:
--
--   psql -v ON_ERROR_STOP=1 -v api_password=... -h postgres -U postgres -d postgres -f 01-telemed-api.sql
--
-- Idempotent, so a rotated TELEMED_API_DB_PASSWORD is applied by the next deploy. The role owns its database and
-- therefore everything EF migrations create in it; btree_gist is a trusted extension, so no superuser is needed.
-- The Go platform's `telemed` database and its roles are left untouched.

\set ON_ERROR_STOP on

SELECT format('CREATE ROLE telemed_api LOGIN PASSWORD %L', :'api_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'telemed_api') \gexec

ALTER ROLE telemed_api WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'api_password';

SELECT 'CREATE DATABASE telemed_api OWNER telemed_api'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'telemed_api') \gexec

REVOKE ALL ON DATABASE telemed_api FROM PUBLIC;
GRANT ALL ON DATABASE telemed_api TO telemed_api;
