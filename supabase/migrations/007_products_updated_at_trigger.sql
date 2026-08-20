-- Trigger function for updated_at
CREATE OR REPLACE FUNCTION public.fn_set_updated_at()
RETURNS TRIGGER 
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to products table
DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;

CREATE TRIGGER trg_products_updated_at
BEFORE UPDATE ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.fn_set_updated_at();

-- Index to optimize incremental sync queries
CREATE INDEX IF NOT EXISTS idx_products_isletme_updated_at ON public.products(isletme_id, updated_at);
