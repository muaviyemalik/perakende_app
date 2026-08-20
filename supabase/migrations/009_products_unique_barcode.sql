-- =============================================================================
-- 009_products_unique_barcode.sql
-- Barkod verisi için Tenant bazlı UNIQUE constraint
--
-- AMAÇ:
--   - Aynı işletmede (isletme_id) aynı barkoda (barcode) sahip birden fazla
--     aktif ürün olmasını engellemek.
--   - Barkodu boş (NULL) olan ürünlerin eklenmesine izin vermek.
--   - Soft-delete (deleted_at IS NOT NULL) edilmiş kopya barkodlara izin vermek.
--
-- GÜVENLİK:
--   - UNIQUE Index eklenmeden önce mevcut veritabanında bu kuralı ihlal eden
--     (duplicate) kayıtlar varsa, en güncel olanı tutulup diğerleri
--     soft-delete ile işaretlenir (veri bütünlüğü / deduplication).
-- =============================================================================

DO $$
BEGIN
    -- 1. ADIM: Mevcut duplicate kayıtları tespit et ve eski olanları soft-delete yap
    -- Aynı isletme_id ve barcode değerine sahip aktif kayıtlardan,
    -- updated_at değeri en yüksek olan (veya id'si en büyük olan) hariç diğerlerini siliyoruz.
    
    WITH RankedDuplicates AS (
        SELECT id,
               ROW_NUMBER() OVER (
                   PARTITION BY isletme_id, barcode 
                   ORDER BY updated_at DESC, id DESC
               ) as rn
        FROM public.products
        WHERE barcode IS NOT NULL AND deleted_at IS NULL
    )
    UPDATE public.products
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id IN (
        SELECT id 
        FROM RankedDuplicates 
        WHERE rn > 1
    );

END $$;

-- 2. ADIM: Partial Unique Index oluştur
-- WHERE barcode IS NOT NULL AND deleted_at IS NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_unique_barcode
    ON public.products (isletme_id, barcode)
    WHERE barcode IS NOT NULL AND deleted_at IS NULL;
