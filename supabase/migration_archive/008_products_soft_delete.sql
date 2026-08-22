-- Add deleted_at column for soft delete support
ALTER TABLE public.products
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ NULL DEFAULT NULL;

-- Index for active products (fast lookup for normal POS operations)
CREATE INDEX IF NOT EXISTS idx_products_active ON public.products(isletme_id) WHERE deleted_at IS NULL;

-- Index for deleted products (optimizes sync for recently deleted items)
CREATE INDEX IF NOT EXISTS idx_products_sync_deleted ON public.products(isletme_id, updated_at) WHERE deleted_at IS NOT NULL;
