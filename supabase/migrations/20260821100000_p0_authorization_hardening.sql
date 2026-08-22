-- Forward-only P0 authorization hardening.
-- Preconditions: 20260821090000_canonical_live_baseline.sql represents the
-- current production schema. Do not run the canonical baseline on production.

-- ---------------------------------------------------------------------------
-- 1. Least-privilege table grants for client roles.
-- ---------------------------------------------------------------------------

-- Business metadata: authenticated users keep SELECT/UPDATE/DELETE because
-- existing admin-only RLS policies authorize those operations.
REVOKE INSERT, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.isletmeler
  FROM PUBLIC, anon, authenticated;

-- Users keep SELECT and UPDATE for their own profile/password-state flow.
REVOKE INSERT, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.kullanicilar
  FROM PUBLIC, anon, authenticated;

-- Products keep SELECT/INSERT/UPDATE/DELETE; write authorization is enforced
-- by the admin-only RLS policies below. TRUNCATE bypasses RLS and must be gone.
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.products
  FROM PUBLIC, anon, authenticated;

-- Financial rows are immutable to all client sessions. complete_sale remains
-- the sole authenticated write path through its SECURITY DEFINER boundary.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.sales, public.sale_items
  FROM PUBLIC, anon, authenticated;

-- Idempotency rows are an internal implementation detail of the hardened RPC.
REVOKE ALL PRIVILEGES
  ON TABLE public.mutation_idempotency
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. RLS: admin-only product mutations; direct financial/idempotency writes
--    remain denied even if a future grant accidentally broadens table ACLs.
-- ---------------------------------------------------------------------------

ALTER POLICY products_insert_own_business
  ON public.products
  TO authenticated
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
    AND (SELECT private.get_my_rol()) = 'admin'::text
  );

ALTER POLICY products_update_own_business
  ON public.products
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
    AND (SELECT private.get_my_rol()) = 'admin'::text
  )
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
    AND (SELECT private.get_my_rol()) = 'admin'::text
  );

ALTER POLICY products_delete_own_business
  ON public.products
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
    AND (SELECT private.get_my_rol()) = 'admin'::text
  );

ALTER POLICY sales_insert_own_business
  ON public.sales
  TO authenticated
  WITH CHECK (false);

ALTER POLICY sales_update_own_business
  ON public.sales
  TO authenticated
  USING (false)
  WITH CHECK (false);

ALTER POLICY sales_delete_own_business
  ON public.sales
  TO authenticated
  USING (false);

ALTER POLICY sale_items_insert_own_business
  ON public.sale_items
  TO authenticated
  WITH CHECK (false);

ALTER POLICY sale_items_update_own_business
  ON public.sale_items
  TO authenticated
  USING (false)
  WITH CHECK (false);

ALTER POLICY sale_items_delete_own_business
  ON public.sale_items
  TO authenticated
  USING (false);

ALTER POLICY "Allow authenticated to insert idempotency"
  ON public.mutation_idempotency
  TO authenticated
  WITH CHECK (false);

ALTER POLICY "Allow authenticated to select idempotency"
  ON public.mutation_idempotency
  TO authenticated
  USING (false);

