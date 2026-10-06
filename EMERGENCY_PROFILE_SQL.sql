-- SkillLink Premium Control Upgrade
-- Run in Supabase SQL Editor before using Emergency Mode and Profile Edit.

ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS emergency_mode boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS emergency_message text;

UPDATE public.company_settings
SET emergency_mode = COALESCE(emergency_mode, false),
    emergency_message = COALESCE(
      emergency_message,
      'SkillLink is temporarily unavailable for maintenance. Please try again shortly.'
    )
WHERE id = 1;

-- Let each signed-in user edit only their own basic profile information.
DROP POLICY IF EXISTS profiles_self_update ON public.profiles;

CREATE POLICY profiles_self_update
ON public.profiles
FOR UPDATE
TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

-- Verify the new control fields.
SELECT id, emergency_mode, emergency_message
FROM public.company_settings
WHERE id = 1;
