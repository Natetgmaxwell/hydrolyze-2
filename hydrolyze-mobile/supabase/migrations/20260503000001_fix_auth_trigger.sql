-- Migration: Fix Supabase Auth signup failure
-- The default handle_new_user() trigger expects a public.profiles table
-- Since we use coaches instead, we need to either:
-- 1. Create a profiles table, OR
-- 2. Drop the broken trigger and let coaches be created on first login
-- Date: 2026-05-03

BEGIN;

-- Option 1: Create a minimal profiles table that the trigger expects
-- This table is just a passthrough for auth; coaches table is the real data

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    email TEXT,
    full_name TEXT,
    avatar_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Make sure RLS is enabled on profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Create policy that allows users to read their own profile
CREATE POLICY "Users can view own profile" ON public.profiles
    FOR SELECT USING (auth.uid() = id);

-- Create policy that allows users to update their own profile
CREATE POLICY "Users can update own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- Create policy that allows insert (used by trigger)
CREATE POLICY "Users can insert own profile" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = id);

-- Drop the old trigger if it exists (from Supabase default setup)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- Create a new trigger that inserts into public.profiles
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email)
    VALUES (NEW.id, NEW.email);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

COMMIT;
