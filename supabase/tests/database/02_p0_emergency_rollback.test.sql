-- Scratch-only executable test for the emergency P0 compensation.
-- Expected chain: canonical baseline -> P0 -> emergency rollback.
-- The fixture and all behavior probes are rolled back.

BEGIN;

INSERT INTO auth.users (id) VALUES
  ('41000000-0000-0000-0000-000000000001'),
  ('41000000-0000-0000-0000-000000000002'),
  ('42000000-0000-0000-0000-000000000001'),
  ('43000000-0000-0000-0000-000000000001');

INSERT INTO public.isletmeler (id, isletme_adi) VALUES
  (980001, 'Rollback Tenant One'),
  (980002, 'Rollback Tenant Two');

INSERT INTO public.kullanicilar (id, isletme_id, rol, sifre_degisti_mi) VALUES
  ('41000000-0000-0000-0000-000000000001', 980001, 'admin', true),
  ('41000000-0000-0000-0000-000000000002', 980001, 'kasiyer', true),
  ('42000000-0000-0000-0000-000000000001', 980002, 'admin', true);

SELECT set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
INSERT INTO public.products (
  id, isletme_id, barcode, name, price, stock, created_at, updated_at, deleted_at
) VALUES
  ('c1000000-0000-0000-0000-000000000001', 980001, '980001000001', 'Active', 10, 10, now(), now(), NULL),
  ('c1000000-0000-0000-0000-000000000002', 980001, '980001000002', 'Soft deleted', 12, 10, now(), now(), now());

SELECT set_config('request.jwt.claim.sub', '42000000-0000-0000-0000-000000000001', true);
INSERT INTO public.sales (
  id, total_amount, created_by, isletme_id, idempotency_key
) VALUES (
  'd2000000-0000-0000-0000-000000000001', 12,
  '42000000-0000-0000-0000-000000000001', 980002,
  'rollback-cross-tenant-key'
);

-- Catalog properties must equal the pre-P0 canonical baseline.
DO $test$
DECLARE
  v_secdef boolean;
  v_config text;
  v_source text;
  v_count integer;
