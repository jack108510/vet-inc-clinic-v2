CREATE OR REPLACE FUNCTION normalize_inventory_uom(
  p_raw_uom TEXT,
  p_item_name TEXT DEFAULT NULL,
  p_dosage_form TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_uom TEXT := LOWER(TRIM(COALESCE(p_raw_uom, '')));
  v_name TEXT := LOWER(COALESCE(p_item_name, ''));
  v_form TEXT := LOWER(COALESCE(p_dosage_form, ''));
BEGIN
  IF v_uom IN ('ea','each','unit','units','cnt','count') THEN RETURN 'ea'; END IF;
  IF v_uom IN ('tab','tabs','tablet','tablets') THEN RETURN 'tab'; END IF;
  IF v_uom IN ('cap','caps','capsule','capsules') THEN RETURN 'cap'; END IF;
  IF v_uom IN ('dose','doses') THEN RETURN 'dose'; END IF;
  IF v_uom IN ('vial','vials') THEN RETURN 'vial'; END IF;
  IF v_uom IN ('tube','tubes') THEN RETURN 'tube'; END IF;
  IF v_uom IN ('bag','bags') THEN RETURN 'bag'; END IF;
  IF v_uom IN ('box','boxes','bx') THEN RETURN 'box'; END IF;
  IF v_uom IN ('bottle','bottles','btl') THEN RETURN 'bottle'; END IF;
  IF v_uom IN ('can','cans') THEN RETURN 'can'; END IF;
  IF v_uom IN ('pack','packs','pkt') THEN RETURN 'pack'; END IF;
  IF v_uom IN ('kit','kits') THEN RETURN 'kit'; END IF;
  IF v_uom IN ('pair','pairs') THEN RETURN 'pair'; END IF;
  IF v_uom IN ('ml','milliliter','milliliters') THEN RETURN 'ml'; END IF;
  IF v_uom IN ('l','liter','liters') THEN RETURN 'l'; END IF;
  IF v_uom IN ('g','gram','grams') THEN RETURN 'g'; END IF;
  IF v_uom IN ('kg','kilogram','kilograms') THEN RETURN 'kg'; END IF;

  IF v_uom = '' THEN
    IF v_form LIKE '%tablet%' OR v_name ~ '(^|[^a-z])(tab|tabs|tablet|tablets)($|[^a-z])' THEN RETURN 'tab'; END IF;
    IF v_form LIKE '%capsule%' OR v_name ~ '(^|[^a-z])(cap|caps|capsule|capsules)($|[^a-z])' THEN RETURN 'cap'; END IF;
    IF v_form LIKE '%inject%' OR v_name LIKE '%vial%' THEN RETURN 'vial'; END IF;
    IF v_form LIKE '%liquid%' OR v_name LIKE '%ml%' THEN RETURN 'ml'; END IF;
    IF v_name LIKE '%kg%' THEN RETURN 'kg'; END IF;
    IF v_name LIKE '%gram%' OR v_name LIKE '% g %' THEN RETURN 'g'; END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION parse_inventory_numeric(p_text TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_clean TEXT;
BEGIN
  v_clean := NULLIF(regexp_replace(COALESCE(p_text, ''), '[^0-9\.]+', '', 'g'), '');
  IF v_clean IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN v_clean::NUMERIC;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION standardize_avimark_purchase_orders(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rows_processed INTEGER := 0;
  v_headers_inserted INTEGER := 0;
  v_lines_inserted INTEGER := 0;
  v_receipts_inserted INTEGER := 0;
BEGIN
  -- Rebuild this clinic's intake truth on each run so re-runs stay deterministic.
  DELETE FROM std_inventory_movements
  WHERE clinic_id = p_clinic_id
    AND source_table = 'purchase_orders'
    AND movement_type = 'receipt';

  DELETE FROM std_purchase_order_lines
  WHERE clinic_id = p_clinic_id;

  DELETE FROM std_purchase_orders
  WHERE clinic_id = p_clinic_id
    AND order_id IS NOT NULL;

  WITH ordered_src AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY record_num, record_type, COALESCE(item_code, ''), COALESCE(item_name, '')) AS ord,
      record_num::TEXT AS record_num,
      LOWER(COALESCE(record_type, '')) AS record_type,
      order_date,
      vendor_code,
      item_code,
      item_name,
      quantity::NUMERIC AS quantity,
      cost::NUMERIC AS cost
    FROM purchase_orders
    WHERE record_num IS NOT NULL
  ),
  grouped_src AS (
    SELECT
      *,
      SUM(CASE WHEN record_type = 'header' THEN 1 ELSE 0 END) OVER (ORDER BY ord) AS header_seq
    FROM ordered_src
  ),
  po_headers AS (
    SELECT
      header_seq,
      MAX(record_num) FILTER (WHERE record_type = 'header') AS order_id,
      MAX(safe_date(order_date::TEXT)) FILTER (WHERE record_type = 'header') AS order_date,
      MAX(NULLIF(TRIM(vendor_code), '')) FILTER (WHERE record_type = 'header') AS vendor,
      ROUND(SUM(COALESCE(cost, 0)) FILTER (WHERE record_type = 'line_item'), 2) AS total_cost,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'item_code', item_code,
            'item_name', item_name,
            'quantity', quantity,
            'cost', cost
          )
          ORDER BY ord
        ) FILTER (WHERE record_type = 'line_item'),
        '[]'::jsonb
      ) AS items
    FROM grouped_src
    GROUP BY header_seq
    HAVING MAX(record_num) FILTER (WHERE record_type = 'header') IS NOT NULL
  ),
  inserted_headers AS (
    INSERT INTO std_purchase_orders (
      clinic_id, order_date, order_id, vendor, total_cost, items
    )
    SELECT
      p_clinic_id,
      COALESCE(order_date, CURRENT_DATE),
      order_id,
      vendor,
      total_cost,
      items
    FROM po_headers
    RETURNING id, order_id
  )
  SELECT COUNT(*)::INTEGER, COALESCE((SELECT COUNT(*) FROM inserted_headers), 0)::INTEGER
  INTO v_rows_processed, v_headers_inserted
  FROM ordered_src;

  WITH ordered_src AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY record_num, record_type, COALESCE(item_code, ''), COALESCE(item_name, '')) AS ord,
      record_num::TEXT AS record_num,
      LOWER(COALESCE(record_type, '')) AS record_type,
      order_date,
      vendor_code,
      item_code,
      item_name,
      quantity::NUMERIC AS quantity,
      cost::NUMERIC AS cost
    FROM purchase_orders
    WHERE record_num IS NOT NULL
  ),
  grouped_src AS (
    SELECT
      *,
      SUM(CASE WHEN record_type = 'header' THEN 1 ELSE 0 END) OVER (ORDER BY ord) AS header_seq
    FROM ordered_src
  ),
  po_headers AS (
    SELECT
      header_seq,
      MAX(record_num) FILTER (WHERE record_type = 'header') AS order_id,
      MAX(safe_date(order_date::TEXT)) FILTER (WHERE record_type = 'header') AS order_date,
      MAX(NULLIF(TRIM(vendor_code), '')) FILTER (WHERE record_type = 'header') AS vendor
    FROM grouped_src
    GROUP BY header_seq
    HAVING MAX(record_num) FILTER (WHERE record_type = 'header') IS NOT NULL
  ),
  po_lines AS (
    SELECT
      ih.id AS purchase_order_id,
      ph.order_id,
      ph.order_date,
      ph.vendor,
      ROW_NUMBER() OVER (PARTITION BY g.header_seq ORDER BY g.ord) AS line_num,
      g.record_num,
      g.item_code,
      g.item_name,
      g.quantity,
      g.cost,
      i.code AS matched_code,
      i.name AS matched_name,
      i.uom AS raw_uom,
      normalize_inventory_uom(i.uom, COALESCE(g.item_name, i.name), i.dosage_form) AS normalized_uom,
      parse_inventory_numeric(i.pack_size) AS pack_size_num,
      i.dosage_form
    FROM grouped_src g
    JOIN po_headers ph
      ON ph.header_seq = g.header_seq
    JOIN std_purchase_orders spo
      ON spo.clinic_id = p_clinic_id
     AND spo.order_id = ph.order_id
     AND spo.order_date = COALESCE(ph.order_date, CURRENT_DATE)
     AND COALESCE(spo.vendor, '') = COALESCE(ph.vendor, '')
    JOIN LATERAL (
      SELECT spo.id
    ) ih ON TRUE
    LEFT JOIN LATERAL (
      SELECT i.*
      FROM raw_avimark_items i
      WHERE i.clinic_id = p_clinic_id
        AND (
          i.code = g.item_code
          OR i.service_code = g.item_code
          OR (g.item_name IS NOT NULL AND LOWER(i.name) = LOWER(g.item_name))
        )
      ORDER BY
        CASE
          WHEN i.code = g.item_code THEN 1
          WHEN i.service_code = g.item_code THEN 2
          ELSE 3
        END,
        i.created_at DESC
      LIMIT 1
    ) i ON TRUE
    WHERE g.record_type = 'line_item'
  )
  INSERT INTO std_purchase_order_lines (
    clinic_id,
    purchase_order_id,
    order_id,
    line_num,
    order_date,
    vendor,
    raw_item_code,
    raw_item_name,
    matched_product_code,
    matched_product_name,
    raw_uom,
    normalized_uom,
    qty_raw,
    qty_normalized,
    unit_cost_raw,
    unit_cost_normalized,
    line_cost,
    pack_size,
    dosage_form,
    normalization_status,
    normalization_notes,
    source_row_ref
  )
  SELECT
    p_clinic_id,
    purchase_order_id,
    order_id,
    line_num,
    order_date,
    vendor,
    item_code,
    item_name,
    matched_code,
    COALESCE(matched_name, item_name),
    raw_uom,
    normalized_uom,
    quantity,
    CASE
      WHEN quantity IS NULL OR quantity <= 0 THEN NULL
      WHEN normalized_uom IN ('g', 'kg', 'ml', 'l') THEN NULL
      ELSE quantity
    END,
    CASE
      WHEN quantity IS NULL OR quantity <= 0 OR cost IS NULL THEN NULL
      ELSE ROUND(cost / NULLIF(quantity, 0), 4)
    END,
    CASE
      WHEN quantity IS NULL OR quantity <= 0 OR cost IS NULL THEN NULL
      WHEN normalized_uom IN ('g', 'kg', 'ml', 'l') THEN NULL
      ELSE ROUND(cost / NULLIF(quantity, 0), 4)
    END,
    ROUND(COALESCE(cost, 0), 2),
    pack_size_num,
    dosage_form,
    CASE
      WHEN quantity IS NULL OR quantity <= 0 OR cost IS NULL THEN 'excluded'
      WHEN matched_code IS NULL THEN 'legacy_unmatched'
      WHEN normalized_uom IN ('g', 'kg', 'ml', 'l') THEN 'conversion_needed'
      WHEN normalized_uom IS NULL THEN 'legacy_unmatched'
      ELSE 'clean'
    END,
    CASE
      WHEN quantity IS NULL OR quantity <= 0 OR cost IS NULL THEN 'Missing usable quantity or cost'
      WHEN matched_code IS NULL THEN 'No catalog match found in raw_avimark_items'
      WHEN normalized_uom IN ('g', 'kg', 'ml', 'l') THEN 'Weight/volume item needs conversion logic before on-hand math'
      WHEN normalized_uom IS NULL THEN 'Could not normalize unit of measure'
      ELSE 'Line normalized from legacy purchase_orders feed'
    END,
    record_num
  FROM po_lines;

  GET DIAGNOSTICS v_lines_inserted = ROW_COUNT;

  INSERT INTO std_inventory_movements (
    clinic_id,
    movement_date,
    product_code,
    product_name,
    movement_type,
    direction,
    quantity,
    uom,
    unit_cost,
    total_cost,
    source_table,
    source_id,
    source_line_id,
    confidence,
    notes
  )
  SELECT
    clinic_id,
    COALESCE(order_date, CURRENT_DATE),
    COALESCE(matched_product_code, raw_item_code),
    COALESCE(matched_product_name, raw_item_name, raw_item_code),
    'receipt',
    'in',
    COALESCE(qty_normalized, qty_raw),
    COALESCE(normalized_uom, raw_uom),
    COALESCE(unit_cost_normalized, unit_cost_raw),
    line_cost,
    'purchase_orders',
    order_id,
    id,
    CASE
      WHEN normalization_status = 'clean' THEN 'normalized'
      WHEN normalization_status = 'conversion_needed' THEN 'raw'
      ELSE 'estimated'
    END,
    normalization_notes
  FROM std_purchase_order_lines
  WHERE clinic_id = p_clinic_id
    AND normalization_status IN ('clean', 'conversion_needed', 'legacy_unmatched');

  GET DIAGNOSTICS v_receipts_inserted = ROW_COUNT;

  INSERT INTO std_extractor_log (
    clinic_id,
    extractor_type,
    rows_processed,
    rows_inserted,
    rows_updated,
    status,
    error_message
  )
  VALUES (
    p_clinic_id,
    'avimark_inventory_intake',
    v_rows_processed,
    v_lines_inserted,
    0,
    'success',
    NULL
  );

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'rows_processed', v_rows_processed,
    'headers_inserted', v_headers_inserted,
    'lines_inserted', v_lines_inserted,
    'receipt_movements_inserted', v_receipts_inserted
  );
END;
$$;
