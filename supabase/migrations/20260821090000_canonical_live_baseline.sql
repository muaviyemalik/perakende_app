-- Canonical source: live Supabase project vnvifxvtutlbivsegjtp, captured 2026-08-21.
-- Schema-only baseline. Do NOT run this file against the existing production database.
-- It deliberately preserves current live authorization/grant behavior; P0 hardening is a later migration.

CREATE SCHEMA private;
ALTER SCHEMA private OWNER TO postgres;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO PUBLIC, anon, authenticated, service_role;

CREATE SEQUENCE "public"."isletmeler_id_seq" AS integer START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 NO CYCLE CACHE 1;
ALTER SEQUENCE "public"."isletmeler_id_seq" OWNER TO "postgres";
REVOKE ALL ON SEQUENCE public.isletmeler_id_seq FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.isletmeler_id_seq TO anon, authenticated, service_role;

CREATE TABLE "public"."isletmeler" (
  "id" integer DEFAULT nextval('isletmeler_id_seq'::regclass) NOT NULL,
  "isletme_adi" text NOT NULL,
  "olusturma_tarihi" timestamp with time zone DEFAULT now()
);
ALTER TABLE "public"."isletmeler" OWNER TO "postgres";

CREATE TABLE "public"."kullanicilar" (
  "id" uuid NOT NULL,
  "isletme_id" integer,
  "rol" text DEFAULT 'kasiyer'::text,
  "sifre_degisti_mi" boolean DEFAULT false
);
ALTER TABLE "public"."kullanicilar" OWNER TO "postgres";

CREATE TABLE "public"."products" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "barcode" text,
  "name" text NOT NULL,
  "price" numeric(10,2) NOT NULL,
  "stock" integer DEFAULT 0 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "isletme_id" integer,
  "deleted_at" timestamp with time zone
);
ALTER TABLE "public"."products" OWNER TO "postgres";

CREATE TABLE "public"."sales" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "total_amount" numeric(10,2) NOT NULL,
  "created_by" uuid NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "isletme_id" integer,
  "idempotency_key" text
);
ALTER TABLE "public"."sales" OWNER TO "postgres";

CREATE TABLE "public"."sale_items" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "sale_id" uuid NOT NULL,
  "product_id" uuid NOT NULL,
  "quantity" integer DEFAULT 1 NOT NULL,
  "unit_price" numeric(10,2) NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "isletme_id" integer
);
ALTER TABLE "public"."sale_items" OWNER TO "postgres";

