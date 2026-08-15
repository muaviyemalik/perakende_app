-- =============================================================================
-- 002_tenant_rls_policies.sql
-- Multi-tenant (çok-işletmeli) RLS politikaları ve güvenlik trigger'ları
--
-- AMAÇ:
--   Bir kullanıcı yalnızca kendi işletmesine (isletme_id) ait verilere
--   erişebilmeli, başka işletmelerin verilerini hiçbir şekilde
--   okuyamamalı, yazamamalı, güncelleyememeli veya silememeli.
--
-- GÜVENLİK MODELİ:
--   auth.uid()
--   → kullanicilar.id
--   → kullanicilar.isletme_id
--   → RLS → yalnızca o işletmenin verileri
--
-- ÇALIŞTIRMA:
--   Supabase Dashboard > SQL Editor'de bu dosyanın tamamını çalıştırın.
-- =============================================================================

-- =============================================================================
-- 1. YARDIMCI FONKSİYON: Giriş yapan kullanıcının işletme ID'si
-- =============================================================================
-- SECURITY DEFINER: kullanicilar tablosunu, kullanıcının kendi SELECT
-- yetkisini bypass ederek okur. Böylece RLS içindeki subquery'ler
-- "infinite recursion" hatası vermez.
-- SET search_path = '': SQL injection riskini sıfırlar.

CREATE OR REPLACE FUNCTION public.get_my_isletme_id()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT isletme_id
  FROM public.kullanicilar
  WHERE id = auth.uid();
$$;

-- Yalnızca kimliği doğrulanmış kullanıcılar bu fonksiyonu çağırabilir
REVOKE ALL ON FUNCTION public.get_my_isletme_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_isletme_id() TO authenticated;


-- =============================================================================
-- 2. PRODUCTS TABLOSU — RLS
-- =============================================================================

-- RLS'yi etkinleştir
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- Eski politikaları temizle (idempotent çalıştırma için)
DROP POLICY IF EXISTS "products_select_own_tenant"  ON public.products;
DROP POLICY IF EXISTS "products_insert_own_tenant"  ON public.products;
DROP POLICY IF EXISTS "products_update_own_tenant"  ON public.products;
DROP POLICY IF EXISTS "products_delete_own_tenant"  ON public.products;

-- SELECT: Kullanıcı yalnızca kendi işletmesinin ürünlerini görebilir
CREATE POLICY "products_select_own_tenant"
ON public.products
FOR SELECT
TO authenticated
USING (isletme_id = public.get_my_isletme_id());

-- INSERT: Kullanıcı yalnızca kendi işletmesine ürün ekleyebilir
-- Flutter'dan yanlış isletme_id gönderilse bile WITH CHECK engeller
CREATE POLICY "products_insert_own_tenant"
ON public.products
FOR INSERT
TO authenticated
WITH CHECK (isletme_id = public.get_my_isletme_id());

-- UPDATE: Kullanıcı yalnızca kendi işletmesinin ürünlerini güncelleyebilir
CREATE POLICY "products_update_own_tenant"
ON public.products
FOR UPDATE
TO authenticated
USING  (isletme_id = public.get_my_isletme_id())
WITH CHECK (isletme_id = public.get_my_isletme_id());

-- DELETE: Kullanıcı yalnızca kendi işletmesinin ürünlerini silebilir
CREATE POLICY "products_delete_own_tenant"
ON public.products
FOR DELETE
TO authenticated
USING (isletme_id = public.get_my_isletme_id());


-- =============================================================================
-- 3. PRODUCTS INSERT TRIGGER — isletme_id'yi DB Tarafında Override Et
-- =============================================================================
-- Flutter'dan gönderilen isletme_id değerine güvenmek yerine,
-- INSERT sırasında isletme_id'yi her zaman kullanıcının GERÇEK
-- işletmesiyle eziyoruz. Böylece:
--   - Kullanıcı LocalStorage'ı değiştirse de etkisiz
--   - Reverse-engineer ile farklı isletme_id gönderse de etkisiz
--   - Yanlışlıkla null gönderilse bile doğru değer atanır

