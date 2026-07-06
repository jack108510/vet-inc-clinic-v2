CREATE TABLE IF NOT EXISTS std_purchase_order_lines (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL REFERENCES std_clinics(clinic_id),
  purchase_order_id BIGINT REFERENCES std_purchase_orders(id) ON DELETE SET NULL,
  order_id TEXT,
  line_num INTEGER,
  order_date DATE,
  vendor TEXT,
  raw_item_code TEXT,
  raw_item_name TEXT,
  matched_product_code TEXT,
  matched_product_name TEXT,
  raw_uom TEXT,
  normalized_uom TEXT,
  qty_raw NUMERIC(14,4),
  qty_normalized NUMERIC(14,4),
  unit_cost_raw NUMERIC(12,4),
  unit_cost_normalized NUMERIC(12,4),
  line_cost NUMERIC(12,2),
  pack_size NUMERIC(14,4),
  dosage_form TEXT,
  normalization_status TEXT NOT NULL DEFAULT 'unreviewed'
    CHECK (normalization_status IN ('unreviewed','clean','conversion_needed','legacy_unmatched','excluded')),
  normalization_notes TEXT,
  source_row_ref TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_po_lines_clinic_date
  ON std_purchase_order_lines(clinic_id, order_date);

CREATE INDEX IF NOT EXISTS idx_po_lines_clinic_status
  ON std_purchase_order_lines(clinic_id, normalization_status);

CREATE INDEX IF NOT EXISTS idx_po_lines_clinic_match_code
  ON std_purchase_order_lines(clinic_id, matched_product_code);

CREATE TABLE IF NOT EXISTS std_inventory_movements (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL REFERENCES std_clinics(clinic_id),
  movement_date DATE NOT NULL,
  product_code TEXT,
  product_name TEXT,
  movement_type TEXT NOT NULL
    CHECK (movement_type IN ('receipt','invoice_dispense','internal_use','waste','return_to_vendor','adjustment','opening_balance')),
  direction TEXT NOT NULL
    CHECK (direction IN ('in','out')),
  quantity NUMERIC(14,4),
  uom TEXT,
  unit_cost NUMERIC(12,4),
  unit_price NUMERIC(12,4),
  total_cost NUMERIC(12,2),
  total_value NUMERIC(12,2),
  source_table TEXT,
  source_id TEXT,
  source_line_id BIGINT REFERENCES std_purchase_order_lines(id) ON DELETE SET NULL,
  confidence TEXT NOT NULL DEFAULT 'raw'
    CHECK (confidence IN ('raw','estimated','normalized','verified')),
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_inv_moves_clinic_date
  ON std_inventory_movements(clinic_id, movement_date);

CREATE INDEX IF NOT EXISTS idx_inv_moves_clinic_product
  ON std_inventory_movements(clinic_id, product_code);

ALTER TABLE std_purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE std_purchase_order_lines FORCE ROW LEVEL SECURITY;
ALTER TABLE std_inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE std_inventory_movements FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'std_purchase_order_lines'
      AND policyname = 'users_read_own_clinic'
  ) THEN
    CREATE POLICY "users_read_own_clinic" ON std_purchase_order_lines
      FOR SELECT USING (clinic_id IN (SELECT public.clinic_ids()));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'std_purchase_order_lines'
      AND policyname = 'users_write_own_clinic'
  ) THEN
    CREATE POLICY "users_write_own_clinic" ON std_purchase_order_lines
      FOR ALL USING (
        clinic_id IN (SELECT public.clinic_ids())
        AND public.clinic_role(clinic_id) IN ('editor','admin','superadmin')
      ) WITH CHECK (
        clinic_id IN (SELECT public.clinic_ids())
        AND public.clinic_role(clinic_id) IN ('editor','admin','superadmin')
      );
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'std_inventory_movements'
      AND policyname = 'users_read_own_clinic'
  ) THEN
    CREATE POLICY "users_read_own_clinic" ON std_inventory_movements
      FOR SELECT USING (clinic_id IN (SELECT public.clinic_ids()));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'std_inventory_movements'
      AND policyname = 'users_write_own_clinic'
  ) THEN
    CREATE POLICY "users_write_own_clinic" ON std_inventory_movements
      FOR ALL USING (
        clinic_id IN (SELECT public.clinic_ids())
        AND public.clinic_role(clinic_id) IN ('editor','admin','superadmin')
      ) WITH CHECK (
        clinic_id IN (SELECT public.clinic_ids())
        AND public.clinic_role(clinic_id) IN ('editor','admin','superadmin')
      );
  END IF;
END
$$;
