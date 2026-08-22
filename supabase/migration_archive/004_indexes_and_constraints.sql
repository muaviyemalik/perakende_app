-- =============================================================================
-- 004_indexes_and_constraints.sql
-- Performance indeksleri ve veri bütünlüğü kısıtlamaları
--
-- AMAÇ:
--   1. Foreign key kolonlarına covering index ekleyerek JOIN/WHERE performansını
--      artırmak ve Supabase Performance Advisor uyarılarını çözmek.
--   2. CHECK constraint'leri ile negatif fiyat, negatif stok ve geçersiz miktar
--      gibi mantık dışı verilerin tablolara yazılmasını DB seviyesinde engellemek.
--
-- GÜVENLİK:
--   • CREATE INDEX IF NOT EXISTS — mevcut indeks varsa atlanır, canlı DB bozulmaz.
--   • ALTER TABLE ... ADD CONSTRAINT ... NOT VALID + VALIDATE — mevcut veriler
--     tablo kilidi olmadan (AccessExclusiveLock almadan) doğrulanır.
--     Yeni satırlar anında kontrol altına alınır.
--
-- ÇALIŞTIRMA:
--   Supabase Dashboard > SQL Editor'de bu dosyanın tamamını çalıştırın.
--   Proje ID: vnvifxvtutlbivsegjtp
-- =============================================================================


-- =============================================================================
-- 1. FOREIGN KEY İNDEKSLERİ
-- =============================================================================
-- Supabase Performance Advisor: "Missing index on FK column" uyarıları.
-- Bu indeksler olmadan FK kolonlarındaki JOIN ve RLS WHERE filtreleri
-- sequential scan yapar — büyüyen tablolarda ciddi performans kaybına yol açar.
--
-- IF NOT EXISTS: Halihazırda indeks varsa hata vermez, sessizce atlar.
-- =============================================================================

-- kullanicilar.isletme_id
-- Kullanım: get_my_isletme_id() helper fonksiyonu, RLS subquery'leri,
--           complete_sale RPC (ADIM 2: isletme_id belirleme)
CREATE INDEX IF NOT EXISTS idx_kullanicilar_isletme_id
    ON public.kullanicilar (isletme_id);

-- products.isletme_id
-- Kullanım: RLS politikaları (products_select_own_tenant vb.),
--           complete_sale RPC (ADIM 4-9: ürün kilitleme, stok kontrolü, güncelleme),
--           Flutter getProductsSmart() sorgusu
CREATE INDEX IF NOT EXISTS idx_products_isletme_id
    ON public.products (isletme_id);

-- sales.isletme_id
-- Kullanım: RLS politikaları (sales_select_own_tenant vb.),
--           dashboard istatistik sorguları
CREATE INDEX IF NOT EXISTS idx_sales_isletme_id
    ON public.sales (isletme_id);

-- sale_items.isletme_id
-- Kullanım: RLS politikaları (sale_items_select_own_tenant vb.)
CREATE INDEX IF NOT EXISTS idx_sale_items_isletme_id
    ON public.sale_items (isletme_id);

-- sale_items.product_id
-- Kullanım: Ürün bazlı satış raporları, JOIN products ON sale_items.product_id
CREATE INDEX IF NOT EXISTS idx_sale_items_product_id
    ON public.sale_items (product_id);

-- sale_items.sale_id
-- Kullanım: Satış detay görüntüleme, JOIN sales ON sale_items.sale_id
CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id
    ON public.sale_items (sale_id);


-- =============================================================================
-- 2. CHECK CONSTRAINTS — products tablosu
-- =============================================================================
-- Negatif fiyat ve negatif stok, iş kuralları açısından geçersizdir.
-- complete_sale RPC zaten stok ve fiyat kontrolü yapıyor, ancak doğrudan
-- INSERT/UPDATE (admin paneli, service_role) yollarını da kapamak için
-- DB seviyesinde kısıtlama şarttır.
--
-- NOT VALID + VALIDATE CONSTRAINT stratejisi:
--   1. ADD CONSTRAINT ... NOT VALID  → Yeni satırları anında kontrol altına alır,
--      mevcut verilere dokunmaz, tablo kilidi kısa sürer.
--   2. VALIDATE CONSTRAINT           → Mevcut verileri arka planda doğrular,
--      ShareUpdateExclusiveLock ile yazma işlemlerini engellemez.
--   Bu iki adımlı yaklaşım canlı veritabanında downtime'ı sıfıra indirir.
-- =============================================================================

-- products.price >= 0
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_products_price_non_negative'
          AND conrelid = 'public.products'::regclass
    ) THEN
        ALTER TABLE public.products
            ADD CONSTRAINT chk_products_price_non_negative
            CHECK (price >= 0)
            NOT VALID;
    END IF;
END $$;

ALTER TABLE public.products
    VALIDATE CONSTRAINT chk_products_price_non_negative;

-- products.stock >= 0
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_products_stock_non_negative'
          AND conrelid = 'public.products'::regclass
    ) THEN
        ALTER TABLE public.products
            ADD CONSTRAINT chk_products_stock_non_negative
            CHECK (stock >= 0)
            NOT VALID;
    END IF;
END $$;

ALTER TABLE public.products
    VALIDATE CONSTRAINT chk_products_stock_non_negative;


-- =============================================================================
-- 3. CHECK CONSTRAINTS — sale_items tablosu
-- =============================================================================
-- quantity > 0: Sıfır veya negatif adetli satış kalemi mantıksal olarak geçersiz.
-- unit_price >= 0: Negatif birim fiyat geçersiz.
-- complete_sale RPC bu kontrolleri zaten yapıyor, ancak service_role veya
-- doğrudan SQL ile yapılan eklemeleri de koruma altına almak gerekir.
-- =============================================================================

-- sale_items.quantity > 0
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_sale_items_quantity_positive'
          AND conrelid = 'public.sale_items'::regclass
    ) THEN
        ALTER TABLE public.sale_items
            ADD CONSTRAINT chk_sale_items_quantity_positive
            CHECK (quantity > 0)
            NOT VALID;
    END IF;
END $$;

ALTER TABLE public.sale_items
    VALIDATE CONSTRAINT chk_sale_items_quantity_positive;

-- sale_items.unit_price >= 0
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_sale_items_unit_price_non_negative'
          AND conrelid = 'public.sale_items'::regclass
    ) THEN
        ALTER TABLE public.sale_items
            ADD CONSTRAINT chk_sale_items_unit_price_non_negative
            CHECK (unit_price >= 0)
            NOT VALID;
    END IF;
END $$;

ALTER TABLE public.sale_items
    VALIDATE CONSTRAINT chk_sale_items_unit_price_non_negative;