CREATE TABLE "public"."mutation_idempotency" (
  "idempotency_key" uuid NOT NULL,
  "isletme_id" integer NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE "public"."mutation_idempotency" OWNER TO "postgres";

ALTER SEQUENCE public.isletmeler_id_seq OWNED BY public.isletmeler.id;

ALTER TABLE ONLY "public"."isletmeler" ADD CONSTRAINT "isletmeler_pkey" PRIMARY KEY (id);

ALTER TABLE ONLY "public"."kullanicilar" ADD CONSTRAINT "kullanicilar_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id);

ALTER TABLE ONLY "public"."kullanicilar" ADD CONSTRAINT "kullanicilar_isletme_id_fkey" FOREIGN KEY (isletme_id) REFERENCES isletmeler(id);

ALTER TABLE ONLY "public"."kullanicilar" ADD CONSTRAINT "kullanicilar_pkey" PRIMARY KEY (id);

ALTER TABLE ONLY "public"."mutation_idempotency" ADD CONSTRAINT "mutation_idempotency_pkey" PRIMARY KEY (idempotency_key);

ALTER TABLE ONLY "public"."products" ADD CONSTRAINT "chk_products_price_non_negative" CHECK (price >= 0::numeric);

ALTER TABLE ONLY "public"."products" ADD CONSTRAINT "chk_products_stock_non_negative" CHECK (stock >= 0);

ALTER TABLE ONLY "public"."products" ADD CONSTRAINT "products_barcode_key" UNIQUE (barcode);

ALTER TABLE ONLY "public"."products" ADD CONSTRAINT "products_isletme_id_fkey" FOREIGN KEY (isletme_id) REFERENCES isletmeler(id);

ALTER TABLE ONLY "public"."products" ADD CONSTRAINT "products_pkey" PRIMARY KEY (id);

ALTER TABLE ONLY "public"."sales" ADD CONSTRAINT "sales_pkey" PRIMARY KEY (id);

ALTER TABLE ONLY "public"."sale_items" ADD CONSTRAINT "chk_sale_items_quantity_positive" CHECK (quantity > 0);

ALTER TABLE ONLY "public"."sale_items" ADD CONSTRAINT "chk_sale_items_unit_price_non_negative" CHECK (unit_price >= 0::numeric);

ALTER TABLE ONLY "public"."sale_items" ADD CONSTRAINT "sale_items_isletme_id_fkey" FOREIGN KEY (isletme_id) REFERENCES isletmeler(id);

ALTER TABLE ONLY "public"."sale_items" ADD CONSTRAINT "sale_items_pkey" PRIMARY KEY (id);

ALTER TABLE ONLY "public"."sale_items" ADD CONSTRAINT "sale_items_product_id_fkey" FOREIGN KEY (product_id) REFERENCES products(id);

ALTER TABLE ONLY "public"."sale_items" ADD CONSTRAINT "sale_items_sale_id_fkey" FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE;

ALTER TABLE ONLY "public"."sales" ADD CONSTRAINT "sales_isletme_id_fkey" FOREIGN KEY (isletme_id) REFERENCES isletmeler(id);

CREATE INDEX idx_kullanicilar_isletme_id ON public.kullanicilar USING btree (isletme_id);

CREATE INDEX idx_products_active ON public.products USING btree (isletme_id) WHERE (deleted_at IS NULL);

CREATE INDEX idx_products_active_sync ON public.products USING btree (isletme_id, updated_at) WHERE (deleted_at IS NULL);

CREATE INDEX idx_products_deleted_sync ON public.products USING btree (isletme_id, deleted_at) WHERE (deleted_at IS NOT NULL);

CREATE INDEX idx_products_isletme_id ON public.products USING btree (isletme_id);

CREATE INDEX idx_products_isletme_updated_at ON public.products USING btree (isletme_id, updated_at);

CREATE INDEX idx_products_sync_deleted ON public.products USING btree (isletme_id, updated_at) WHERE (deleted_at IS NOT NULL);

CREATE UNIQUE INDEX idx_products_unique_barcode ON public.products USING btree (isletme_id, barcode) WHERE ((barcode IS NOT NULL) AND (deleted_at IS NULL));

CREATE INDEX idx_sale_items_isletme_id ON public.sale_items USING btree (isletme_id);

CREATE INDEX idx_sale_items_product_id ON public.sale_items USING btree (product_id);

CREATE INDEX idx_sale_items_sale_id ON public.sale_items USING btree (sale_id);

CREATE UNIQUE INDEX idx_sales_idempotency_key_unique ON public.sales USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);

CREATE INDEX idx_sales_isletme_id ON public.sales USING btree (isletme_id);

ALTER TABLE "public"."isletmeler" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."isletmeler" NO FORCE ROW LEVEL SECURITY;

ALTER TABLE "public"."kullanicilar" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."kullanicilar" NO FORCE ROW LEVEL SECURITY;

ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."products" NO FORCE ROW LEVEL SECURITY;

ALTER TABLE "public"."sales" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sales" NO FORCE ROW LEVEL SECURITY;

ALTER TABLE "public"."sale_items" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sale_items" NO FORCE ROW LEVEL SECURITY;

ALTER TABLE "public"."mutation_idempotency" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."mutation_idempotency" NO FORCE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.get_kullanici_isletme_id()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select k.isletme_id from public.kullanicilar k where k.id = (select auth.uid()) limit 1 $function$;
ALTER FUNCTION "private"."get_kullanici_isletme_id"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION private.get_my_isletme_id()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select k.isletme_id from public.kullanicilar k where k.id = (select auth.uid()) limit 1 $function$;
ALTER FUNCTION "private"."get_my_isletme_id"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION private.get_my_rol()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select k.rol from public.kullanicilar k where k.id = (select auth.uid()) limit 1 $function$;
ALTER FUNCTION "private"."get_my_rol"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION private.prevent_self_role_or_tenant_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if (select auth.uid()) = old.id
     and (new.rol is distinct from old.rol or new.isletme_id is distinct from old.isletme_id) then
    raise exception 'Rol veya isletme_id bu kullanici tarafindan degistirilemez';
  end if;
  return new;