BEGIN
  IF NOT has_table_privilege('authenticated','public.sales','INSERT')
     OR NOT has_table_privilege('authenticated','public.sale_items','INSERT')
     OR NOT has_table_privilege('authenticated','public.mutation_idempotency','INSERT')
     OR NOT has_table_privilege('anon','public.mutation_idempotency','SELECT') THEN
    RAISE EXCEPTION 'ASSERT: canonical baseline table grants were not restored';
  END IF;

  SELECT count(*) INTO v_count
    FROM information_schema.table_privileges
   WHERE table_schema='public'
     AND table_name IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')
     AND grantee IN ('anon','authenticated','service_role');
  IF v_count <> 91 THEN
    RAISE EXCEPTION 'ASSERT: expected 91 canonical table grants, got %', v_count;
  END IF;

  IF NOT has_function_privilege('authenticated','public.fn_set_updated_at()','EXECUTE')
     OR NOT has_function_privilege('anon','public.process_product_mutation(uuid,integer,text,uuid,jsonb,timestamp with time zone)','EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT: canonical baseline routine grants were not restored';
  END IF;

  SELECT p.prosecdef, coalesce(array_to_string(p.proconfig, ','), ''), p.prosrc
    INTO v_secdef, v_config, v_source
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='process_product_mutation';
  IF v_secdef OR v_config <> ''
     OR strpos(v_source, 'v_user_role') <> 0
     OR strpos(v_source, 'PRODUCT_MUTATION_FORBIDDEN') <> 0 THEN
    RAISE EXCEPTION 'ASSERT: product mutation must be SECURITY INVOKER with no config';
  END IF;

  SELECT p.prosecdef, coalesce(array_to_string(p.proconfig, ','), ''), p.prosrc
    INTO v_secdef, v_config, v_source
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='complete_sale';
  IF NOT v_secdef OR v_config <> 'search_path=""'
     OR strpos(v_source, 'IF p_idempotency_key IS NOT NULL') = 0
     OR strpos(v_source, 'IF p_idempotency_key IS NOT NULL') > strpos(v_source, 'v_user_id := auth.uid()')
     OR strpos(v_source, 'deleted_at IS NULL') <> 0 THEN
    RAISE EXCEPTION 'ASSERT: complete_sale canonical baseline boundary mismatch';
  END IF;

  SELECT count(*) INTO v_count FROM pg_policies
   WHERE schemaname='public' AND tablename='products'
     AND cmd IN ('INSERT','UPDATE','DELETE')
     AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%get_my_isletme_id%'
     AND (coalesce(qual,'') || coalesce(with_check,'')) NOT LIKE '%get_my_rol%';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'ASSERT: product write policies are not baseline tenant-only';
  END IF;

  SELECT count(*) INTO v_count FROM pg_policies
   WHERE schemaname='public' AND tablename IN ('sales','sale_items')
     AND cmd IN ('INSERT','UPDATE','DELETE')
     AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%get_my_isletme_id%';
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'ASSERT: financial write policies are not baseline tenant-only';
  END IF;

  SELECT count(*) INTO v_count
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public'
     AND c.relname IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')
     AND c.relrowsecurity;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'ASSERT: six RLS-enabled tables expected, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM pg_publication_tables
   WHERE pubname='supabase_realtime' AND schemaname='public'
     AND tablename IN ('products','sales');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'ASSERT: realtime membership changed';
  END IF;
END
$test$;

-- Cashier product, financial, and idempotency writes are deliberately reopened.
SELECT set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;

INSERT INTO public.products (id, name, price, stock, barcode, isletme_id)
VALUES ('c1000000-0000-0000-0000-000000000010', 'Cashier direct', 3, 2, '980001000010', 980002);

SELECT public.process_product_mutation(
  '44000000-0000-0000-0000-000000000001', 980001, 'CREATE',
  'c1000000-0000-0000-0000-000000000011',
  '{"name":"Cashier RPC","price":4,"stock":2,"barcode":"980001000011"}'::jsonb,
  NULL
);

INSERT INTO public.sales (id, total_amount, created_by, isletme_id)
VALUES (
  'd1000000-0000-0000-0000-000000000001', 3,
  '41000000-0000-0000-0000-000000000002', 980001
);
UPDATE public.sales SET total_amount=4
 WHERE id='d1000000-0000-0000-0000-000000000001';

INSERT INTO public.sale_items (
  id, sale_id, product_id, quantity, unit_price, isletme_id
) VALUES (
  'e1000000-0000-0000-0000-000000000001',
  'd1000000-0000-0000-0000-000000000001',
  'c1000000-0000-0000-0000-000000000010', 1, 3, 980002
);

INSERT INTO public.mutation_idempotency (idempotency_key, isletme_id)
VALUES ('44000000-0000-0000-0000-000000000002', 980001);

-- Baseline complete_sale still works and still accepts soft-deleted products.
SELECT public.complete_sale(
  '[{"product_id":"c1000000-0000-0000-0000-000000000002","quantity":1}]'::jsonb,
  'rollback-soft-deleted-key'
);

DO $test$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.products
     WHERE id='c1000000-0000-0000-0000-000000000010' AND isletme_id=980001
  ) THEN
    RAISE EXCEPTION 'ASSERT: cashier direct product write baseline behavior missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.products
     WHERE id='c1000000-0000-0000-0000-000000000011' AND isletme_id=980001
  ) THEN
    RAISE EXCEPTION 'ASSERT: cashier product RPC baseline behavior missing';
  END IF;
  IF (SELECT stock FROM public.products WHERE id='c1000000-0000-0000-0000-000000000002') <> 9 THEN
    RAISE EXCEPTION 'ASSERT: baseline soft-deleted sale behavior was not restored';
  END IF;
END
$test$;

-- Baseline idempotency-before-auth ordering leaks an existing result to a
-- profile-less authenticated identity. This assertion documents the risk.
SELECT set_config('request.jwt.claim.sub', '43000000-0000-0000-0000-000000000001', true);
SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result jsonb;
BEGIN
  v_result := public.complete_sale('[]'::jsonb, 'rollback-cross-tenant-key');
  IF coalesce((v_result->>'idempotent')::boolean, false) IS NOT TRUE
     OR (v_result->>'isletme_id')::integer <> 980002 THEN
    RAISE EXCEPTION 'ASSERT: canonical idempotency-before-auth behavior mismatch';
  END IF;
END
$test$;
RESET ROLE;

ROLLBACK;

SELECT 'P0_EMERGENCY_ROLLBACK_TEST_PASS' AS result;
