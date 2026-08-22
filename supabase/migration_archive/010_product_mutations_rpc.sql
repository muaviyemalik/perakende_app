-- 1. Idempotency tablosunu oluştur
CREATE TABLE IF NOT EXISTS public.mutation_idempotency (
    idempotency_key UUID PRIMARY KEY,
    isletme_id INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS for idempotency
ALTER TABLE public.mutation_idempotency ENABLE ROW LEVEL SECURITY;

-- Kullanıcı sadece kendi işletmesine ait idempotency kayıtlarını ekleyebilir
CREATE POLICY "Allow authenticated to insert idempotency"
    ON public.mutation_idempotency FOR INSERT
    TO authenticated
    WITH CHECK (isletme_id = (SELECT isletme_id FROM public.kullanicilar WHERE id = auth.uid()));

-- Kullanıcı sadece kendi işletmesine ait idempotency kayıtlarını görebilir
CREATE POLICY "Allow authenticated to select idempotency"
    ON public.mutation_idempotency FOR SELECT
    TO authenticated
    USING (isletme_id = (SELECT isletme_id FROM public.kullanicilar WHERE id = auth.uid()));


-- 2. process_product_mutation RPC'si
CREATE OR REPLACE FUNCTION public.process_product_mutation(
    p_idempotency_key UUID,
    p_isletme_id INT,
    p_operation_type TEXT,
    p_product_id UUID,
    p_payload JSONB,
    p_base_updated_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_user_isletme_id INT;
    v_current_updated_at TIMESTAMPTZ;
BEGIN
    -- 1. Tenant & Auth Kontrolü (GÜVENLİK: İLK ADIMDA YAPILMALI)
    -- Kullanıcının işletme ID'si ile mutasyonun işletme ID'si eşleşiyor mu?
    SELECT isletme_id INTO v_user_isletme_id
    FROM public.kullanicilar
    WHERE id = auth.uid();

    IF v_user_isletme_id IS NULL OR v_user_isletme_id != p_isletme_id THEN
        RAISE EXCEPTION 'TENANT_MISMATCH';
    END IF;

    -- 2. Idempotency Kontrolü
    -- Yalnızca auth başarılı ise ve doğru tenant için işlem yapılıyorsa eklenir.
    INSERT INTO public.mutation_idempotency (idempotency_key, isletme_id)
    VALUES (p_idempotency_key, p_isletme_id)
    ON CONFLICT (idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'IDEMPOTENT_TEKRAR');
    END IF;

    -- 3. Operation Types
    IF p_operation_type = 'CREATE' THEN
        INSERT INTO public.products (
            id, isletme_id, name, price, stock, barcode, updated_at
        ) VALUES (
            p_product_id,
            p_isletme_id,
            p_payload->>'name',
            CAST(p_payload->>'price' AS NUMERIC),
            CAST(p_payload->>'stock' AS INT),
            p_payload->>'barcode',
            NOW()
        );
        
        RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'CREATE');

    ELSIF p_operation_type = 'UPDATE' THEN
        -- Optimistic Concurrency Control
        SELECT updated_at INTO v_current_updated_at
        FROM public.products
        WHERE id = p_product_id AND isletme_id = p_isletme_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
        END IF;

        IF v_current_updated_at > p_base_updated_at THEN
            RAISE EXCEPTION 'CONFLICT_DETECTED';
        END IF;

        UPDATE public.products
        SET 
            name = COALESCE(p_payload->>'name', name),
            price = COALESCE(CAST(p_payload->>'price' AS NUMERIC), price),
            stock = COALESCE(CAST(p_payload->>'stock' AS INT), stock),
            barcode = CASE WHEN p_payload ? 'barcode' THEN p_payload->>'barcode' ELSE barcode END,
            updated_at = NOW()
        WHERE id = p_product_id AND isletme_id = p_isletme_id;

        RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'UPDATE');

    ELSIF p_operation_type = 'DELETE' THEN
        -- Optimistic Concurrency Control
        SELECT updated_at INTO v_current_updated_at
        FROM public.products
        WHERE id = p_product_id AND isletme_id = p_isletme_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'DELETE_ALREADY_GONE');
        END IF;

        IF v_current_updated_at > p_base_updated_at THEN
            RAISE EXCEPTION 'CONFLICT_DETECTED';
        END IF;

        UPDATE public.products
        SET deleted_at = NOW(),
            updated_at = NOW()
        WHERE id = p_product_id AND isletme_id = p_isletme_id;

        RETURN jsonb_build_object('status', 'SUCCESS', 'operation', 'DELETE');
    ELSE
        RAISE EXCEPTION 'INVALID_OPERATION_TYPE';
    END IF;
END;
$$;
