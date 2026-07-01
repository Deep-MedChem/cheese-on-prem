-- Role bootstrap for the slim self-host. Applied first by `cheese setup-supabase`.
--
-- supabase/postgres already ships anon / authenticated / service_role and the
-- `authenticator` login role, but their passwords are not pinned to our
-- generated POSTGRES_PASSWORD. PostgREST connects as `authenticator` (NOT the
-- superuser — a superuser would bypass RLS and break per-user isolation) and
-- then SET ROLE to the JWT's role, so we must guarantee that role exists, is
-- NOINHERIT, can assume the three API roles, and has our password.
--
-- Idempotent: safe to re-run. __POSTGRES_PASSWORD__ is substituted by the script.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT;
  END IF;
END
$$;

ALTER ROLE authenticator WITH LOGIN NOINHERIT PASSWORD '__POSTGRES_PASSWORD__';

GRANT anon, authenticated, service_role TO authenticator;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated, service_role;
