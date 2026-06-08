-- ═══════════════════════════════════════════════════════════════════════════
-- CYPHER — Complete Supabase SQL Schema
-- Run this entire file in Supabase → SQL Editor
-- Safe to re-run: uses IF NOT EXISTS and CREATE OR REPLACE throughout
-- ═══════════════════════════════════════════════════════════════════════════

-- ── EXTENSIONS ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── 1. USERS ─────────────────────────────────────────────────────────────────
-- Mirrors auth.users. Trigger auto-creates a row on sign-up.
-- Roles: 'owner' (Bam, full access) | 'admin' (executive assistant, restricted)
CREATE TABLE IF NOT EXISTS public.users (
  id           UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email        TEXT,
  display_name TEXT NOT NULL DEFAULT '',
  role         TEXT NOT NULL DEFAULT 'admin' CHECK (role IN ('owner','admin')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Add display_name if upgrading an existing schema (safe no-op if already present)
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS display_name TEXT NOT NULL DEFAULT '';

-- ── Role helper functions — SECURITY DEFINER ─────────────────────────────
-- These bypass RLS on public.users so policies on OTHER tables can safely call
-- them without triggering recursive RLS evaluation or cross-user read errors.

CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'owner')
$$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
$$;

-- Check whether a specific user (by id) has a given role — used in cross-row policies
CREATE OR REPLACE FUNCTION public.user_has_role(_user_id UUID, _role TEXT)
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE id = _user_id AND role = _role)
$$;

-- Trigger: auto-insert into public.users on new auth.users row
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.users (id, email, role)
  VALUES (NEW.id, NEW.email, 'admin')
  ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- RLS
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Each user can always read and update their own row (no recursion possible)
DROP POLICY IF EXISTS "Users can read own row" ON public.users;
CREATE POLICY "Users can read own row"
  ON public.users FOR SELECT
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own row" ON public.users;
CREATE POLICY "Users can update own row"
  ON public.users FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Users can insert their own row (needed when trigger fires before RLS allows it)
DROP POLICY IF EXISTS "Users can insert own row" ON public.users;
CREATE POLICY "Users can insert own row"
  ON public.users FOR INSERT
  WITH CHECK (auth.uid() = id);

-- Owner can see all users — uses is_owner() to avoid recursive subquery
DROP POLICY IF EXISTS "Owners can view all users" ON public.users;
CREATE POLICY "Owners can view all users"
  ON public.users FOR SELECT
  USING (public.is_owner());

-- Admin can read the owner's row (needed to resolve owner user_id for data sync)
DROP POLICY IF EXISTS "Admins can view owner user" ON public.users;
CREATE POLICY "Admins can view owner user"
  ON public.users FOR SELECT
  USING (public.is_admin() AND role = 'owner');

-- Owner can update any user's role — also uses is_owner()
DROP POLICY IF EXISTS "Owners can update roles" ON public.users;
CREATE POLICY "Owners can update roles"
  ON public.users FOR UPDATE
  USING (public.is_owner())
  WITH CHECK (public.is_owner());

-- ── 2. TASKS ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tasks (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  text         TEXT NOT NULL,
  owner        TEXT NOT NULL DEFAULT 'Bam',
  priority     TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('high','medium','low')),
  status       TEXT NOT NULL DEFAULT 'pending',
  due_at       TIMESTAMPTZ,
  initiative   TEXT,
  source       TEXT DEFAULT 'Manual',
  notes        TEXT,
  completed    BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS tasks_user_id_idx       ON public.tasks(user_id);
CREATE INDEX IF NOT EXISTS tasks_completed_idx     ON public.tasks(user_id, completed);
CREATE INDEX IF NOT EXISTS tasks_owner_idx         ON public.tasks(user_id, owner);
CREATE INDEX IF NOT EXISTS tasks_completed_at_idx  ON public.tasks(completed_at) WHERE completed = TRUE;

ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own tasks" ON public.tasks;
CREATE POLICY "Users manage own tasks"
  ON public.tasks FOR ALL
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can view owner tasks" ON public.tasks;
CREATE POLICY "Admins can view owner tasks"
  ON public.tasks FOR SELECT
  USING (public.is_admin() AND public.user_has_role(user_id, 'owner'));

DROP POLICY IF EXISTS "Admins can update owner tasks" ON public.tasks;
CREATE POLICY "Admins can update owner tasks"
  ON public.tasks FOR UPDATE
  USING (public.is_admin() AND public.user_has_role(user_id, 'owner'));

