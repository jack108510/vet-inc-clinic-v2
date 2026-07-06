ALTER TABLE std_purchase_orders
ADD COLUMN IF NOT EXISTS order_id TEXT;

CREATE INDEX IF NOT EXISTS idx_po_clinic_date
  ON std_purchase_orders(clinic_id, order_date);
