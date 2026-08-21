-- EMERGENCY USE ONLY: forward-only compensation for
-- 20260821100000_p0_authorization_hardening.sql.
--
-- This migration intentionally reopens the weaker authorization surface that
-- existed in 20260821090000_canonical_live_baseline.sql. It must never be part
-- of the normal migration directory or routine db push workflow.
--
-- Activation requires an incident decision, a fresh backup/PITR confirmation,
-- scratch verification, and an explicit copy into supabase/migrations. The P0
-- migration history row is retained; this new version records the compensation.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM supabase_migrations.schema_migrations
    WHERE version = '20260821100000'
  ) THEN
    RAISE EXCEPTION
      'EMERGENCY_ROLLBACK_ABORTED:P0_HISTORY_NOT_PRESENT';
  END IF;

  IF has_table_privilege('authenticated', 'public.sales', 'INSERT')
     OR has_table_privilege('authenticated', 'public.sale_items', 'INSERT')
     OR has_function_privilege(
          'authenticated',
          'public.fn_set_updated_at()',
          'EXECUTE'
        )
     OR NOT (
       SELECT p.prosecdef
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND p.proname = 'process_product_mutation'
         AND pg_get_function_identity_arguments(p.oid) =
           'p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone'
     )
  THEN
    RAISE EXCEPTION
      'EMERGENCY_ROLLBACK_ABORTED:P0_POSTCONDITIONS_NOT_PRESENT';
  END IF;
END
$guard$;

