-- kullanicilar tablosu RLS politikaları
-- Supabase Dashboard > SQL Editor'de çalıştırın veya supabase db push ile uygulayın.
--
-- ÖNEMLİ: kullanicilar.id sütunu, auth.users.id ile birebir eşleşmelidir.
-- Admin tarafından kullanıcı oluşturulurken auth.users kaydı oluşturulduktan sonra
-- aynı UUID ile kullanicilar satırı eklenmelidir.

-- RLS'yi etkinleştir
ALTER TABLE public.kullanicilar ENABLE ROW LEVEL SECURITY;

-- Eski politikalar varsa temizle (isteğe bağlı — isimler farklıysa uyarlayın)
DROP POLICY IF EXISTS "Kullanicilar kendi satirini okuyabilir" ON public.kullanicilar;
DROP POLICY IF EXISTS "Kullanicilar kendi satirini guncelleyebilir" ON public.kullanicilar;

-- Giriş yapan kullanıcı kendi satırını okuyabilir (SELECT)
CREATE POLICY "Kullanicilar kendi satirini okuyabilir"
ON public.kullanicilar
FOR SELECT
TO authenticated
USING (auth.uid() = id);

-- Giriş yapan kullanıcı kendi satırını güncelleyebilir (UPDATE — sifre_degisti_mi vb.)
CREATE POLICY "Kullanicilar kendi satirini guncelleyebilir"
ON public.kullanicilar
FOR UPDATE
TO authenticated
USING (auth.uid() = id)
WITH CHECK (auth.uid() = id);

-- NOT: INSERT ve DELETE politikaları kasıtlı olarak eklenmedi.
-- Yeni kullanıcı kayıtları service_role veya admin paneli üzerinden oluşturulmalıdır.
