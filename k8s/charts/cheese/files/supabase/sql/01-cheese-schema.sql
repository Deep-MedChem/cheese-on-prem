-- VENDORED from cheese-supabase/supabase/migrations/20250624033639_initial_schema.sql
-- (base schema only — Stripe / tier-sync / free-trial migrations are intentionally
-- NOT vendored; on-prem has no billing and the orchestrator runs universal-cheese,
-- so tiers are irrelevant). The on-prem overlay in 02-onprem-overlay.sql adjusts
-- defaults (premium) and adds the signup domain restriction. If the upstream base
-- schema changes, re-copy this file.
--
-- Chemical Search Platform Database Schema
-- Created: 2025-06-23
-- Description: Database for chemical search, download, and quotation workflow

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create enum types
CREATE TYPE account_type_enum AS ENUM (
    'free',
    'academia',
    'premium',
    'ultra',
    'entreprise',
    'demo'
);

CREATE TYPE search_method_enum AS ENUM (
    'espsim_electrostatic', 
    'espsim_shape', 
    'morgan'
);

CREATE TYPE search_quality_enum AS ENUM (
    'very_accurate', 
    'accurate', 
    'fast'
);

CREATE TYPE download_format_enum AS ENUM (
    'csv',
    'sdf',
    'json',
    'xlsx'
);

CREATE TYPE quotation_status_enum AS ENUM (
    'clicked_get_quote',
    'clicked_open_email',
    'email_sent',
    'quote_received',
    'quote_declined'
);

-- Create profiles table for additional user metadata
-- This table links to auth.users via UUID and stores only extra fields
-- not already handled by Supabase Auth (email, name, created_at, etc.)
CREATE TABLE public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    company VARCHAR(255),
    job_title VARCHAR(255),
    ip_address INET,
    country VARCHAR(255),
    newsletter_consent BOOLEAN DEFAULT false,
    contact_consent BOOLEAN DEFAULT false,
    account_type account_type_enum DEFAULT 'free',
    linkedin_profile VARCHAR(255),
    completed_registration BOOLEAN DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create indexes for profiles table
CREATE INDEX idx_profiles_company ON public.profiles(company);
CREATE INDEX idx_profiles_country ON public.profiles(country);
CREATE INDEX idx_profiles_account_type ON public.profiles(account_type);

-- Enable Row Level Security
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Create RLS policies for profiles
-- Users can view their own profile
CREATE POLICY "Users can view own profile" ON public.profiles
    FOR SELECT USING (auth.uid() = id);

-- Users can update their own profile
CREATE POLICY "Users can update own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- Users can insert their own profile (handled by trigger, but allows manual creation)
CREATE POLICY "Users can insert own profile" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = id);

-- Create Databases table
CREATE TABLE databases (
    database_id VARCHAR(255) PRIMARY KEY,
    vendor VARCHAR(255),
    num_molecules BIGINT,
    website VARCHAR(500),
    email VARCHAR(255),
    suffix VARCHAR(50),
    download_restricted BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    is_active BOOLEAN NOT NULL DEFAULT true
);

-- Create indexes for Databases
CREATE INDEX idx_databases_vendor ON databases(vendor);
CREATE INDEX idx_databases_active ON databases(is_active);

