-- Forward-only hardening, after 20260821100000_p0_authorization_hardening.sql.
--
-- 1. Zorunlu şifre değişimi sunucuda uygulanır.
--    Eskiden kullanıcı kendi kullanicilar satırını güncelleyebildiği için,
--    şifresini HİÇ değiştirmeden `sifre_degisti_mi = true` yazarak zorunlu
--    şifre ekranını atlayabiliyordu. Artık bayrak false -> true ancak
--    auth.users.encrypted_password, bayrak false iken alınan anlık görüntüden
--    farklıysa (yani şifre gerçekten değiştiyse) kabul edilir.
--    Uygulama akışı değişmez: önce auth.updateUser(password), sonra bayrak.
--
-- 2. İstemci rollerinin işletme sequence'i üzerindeki gereksiz yetkileri
--    kaldırılır. isletmeler INSERT yetkisi P0'da zaten kaldırılmıştı;
--    anon/authenticated için nextval/setval'e ihtiyaç yoktur.
--
-- NOT: Bu dosya yerel olarak çalıştırılıp test EDİLMEDİ (Supabase CLI/Docker
-- yok). Önce scratch projede uygulayıp
-- supabase/tests/database/03_password_flag_guard.test.sql ile doğrulayın.

-- ---------------------------------------------------------------------------
-- 1. Şifre bayrağı koruması
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.pending_password_change (
  user_id uuid PRIMARY KEY,
  password_hash_snapshot text,
  captured_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.pending_password_change OWNER TO postgres;
REVOKE ALL ON TABLE private.pending_password_change
  FROM PUBLIC, anon, authenticated;

-- Bayrağı false olan mevcut kullanıcılar için şu anki şifre özetini sakla.
INSERT INTO private.pending_password_change (user_id, password_hash_snapshot)
SELECT k.id, u.encrypted_password
  FROM public.kullanicilar k
  JOIN auth.users u ON u.id = k.id
 WHERE coalesce(k.sifre_degisti_mi, false) = false
ON CONFLICT (user_id) DO UPDATE
  SET password_hash_snapshot = EXCLUDED.password_hash_snapshot,
      captured_at = now();

-- Bayrak false olduğunda (yeni kullanıcı / admin sıfırlaması) anlık görüntü al.
CREATE OR REPLACE FUNCTION private.capture_password_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if coalesce(new.sifre_degisti_mi, false) = false then
    insert into private.pending_password_change (user_id, password_hash_snapshot)
    select new.id, u.encrypted_password
      from auth.users u
     where u.id = new.id
    on conflict (user_id) do update
      set password_hash_snapshot = excluded.password_hash_snapshot,
          captured_at = now();
  else
    delete from private.pending_password_change where user_id = new.id;
  end if;
  return new;
end;
$function$;
ALTER FUNCTION private.capture_password_snapshot() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.capture_password_snapshot()
  FROM PUBLIC, anon, authenticated;

-- Kullanıcı kendi bayrağını ancak şifresi gerçekten değiştiyse true yapabilir.
-- service_role / admin işlemleri (auth.uid() farklı veya null) etkilenmez.
CREATE OR REPLACE FUNCTION private.guard_password_changed_flag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_snapshot text;
  v_current text;
begin
  if (select auth.uid()) = old.id
     and coalesce(old.sifre_degisti_mi, false) = false
     and new.sifre_degisti_mi = true then

    select p.password_hash_snapshot into v_snapshot
      from private.pending_password_change p
     where p.user_id = old.id;

    select u.encrypted_password into v_current
      from auth.users u
     where u.id = old.id;

    -- Anlık görüntü yoksa ya da şifre özeti değişmediyse reddet.
    if v_snapshot is null or v_current is null
       or v_current = v_snapshot then
      raise exception 'SIFRE_HATA:SIFRE_DEGISMEDI'
        using hint = 'Önce şifrenizi değiştirin.';
    end if;
  end if;
  return new;
end;
$function$;
ALTER FUNCTION private.guard_password_changed_flag() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.guard_password_changed_flag()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guard_password_changed_flag ON public.kullanicilar;
CREATE TRIGGER guard_password_changed_flag
  BEFORE UPDATE OF sifre_degisti_mi ON public.kullanicilar
  FOR EACH ROW EXECUTE FUNCTION private.guard_password_changed_flag();

DROP TRIGGER IF EXISTS capture_password_snapshot ON public.kullanicilar;
CREATE TRIGGER capture_password_snapshot
  AFTER INSERT OR UPDATE OF sifre_degisti_mi ON public.kullanicilar
  FOR EACH ROW EXECUTE FUNCTION private.capture_password_snapshot();

-- ---------------------------------------------------------------------------
-- 2. Sequence yetkileri
-- ---------------------------------------------------------------------------

REVOKE ALL ON SEQUENCE public.isletmeler_id_seq FROM PUBLIC, anon, authenticated;