-- ── 3. CONVERSATIONS ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.conversations (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title      TEXT NOT NULL DEFAULT 'New Conversation',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS conversations_user_id_idx ON public.conversations(user_id);
CREATE INDEX IF NOT EXISTS conversations_updated_idx ON public.conversations(user_id, updated_at DESC);

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own conversations" ON public.conversations;
CREATE POLICY "Users manage own conversations"
  ON public.conversations FOR ALL
  USING (auth.uid() = user_id);

-- ── 4. MESSAGES ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.messages (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  role            TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
  content         TEXT NOT NULL,
  model           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS messages_conv_id_idx  ON public.messages(conversation_id);
CREATE INDEX IF NOT EXISTS messages_created_idx  ON public.messages(conversation_id, created_at);

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own messages" ON public.messages;
CREATE POLICY "Users manage own messages"
  ON public.messages FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations
      WHERE id = messages.conversation_id AND user_id = auth.uid()
    )
  );

-- ── 5. CYPHER MEMORY ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cypher_memory (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content    TEXT NOT NULL,
  source     TEXT DEFAULT 'manual',  -- 'manual' | 'auto' | 'corrected'
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS memory_user_id_idx ON public.cypher_memory(user_id);
CREATE INDEX IF NOT EXISTS memory_created_idx ON public.cypher_memory(user_id, created_at DESC);

ALTER TABLE public.cypher_memory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own memory" ON public.cypher_memory;
CREATE POLICY "Users manage own memory"
  ON public.cypher_memory FOR ALL
  USING (auth.uid() = user_id);

-- ── 6. INTEL TRANSCRIPTS ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.intel_transcripts (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label        TEXT NOT NULL,
  word_count   INTEGER DEFAULT 0,
  mode         TEXT DEFAULT 'A',          -- 'A' (Intel) | 'B' (Narrative) | 'suggested'
  display_mode TEXT,                      -- human-readable label shown in card
  raw_content  TEXT,                      -- original pasted/uploaded text
  intel_output TEXT,                      -- CYPHER-generated output
  user_notes   TEXT,                      -- user-added notes per card
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS intel_user_id_idx ON public.intel_transcripts(user_id);
CREATE INDEX IF NOT EXISTS intel_created_idx ON public.intel_transcripts(user_id, created_at DESC);

ALTER TABLE public.intel_transcripts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own intel" ON public.intel_transcripts;
CREATE POLICY "Users manage own intel"
  ON public.intel_transcripts FOR ALL
  USING (auth.uid() = user_id);

-- ── 7. CALENDAR SUGGESTIONS ──────────────────────────────────────────────────
-- Admin proposes calendar changes; owner approves or rejects
CREATE TABLE IF NOT EXISTS public.calendar_suggestions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,  -- Bam's user id
  suggested_by   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,  -- admin's user id
  suggester_name TEXT,
  title          TEXT NOT NULL,
  notes          TEXT,
  proposed_start TIMESTAMPTZ,
  proposed_end   TIMESTAMPTZ,
  status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS cal_sug_owner_idx  ON public.calendar_suggestions(owner_id, status);
CREATE INDEX IF NOT EXISTS cal_sug_admin_idx  ON public.calendar_suggestions(suggested_by);

ALTER TABLE public.calendar_suggestions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owner can manage own suggestions" ON public.calendar_suggestions;
CREATE POLICY "Owner can manage own suggestions"
  ON public.calendar_suggestions FOR ALL
  USING (auth.uid() = owner_id);

DROP POLICY IF EXISTS "Admin can insert and view own suggestions" ON public.calendar_suggestions;
CREATE POLICY "Admin can insert and view own suggestions"
  ON public.calendar_suggestions FOR ALL
  USING (auth.uid() = suggested_by);

-- ── 8. NOTIFICATIONS ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.notifications (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type       TEXT NOT NULL DEFAULT 'info',  -- 'task_update' | 'task_status' | 'cal_response' | 'info'
  title      TEXT NOT NULL,
  body       TEXT,
  task_id    UUID REFERENCES public.tasks(id) ON DELETE SET NULL,
  read       BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS notifs_user_unread_idx ON public.notifications(user_id, read, created_at DESC);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own notifications" ON public.notifications;
CREATE POLICY "Users manage own notifications"
  ON public.notifications FOR ALL
  USING (auth.uid() = user_id);

-- Allow admins to INSERT notifications into the owner's inbox
DROP POLICY IF EXISTS "Admins can notify owner" ON public.notifications;
CREATE POLICY "Admins can notify owner"
  ON public.notifications FOR INSERT
  WITH CHECK (public.is_admin());

-- ── 9. CONNECTORS ────────────────────────────────────────────────────────────
-- Stores per-user connector enabled/config state as JSON blob
CREATE TABLE IF NOT EXISTS public.connectors (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  state      JSONB NOT NULL DEFAULT '{}',  -- {connectorId: {enabled, verified, ...}}
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS connectors_user_id_idx ON public.connectors(user_id);

ALTER TABLE public.connectors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own connectors" ON public.connectors;
CREATE POLICY "Users manage own connectors"
  ON public.connectors FOR ALL
  USING (auth.uid() = user_id);

-- Allow admins to read owner's connectors (so admin can display owner's calendar)
DROP POLICY IF EXISTS "Admins can read owner connectors" ON public.connectors;
CREATE POLICY "Admins can read owner connectors"
  ON public.connectors FOR SELECT
  USING (public.is_admin() AND public.user_has_role(user_id, 'owner'));

-- ── 10. INITIATIVE TAGS ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.initiative_tags (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  emoji      TEXT DEFAULT '🏷️',
  name       TEXT NOT NULL,
  color      TEXT DEFAULT '#9aa3b2',
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS tags_user_id_idx ON public.initiative_tags(user_id, sort_order);

ALTER TABLE public.initiative_tags ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own tags" ON public.initiative_tags;
CREATE POLICY "Users manage own tags"
  ON public.initiative_tags FOR ALL
  USING (auth.uid() = user_id);

-- ── 11. OWNERS (task assignees) ──────────────────────────────────────────────
-- A curated list of people tasks can be assigned to (Bam, Admin, CYPHER, etc.)
CREATE TABLE IF NOT EXISTS public.owners (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  email      TEXT DEFAULT '',
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS owners_user_id_idx ON public.owners(user_id, sort_order);

ALTER TABLE public.owners ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own owners" ON public.owners;
CREATE POLICY "Users manage own owners"
  ON public.owners FOR ALL
  USING (auth.uid() = user_id);

-- ── 12. PUSH SUBSCRIPTIONS ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint   TEXT NOT NULL UNIQUE,
  p256dh     TEXT NOT NULL,
  auth       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS push_user_id_idx ON public.push_subscriptions(user_id);

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users manage own push subscriptions"
  ON public.push_subscriptions FOR ALL
  USING (auth.uid() = user_id);

-- ── REALTIME: enable for all tables ─────────────────────────────────────────
-- Run in Supabase → Database → Replication → enable for each table below,
-- OR run these ALTER TABLE commands:
ALTER TABLE public.tasks              REPLICA IDENTITY FULL;
ALTER TABLE public.conversations      REPLICA IDENTITY FULL;
ALTER TABLE public.messages           REPLICA IDENTITY FULL;
ALTER TABLE public.cypher_memory      REPLICA IDENTITY FULL;
ALTER TABLE public.intel_transcripts  REPLICA IDENTITY FULL;
ALTER TABLE public.calendar_suggestions REPLICA IDENTITY FULL;
ALTER TABLE public.notifications      REPLICA IDENTITY FULL;
ALTER TABLE public.users              REPLICA IDENTITY FULL;

-- ── MANUAL STEP: Set Bam's role to owner ────────────────────────────────────
-- After Bam signs up, run this with his actual user ID:
--
--   UPDATE public.users SET role = 'owner' WHERE email = 'bam@example.com';
--
-- OR find the ID in auth.users and run:
--   UPDATE public.users SET role = 'owner' WHERE id = '<bam-uuid>';

-- ═══════════════════════════════════════════════════════════════════════════
-- EDGE FUNCTION: generate-doc
-- ═══════════════════════════════════════════════════════════════════════════
-- Required Supabase Edge Function secrets (set in Supabase Dashboard →
-- Edge Functions → generate-doc → Secrets):
--
--   ANTHROPIC_API_KEY        = sk-ant-...
--   NYLAS_API_KEY            = nyk_v0_...         (from dashboard.nylas.com)
--   NYLAS_GRANT_ID           = <google-grant-id>  (Gmail/Google Calendar)
--   NYLAS_OUTLOOK_GRANT_ID   = <outlook-grant-id> (Microsoft Calendar/Mail)
--
-- The Edge Function must have JWT verification DISABLED so the browser
-- can call it with the user's access token in Authorization header.
-- Supabase → Edge Functions → generate-doc → Settings → toggle off "Verify JWT"
-- (the function does its own auth check using the token)