-- ---------------------------------------------------------------------------
-- 3. complete_sale: authenticate and resolve tenant before idempotency lookup;
--    never sell soft-deleted products. Existing signature/result contract is
--    preserved for both admin and cashier application flows.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.complete_sale(
  p_items jsonb,
  p_idempotency_key text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id         uuid;
  v_isletme_id      integer;
  v_item            jsonb;
  v_product_id      uuid;
  v_quantity        integer;
  v_locked_count    integer;
  v_item_count      integer;
  v_product_rec     record;
  v_total_amount    numeric(12, 2) := 0;
  v_sale_id         uuid;
  v_existing_sale   record;
BEGIN
  -- Authorization must precede every data-dependent response.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'SATIS_HATA:KIMLIK_DOGRULANAMADI'
      USING DETAIL = 'auth.uid() NULL dondu -- oturum gecersiz';
  END IF;

  SELECT k.isletme_id
    INTO v_isletme_id
    FROM public.kullanicilar k
   WHERE k.id = v_user_id;

  IF v_isletme_id IS NULL THEN
    RAISE EXCEPTION 'SATIS_HATA:ISLETME_BULUNAMADI'
      USING DETAIL = 'Kullanici gecerli bir isletmeye bagli degil';
  END IF;

  -- Idempotency is tenant-scoped after authentication and tenant resolution.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT s.id, s.total_amount, s.isletme_id
      INTO v_existing_sale
      FROM public.sales s
     WHERE s.idempotency_key = p_idempotency_key
       AND s.isletme_id = v_isletme_id;

    IF v_existing_sale.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'sale_id',      v_existing_sale.id,
        'total_amount', v_existing_sale.total_amount,
        'isletme_id',   v_existing_sale.isletme_id,
        'idempotent',   true
      );
    END IF;
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'SATIS_HATA:SEPET_BOS'
      USING DETAIL = 'Sepet bos -- en az 1 urun gereklidir';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'product_id') IS NULL THEN
      RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_URUN_ID'
        USING DETAIL = 'product_id eksik: ' || v_item::text;
    END IF;

    BEGIN
      v_product_id := (v_item->>'product_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_UUID_FORMAT'
        USING DETAIL = 'Gecersiz product_id formati: ' || (v_item->>'product_id');
    END;

    IF (v_item->>'quantity') IS NULL THEN
      RAISE EXCEPTION 'SATIS_HATA:QUANTITY_EKSIK'
        USING DETAIL = 'quantity eksik: ' || v_item::text;
    END IF;

    v_quantity := (v_item->>'quantity')::integer;
    IF v_quantity <= 0 THEN
      RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_MIKTAR'
        USING DETAIL = 'quantity 0 veya negatif olamaz -- product_id='
          || (v_item->>'product_id') || ', quantity=' || v_quantity;
    END IF;
  END LOOP;

  IF (
    SELECT count(DISTINCT elem->>'product_id')
      FROM jsonb_array_elements(p_items) AS elem
  ) <> v_item_count THEN
    RAISE EXCEPTION 'SATIS_HATA:TEKRAR_URUN_ID'
      USING DETAIL = 'Ayni product_id birden fazla kez gonderildi -- sepette tekrar eden urunleri birlestirin';
  END IF;

  PERFORM p.id
    FROM public.products p
   WHERE p.id IN (
           SELECT (elem->>'product_id')::uuid
             FROM jsonb_array_elements(p_items) AS elem
         )
     AND p.isletme_id = v_isletme_id
     AND p.deleted_at IS NULL
   ORDER BY p.id
   FOR UPDATE;

  SELECT count(*)
    INTO v_locked_count
    FROM public.products p
   WHERE p.id IN (
           SELECT (elem->>'product_id')::uuid
             FROM jsonb_array_elements(p_items) AS elem
         )
     AND p.isletme_id = v_isletme_id
     AND p.deleted_at IS NULL;

  IF v_locked_count <> v_item_count THEN
    RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_URUN'
      USING DETAIL = 'Bazi urunler bu isletmeye ait degil, silinmis veya mevcut degil -- '
        || 'beklenen=' || v_item_count || ', bulunan=' || v_locked_count
        || ', isletme_id=' || v_isletme_id;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;

    SELECT p.id, p.name, p.price, p.stock
      INTO v_product_rec
      FROM public.products p
     WHERE p.id = v_product_id
       AND p.isletme_id = v_isletme_id
       AND p.deleted_at IS NULL;

    IF v_product_rec.price < 0 THEN
      RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_FIYAT'
        USING DETAIL = 'Urun fiyati negatif olamaz -- product_id='
          || v_product_id || ', price=' || v_product_rec.price;
    END IF;

    IF v_product_rec.stock < v_quantity THEN
      RAISE EXCEPTION 'SATIS_HATA:YETERSIZ_STOK'
        USING DETAIL = 'Yetersiz stok -- urun=' || v_product_rec.name
          || ', mevcut=' || v_product_rec.stock || ', istenen=' || v_quantity;
    END IF;

    v_total_amount := v_total_amount + (v_product_rec.price * v_quantity);
  END LOOP;

  INSERT INTO public.sales (total_amount, isletme_id, created_by, idempotency_key)
  VALUES (v_total_amount, v_isletme_id, v_user_id, p_idempotency_key)
  RETURNING id INTO v_sale_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;

    INSERT INTO public.sale_items (sale_id, product_id, quantity, unit_price, isletme_id)
    SELECT v_sale_id, p.id, v_quantity, p.price, p.isletme_id
      FROM public.products p
     WHERE p.id = v_product_id
       AND p.isletme_id = v_isletme_id
       AND p.deleted_at IS NULL;
  END LOOP;

  UPDATE public.products p
     SET stock = p.stock - (
           SELECT (elem->>'quantity')::integer
             FROM jsonb_array_elements(p_items) AS elem
            WHERE (elem->>'product_id')::uuid = p.id
         )
   WHERE p.id IN (
           SELECT (elem->>'product_id')::uuid
             FROM jsonb_array_elements(p_items) AS elem
         )
     AND p.isletme_id = v_isletme_id
     AND p.deleted_at IS NULL;

  RETURN jsonb_build_object(
    'sale_id',      v_sale_id,
    'total_amount', v_total_amount,
    'isletme_id',   v_isletme_id
  );
END;
$function$;

ALTER FUNCTION public.complete_sale(jsonb, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.complete_sale(jsonb, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_sale(jsonb, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Product mutation RPC: explicit auth -> tenant -> admin -> idempotency
--    ordering, fixed search_path, and a closed execution ACL.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.process_product_mutation(
  p_idempotency_key uuid,
  p_isletme_id integer,
  p_operation_type text,
  p_product_id uuid,
  p_payload jsonb,
  p_base_updated_at timestamp with time zone
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_user_isletme_id integer;
  v_user_role text;
  v_current_updated_at timestamp with time zone;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT k.isletme_id, k.rol
    INTO v_user_isletme_id, v_user_role
    FROM public.kullanicilar k
   WHERE k.id = v_user_id;

  IF v_user_isletme_id IS NULL
     OR v_user_isletme_id <> p_isletme_id THEN
    RAISE EXCEPTION 'TENANT_MISMATCH';
  END IF;

  IF v_user_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'PRODUCT_MUTATION_FORBIDDEN';
  END IF;

  INSERT INTO public.mutation_idempotency (idempotency_key, isletme_id)
  VALUES (p_idempotency_key, v_user_isletme_id)
  ON CONFLICT (idempotency_key) DO NOTHING;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'IDEMPOTENT_TEKRAR');
  END IF;

  IF p_operation_type = 'CREATE' THEN
    INSERT INTO public.products (
      id, isletme_id, name, price, stock, barcode, updated_at
    )
    VALUES (
      p_product_id,
      v_user_isletme_id,
      p_payload->>'name',
      (p_payload->>'price')::numeric,
      (p_payload->>'stock')::integer,
      p_payload->>'barcode',
      now()
    );

    RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'CREATE');

  ELSIF p_operation_type = 'UPDATE' THEN
    SELECT p.updated_at
      INTO v_current_updated_at
      FROM public.products p
     WHERE p.id = p_product_id
       AND p.isletme_id = v_user_isletme_id
       AND p.deleted_at IS NULL
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
    END IF;

    IF v_current_updated_at > p_base_updated_at THEN
      RAISE EXCEPTION 'CONFLICT_DETECTED';
    END IF;

    UPDATE public.products p
       SET name = coalesce(p_payload->>'name', p.name),
           price = coalesce((p_payload->>'price')::numeric, p.price),
           stock = coalesce((p_payload->>'stock')::integer, p.stock),
           barcode = CASE
             WHEN p_payload ? 'barcode' THEN p_payload->>'barcode'
             ELSE p.barcode
           END,
           updated_at = now()
     WHERE p.id = p_product_id
       AND p.isletme_id = v_user_isletme_id
       AND p.deleted_at IS NULL;

    RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'UPDATE');

  ELSIF p_operation_type = 'DELETE' THEN
    SELECT p.updated_at
      INTO v_current_updated_at
      FROM public.products p
     WHERE p.id = p_product_id
       AND p.isletme_id = v_user_isletme_id
       AND p.deleted_at IS NULL
     FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'status', 'SUCCESS', 'operation', 'DELETE_ALREADY_GONE'
      );
    END IF;

    IF v_current_updated_at > p_base_updated_at THEN
      RAISE EXCEPTION 'CONFLICT_DETECTED';
    END IF;

    UPDATE public.products p
       SET deleted_at = now(),
           updated_at = now()
     WHERE p.id = p_product_id
       AND p.isletme_id = v_user_isletme_id
       AND p.deleted_at IS NULL;

    RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'DELETE');
  ELSE
    RAISE EXCEPTION 'INVALID_OPERATION_TYPE';
  END IF;
END;
$function$;

ALTER FUNCTION public.process_product_mutation(
  uuid, integer, text, uuid, jsonb, timestamp with time zone
) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.process_product_mutation(
  uuid, integer, text, uuid, jsonb, timestamp with time zone
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.process_product_mutation(
  uuid, integer, text, uuid, jsonb, timestamp with time zone
) TO authenticated, service_role;

-- Trigger-only function: no client needs direct EXECUTE.
REVOKE ALL ON FUNCTION public.fn_set_updated_at()
  FROM PUBLIC, anon, authenticated, service_role;
