-- On-prem overlay. Applied after 01-cheese-schema.sql by `cheese setup-supabase`.
-- __ALLOWED_DOMAINS_SQL__ is substituted with a SQL array literal of allowed
-- email domains, e.g. ARRAY['customer.com','partner.org'].
--
-- Two on-prem behaviours, both deliberate:
--   1. Every new user is created as account_type='premium' — on-prem is
--      all-premium (the orchestrator runs universal-cheese and the UI's paywalls
--      are off, so this is belt-and-suspenders for any code that reads the tier).
--   2. Sign-up is restricted to an allow-list of email domains, enforced in the
--      DB so it covers every signup path (GoTrue API, Studio, admin API).

-- 1) New accounts default to premium ----------------------------------------
ALTER TABLE public.profiles ALTER COLUMN account_type SET DEFAULT 'premium';

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, account_type, completed_registration, is_active, created_at, updated_at)
    VALUES (NEW.id, 'premium', true, true, now(), now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2) Domain-restricted signup ------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_allowed_email_domain()
RETURNS TRIGGER AS $$
DECLARE
    allowed text[] := __ALLOWED_DOMAINS_SQL__;
    domain  text  := lower(split_part(NEW.email, '@', 2));
BEGIN
    IF NEW.email IS NULL OR domain = '' THEN
        RAISE EXCEPTION 'A valid email address is required to register.';
    END IF;
    IF NOT (domain = ANY (allowed)) THEN
        RAISE EXCEPTION 'Registration is restricted to approved email domains (%).', array_to_string(allowed, ', ');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS enforce_allowed_email_domain_trigger ON auth.users;
CREATE TRIGGER enforce_allowed_email_domain_trigger
    BEFORE INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_allowed_email_domain();