CREATE OR REPLACE FUNCTION public.fn_set_product_isletme_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.isletme_id := public.get_my_isletme_id();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_product_isletme_id ON public.products;

CREATE TRIGGER trg_set_product_isletme_id
BEFORE INSERT ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.fn_set_product_isletme_id();


-- =============================================================================
-- 4. SALES TABLOSU — RLS
-- =============================================================================

ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sales_select_own_tenant"  ON public.sales;
DROP POLICY IF EXISTS "sales_insert_own_tenant"  ON public.sales;
DROP POLICY IF EXISTS "sales_update_own_tenant"  ON public.sales;
DROP POLICY IF EXISTS "sales_delete_own_tenant"  ON public.sales;

-- SELECT: Yalnızca kendi işletmesinin satışları
CREATE POLICY "sales_select_own_tenant"
ON public.sales
FOR SELECT
TO authenticated
USING (isletme_id = public.get_my_isletme_id());

-- INSERT: Yalnızca kendi işletmesine satış oluşturabilir
CREATE POLICY "sales_insert_own_tenant"
ON public.sales
FOR INSERT
TO authenticated
WITH CHECK (isletme_id = public.get_my_isletme_id());

-- UPDATE: Yalnızca kendi işletmesinin satışları
CREATE POLICY "sales_update_own_tenant"
ON public.sales
FOR UPDATE
TO authenticated
USING  (isletme_id = public.get_my_isletme_id())
WITH CHECK (isletme_id = public.get_my_isletme_id());

-- DELETE: Yalnızca kendi işletmesinin satışları
CREATE POLICY "sales_delete_own_tenant"
ON public.sales
FOR DELETE
TO authenticated
USING (isletme_id = public.get_my_isletme_id());


-- =============================================================================
-- 5. SALES INSERT TRIGGER — isletme_id ve created_by'ı DB Tarafında Override Et
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_set_sale_tenant_and_creator()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- isletme_id: kullanıcının gerçek işletmesi (override)
  NEW.isletme_id := public.get_my_isletme_id();
  -- created_by: giriş yapan kullanıcı (override — manipülasyon engeli)
  NEW.created_by := auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_sale_tenant_and_creator ON public.sales;

CREATE TRIGGER trg_set_sale_tenant_and_creator
BEFORE INSERT ON public.sales
FOR EACH ROW
EXECUTE FUNCTION public.fn_set_sale_tenant_and_creator();


-- =============================================================================
-- 6. SALE_ITEMS TABLOSU — RLS
-- =============================================================================

ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sale_items_select_own_tenant"  ON public.sale_items;
DROP POLICY IF EXISTS "sale_items_insert_own_tenant"  ON public.sale_items;
DROP POLICY IF EXISTS "sale_items_update_own_tenant"  ON public.sale_items;
DROP POLICY IF EXISTS "sale_items_delete_own_tenant"  ON public.sale_items;

-- SELECT: Yalnızca kendi işletmesinin satış kalemleri
CREATE POLICY "sale_items_select_own_tenant"
ON public.sale_items
FOR SELECT
TO authenticated
USING (isletme_id = public.get_my_isletme_id());

-- INSERT: Yalnızca kendi işletmesine ait satışa kalem ekleyebilir
-- Ek kontrol: sale_id'nin de aynı işletmeye ait olduğu doğrulanır
CREATE POLICY "sale_items_insert_own_tenant"
ON public.sale_items
FOR INSERT
TO authenticated
WITH CHECK (
  isletme_id = public.get_my_isletme_id()
  AND EXISTS (
    SELECT 1 FROM public.sales s
    WHERE s.id = sale_id
      AND s.isletme_id = public.get_my_isletme_id()
  )
);

