-- =============================================================================
-- 006_secure_complete_sale_cleanup.sql
-- 
-- 1. Kullanilmayan eski complete_sale(jsonb) overload'ini kaldirir.
-- 2. Guncel complete_sale(jsonb, text) fonksiyonunun erisim haklarini (GRANT/REVOKE) 
--    anonim kullanicilardan temizler, sadece authenticated kullanicilara acar.
-- 3. Guncel fonksiyon icin guvenlik (search_path) ayarlarini garanti altina alir.
-- =============================================================================

-- 1. ESKI OVERLOAD TEMIZLIGI
-- Uygulama artik idempotency destegi (text parametresi) olan versiyonu kullaniyor.
-- Hata ve belirsizligi onlemek icin eski versiyonu kaldiriyoruz.
DROP FUNCTION IF EXISTS public.complete_sale(jsonb);

-- 2. YETKILENDIRME (GRANT / REVOKE)
-- Satis islemi kesinlikle anonim erisime kapali olmalidir.
REVOKE ALL ON FUNCTION public.complete_sale(jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_sale(jsonb, text) FROM anon;

-- Sadece kimligi dogrulanmis (authenticated) kullanicilar cagirabilir.
GRANT EXECUTE ON FUNCTION public.complete_sale(jsonb, text) TO authenticated;

-- Supabase servis rolu icin erisim ver (maintenance/cron vb. islemler icin iyi bir pratiktir)
GRANT EXECUTE ON FUNCTION public.complete_sale(jsonb, text) TO service_role;

-- 3. SEARCH_PATH GUVENLIGI
-- Fonksiyon SECURITY DEFINER oldugundan search_path hijacking'e karsi korunmalidir.
-- (Guncel fonksiyonda baslangicta vardi ancak tekrar garanti altina aliyoruz)
ALTER FUNCTION public.complete_sale(jsonb, text) SET search_path = '';