end;
$function$;
ALTER FUNCTION "private"."prevent_self_role_or_tenant_change"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION private.set_product_isletme_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  new.isletme_id := (select private.get_my_isletme_id());
  if new.isletme_id is null then raise exception 'Kullanıcının işletmesi bulunamadı'; end if;
  return new;
end;
$function$;
ALTER FUNCTION "private"."set_product_isletme_id"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION private.set_sale_item_tenant_data()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare sale_isletme_id integer;
begin
  select s.isletme_id into sale_isletme_id from public.sales s where s.id = new.sale_id limit 1;
  if sale_isletme_id is null then raise exception 'Satış bulunamadı veya satışın işletmesi belirlenemedi'; end if;
  if sale_isletme_id <> (select private.get_my_isletme_id()) then raise exception 'Bu satış başka bir işletmeye ait'; end if;
  new.isletme_id := (select private.get_my_isletme_id());
  return new;
end;
$function$;
ALTER FUNCTION "private"."set_sale_item_tenant_data"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION private.set_sale_tenant_data()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  new.isletme_id := (select private.get_my_isletme_id());
  new.created_by := (select auth.uid());
  if new.isletme_id is null then raise exception 'Kullanıcının işletmesi bulunamadı'; end if;
  if new.created_by is null then raise exception 'Kimliği doğrulanmış kullanıcı bulunamadı'; end if;
  return new;
end;
$function$;
ALTER FUNCTION "private"."set_sale_tenant_data"() OWNER TO "postgres";

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

CREATE TRIGGER protect_user_role_and_tenant BEFORE UPDATE ON kullanicilar FOR EACH ROW EXECUTE FUNCTION private.prevent_self_role_or_tenant_change();

CREATE TRIGGER set_product_isletme_id_trigger BEFORE INSERT ON products FOR EACH ROW EXECUTE FUNCTION private.set_product_isletme_id();

CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER set_sale_item_tenant_data_trigger BEFORE INSERT ON sale_items FOR EACH ROW EXECUTE FUNCTION private.set_sale_item_tenant_data();

CREATE TRIGGER set_sale_tenant_data_trigger BEFORE INSERT ON sales FOR EACH ROW EXECUTE FUNCTION private.set_sale_tenant_data();

CREATE POLICY "isletmeler_delete_own_business_admin" ON "public"."isletmeler" AS PERMISSIVE FOR DELETE TO "authenticated" USING (((id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)) AND (( SELECT private.get_my_rol() AS get_my_rol) = 'admin'::text)));

CREATE POLICY "isletmeler_select_own_business" ON "public"."isletmeler" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "isletmeler_update_own_business_admin" ON "public"."isletmeler" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)) AND (( SELECT private.get_my_rol() AS get_my_rol) = 'admin'::text))) WITH CHECK ((id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "kullanicilar_select" ON "public"."kullanicilar" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "kullanicilar_update" ON "public"."kullanicilar" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((id = ( SELECT auth.uid() AS uid))) WITH CHECK ((id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Allow authenticated to insert idempotency" ON "public"."mutation_idempotency" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((isletme_id = ( SELECT kullanicilar.isletme_id
   FROM kullanicilar
  WHERE (kullanicilar.id = auth.uid()))));

CREATE POLICY "Allow authenticated to select idempotency" ON "public"."mutation_idempotency" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((isletme_id = ( SELECT kullanicilar.isletme_id
   FROM kullanicilar
  WHERE (kullanicilar.id = auth.uid()))));

CREATE POLICY "products_delete_own_business" ON "public"."products" AS PERMISSIVE FOR DELETE TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "products_insert_own_business" ON "public"."products" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "products_select_own_business" ON "public"."products" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "products_update_own_business" ON "public"."products" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id))) WITH CHECK ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sale_items_delete_own_business" ON "public"."sale_items" AS PERMISSIVE FOR DELETE TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sale_items_insert_own_business" ON "public"."sale_items" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sale_items_select_own_business" ON "public"."sale_items" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sale_items_update_own_business" ON "public"."sale_items" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id))) WITH CHECK ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sales_delete_own_business" ON "public"."sales" AS PERMISSIVE FOR DELETE TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sales_insert_own_business" ON "public"."sales" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sales_select_own_business" ON "public"."sales" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