-- Restore the canonical baseline RLS expressions.
ALTER POLICY products_insert_own_business
  ON public.products
  TO authenticated
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY products_update_own_business
  ON public.products
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
  )
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY products_delete_own_business
  ON public.products
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY sales_insert_own_business
  ON public.sales
  TO authenticated
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY sales_update_own_business
  ON public.sales
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
  )
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY sales_delete_own_business
  ON public.sales
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY sale_items_insert_own_business
  ON public.sale_items
  TO authenticated
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY sale_items_update_own_business
  ON public.sale_items
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
  )
  WITH CHECK (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY sale_items_delete_own_business
  ON public.sale_items
  TO authenticated
  USING (
    isletme_id = (SELECT private.get_my_isletme_id())
  );

ALTER POLICY "Allow authenticated to insert idempotency"
  ON public.mutation_idempotency
  TO authenticated
  WITH CHECK (
    isletme_id = (
      SELECT kullanicilar.isletme_id
      FROM public.kullanicilar
      WHERE kullanicilar.id = auth.uid()
    )
  );

ALTER POLICY "Allow authenticated to select idempotency"
  ON public.mutation_idempotency
  TO authenticated
  USING (
    isletme_id = (
      SELECT kullanicilar.isletme_id
      FROM public.kullanicilar
      WHERE kullanicilar.id = auth.uid()
    )
  );

-- Restore the exact canonical baseline function bodies.
CREATE OR REPLACE FUNCTION public.complete_sale(p_items jsonb, p_idempotency_key text DEFAULT NULL::text)
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

  -- =========================================================================
  -- ADIM 0: Idempotency kontrolü
  -- =========================================================================
  -- p_idempotency_key verilmişse ve daha önce işlendiyse:
  --   stok/fiyat/insert işlemleri TEKRARLANMAZ, mevcut sonuç döndürülür.
  -- Bu adım tüm diğer adımlardan önce çalışır — gereksiz kilit/sorgu engellenir.
  -- =========================================================================
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id, total_amount, isletme_id
      INTO v_existing_sale
      FROM public.sales
     WHERE idempotency_key = p_idempotency_key;

    IF v_existing_sale.id IS NOT NULL THEN
      -- Zaten işlenmiş — idempotent yanıt
      RETURN jsonb_build_object(
        'sale_id',      v_existing_sale.id,
        'total_amount', v_existing_sale.total_amount,
        'isletme_id',   v_existing_sale.isletme_id,
        'idempotent',   true
      );
    END IF;
  END IF;

  -- =========================================================================
  -- ADIM 1: Kimlik dogrulama
  -- =========================================================================
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'SATIS_HATA:KIMLIK_DOGRULANAMADI'
      USING DETAIL = 'auth.uid() NULL dondu -- oturum gecersiz';
  END IF;

  -- =========================================================================
  -- ADIM 2: Isletme ID belirleme (auth.uid() -> kullanicilar.isletme_id)
  -- =========================================================================
  SELECT isletme_id
    INTO v_isletme_id
    FROM public.kullanicilar
   WHERE id = v_user_id;

  IF v_isletme_id IS NULL THEN
    RAISE EXCEPTION 'SATIS_HATA:ISLETME_BULUNAMADI'
      USING DETAIL = 'Kullanici gecerli bir isletmeye bagli degil';
  END IF;

  -- =========================================================================
  -- ADIM 3: Input validasyonu
  -- =========================================================================

  -- Bos sepet red
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'SATIS_HATA:SEPET_BOS'
      USING DETAIL = 'Sepet bos -- en az 1 urun gereklidir';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  -- Her kalem icin product_id ve quantity validasyonu
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

    -- quantity > 0 zorunlulugu (0 ve negatif kesin red)
    IF v_quantity <= 0 THEN
      RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_MIKTAR'
        USING DETAIL = 'quantity 0 veya negatif olamaz -- product_id=' || (v_item->>'product_id') || ', quantity=' || v_quantity;
    END IF;
  END LOOP;

  -- Duplicate product_id kontrolu (kesin red)
  -- Input icindeki unique product_id sayisi toplam sayiya esit olmali
  IF (
    SELECT COUNT(DISTINCT elem->>'product_id')
      FROM jsonb_array_elements(p_items) AS elem
  ) <> v_item_count THEN
    RAISE EXCEPTION 'SATIS_HATA:TEKRAR_URUN_ID'
      USING DETAIL = 'Ayni product_id birden fazla kez gonderildi -- sepette tekrar eden urunler birlestirin';
  END IF;

  -- =========================================================================
  -- ADIM 4: Row-level locking -- FOR UPDATE (sirali, deadlock-safe)
  --
  -- ORDER BY p.id: farkli islemler ayni ureunleri hep ayni sirada kilitler,
  -- dolayisiyla dairesel bekleme (deadlock) olusumu engellenir.
  --
  -- WHERE isletme_id = v_isletme_id: cross-tenant koruma burada baslar.
  -- Baska tenant'in urunu gonderilirse o satir bu WHERE'i gecemez,
  -- kilitlenen satir sayisi v_item_count'tan az olur -> ADIM 5 hata firlatir.
  --
  -- Concurrency: Eszamanli iki islem ayni urunu kilitlemek isterse,
  -- ikincisi birincisi COMMIT/ROLLBACK yapana kadar burada bekler.
  -- =========================================================================
  PERFORM p.id
    FROM public.products p
   WHERE p.id IN (
           SELECT (elem->>'product_id')::uuid
             FROM jsonb_array_elements(p_items) AS elem
         )
     AND p.isletme_id = v_isletme_id
   ORDER BY p.id
   FOR UPDATE;

  -- =========================================================================
  -- ADIM 5: Kilit alinan satir sayisi dogrulamasi
  --
  -- FOR UPDATE: yalnizca v_isletme_id'ye ait satirlari kilitler.
  -- Bu SELECT ile kac satirin kilitlendigini dogruluyoruz.
  -- Fark varsa: urun mevcut degil VEYA baska tenant'a ait.
  -- =========================================================================
  SELECT COUNT(*)
    INTO v_locked_count
    FROM public.products
   WHERE id IN (
           SELECT (elem->>'product_id')::uuid
             FROM jsonb_array_elements(p_items) AS elem
         )
     AND isletme_id = v_isletme_id;

  IF v_locked_count <> v_item_count THEN
    RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_URUN'
      USING DETAIL = 'Bazi urunler bu isletmeye ait degil veya mevcut degil -- '
                   || 'beklenen=' || v_item_count || ', bulunan=' || v_locked_count
                   || ', isletme_id=' || v_isletme_id;
  END IF;

  -- =========================================================================
  -- ADIM 6: Stok kontrolu + toplam tutar hesaplama
  --
  -- FOR UPDATE sonrasi bu SELECT'ler kilitli satirlari okur.
  -- Baska hicbir transaction bu satirlari degistiremez -- stok guvende.
  -- unit_price her zaman DB'deki products.price'tan alinir.
  -- =========================================================================
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity   := (v_item->>'quantity')::integer;

    SELECT id, name, price, stock
      INTO v_product_rec
      FROM public.products
     WHERE id = v_product_id
       AND isletme_id = v_isletme_id;

    -- Price negatif veri butunlugu kontrolu
    IF v_product_rec.price < 0 THEN
      RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_FIYAT'
        USING DETAIL = 'Urun fiyati negatif olamaz -- product_id=' || v_product_id
                     || ', price=' || v_product_rec.price;
    END IF;

    -- Stok yeterlilik kontrolu (FOR UPDATE sonrasi snapshot)
    IF v_product_rec.stock < v_quantity THEN
      RAISE EXCEPTION 'SATIS_HATA:YETERSIZ_STOK'
        USING DETAIL = 'Yetersiz stok -- urun=' || v_product_rec.name
                     || ', mevcut=' || v_product_rec.stock
                     || ', istenen=' || v_quantity;
    END IF;

    -- Toplam tutara ekle (DB fiyati kullanilir -- client manipulasyona kapali)
    v_total_amount := v_total_amount + (v_product_rec.price * v_quantity);
  END LOOP;

  -- =========================================================================
  -- ADIM 7: Sales kaydi olustur
  --
  -- isletme_id ve created_by burada set edilir.
  -- idempotency_key varsa kaydedilir (tekrar gönderim koruması).
  -- trg_set_sale_tenant_and_creator trigger'i ayni degerleri override eder (zararsiz).
  -- =========================================================================
  INSERT INTO public.sales (total_amount, isletme_id, created_by, idempotency_key)
  VALUES (v_total_amount, v_isletme_id, v_user_id, p_idempotency_key)
  RETURNING id INTO v_sale_id;

  -- =========================================================================
  -- ADIM 8: Sale_items kayitlari
  --
  -- unit_price her zaman products.price'tan alinir.
  -- trg_set_sale_item_isletme_id trigger'i isletme_id'yi sales tablosundan
  -- dogrular ve set eder -- bizimle tutarli (zararsiz).
  -- =========================================================================
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity   := (v_item->>'quantity')::integer;

    INSERT INTO public.sale_items (sale_id, product_id, quantity, unit_price, isletme_id)
    SELECT
      v_sale_id,
      p.id,
      v_quantity,
      p.price,       -- Fiyat her zaman DB'den
      p.isletme_id   -- trigger da set edecek; burada da vererek tutarlilik saglanir
    FROM public.products p
    WHERE p.id = v_product_id
      AND p.isletme_id = v_isletme_id;
  END LOOP;

  -- =========================================================================
  -- ADIM 9: Stoklari atomik olarak dusur (tek bulk UPDATE)
  --
  -- FOR UPDATE kilidi hala aktif.
  -- Subquery ile her urun icin dogru quantity dusurulur.
  -- =========================================================================
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
     AND p.isletme_id = v_isletme_id;

  -- =========================================================================
  -- ADIM 10: Basarili sonucu dondur
  -- =========================================================================
  RETURN jsonb_build_object(
    'sale_id',      v_sale_id,
    'total_amount', v_total_amount,
    'isletme_id',   v_isletme_id
  );

END;
$function$;
ALTER FUNCTION "public"."complete_sale"(p_items jsonb, p_idempotency_key text) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION public.fn_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$;
ALTER FUNCTION "public"."fn_set_updated_at"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION public.process_product_mutation(p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_isletme_id INT;
    v_current_updated_at TIMESTAMPTZ;
BEGIN
    -- 1. Tenant & Auth kontrolü
    SELECT isletme_id
    INTO v_user_isletme_id
    FROM public.kullanicilar
    WHERE id = auth.uid();

    IF v_user_isletme_id IS NULL
       OR v_user_isletme_id != p_isletme_id THEN
        RAISE EXCEPTION 'TENANT_MISMATCH';
    END IF;

    -- 2. Idempotency
    INSERT INTO public.mutation_idempotency (
        idempotency_key,
        isletme_id
    )
    VALUES (
        p_idempotency_key,
        p_isletme_id
    )
    ON CONFLICT (idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'status',
            'IDEMPOTENT_TEKRAR'
        );
    END IF;

    -- 3. CREATE
    IF p_operation_type = 'CREATE' THEN

        INSERT INTO public.products (
            id,
            isletme_id,
            name,
            price,
            stock,
            barcode,
            updated_at
        )
        VALUES (
            p_product_id,
            p_isletme_id,
            p_payload->>'name',
            CAST(p_payload->>'price' AS NUMERIC),
            CAST(p_payload->>'stock' AS INT),
            p_payload->>'barcode',
            NOW()
        );

        RETURN jsonb_build_object(
            'status',
            'SUCCESS',
            'operation',
            'CREATE'
        );

    -- 4. UPDATE
    ELSIF p_operation_type = 'UPDATE' THEN

        SELECT updated_at
        INTO v_current_updated_at
        FROM public.products
        WHERE id = p_product_id
          AND isletme_id = p_isletme_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
        END IF;

        IF v_current_updated_at > p_base_updated_at THEN
            RAISE EXCEPTION 'CONFLICT_DETECTED';
        END IF;

        UPDATE public.products
        SET
            name = COALESCE(
                p_payload->>'name',
                name
            ),
            price = COALESCE(
                CAST(p_payload->>'price' AS NUMERIC),
                price
            ),
            stock = COALESCE(
                CAST(p_payload->>'stock' AS INT),
                stock
            ),
            barcode = CASE
                WHEN p_payload ? 'barcode'
                THEN p_payload->>'barcode'
                ELSE barcode
            END,
            updated_at = NOW()
        WHERE id = p_product_id
          AND isletme_id = p_isletme_id;

        RETURN jsonb_build_object(
            'status',
            'SUCCESS',
            'operation',
            'UPDATE'
        );

    -- 5. DELETE
    ELSIF p_operation_type = 'DELETE' THEN

        SELECT updated_at
        INTO v_current_updated_at
        FROM public.products
        WHERE id = p_product_id
          AND isletme_id = p_isletme_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'status',
                'SUCCESS',
                'operation',
                'DELETE_ALREADY_GONE'
            );
        END IF;

        IF v_current_updated_at > p_base_updated_at THEN
            RAISE EXCEPTION 'CONFLICT_DETECTED';
        END IF;

        UPDATE public.products
        SET
            deleted_at = NOW(),
            updated_at = NOW()
        WHERE id = p_product_id
          AND isletme_id = p_isletme_id;

        RETURN jsonb_build_object(
            'status',
            'SUCCESS',
            'operation',
            'DELETE'
        );

    ELSE
        RAISE EXCEPTION 'INVALID_OPERATION_TYPE';
    END IF;
END;
$function$;
ALTER FUNCTION "public"."process_product_mutation"(p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone) OWNER TO "postgres";

-- Make the baseline attributes explicit after replacement.
ALTER FUNCTION public.process_product_mutation(
  uuid, integer, text, uuid, jsonb, timestamp with time zone
) SECURITY INVOKER;
ALTER FUNCTION public.process_product_mutation(
  uuid, integer, text, uuid, jsonb, timestamp with time zone
) RESET ALL;

-- Restore the exact canonical baseline table ACL matrix:
-- authenticated/service_role receive all seven table privileges on all tables;
-- anon receives them only on mutation_idempotency.
REVOKE ALL PRIVILEGES
  ON TABLE public.isletmeler, public.kullanicilar, public.products,
    public.sales, public.sale_items, public.mutation_idempotency
  FROM PUBLIC, anon, authenticated, service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.isletmeler, public.kullanicilar, public.products,
    public.sales, public.sale_items, public.mutation_idempotency
  TO authenticated, service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.mutation_idempotency
  TO anon;

-- Restore the canonical routine ACLs.
REVOKE ALL PRIVILEGES
  ON FUNCTION public.complete_sale(jsonb, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL PRIVILEGES
  ON FUNCTION public.fn_set_updated_at()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL PRIVILEGES
  ON FUNCTION public.process_product_mutation(
    uuid, integer, text, uuid, jsonb, timestamp with time zone
  )
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE
  ON FUNCTION public.complete_sale(jsonb, text)
  TO authenticated, service_role;
GRANT EXECUTE
  ON FUNCTION public.fn_set_updated_at()
  TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE
  ON FUNCTION public.process_product_mutation(
    uuid, integer, text, uuid, jsonb, timestamp with time zone
  )
  TO PUBLIC, anon, authenticated, service_role;

COMMIT;