-- UPDATE: Yalnızca kendi işletmesinin satış kalemleri
CREATE POLICY "sale_items_update_own_tenant"
ON public.sale_items
FOR UPDATE
TO authenticated
USING  (isletme_id = public.get_my_isletme_id())
WITH CHECK (isletme_id = public.get_my_isletme_id());

-- DELETE: Yalnızca kendi işletmesinin satış kalemleri
CREATE POLICY "sale_items_delete_own_tenant"
ON public.sale_items
FOR DELETE
TO authenticated
USING (isletme_id = public.get_my_isletme_id());


-- =============================================================================
-- 7. SALE_ITEMS INSERT TRIGGER — isletme_id'yi DB Tarafında Override Et
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_set_sale_item_isletme_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Bağlı olduğu satışın işletme_id'sini kullan (çapraz işletme erişimi engeli)
  SELECT isletme_id INTO NEW.isletme_id
  FROM public.sales
  WHERE id = NEW.sale_id;

  -- Eğer satış bulunamazsa veya farklı işletmeye aitse reddet
  IF NEW.isletme_id IS NULL OR NEW.isletme_id != public.get_my_isletme_id() THEN
    RAISE EXCEPTION 'Geçersiz satış veya işletme uyuşmazlığı (sale_id=%, tenant=%, my_tenant=%)',
      NEW.sale_id, NEW.isletme_id, public.get_my_isletme_id();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_sale_item_isletme_id ON public.sale_items;

CREATE TRIGGER trg_set_sale_item_isletme_id
BEFORE INSERT ON public.sale_items
FOR EACH ROW
EXECUTE FUNCTION public.fn_set_sale_item_isletme_id();


-- =============================================================================
-- 8. KULLANICILAR — Admin Kendi İşletmesindeki Kullanıcıları Görebilir
-- =============================================================================
-- Mevcut 001 migration'ındaki politikalar korunuyor.
-- Ek politika: Admin kendi işletmesindeki diğer kullanıcıları görebilir
-- (sadece admin rolü için)

DROP POLICY IF EXISTS "Admin kendi isletme kullanicilarini gorebilir" ON public.kullanicilar;

CREATE POLICY "Admin kendi isletme kullanicilarini gorebilir"
ON public.kullanicilar
FOR SELECT
TO authenticated
USING (
  -- Kendi kaydını görebilir (001 migration'ındakiyle örtüşür, OR ile genişletiyoruz)
  auth.uid() = id
  OR
  -- Admin rolündeyse kendi işletmesindeki diğer kullanıcıları da görebilir
  (
    isletme_id = public.get_my_isletme_id()
    AND EXISTS (
      SELECT 1 FROM public.kullanicilar me
      WHERE me.id = auth.uid()
        AND me.rol = 'admin'
    )
  )
);

-- NOT: 001 migration'ındaki "Kullanicilar kendi satirini okuyabilir" policy'si
-- artık bu policy ile kapsandığı için çakışabilir. Güvenle kaldırılabilir:
DROP POLICY IF EXISTS "Kullanicilar kendi satirini okuyabilir" ON public.kullanicilar;


-- =============================================================================
-- 9. ÖZET — Yapılan Değişiklikler
-- =============================================================================
--
-- Tablo              | RLS | SELECT | INSERT | UPDATE | DELETE | Trigger
-- -------------------|-----|--------|--------|--------|--------|--------
-- kullanicilar       | ✅  | ✅     | ❌(*)  | ✅     | ❌(*)  | —
-- products           | ✅  | ✅     | ✅     | ✅     | ✅     | ✅ (isletme_id override)
-- sales              | ✅  | ✅     | ✅     | ✅     | ✅     | ✅ (isletme_id + created_by override)
-- sale_items         | ✅  | ✅     | ✅     | ✅     | ✅     | ✅ (isletme_id, sale kontrol)
--
-- (*) INSERT/DELETE kullanicilar için service_role üzerinden yapılmalı