CREATE POLICY "sales_update_own_business" ON "public"."sales" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id))) WITH CHECK ((isletme_id = ( SELECT private.get_my_isletme_id() AS get_my_isletme_id)));

REVOKE ALL ON TABLE "public"."isletmeler" FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON TABLE "public"."kullanicilar" FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON TABLE "public"."products" FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON TABLE "public"."sales" FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON TABLE "public"."sale_items" FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON TABLE "public"."mutation_idempotency" FROM PUBLIC, anon, authenticated, service_role;

GRANT DELETE ON TABLE "public"."isletmeler" TO "authenticated";

GRANT INSERT ON TABLE "public"."isletmeler" TO "authenticated";

GRANT REFERENCES ON TABLE "public"."isletmeler" TO "authenticated";

GRANT SELECT ON TABLE "public"."isletmeler" TO "authenticated";

GRANT TRIGGER ON TABLE "public"."isletmeler" TO "authenticated";

GRANT TRUNCATE ON TABLE "public"."isletmeler" TO "authenticated";

GRANT UPDATE ON TABLE "public"."isletmeler" TO "authenticated";

GRANT DELETE ON TABLE "public"."isletmeler" TO "service_role";

GRANT INSERT ON TABLE "public"."isletmeler" TO "service_role";

GRANT REFERENCES ON TABLE "public"."isletmeler" TO "service_role";

GRANT SELECT ON TABLE "public"."isletmeler" TO "service_role";

GRANT TRIGGER ON TABLE "public"."isletmeler" TO "service_role";

GRANT TRUNCATE ON TABLE "public"."isletmeler" TO "service_role";

GRANT UPDATE ON TABLE "public"."isletmeler" TO "service_role";

GRANT DELETE ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT INSERT ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT REFERENCES ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT SELECT ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT TRIGGER ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT TRUNCATE ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT UPDATE ON TABLE "public"."kullanicilar" TO "authenticated";

GRANT DELETE ON TABLE "public"."kullanicilar" TO "service_role";

GRANT INSERT ON TABLE "public"."kullanicilar" TO "service_role";

GRANT REFERENCES ON TABLE "public"."kullanicilar" TO "service_role";

GRANT SELECT ON TABLE "public"."kullanicilar" TO "service_role";

GRANT TRIGGER ON TABLE "public"."kullanicilar" TO "service_role";

GRANT TRUNCATE ON TABLE "public"."kullanicilar" TO "service_role";

GRANT UPDATE ON TABLE "public"."kullanicilar" TO "service_role";

GRANT DELETE ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT INSERT ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT REFERENCES ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT SELECT ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT TRIGGER ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT TRUNCATE ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT UPDATE ON TABLE "public"."mutation_idempotency" TO "anon";

GRANT DELETE ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT INSERT ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT REFERENCES ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT SELECT ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT TRIGGER ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT TRUNCATE ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT UPDATE ON TABLE "public"."mutation_idempotency" TO "authenticated";

GRANT DELETE ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT INSERT ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT REFERENCES ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT SELECT ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT TRIGGER ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT TRUNCATE ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT UPDATE ON TABLE "public"."mutation_idempotency" TO "service_role";

GRANT DELETE ON TABLE "public"."products" TO "authenticated";

GRANT INSERT ON TABLE "public"."products" TO "authenticated";

GRANT REFERENCES ON TABLE "public"."products" TO "authenticated";

GRANT SELECT ON TABLE "public"."products" TO "authenticated";

GRANT TRIGGER ON TABLE "public"."products" TO "authenticated";

