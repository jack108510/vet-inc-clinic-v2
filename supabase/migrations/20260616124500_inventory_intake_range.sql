CREATE OR REPLACE FUNCTION standardize_avimark_purchase_orders_range(
  p_clinic_id TEXT,
  p_start_date DATE,
  p_end_date DATE,
  p_reset BOOLEAN DEFAULT FALSE
)
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
  IF p_reset THEN
    DELETE FROM std_inventory_movements
    WHERE clinic_id = p_clinic_id
      AND source_table = 'purchase_orders'
      AND movement_type = 'receipt';

    DELETE FROM std_purchase_order_lines
    WHERE clinic_id = p_clinic_id;

    DELETE FROM std_purchase_orders
    WHERE clinic_id = p_clinic_id
      AND order_id IS NOT NULL;
  ELSE
    DELETE FROM std_inventory_movements
    WHERE clinic_id = p_clinic_id
      AND source_table = 'purchase_orders'
      AND movement_type = 'receipt'
      AND movement_date >= p_start_date
      AND movement_date < p_end_date;

    DELETE FROM std_purchase_order_lines
    WHERE clinic_id = p_clinic_id
      AND order_date >= p_start_date
      AND order_date < p_end_date;

    DELETE FROM std_purchase_orders
    WHERE clinic_id = p_clinic_id
      AND order_id IS NOT NULL
      AND order_date >= p_start_date
      AND order_date < p_end_date;
  END IF;

  WITH ordered_src AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY record_num, record_type, COALESCE(item_code, '')) AS ord,
      record_num::TEXT AS record_num,
      LOWER(COALESCE(record_type, '')) AS record_type,
      order_date,
      po_number,
      vendor_code,
      item_code,
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
      MAX(COALESCE(NULLIF(TRIM(po_number), ''), record_num)) FILTER (WHERE record_type = 'header') AS order_id,
      MAX(safe_date(order_date::TEXT)) FILTER (WHERE record_type = 'header') AS order_date,
      MAX(NULLIF(TRIM(vendor_code), '')) FILTER (WHERE record_type = 'header') AS vendor,
      ROUND(SUM(COALESCE(cost, 0)) FILTER (WHERE record_type = 'line_item'), 2) AS total_cost,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'item_code', item_code,
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
  selected_headers AS (
    SELECT *
    FROM po_headers
    WHERE order_date >= p_start_date
      AND order_date < p_end_date
  ),
  inserted_headers AS (
    INSERT INTO std_purchase_orders (
      clinic_id, order_date, order_id, vendor, total_cost, items
    )
    SELECT
      p_clinic_id,
      order_date,
      order_id,
      vendor,
      total_cost,
      items
    FROM selected_headers
    RETURNING id, order_id
  )
  SELECT
    COALESCE((SELECT COUNT(*) FROM selected_headers), 0)::INTEGER,
    COALESCE((SELECT COUNT(*) FROM inserted_headers), 0)::INTEGER
  INTO v_rows_processed, v_headers_inserted;

  WITH ordered_src AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY record_num, record_type, COALESCE(item_code, '')) AS ord,
      record_num::TEXT AS record_num,
      LOWER(COALESCE(record_type, '')) AS record_type,
      order_date,
      po_number,
      vendor_code,
      item_code,
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
      MAX(COALESCE(NULLIF(TRIM(po_number), ''), record_num)) FILTER (WHERE record_type = 'header') AS order_id,
      MAX(safe_date(order_date::TEXT)) FILTER (WHERE record_type = 'header') AS order_date,
      MAX(NULLIF(TRIM(vendor_code), '')) FILTER (WHERE record_type = 'header') AS vendor
    FROM grouped_src
    GROUP BY header_seq
    HAVING MAX(record_num) FILTER (WHERE record_type = 'header') IS NOT NULL
  ),
  selected_headers AS (
    SELECT *
    FROM po_headers
    WHERE order_date >= p_start_date
      AND order_date < p_end_date
  ),
  po_lines AS (
    SELECT
      spo.id AS purchase_order_id,
      ph.order_id,
      ph.order_date,
      ph.vendor,
      ROW_NUMBER() OVER (PARTITION BY g.header_seq ORDER BY g.ord) AS line_num,
      g.record_num,
      g.item_code,
      g.quantity,
      g.cost,
      i.code AS matched_code,
      i.name AS matched_name,
      i.uom AS raw_uom,
      normalize_inventory_uom(i.uom, i.name, i.dosage_form) AS normalized_uom,
      parse_inventory_numeric(i.pack_size) AS pack_size_num,
      i.dosage_form
    FROM grouped_src g
    JOIN selected_headers ph
      ON ph.header_seq = g.header_seq
    JOIN std_purchase_orders spo
      ON spo.clinic_id = p_clinic_id
     AND spo.order_id = ph.order_id
     AND spo.order_date = ph.order_date
     AND COALESCE(spo.vendor, '') = COALESCE(ph.vendor, '')
    LEFT JOIN LATERAL (
      SELECT i.*
      FROM raw_avimark_items i
      WHERE i.clinic_id = p_clinic_id
        AND (
          i.code = g.item_code
          OR i.service_code = g.item_code
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
    COALESCE(matched_name, item_code),
    matched_code,
    COALESCE(matched_name, item_code),
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
    order_date,
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
    AND order_date >= p_start_date
    AND order_date < p_end_date
    AND normalization_status IN ('clean', 'conversion_needed', 'legacy_unmatched');

  GET DIAGNOSTICS v_receipts_inserted = ROW_COUNT;

  INSERT INTO std_extractor_log (
    clinic_id,
    extractor_type,
    date_from,
    date_to,
    rows_processed,
    rows_inserted,
    rows_updated,
    status,
    error_message
  )
  VALUES (
    p_clinic_id,
    'avimark_inventory_intake_range',
    p_start_date,
    p_end_date,
    v_rows_processed,
    v_lines_inserted,
    0,
    'success',
    NULL
  );

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'date_from', p_start_date,
    'date_to', p_end_date,
    'headers_processed', v_rows_processed,
    'headers_inserted', v_headers_inserted,
    'lines_inserted', v_lines_inserted,
    'receipt_movements_inserted', v_receipts_inserted
  );
END;
$$;
