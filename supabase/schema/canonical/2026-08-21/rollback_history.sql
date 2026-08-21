-- Run only in an approved production maintenance window if the history-only reconciliation must be undone.
-- This script changes supabase_migrations metadata only. It does not alter application schema or data.
BEGIN;
DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM supabase_migrations.schema_migrations
    WHERE version = '20260821100000'
  ) THEN
    RAISE EXCEPTION
      'Refusing history-only rollback: P0 authorization migration is recorded as applied';
  END IF;
END
$guard$;

DELETE FROM supabase_migrations.schema_migrations WHERE version = '20260821090000';
INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
VALUES
  ('20260817175921'::text, 'harden_rls_and_user_protection'::text, ARRAY[$history$-- 1) Anonymous clients should not have direct table access.
REVOKE ALL ON TABLE public.isletmeler, public.kullanicilar, public.products, public.sales, public.sale_items FROM anon;

-- 2) These helpers are only meaningful for signed-in users; trigger helpers
-- are not application RPC endpoints at all.
REVOKE EXECUTE ON FUNCTION public.get_kullanici_isletme_id() FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_isletme_id() FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_rol() FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_product_isletme_id() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_sale_item_tenant_data() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_sale_tenant_data() FROM anon, authenticated;

-- 3) Harden the remaining SECURITY DEFINER helper with an explicit search_path.
CREATE OR REPLACE FUNCTION public.get_kullanici_isletme_id()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT k.isletme_id
  FROM public.kullanicilar AS k
  WHERE k.id = auth.uid()
  LIMIT 1;
$$;

-- 4) Protect tenant and role fields on user profiles.
-- A normal user may update their own profile (e.g. sifre_degisti_mi),
-- but cannot promote themselves or move themselves to another business.
CREATE OR REPLACE FUNCTION public.prevent_self_role_or_tenant_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() = OLD.id
     AND (NEW.rol IS DISTINCT FROM OLD.rol
          OR NEW.isletme_id IS DISTINCT FROM OLD.isletme_id)
     AND NOT EXISTS (
       SELECT 1
       FROM public.kullanicilar AS admin_user
       WHERE admin_user.id = auth.uid()
         AND admin_user.rol = 'admin'
     )
  THEN
    RAISE EXCEPTION 'Rol veya isletme_id bu kullanici tarafindan degistirilemez';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_user_role_and_tenant ON public.kullanicilar;
CREATE TRIGGER protect_user_role_and_tenant
BEFORE UPDATE ON public.kullanicilar
FOR EACH ROW
EXECUTE FUNCTION public.prevent_self_role_or_tenant_change();

-- 5) Explicitly define access to the business record.
-- Users can read their own business; only admins can modify/delete it.
DROP POLICY IF EXISTS isletmeler_select_own_business ON public.isletmeler;
CREATE POLICY isletmeler_select_own_business
ON public.isletmeler
FOR SELECT
TO authenticated
USING (id = public.get_my_isletme_id());

DROP POLICY IF EXISTS isletmeler_update_own_business_admin ON public.isletmeler;
CREATE POLICY isletmeler_update_own_business_admin
ON public.isletmeler
FOR UPDATE
TO authenticated
USING (id = public.get_my_isletme_id() AND public.get_my_rol() = 'admin')
WITH CHECK (id = public.get_my_isletme_id());