GRANT TRUNCATE ON TABLE "public"."products" TO "authenticated";

GRANT UPDATE ON TABLE "public"."products" TO "authenticated";

GRANT DELETE ON TABLE "public"."products" TO "service_role";

GRANT INSERT ON TABLE "public"."products" TO "service_role";

GRANT REFERENCES ON TABLE "public"."products" TO "service_role";

GRANT SELECT ON TABLE "public"."products" TO "service_role";

GRANT TRIGGER ON TABLE "public"."products" TO "service_role";

GRANT TRUNCATE ON TABLE "public"."products" TO "service_role";

GRANT UPDATE ON TABLE "public"."products" TO "service_role";

GRANT DELETE ON TABLE "public"."sale_items" TO "authenticated";

GRANT INSERT ON TABLE "public"."sale_items" TO "authenticated";

GRANT REFERENCES ON TABLE "public"."sale_items" TO "authenticated";

GRANT SELECT ON TABLE "public"."sale_items" TO "authenticated";

GRANT TRIGGER ON TABLE "public"."sale_items" TO "authenticated";

GRANT TRUNCATE ON TABLE "public"."sale_items" TO "authenticated";

GRANT UPDATE ON TABLE "public"."sale_items" TO "authenticated";

GRANT DELETE ON TABLE "public"."sale_items" TO "service_role";

GRANT INSERT ON TABLE "public"."sale_items" TO "service_role";

GRANT REFERENCES ON TABLE "public"."sale_items" TO "service_role";

GRANT SELECT ON TABLE "public"."sale_items" TO "service_role";

GRANT TRIGGER ON TABLE "public"."sale_items" TO "service_role";

GRANT TRUNCATE ON TABLE "public"."sale_items" TO "service_role";

GRANT UPDATE ON TABLE "public"."sale_items" TO "service_role";

GRANT DELETE ON TABLE "public"."sales" TO "authenticated";

GRANT INSERT ON TABLE "public"."sales" TO "authenticated";

GRANT REFERENCES ON TABLE "public"."sales" TO "authenticated";

GRANT SELECT ON TABLE "public"."sales" TO "authenticated";

GRANT TRIGGER ON TABLE "public"."sales" TO "authenticated";

GRANT TRUNCATE ON TABLE "public"."sales" TO "authenticated";

GRANT UPDATE ON TABLE "public"."sales" TO "authenticated";

GRANT DELETE ON TABLE "public"."sales" TO "service_role";

GRANT INSERT ON TABLE "public"."sales" TO "service_role";

GRANT REFERENCES ON TABLE "public"."sales" TO "service_role";

GRANT SELECT ON TABLE "public"."sales" TO "service_role";

GRANT TRIGGER ON TABLE "public"."sales" TO "service_role";

GRANT TRUNCATE ON TABLE "public"."sales" TO "service_role";

GRANT UPDATE ON TABLE "public"."sales" TO "service_role";

REVOKE ALL ON FUNCTION "private"."get_kullanici_isletme_id"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "private"."get_my_isletme_id"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "private"."get_my_rol"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "private"."prevent_self_role_or_tenant_change"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "private"."set_product_isletme_id"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "private"."set_sale_item_tenant_data"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "private"."set_sale_tenant_data"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "public"."complete_sale"(p_items jsonb, p_idempotency_key text) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "public"."fn_set_updated_at"() FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION "public"."process_product_mutation"(p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION "private"."get_kullanici_isletme_id"() TO authenticated;

GRANT EXECUTE ON FUNCTION "private"."get_my_isletme_id"() TO authenticated;

GRANT EXECUTE ON FUNCTION "private"."get_my_rol"() TO authenticated;

GRANT EXECUTE ON FUNCTION "public"."complete_sale"(p_items jsonb, p_idempotency_key text) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION "public"."fn_set_updated_at"() TO PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION "public"."process_product_mutation"(p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone) TO PUBLIC, anon, authenticated, service_role;

DO $publication$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    RAISE EXCEPTION 'supabase_realtime publication must exist in a Supabase scratch environment';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'products') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.products;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'sales') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.sales;
  END IF;
END;
$publication$;