-- Create Searches table (one entry per database searched)
CREATE TABLE searches (
    search_id VARCHAR(255) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    ip_address INET NOT NULL,
    search_method search_method_enum NOT NULL,
    search_quality search_quality_enum NOT NULL,
    databases TEXT[] NOT NULL, -- Array of database_ids
    query_smiles TEXT NOT NULL,
    num_results INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Create indexes for Searches
CREATE INDEX idx_searches_user_created ON searches(user_id, created_at);
CREATE INDEX idx_searches_databases ON searches USING gin(databases); -- GIN index for array searches
CREATE INDEX idx_searches_method_quality ON searches(search_method, search_quality);
CREATE INDEX idx_searches_smiles ON searches USING hash(query_smiles);

-- Create ADMET Properties table (for tracking property computation requests)
CREATE TABLE admet_properties (
    admet_id VARCHAR(255) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    search_id VARCHAR(255) REFERENCES searches(search_id) ON DELETE SET NULL,
    ip_address INET NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Create indexes for ADMET Properties
CREATE INDEX idx_admet_properties_user_created ON admet_properties(user_id, created_at);
CREATE INDEX idx_admet_properties_search ON admet_properties(search_id);

-- Create Downloads table
CREATE TABLE downloads (
    download_id VARCHAR(255) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    search_id VARCHAR(255) NOT NULL REFERENCES searches(search_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    ip_address INET NOT NULL,
    databases TEXT[] NOT NULL, -- Array of database_ids that were downloaded from
    download_format download_format_enum NOT NULL,
    num_molecules_downloaded INTEGER NOT NULL,
    download_metadata BOOLEAN DEFAULT false,
    download_properties BOOLEAN DEFAULT false,
    file_size_bytes BIGINT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Create indexes for Downloads
CREATE INDEX idx_downloads_search ON downloads(search_id);
CREATE INDEX idx_downloads_user_created ON downloads(user_id, created_at);
CREATE INDEX idx_downloads_databases ON downloads USING gin(databases); -- GIN index for array searches

-- Create Quotations table
CREATE TABLE quotations (
    quotation_id VARCHAR(255) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    search_id VARCHAR(255) REFERENCES searches(search_id) ON DELETE SET NULL,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    ip_address INET NOT NULL,
    status quotation_status_enum NOT NULL DEFAULT 'clicked_get_quote',
    query_smiles TEXT,
    databases TEXT[] NOT NULL, -- Array of database_ids
    search_method search_method_enum,
    additional_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Create indexes for Quotations
CREATE INDEX idx_quotations_search ON quotations(search_id);
CREATE INDEX idx_quotations_user_created ON quotations(user_id, created_at);
CREATE INDEX idx_quotations_databases ON quotations USING gin(databases); -- GIN index for array searches
CREATE INDEX idx_quotations_status ON quotations(status);

-- Create Requests table (for API logging)
CREATE TABLE requests (
    request_id VARCHAR(255) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    username VARCHAR(255) NOT NULL,
    path VARCHAR(255) NOT NULL,
    ip_address INET NOT NULL,
    status_code VARCHAR(255),
    origin VARCHAR(255),
    response TEXT,
    sent_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Create index for Requests
CREATE INDEX idx_request_id ON requests(request_id);

-- Enable RLS on tables that anonymous users can access
ALTER TABLE searches ENABLE ROW LEVEL SECURITY;
ALTER TABLE downloads ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotations ENABLE ROW LEVEL SECURITY;
ALTER TABLE admet_properties ENABLE ROW LEVEL SECURITY;

-- RLS Policies for searches table
-- All users (including anonymous) can view their own searches by user_id
CREATE POLICY "Users can view own searches" ON searches
    FOR SELECT USING (auth.uid() = user_id);

-- All users (including anonymous) can insert their own searches
CREATE POLICY "Users can insert searches" ON searches
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- RLS Policies for downloads table
-- All users (including anonymous) can view their own downloads by user_id
CREATE POLICY "Users can view own downloads" ON downloads
    FOR SELECT USING (auth.uid() = user_id);

-- All users (including anonymous) can insert their own downloads
CREATE POLICY "Users can insert downloads" ON downloads
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- RLS Policies for quotations table
-- All users (including anonymous) can view their own quotations by user_id
CREATE POLICY "Users can view own quotations" ON quotations
    FOR SELECT USING (auth.uid() = user_id);

-- All users (including anonymous) can insert their own quotations
CREATE POLICY "Users can insert quotations" ON quotations
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- All users (including anonymous) can update their own quotations
CREATE POLICY "Users can update own quotations" ON quotations
    FOR UPDATE USING (auth.uid() = user_id);

-- RLS Policies for admet_properties table
-- All users (including anonymous) can view their own ADMET properties by user_id
CREATE POLICY "Users can view own admet properties" ON admet_properties
    FOR SELECT USING (auth.uid() = user_id);

-- All users (including anonymous) can insert their own ADMET properties
CREATE POLICY "Users can insert admet properties" ON admet_properties
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Create API Keys table (for user API key management)
CREATE TABLE api_keys (
    api_key_id VARCHAR(255) PRIMARY KEY DEFAULT gen_random_uuid()::text,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    api_key_value VARCHAR(128) NOT NULL UNIQUE,
    key_name VARCHAR(255), -- Optional name to help users identify their keys
    key_description TEXT, -- Optional description
    tier account_type_enum NOT NULL, -- API tier based on account type
    expiration_days INTEGER NOT NULL DEFAULT 365, -- Configurable expiration in days
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_used_at TIMESTAMP WITH TIME ZONE,
    usage_count BIGINT DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Create indexes for API Keys
CREATE UNIQUE INDEX idx_api_keys_value ON api_keys(api_key_value);
CREATE INDEX idx_api_keys_user ON api_keys(user_id);
CREATE INDEX idx_api_keys_active ON api_keys(is_active);
CREATE INDEX idx_api_keys_expires ON api_keys(expires_at);
CREATE INDEX idx_api_keys_tier ON api_keys(tier);

-- Create trigger function for updating updated_at columns
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create trigger function for setting API key expiration date
CREATE OR REPLACE FUNCTION set_api_key_expiration()
RETURNS TRIGGER AS $$
BEGIN
    NEW.expires_at = NOW() + INTERVAL '1 day' * NEW.expiration_days;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create trigger function for automatic profile creation
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, created_at, updated_at)
    VALUES (NEW.id, now(), now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create triggers for tables with updated_at columns
CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Create trigger for automatic profile creation when user signs up
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- Create a view that combines auth.users data with profiles data
-- This makes it easy to access email, display_name, and providers alongside profile data
CREATE VIEW public.user_profiles AS
SELECT 
    p.id,
    au.email,
    au.raw_user_meta_data->>'full_name' as display_name,
    au.raw_user_meta_data->>'name' as name,
    au.raw_user_meta_data->>'avatar_url' as avatar_url,
    COALESCE(
        NULLIF(au.raw_app_meta_data->>'providers', '[]'),
        '["email"]'
    )::jsonb as providers,
    au.email_confirmed_at,
    au.created_at as auth_created_at,
    au.last_sign_in_at,
    p.company,
    p.job_title,
    p.ip_address,
    p.country,
    p.newsletter_consent,
    p.contact_consent,
    p.account_type,
    p.linkedin_profile,
    p.completed_registration,
    p.is_active,
    p.created_at,
    p.updated_at
FROM public.profiles p
JOIN auth.users au ON p.id = au.id;

-- Create RLS policy for the view
ALTER VIEW public.user_profiles SET (security_invoker = true);

CREATE TRIGGER update_databases_updated_at
    BEFORE UPDATE ON databases
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_searches_updated_at
    BEFORE UPDATE ON searches
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_downloads_updated_at
    BEFORE UPDATE ON downloads
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_quotations_updated_at
    BEFORE UPDATE ON quotations
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_requests_updated_at
    BEFORE UPDATE ON requests
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_api_keys_updated_at
    BEFORE UPDATE ON api_keys
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_admet_properties_updated_at
    BEFORE UPDATE ON admet_properties
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER set_api_key_expiration_trigger
    BEFORE INSERT OR UPDATE OF expiration_days ON api_keys
    FOR EACH ROW
    EXECUTE FUNCTION set_api_key_expiration();

-- End of initial schema