-- Scratch-only executable authorization test suite.
-- The entire fixture is rolled back. Run only after the canonical baseline and
-- 20260821100000_p0_authorization_hardening.sql are applied.

BEGIN;

-- Stable fixture identities.
INSERT INTO auth.users (id) VALUES
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002'),
  ('20000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000001');

INSERT INTO public.isletmeler (id, isletme_adi) VALUES
  (990001, 'P0 Test Tenant One'),
  (990002, 'P0 Test Tenant Two');

INSERT INTO public.kullanicilar (id, isletme_id, rol, sifre_degisti_mi) VALUES
  ('10000000-0000-0000-0000-000000000001', 990001, 'admin', true),
  ('10000000-0000-0000-0000-000000000002', 990001, 'kasiyer', true),
  ('20000000-0000-0000-0000-000000000001', 990002, 'admin', true);

SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
INSERT INTO public.products (
  id, isletme_id, barcode, name, price, stock, created_at, updated_at, deleted_at
) VALUES
  ('a0000000-0000-0000-0000-000000000001', 990001, '990001000001', 'Tenant One Active', 25.00, 10, now(), now(), NULL),
  ('a0000000-0000-0000-0000-000000000002', 990001, '990001000002', 'Tenant One Deleted', 30.00, 10, now(), now(), now());

SELECT set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000001', true);
INSERT INTO public.products (
  id, isletme_id, barcode, name, price, stock, created_at, updated_at, deleted_at
) VALUES
  ('b0000000-0000-0000-0000-000000000001', 990002, '990002000001', 'Tenant Two Active', 40.00, 10, now(), now(), NULL);

-- Seed a tenant-two idempotency record through the same tenant trigger context.
INSERT INTO public.sales (total_amount, created_by, isletme_id, idempotency_key)
VALUES (40.00, '20000000-0000-0000-0000-000000000001', 990002, 'p0-cross-tenant-key');
SELECT set_config('request.jwt.claim.sub', '', true);

-- ---------------------------------------------------------------------------
-- Catalog assertions.
-- ---------------------------------------------------------------------------

DO $test$
DECLARE
  v_count integer;
  v_source text;
  v_secdef boolean;
  v_config text;
