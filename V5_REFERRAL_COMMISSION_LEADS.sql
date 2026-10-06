-- SkillLink V5: referral, commission and partner lead controls
-- Additive migration. Does not delete existing business data.

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS referred_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS referral_code text,
  ADD COLUMN IF NOT EXISTS referral_type text NOT NULL DEFAULT 'registration',
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS referrals_referred_user_idx ON public.referrals(referred_user_id);
CREATE INDEX IF NOT EXISTS referrals_referrer_status_idx ON public.referrals(referrer_id,status);
CREATE INDEX IF NOT EXISTS leads_assigned_status_idx ON public.leads(assigned_to,status);

CREATE TABLE IF NOT EXISTS public.partner_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name text NOT NULL,
  phone text,
  email text NOT NULL,
  invite_code text NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(6),'hex'),
  status text NOT NULL DEFAULT 'pending',
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  used_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.masterclass_referral_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  referred_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(partner_id,referred_user_id)
);

CREATE INDEX IF NOT EXISTS masterclass_referral_partner_idx
ON public.masterclass_referral_events(partner_id,created_at);

-- Referral registration: the referral code is resolved server-side.
CREATE OR REPLACE FUNCTION public.skilllink_record_referral_signup(
  p_referral_code text,
  p_referred_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer uuid;
BEGIN
  IF p_referred_user_id IS NULL OR NULLIF(trim(p_referral_code),'') IS NULL THEN
    RETURN false;
  END IF;

  SELECT id INTO v_referrer
  FROM public.profiles
  WHERE upper(trim(referral_code)) = upper(trim(p_referral_code))
    AND role = 'partner'
    AND COALESCE(active,true) = true
  LIMIT 1;

  IF v_referrer IS NULL OR v_referrer = p_referred_user_id THEN
    RETURN false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.referrals
    WHERE referrer_id = v_referrer
      AND referred_user_id = p_referred_user_id
  ) THEN
    INSERT INTO public.referrals(referrer_id,referred_user_id,referral_code,referral_type,status,created_at)
    VALUES(v_referrer,p_referred_user_id,upper(trim(p_referral_code)),'registration','registered',now());
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_record_referral_signup(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_record_referral_signup(text,uuid) TO authenticated;

-- Partner lead pull: one unassigned lead per call, partner-only.
CREATE OR REPLACE FUNCTION public.skilllink_pull_lead(p_partner_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_lead uuid;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR auth.uid() <> p_partner_id OR v_role <> 'partner' THEN
    RAISE EXCEPTION 'Only the signed-in Partner can pull leads';
  END IF;

  SELECT id INTO v_lead
  FROM public.leads
  WHERE assigned_to IS NULL
    AND COALESCE(status,'new') IN ('new','open','available')
  ORDER BY created_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF v_lead IS NULL THEN
    RAISE EXCEPTION 'No lead is currently available';
  END IF;

  UPDATE public.leads
  SET assigned_to = p_partner_id,
      status = 'assigned',
      updated_by = p_partner_id,
      updated_at = now()
  WHERE id = v_lead;

  RETURN v_lead;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_pull_lead(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_pull_lead(uuid) TO authenticated;

-- Partner lead status/follow-up update.
CREATE OR REPLACE FUNCTION public.skilllink_update_lead(
  p_lead_id uuid,
  p_status text,
  p_notes text,
  p_partner_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_partner_id THEN
    RAISE EXCEPTION 'Unauthorized lead update';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'partner' AND COALESCE(active,true) = true
  ) THEN
    RAISE EXCEPTION 'Only active Partners can update pulled leads';
  END IF;

  UPDATE public.leads
  SET status = trim(p_status),
      notes = trim(COALESCE(p_notes,'')),
      updated_by = auth.uid(),
      updated_at = now()
  WHERE id = p_lead_id
    AND assigned_to = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Lead not found in your My Leads';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_update_lead(uuid,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_update_lead(uuid,text,text,uuid) TO authenticated;

-- CEO/Admin commission entry. Every entry becomes available balance immediately.
CREATE OR REPLACE FUNCTION public.skilllink_add_commission(
  p_partner_id uuid,
  p_amount numeric,
  p_commission_type text,
  p_description text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role text;
  v_id uuid;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('ceo','admin') THEN
    RAISE EXCEPTION 'Only CEO or Admin can add commission';
  END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Commission amount must be greater than zero'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=p_partner_id AND role='partner' AND COALESCE(active,true)=true) THEN
    RAISE EXCEPTION 'Partner not found or inactive';
  END IF;

  INSERT INTO public.earnings_ledger(partner_id,project_id,description,gross_amount,company_share,partner_share,status,created_at)
  VALUES(p_partner_id,NULL,trim(p_description),p_amount,0,p_amount,'available',now())
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_add_commission(uuid,numeric,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_add_commission(uuid,numeric,text,text) TO authenticated;

-- CEO/Admin creates a secure partner invitation record. Auth credentials are never stored here.
CREATE OR REPLACE FUNCTION public.skilllink_create_partner_invite(
  p_full_name text,
  p_phone text,
  p_email text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_code text;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id=auth.uid();
  IF v_role <> 'ceo' THEN RAISE EXCEPTION 'Only CEO can create Partner invites'; END IF;
  IF NULLIF(trim(p_full_name),'') IS NULL OR NULLIF(trim(p_email),'') IS NULL THEN RAISE EXCEPTION 'Name and email are required'; END IF;
  INSERT INTO public.partner_invites(full_name,phone,email,created_by)
  VALUES(trim(p_full_name),NULLIF(trim(p_phone),''),lower(trim(p_email)),auth.uid())
  RETURNING invite_code INTO v_code;
  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_create_partner_invite(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_create_partner_invite(text,text,text) TO authenticated;

-- Record a verified masterclass referral. No per-masterclass commission.
-- Every 10 unique verified people earns one ₹300 bonus.
CREATE OR REPLACE FUNCTION public.skilllink_record_masterclass_referral(
  p_partner_id uuid,
  p_referred_user_id uuid
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_count integer;
  v_bonus_count integer;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id=auth.uid();
  IF v_role NOT IN ('ceo','admin') THEN RAISE EXCEPTION 'Only CEO or Admin can verify masterclass referrals'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=p_partner_id AND role='partner') THEN RAISE EXCEPTION 'Partner not found'; END IF;

  INSERT INTO public.masterclass_referral_events(partner_id,referred_user_id)
  VALUES(p_partner_id,p_referred_user_id)
  ON CONFLICT (partner_id,referred_user_id) DO NOTHING;

  SELECT count(*) INTO v_count FROM public.masterclass_referral_events WHERE partner_id=p_partner_id;
  v_bonus_count := floor(v_count/10.0);

  IF v_bonus_count > (
    SELECT count(*) FROM public.earnings_ledger
    WHERE partner_id=p_partner_id AND description LIKE 'Masterclass 10-Person Bonus%'
  ) THEN
    INSERT INTO public.earnings_ledger(partner_id,project_id,description,gross_amount,company_share,partner_share,status,created_at)
    VALUES(p_partner_id,NULL,'Masterclass 10-Person Bonus #'||v_bonus_count,300,0,300,'available',now());
    RETURN 300;
  END IF;
  RETURN 0;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_record_masterclass_referral(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_record_masterclass_referral(uuid,uuid) TO authenticated;

-- Package sale commission helper. Call this only after payment is verified by CEO/Admin.
CREATE OR REPLACE FUNCTION public.skilllink_record_package_sale(
  p_partner_id uuid,
  p_customer_id uuid,
  p_package_id uuid
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_commission numeric;
  v_name text;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id=auth.uid();
  IF v_role NOT IN ('ceo','admin') THEN RAISE EXCEPTION 'Only CEO or Admin can verify package sales'; END IF;
  SELECT name,partner_commission INTO v_name,v_commission FROM public.packages WHERE id=p_package_id AND active=true;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Package not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=p_partner_id AND role='partner') THEN RAISE EXCEPTION 'Partner not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.referrals WHERE referrer_id=p_partner_id AND referred_user_id=p_customer_id) THEN
    RAISE EXCEPTION 'This customer is not linked to this Partner referral';
  END IF;

  INSERT INTO public.earnings_ledger(partner_id,project_id,description,gross_amount,company_share,partner_share,status,created_at)
  VALUES(p_partner_id,NULL,'Package Sale Commission — '||v_name,v_commission,0,v_commission,'available',now());
  RETURN v_commission;
END;
$$;

REVOKE ALL ON FUNCTION public.skilllink_record_package_sale(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.skilllink_record_package_sale(uuid,uuid,uuid) TO authenticated;
