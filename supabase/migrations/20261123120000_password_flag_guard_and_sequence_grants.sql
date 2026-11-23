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
-- NOT: Yerel PostgreSQL 17 + Supabase taklidi (supabase/tests/local) ile tüm
-- migration zinciri üzerinde çalıştırıldı ve 01/02/03 testleri geçti. Taklit
-- tam bir Supabase değildir; canlıya almadan önce scratch Supabase projesinde
-- de uygulayıp 03_password_flag_guard.test.sql ile doğrulayın.

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

-- Anlık görüntü YALNIZCA şu anlarda alınır: yeni kullanıcı (bayrak false) ve
-- bayrağın true -> false sıfırlanması (admin reseti). false -> false gibi
-- değişmeyen yazımlar anlık görüntüyü yenilemez; yenilerse kullanıcının
-- az önce değiştirdiği şifre "geçici şifre" sanılır ve onayı reddedilirdi.
CREATE OR REPLACE FUNCTION private.capture_password_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'UPDATE'
     and coalesce(old.sifre_degisti_mi, false)
         = coalesce(new.sifre_degisti_mi, false) then
    return new;
  end if;

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
  found_snapshot boolean;
begin
  if (select auth.uid()) = old.id
     and coalesce(old.sifre_degisti_mi, false) = false
     and new.sifre_degisti_mi = true then

    select p.password_hash_snapshot into v_snapshot
      from private.pending_password_change p
     where p.user_id = old.id;
    found_snapshot := found;

    select u.encrypted_password into v_current
      from auth.users u
     where u.id = old.id;

    -- Anlık görüntü satırı yoksa: şifrenin değiştiği kanıtlanamaz, reddet.
    if not found_snapshot then
      raise exception 'SIFRE_HATA:SIFRE_DEGISMEDI'
        using hint = 'Önce şifrenizi değiştirin.';
    end if;

    -- Görüntü NULL ise (hesabın başta şifresi yoktu) yeni bir şifre
    -- belirlenmiş olması yeterli; değilse özet değişmiş olmalı.
    if v_current is null
       or (v_snapshot is not null and v_current = v_snapshot) then
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

-- Mevcut kullanıcılar için backfill — trigger'lar KURULDUKTAN SONRA ve tablo
-- kilitliyken yapılır; arada eklenen bir profil anlık görüntüsüz kalmaz.
LOCK TABLE public.kullanicilar IN SHARE ROW EXCLUSIVE MODE;

INSERT INTO private.pending_password_change (user_id, password_hash_snapshot)
SELECT k.id, u.encrypted_password
  FROM public.kullanicilar k
  JOIN auth.users u ON u.id = k.id
 WHERE coalesce(k.sifre_degisti_mi, false) = false
ON CONFLICT (user_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Sequence yetkileri
-- ---------------------------------------------------------------------------

REVOKE ALL ON SEQUENCE public.isletmeler_id_seq FROM PUBLIC, anon, authenticated;
