-- SkillLink Emergency Maintenance Mode
-- Run once in Supabase SQL Editor.
ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS maintenance_mode boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS maintenance_message text;

-- CEO-only write access is already enforced by the existing
-- company_settings_ceo_write policy in this project.
-- Non-CEO users keep SELECT access so the frontend can display maintenance mode.

UPDATE public.company_settings
SET maintenance_mode = COALESCE(maintenance_mode, false),
    maintenance_message = COALESCE(
      maintenance_message,
      'SkillLink is temporarily under emergency maintenance. Please try again later.'
    )
WHERE id = 1;