BEGIN
  IF has_table_privilege('authenticated', 'public.sales', 'INSERT')
     OR has_table_privilege('authenticated', 'public.sales', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.sales', 'DELETE')
     OR has_table_privilege('authenticated', 'public.sales', 'TRUNCATE')
     OR has_table_privilege('authenticated', 'public.sale_items', 'INSERT')
     OR has_table_privilege('authenticated', 'public.sale_items', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.sale_items', 'DELETE')
     OR has_table_privilege('authenticated', 'public.sale_items', 'TRUNCATE') THEN
    RAISE EXCEPTION 'ASSERT: authenticated financial write privilege remains';
  END IF;

  IF NOT has_table_privilege('authenticated', 'public.sales', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.sale_items', 'SELECT') THEN
    RAISE EXCEPTION 'ASSERT: authenticated financial SELECT privilege was broken';
  END IF;

  IF has_table_privilege('authenticated', 'public.products', 'TRUNCATE')
     OR NOT has_table_privilege('authenticated', 'public.products', 'INSERT')
     OR NOT has_table_privilege('authenticated', 'public.products', 'UPDATE')
     OR NOT has_table_privilege('authenticated', 'public.products', 'DELETE')
     OR NOT has_table_privilege('authenticated', 'public.products', 'SELECT') THEN
    RAISE EXCEPTION 'ASSERT: product ACL is not the intended admin-via-RLS shape';
  END IF;

  IF has_table_privilege('authenticated', 'public.mutation_idempotency', 'SELECT')
     OR has_table_privilege('authenticated', 'public.mutation_idempotency', 'INSERT')
     OR has_table_privilege('anon', 'public.mutation_idempotency', 'SELECT')
     OR has_table_privilege('anon', 'public.mutation_idempotency', 'INSERT') THEN
    RAISE EXCEPTION 'ASSERT: idempotency table is still client-accessible';
  END IF;

  IF has_function_privilege('anon', 'public.complete_sale(jsonb,text)', 'EXECUTE')
     OR has_function_privilege('public', 'public.complete_sale(jsonb,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.complete_sale(jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT: complete_sale EXECUTE ACL mismatch';
  END IF;

  IF has_function_privilege('anon', 'public.process_product_mutation(uuid,integer,text,uuid,jsonb,timestamp with time zone)', 'EXECUTE')
     OR has_function_privilege('public', 'public.process_product_mutation(uuid,integer,text,uuid,jsonb,timestamp with time zone)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.process_product_mutation(uuid,integer,text,uuid,jsonb,timestamp with time zone)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT: process_product_mutation EXECUTE ACL mismatch';
  END IF;

  IF has_function_privilege('anon', 'public.fn_set_updated_at()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_set_updated_at()', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.fn_set_updated_at()', 'EXECUTE')
     OR has_function_privilege('public', 'public.fn_set_updated_at()', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT: trigger-only function remains client-executable';
  END IF;

  SELECT p.prosecdef, coalesce(array_to_string(p.proconfig, ','), ''), p.prosrc
    INTO v_secdef, v_config, v_source
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'complete_sale';

  IF NOT v_secdef OR v_config <> 'search_path=""' THEN
    RAISE EXCEPTION 'ASSERT: complete_sale SECURITY DEFINER/search_path mismatch';
  END IF;
  IF strpos(v_source, 'v_user_id := auth.uid()') = 0
     OR strpos(v_source, 'IF p_idempotency_key IS NOT NULL') = 0
     OR strpos(v_source, 'v_user_id := auth.uid()') > strpos(v_source, 'IF p_idempotency_key IS NOT NULL')
     OR strpos(v_source, 's.isletme_id = v_isletme_id') = 0
     OR strpos(v_source, 'deleted_at IS NULL') = 0 THEN
    RAISE EXCEPTION 'ASSERT: complete_sale authorization/order/deleted filter mismatch';
  END IF;

  SELECT p.prosecdef, coalesce(array_to_string(p.proconfig, ','), ''), p.prosrc
    INTO v_secdef, v_config, v_source
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'process_product_mutation';

  IF NOT v_secdef OR v_config <> 'search_path=""'
     OR strpos(v_source, $$v_user_role IS DISTINCT FROM 'admin'$$) = 0
     OR strpos(v_source, 'v_user_id := auth.uid()') > strpos(v_source, 'INSERT INTO public.mutation_idempotency') THEN
    RAISE EXCEPTION 'ASSERT: process_product_mutation authorization boundary mismatch';
  END IF;

  SELECT count(*) INTO v_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')
     AND c.relrowsecurity;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'ASSERT: expected six RLS-enabled application tables, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count
    FROM pg_publication_tables
   WHERE pubname = 'supabase_realtime'
     AND schemaname = 'public'
     AND tablename IN ('products', 'sales');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'ASSERT: Realtime publication membership changed';
  END IF;
END;
$test$;

-- ---------------------------------------------------------------------------
-- Anonymous RPC execution is denied.
-- ---------------------------------------------------------------------------

SET LOCAL ROLE anon;
DO $test$
DECLARE v_denied boolean := false;
BEGIN
  BEGIN
    PERFORM public.complete_sale('[]'::jsonb, 'p0-anon-key');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: anon complete_sale executed'; END IF;

  v_denied := false;
  BEGIN
    PERFORM public.process_product_mutation(
      '90000000-0000-0000-0000-000000000001', 990001, 'DELETE',
      'a0000000-0000-0000-0000-000000000001', NULL, now()
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: anon product RPC executed'; END IF;
END;
$test$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Cashier: tenant reads and sales RPC work; product/financial writes do not.
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;

DO $test$
DECLARE
  v_count integer;
  v_denied boolean := false;
  v_rows integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.products
   WHERE id = 'b0000000-0000-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'ASSERT: cashier read another tenant product'; END IF;

  BEGIN
    INSERT INTO public.products (id, name, price, stock, barcode, isletme_id)
    VALUES ('a0000000-0000-0000-0000-000000000010', 'Cashier Insert', 1, 1, '990001000010', 990001);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: cashier inserted product'; END IF;

  UPDATE public.products SET price = 999
   WHERE id = 'a0000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'ASSERT: cashier updated product'; END IF;

  DELETE FROM public.products
   WHERE id = 'a0000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'ASSERT: cashier deleted product'; END IF;

  v_denied := false;
  BEGIN
    PERFORM public.process_product_mutation(
      '90000000-0000-0000-0000-000000000002', 990001, 'UPDATE',
      'a0000000-0000-0000-0000-000000000001',
      '{"price": 999}'::jsonb,
      '2000-01-01T00:00:00Z'::timestamptz
    );
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'PRODUCT_MUTATION_FORBIDDEN' THEN v_denied := true; ELSE RAISE; END IF;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: cashier product RPC succeeded'; END IF;

  v_denied := false;
  BEGIN
    UPDATE public.kullanicilar SET rol = 'admin'
     WHERE id = '10000000-0000-0000-0000-000000000002';
  EXCEPTION WHEN raise_exception THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: cashier changed own role'; END IF;
END;
$test$;

SELECT public.complete_sale(
  '[{"product_id":"a0000000-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
  'p0-own-sale-key'
);

-- Same-tenant replay must remain idempotent and must not reduce stock twice.
SELECT public.complete_sale(
  '[{"product_id":"a0000000-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
  'p0-own-sale-key'
);

DO $test$
DECLARE
  v_denied boolean := false;
  v_stock integer;
BEGIN
  SELECT stock INTO v_stock FROM public.products
   WHERE id = 'a0000000-0000-0000-0000-000000000001';
  IF v_stock <> 8 THEN RAISE EXCEPTION 'ASSERT: idempotent sale stock expected 8, got %', v_stock; END IF;

  -- Old ordering returned tenant-two sale data. Hardened ordering reaches
  -- same-tenant lookup, finds nothing, then rejects the empty basket.
  BEGIN
    PERFORM public.complete_sale('[]'::jsonb, 'p0-cross-tenant-key');
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE '%SATIS_HATA:SEPET_BOS%' THEN v_denied := true; ELSE RAISE; END IF;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: cross-tenant idempotency result leaked'; END IF;

  v_denied := false;
  BEGIN
    PERFORM public.complete_sale(
      '[{"product_id":"a0000000-0000-0000-0000-000000000002","quantity":1}]'::jsonb,
      'p0-deleted-product-key'
    );
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE '%SATIS_HATA:GECERSIZ_URUN%' THEN v_denied := true; ELSE RAISE; END IF;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: soft-deleted product was sold'; END IF;

  v_denied := false;
  BEGIN
    INSERT INTO public.sales (total_amount, created_by, isletme_id)
    VALUES (1, '10000000-0000-0000-0000-000000000002', 990001);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: cashier directly inserted sale'; END IF;

  v_denied := false;
  BEGIN
    UPDATE public.sales SET total_amount = 1 WHERE idempotency_key = 'p0-own-sale-key';
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: cashier directly updated sale'; END IF;
END;
$test$;

RESET ROLE;

-- Cashier denial must occur before idempotency persistence.
DO $test$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.mutation_idempotency
     WHERE idempotency_key = '90000000-0000-0000-0000-000000000002'
  ) THEN
    RAISE EXCEPTION 'ASSERT: denied cashier RPC consumed idempotency key';
  END IF;
END;
$test$;

-- ---------------------------------------------------------------------------
-- Profile-less authenticated user cannot probe an existing idempotency key.
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', true);
SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_denied boolean := false;
BEGIN
  BEGIN
    PERFORM public.complete_sale('[]'::jsonb, 'p0-cross-tenant-key');
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE '%SATIS_HATA:ISLETME_BULUNAMADI%' THEN v_denied := true; ELSE RAISE; END IF;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'ASSERT: profile-less idempotency probe was not denied first'; END IF;
END;
$test$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Admin: existing direct product INSERT and offline mutation RPC still work.
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
SET LOCAL ROLE authenticated;

INSERT INTO public.products (id, name, price, stock, barcode, isletme_id)
VALUES ('a0000000-0000-0000-0000-000000000020', 'Admin Direct Insert', 5, 2, '990001000020', 990002);

SELECT public.process_product_mutation(
  '90000000-0000-0000-0000-000000000003',
  990001,
  'CREATE',
  'a0000000-0000-0000-0000-000000000021',
  '{"name":"Admin RPC Insert","price":6,"stock":3,"barcode":"990001000021"}'::jsonb,
  NULL
);

RESET ROLE;

DO $test$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.products
     WHERE id = 'a0000000-0000-0000-0000-000000000020'
       AND isletme_id = 990001
  ) THEN
    RAISE EXCEPTION 'ASSERT: admin direct insert failed or tenant trigger did not override input';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
     WHERE id = 'a0000000-0000-0000-0000-000000000021'
       AND isletme_id = 990001
  ) THEN
    RAISE EXCEPTION 'ASSERT: admin process_product_mutation CREATE failed';
  END IF;
END;
$test$;

ROLLBACK;

SELECT 'P0_AUTHORIZATION_TEST_PASS' AS result;