DROP POLICY IF EXISTS isletmeler_delete_own_business_admin ON public.isletmeler;
CREATE POLICY isletmeler_delete_own_business_admin
ON public.isletmeler
FOR DELETE
TO authenticated
USING (id = public.get_my_isletme_id() AND public.get_my_rol() = 'admin');
$history$]::text[]),
  ('20260817175945'::text, 'close_trigger_rpc_surface'::text, ARRAY[$history$-- Trigger-only functions are not application RPC endpoints.
-- Remove the default PUBLIC/role EXECUTE grants while leaving the
-- database trigger itself able to invoke them.
REVOKE EXECUTE ON FUNCTION public.prevent_self_role_or_tenant_change() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_product_isletme_id() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_sale_item_tenant_data() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_sale_tenant_data() FROM PUBLIC, anon, authenticated;

-- The helper functions are intentionally callable by authenticated users
-- because the existing RLS policies use them to establish tenant scope.
-- They remain SECURITY DEFINER with an explicit empty search_path.$history$]::text[]),
  ('20260817175955'::text, 'restrict_tenant_helper_rpc_execution'::text, ARRAY[$history$-- These helpers are used by authenticated RLS policies, but they should not
-- be callable by anonymous/public API clients.
REVOKE EXECUTE ON FUNCTION public.get_kullanici_isletme_id() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_my_isletme_id() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_my_rol() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kullanici_isletme_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_isletme_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_rol() TO authenticated;$history$]::text[]),
  ('20260817181420'::text, 'move_rls_helpers_to_private_schema_v2'::text, ARRAY[$history$create schema if not exists private;

create or replace function private.get_kullanici_isletme_id()
returns integer language sql stable security definer set search_path = ''
as $$ select k.isletme_id from public.kullanicilar k where k.id = (select auth.uid()) limit 1 $$;
create or replace function private.get_my_isletme_id()
returns integer language sql stable security definer set search_path = ''
as $$ select k.isletme_id from public.kullanicilar k where k.id = (select auth.uid()) limit 1 $$;
create or replace function private.get_my_rol()
returns text language sql stable security definer set search_path = ''
as $$ select k.rol from public.kullanicilar k where k.id = (select auth.uid()) limit 1 $$;

-- Re-point every policy that depended on the public helper functions.
drop policy if exists kullanicilar_select on public.kullanicilar;
drop policy if exists kullanicilar_update on public.kullanicilar;
create policy kullanicilar_select on public.kullanicilar for select to authenticated using (id = (select auth.uid()));
create policy kullanicilar_update on public.kullanicilar for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists isletmeler_select_own_business on public.isletmeler;
drop policy if exists isletmeler_update_own_business_admin on public.isletmeler;
drop policy if exists isletmeler_delete_own_business_admin on public.isletmeler;
create policy isletmeler_select_own_business on public.isletmeler for select to authenticated using (id = (select private.get_my_isletme_id()));
create policy isletmeler_update_own_business_admin on public.isletmeler for update to authenticated using (id = (select private.get_my_isletme_id()) and (select private.get_my_rol()) = 'admin') with check (id = (select private.get_my_isletme_id()));
create policy isletmeler_delete_own_business_admin on public.isletmeler for delete to authenticated using (id = (select private.get_my_isletme_id()) and (select private.get_my_rol()) = 'admin');

-- Keep tenant policies but point them at private helpers.
drop policy if exists products_select_own_business on public.products;
drop policy if exists products_insert_own_business on public.products;
drop policy if exists products_update_own_business on public.products;
drop policy if exists products_delete_own_business on public.products;
create policy products_select_own_business on public.products for select to authenticated using (isletme_id = (select private.get_my_isletme_id()));
create policy products_insert_own_business on public.products for insert to authenticated with check (isletme_id = (select private.get_my_isletme_id()));
create policy products_update_own_business on public.products for update to authenticated using (isletme_id = (select private.get_my_isletme_id())) with check (isletme_id = (select private.get_my_isletme_id()));
create policy products_delete_own_business on public.products for delete to authenticated using (isletme_id = (select private.get_my_isletme_id()));

drop policy if exists sales_select_own_business on public.sales;
drop policy if exists sales_insert_own_business on public.sales;
drop policy if exists sales_update_own_business on public.sales;
drop policy if exists sales_delete_own_business on public.sales;
create policy sales_select_own_business on public.sales for select to authenticated using (isletme_id = (select private.get_my_isletme_id()));
create policy sales_insert_own_business on public.sales for insert to authenticated with check (isletme_id = (select private.get_my_isletme_id()));
create policy sales_update_own_business on public.sales for update to authenticated using (isletme_id = (select private.get_my_isletme_id())) with check (isletme_id = (select private.get_my_isletme_id()));
create policy sales_delete_own_business on public.sales for delete to authenticated using (isletme_id = (select private.get_my_isletme_id()));

drop policy if exists sale_items_select_own_business on public.sale_items;
drop policy if exists sale_items_insert_own_business on public.sale_items;
drop policy if exists sale_items_update_own_business on public.sale_items;
drop policy if exists sale_items_delete_own_business on public.sale_items;
create policy sale_items_select_own_business on public.sale_items for select to authenticated using (isletme_id = (select private.get_my_isletme_id()));
create policy sale_items_insert_own_business on public.sale_items for insert to authenticated with check (isletme_id = (select private.get_my_isletme_id()));
create policy sale_items_update_own_business on public.sale_items for update to authenticated using (isletme_id = (select private.get_my_isletme_id())) with check (isletme_id = (select private.get_my_isletme_id()));
create policy sale_items_delete_own_business on public.sale_items for delete to authenticated using (isletme_id = (select private.get_my_isletme_id()));

-- The old public helper functions are no longer API endpoints.
drop function public.get_kullanici_isletme_id();
drop function public.get_my_isletme_id();
drop function public.get_my_rol();

revoke all on function private.get_kullanici_isletme_id() from public, anon, authenticated;
revoke all on function private.get_my_isletme_id() from public, anon, authenticated;
revoke all on function private.get_my_rol() from public, anon, authenticated;$history$]::text[]),
  ('20260817181445'::text, 'move_trigger_security_functions_private'::text, ARRAY[$history$create schema if not exists private;

create or replace function private.prevent_self_role_or_tenant_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) = old.id
     and (new.rol is distinct from old.rol or new.isletme_id is distinct from old.isletme_id) then
    raise exception 'Rol veya isletme_id bu kullanici tarafindan degistirilemez';
  end if;
  return new;
end;
$$;

create or replace function private.set_product_isletme_id()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  new.isletme_id := (select private.get_my_isletme_id());
  if new.isletme_id is null then raise exception 'Kullanıcının işletmesi bulunamadı'; end if;
  return new;
end;
$$;

create or replace function private.set_sale_tenant_data()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  new.isletme_id := (select private.get_my_isletme_id());
  new.created_by := (select auth.uid());
  if new.isletme_id is null then raise exception 'Kullanıcının işletmesi bulunamadı'; end if;
  if new.created_by is null then raise exception 'Kimliği doğrulanmış kullanıcı bulunamadı'; end if;
  return new;
end;
$$;

create or replace function private.set_sale_item_tenant_data()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare sale_isletme_id integer;
begin
  select s.isletme_id into sale_isletme_id from public.sales s where s.id = new.sale_id limit 1;
  if sale_isletme_id is null then raise exception 'Satış bulunamadı veya satışın işletmesi belirlenemedi'; end if;
  if sale_isletme_id <> (select private.get_my_isletme_id()) then raise exception 'Bu satış başka bir işletmeye ait'; end if;
  new.isletme_id := (select private.get_my_isletme_id());
  return new;
end;
$$;

-- Point existing triggers at private functions.
alter function private.prevent_self_role_or_tenant_change() owner to postgres;
alter function private.set_product_isletme_id() owner to postgres;
alter function private.set_sale_tenant_data() owner to postgres;
alter function private.set_sale_item_tenant_data() owner to postgres;

drop trigger if exists protect_user_role_and_tenant on public.kullanicilar;
create trigger protect_user_role_and_tenant before update on public.kullanicilar for each row execute function private.prevent_self_role_or_tenant_change();
drop trigger if exists set_product_isletme_id_trigger on public.products;
create trigger set_product_isletme_id_trigger before insert on public.products for each row execute function private.set_product_isletme_id();
drop trigger if exists set_sale_tenant_data_trigger on public.sales;
create trigger set_sale_tenant_data_trigger before insert on public.sales for each row execute function private.set_sale_tenant_data();
drop trigger if exists set_sale_item_tenant_data_trigger on public.sale_items;
create trigger set_sale_item_tenant_data_trigger before insert on public.sale_items for each row execute function private.set_sale_item_tenant_data();

drop function public.prevent_self_role_or_tenant_change();
drop function public.set_product_isletme_id();
drop function public.set_sale_tenant_data();
drop function public.set_sale_item_tenant_data();

revoke all on function private.prevent_self_role_or_tenant_change() from public, anon, authenticated;
revoke all on function private.set_product_isletme_id() from public, anon, authenticated;
revoke all on function private.set_sale_tenant_data() from public, anon, authenticated;
revoke all on function private.set_sale_item_tenant_data() from public, anon, authenticated;$history$]::text[]),
  ('20260817181504'::text, 'grant_private_rls_helpers_to_authenticated'::text, ARRAY[$history$grant execute on function private.get_kullanici_isletme_id() to authenticated;
grant execute on function private.get_my_isletme_id() to authenticated;
grant execute on function private.get_my_rol() to authenticated;
revoke execute on function private.prevent_self_role_or_tenant_change() from public, anon, authenticated;
revoke execute on function private.set_product_isletme_id() from public, anon, authenticated;
revoke execute on function private.set_sale_tenant_data() from public, anon, authenticated;
revoke execute on function private.set_sale_item_tenant_data() from public, anon, authenticated;$history$]::text[]),
  ('20260818131542'::text, '003_complete_sale_rpc'::text, ARRAY[$history$CREATE OR REPLACE FUNCTION public.complete_sale(
    p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id      uuid;
    v_isletme_id   integer;
    v_item         jsonb;
    v_product_id   uuid;
    v_quantity     integer;
    v_locked_count integer;
    v_item_count   integer;
    v_product_rec  record;
    v_total_amount numeric(12, 2) := 0;
    v_sale_id      uuid;
BEGIN

    -- ================================================================
    -- 1. Kimlik doğrulama
    -- ================================================================
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'SATIS_HATA:KIMLIK_DOGRULANAMADI'
            USING DETAIL = 'auth.uid() NULL döndü -- oturum geçersiz';
    END IF;


    -- ================================================================
    -- 2. Kullanıcının işletmesini belirle
    -- ================================================================
    SELECT isletme_id
      INTO v_isletme_id
      FROM public.kullanicilar
     WHERE id = v_user_id;

    IF v_isletme_id IS NULL THEN
        RAISE EXCEPTION 'SATIS_HATA:ISLETME_BULUNAMADI'
            USING DETAIL = 'Kullanıcı geçerli bir işletmeye bağlı değil';
    END IF;


    -- ================================================================
    -- 3. Input validasyonu
    -- ================================================================

    IF p_items IS NULL
       OR jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) = 0
    THEN
        RAISE EXCEPTION 'SATIS_HATA:SEPET_BOS'
            USING DETAIL = 'Sepet boş veya geçersiz';
    END IF;

    v_item_count := jsonb_array_length(p_items);


    -- Her ürün için product_id ve quantity kontrolü
    FOR v_item IN
        SELECT *
        FROM jsonb_array_elements(p_items)
    LOOP

        IF (v_item->>'product_id') IS NULL THEN
            RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_URUN_ID'
                USING DETAIL = 'product_id eksik: ' || v_item::text;
        END IF;

        BEGIN
            v_product_id := (v_item->>'product_id')::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_UUID_FORMAT'
                    USING DETAIL =
                        'Geçersiz product_id formatı: '
                        || (v_item->>'product_id');
        END;

        IF (v_item->>'quantity') IS NULL THEN
            RAISE EXCEPTION 'SATIS_HATA:QUANTITY_EKSIK'
                USING DETAIL = 'quantity eksik: ' || v_item::text;
        END IF;

        BEGIN
            v_quantity := (v_item->>'quantity')::integer;
        EXCEPTION
            WHEN invalid_text_representation THEN
                RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_MIKTAR'
                    USING DETAIL =
                        'quantity integer olmalı: '
                        || (v_item->>'quantity');
        END;

        IF v_quantity <= 0 THEN
            RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_MIKTAR'
                USING DETAIL =
                    'quantity 0 veya negatif olamaz -- product_id='
                    || (v_item->>'product_id')
                    || ', quantity='
                    || v_quantity;
        END IF;

    END LOOP;


    -- ================================================================
    -- 4. Duplicate product_id kontrolü
    -- ================================================================
    IF (
        SELECT COUNT(DISTINCT elem->>'product_id')
        FROM jsonb_array_elements(p_items) AS elem
    ) <> v_item_count THEN

        RAISE EXCEPTION 'SATIS_HATA:TEKRAR_URUN_ID'
            USING DETAIL =
                'Aynı product_id birden fazla kez gönderildi';
    END IF;


    -- ================================================================
    -- 5. Ürünleri kilitle
    -- ================================================================
    PERFORM p.id
      FROM public.products AS p
     WHERE p.id IN (
         SELECT (elem->>'product_id')::uuid
         FROM jsonb_array_elements(p_items) AS elem
     )
       AND p.isletme_id = v_isletme_id
     ORDER BY p.id
     FOR UPDATE;


    -- ================================================================
    -- 6. Bütün ürünlerin mevcut ve aynı tenant'a ait olduğunu doğrula
    -- ================================================================
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
            USING DETAIL =
                'Bazı ürünler bu işletmeye ait değil veya mevcut değil -- '
                || 'beklenen=' || v_item_count
                || ', bulunan=' || v_locked_count;
    END IF;


    -- ================================================================
    -- 7. Stok ve fiyat kontrolü
    -- ================================================================
    FOR v_item IN
        SELECT *
        FROM jsonb_array_elements(p_items)
    LOOP

        v_product_id := (v_item->>'product_id')::uuid;
        v_quantity   := (v_item->>'quantity')::integer;

        SELECT id, name, price, stock
          INTO v_product_rec
          FROM public.products
         WHERE id = v_product_id
           AND isletme_id = v_isletme_id;

        IF v_product_rec.price < 0 THEN
            RAISE EXCEPTION 'SATIS_HATA:GECERSIZ_FIYAT'
                USING DETAIL =
                    'Ürün fiyatı negatif olamaz -- product_id='
                    || v_product_id;
        END IF;

        IF v_product_rec.stock < v_quantity THEN
            RAISE EXCEPTION 'SATIS_HATA:YETERSIZ_STOK'
                USING DETAIL =
                    'Yetersiz stok -- ürün='
                    || v_product_rec.name
                    || ', mevcut='
                    || v_product_rec.stock
                    || ', istenen='
                    || v_quantity;
        END IF;

        v_total_amount :=
            v_total_amount
            + (v_product_rec.price * v_quantity);

    END LOOP;


    -- ================================================================
    -- 8. Sales kaydı
    -- ================================================================
    INSERT INTO public.sales (
        total_amount,
        isletme_id,
        created_by
    )
    VALUES (
        v_total_amount,
        v_isletme_id,
        v_user_id
    )
    RETURNING id INTO v_sale_id;


    -- ================================================================
    -- 9. Sale items
    -- ================================================================
    FOR v_item IN
        SELECT *
        FROM jsonb_array_elements(p_items)
    LOOP

        v_product_id := (v_item->>'product_id')::uuid;
        v_quantity   := (v_item->>'quantity')::integer;

        INSERT INTO public.sale_items (
            sale_id,
            product_id,
            quantity,
            unit_price,
            isletme_id
        )
        SELECT
            v_sale_id,
            p.id,
            v_quantity,
            p.price,
            p.isletme_id
        FROM public.products AS p
        WHERE p.id = v_product_id
          AND p.isletme_id = v_isletme_id;

    END LOOP;


    -- ================================================================
    -- 10. Stokları düşür
    -- ================================================================
    UPDATE public.products AS p
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


    -- ================================================================
    -- 11. Sonucu döndür
    -- ================================================================
    RETURN jsonb_build_object(
        'sale_id',      v_sale_id,
        'total_amount', v_total_amount,
        'isletme_id',   v_isletme_id
    );

END;
$$;


-- ================================================================
-- Yetki yönetimi
-- ================================================================

REVOKE ALL
ON FUNCTION public.complete_sale(jsonb)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.complete_sale(jsonb)
TO authenticated;$history$]::text[]),
  ('20260818132659'::text, '004_revoke_anon_complete_sale_execute'::text, ARRAY[$history$REVOKE EXECUTE ON FUNCTION public.complete_sale(jsonb) FROM anon;$history$]::text[])
ON CONFLICT (version) DO UPDATE
SET name = EXCLUDED.name,
    statements = EXCLUDED.statements;
COMMIT;
