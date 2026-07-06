ALTER TABLE std_purchase_orders
ADD COLUMN IF NOT EXISTS vendor TEXT;

ALTER TABLE std_purchase_orders
ADD COLUMN IF NOT EXISTS items JSONB DEFAULT '[]'::jsonb;
