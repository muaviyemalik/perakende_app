-- Scratch-only test. The entire fixture is rolled back. Run after
-- 20261123120000_password_flag_guard_and_sequence_grants.sql is applied.

BEGIN;

INSERT INTO auth.users (id, encrypted_password) VALUES
  ('40000000-0000-0000-0000-000000000001', 'hash-temp-1'),
  ('40000000-0000-0000-0000-000000000002', 'hash-temp-2');

INSERT INTO public.isletmeler (id, isletme_adi) VALUES
  (990401, 'Password Flag Test Tenant');

INSERT INTO public.kullanicilar (id, isletme_id, rol, sifre_degisti_mi) VALUES
  ('40000000-0000-0000-0000-000000000001', 990401, 'kasiyer', false),
  ('40000000-0000-0000-0000-000000000002', 990401, 'kasiyer', false);

-- Sequence grants.
DO $test$
BEGIN
  IF has_sequence_privilege('authenticated', 'public.isletmeler_id_seq', 'UPDATE')
     OR has_sequence_privilege('authenticated', 'public.isletmeler_id_seq', 'USAGE')
     OR has_sequence_privilege('anon', 'public.isletmeler_id_seq', 'UPDATE')
     OR has_sequence_privilege('anon', 'public.isletmeler_id_seq', 'USAGE') THEN
    RAISE EXCEPTION 'ASSERT: client roles still have sequence privileges';
  END IF;
END
$test$;

-- Snapshot captured on insert.
DO $test$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM private.pending_password_change
     WHERE user_id = '40000000-0000-0000-0000-000000000001'
       AND password_hash_snapshot = 'hash-temp-1'
  ) THEN
    RAISE EXCEPTION 'ASSERT: password snapshot not captured on insert';
  END IF;
END
$test$;

-- User 1: flag without changing password -> rejected.
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000001', true);
DO $test$
BEGIN
  BEGIN
    UPDATE public.kullanicilar SET sifre_degisti_mi = true
     WHERE id = '40000000-0000-0000-0000-000000000001';
    RAISE EXCEPTION 'ASSERT: flag set without password change';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'SIFRE_HATA:SIFRE_DEGISMEDI%' THEN
      RAISE;
    END IF;
  END;
END
$test$;

-- User 2: change password, then flag -> allowed, snapshot removed.
UPDATE auth.users SET encrypted_password = 'hash-new-2'
 WHERE id = '40000000-0000-0000-0000-000000000002';
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000002', true);
UPDATE public.kullanicilar SET sifre_degisti_mi = true
 WHERE id = '40000000-0000-0000-0000-000000000002';
SELECT set_config('request.jwt.claim.sub', '', true);

DO $test$
BEGIN
  IF NOT (SELECT sifre_degisti_mi FROM public.kullanicilar
           WHERE id = '40000000-0000-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'ASSERT: flag not set after real password change';
  END IF;
  IF EXISTS (SELECT 1 FROM private.pending_password_change
              WHERE user_id = '40000000-0000-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'ASSERT: snapshot not removed after flag set';
  END IF;
END
$test$;

-- Admin/service context (no auth.uid) can still reset or set the flag.
UPDATE public.kullanicilar SET sifre_degisti_mi = true
 WHERE id = '40000000-0000-0000-0000-000000000001';

ROLLBACK;
