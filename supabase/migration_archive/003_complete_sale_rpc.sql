-- =============================================================================
-- 003_complete_sale_rpc.sql
-- Atomik Satis Islemi -- complete_sale RPC fonksiyonu
--
-- AMAC:
--   Flutter client'in ayri ayri yaptigi sales INSERT, sale_items INSERT,
--   products stok UPDATE islemlerini tek bir guvenli PostgreSQL transaction'a tasir.
--
-- GUVENLIK:
--   * SECURITY DEFINER + SET search_path = '' (SQL injection korumasi)
--   * isletme_id ve created_by ASLA client'tan alinmaz; auth.uid() uzerinden belirlenir
--   * unit_price ASLA client'tan alinmaz; products.price uzerinden belirlenir
--   * total_amount ASLA client'tan alinmaz; DB hesaplar
--   * Cross-tenant erisim: WHERE isletme_id = v_isletme_id ile engellenir
--   * EXECUTE yetkisi yalnizca authenticated role'e verilir
--
-- RACE CONDITION COZUMU:
--   SELECT ... FOR UPDATE ORDER BY id: tum urun satirlarini kilitler.
--   Stok=1 iken eszamanli iki satis gelirse:
--     - Ilki kilitleri alir, stok kontrolunu gecer, tamamlar
--     - Ikincisi bekler, kilit alinca stok=0 gorur, YETERSIZ_STOK hatasiyla rollback
--
-- MEVCUT TRIGGER UYUMLULUGU:
--   * trg_set_sale_tenant_and_creator: auth.uid() gecerlidir, ayni degeri yazar (zararsiz)
--   * trg_set_sale_item_isletme_id: sales tablosundan isletme_id okur (zararsiz)
--   * trg_set_product_isletme_id: sadece INSERT'te calisir, UPDATE'i etkilemez
--
-- IDEMPOTENT: CREATE OR REPLACE FUNCTION, DROP TYPE IF EXISTS ... CASCADE
-- =============================================================================


-- =============================================================================
-- 1. complete_sale FONKSIYONU
-- =============================================================================

CREATE OR REPLACE FUNCTION public.complete_sale(
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
BEGIN

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
  -- trg_set_sale_tenant_and_creator trigger'i ayni degerleri override eder (zararsiz).
  -- =========================================================================
  INSERT INTO public.sales (total_amount, isletme_id, created_by)
  VALUES (v_total_amount, v_isletme_id, v_user_id)
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
$$;


-- =============================================================================
-- 3. YETKI YONETIMI
-- =============================================================================

-- Herkese acik erisimi kapat
REVOKE ALL ON FUNCTION public.complete_sale(jsonb) FROM PUBLIC;

-- Yalnizca authenticate olmus kullanicilar cagirabillir
GRANT EXECUTE ON FUNCTION public.complete_sale(jsonb) TO authenticated;

-- service_role: Supabase default olarak tum fonksiyonlara erisir
