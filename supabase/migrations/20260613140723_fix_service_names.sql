-- Update std_service_prices.service_name from most common transaction description
UPDATE std_service_prices sp
SET service_name = sub.most_common_desc
FROM (
  SELECT service_code, 
         MODE() WITHIN GROUP (ORDER BY description) as most_common_desc
  FROM std_transactions
  WHERE clinic_id = 'rosslyn' AND amount > 0 
    AND description IS NOT NULL AND TRIM(description) != ''
  GROUP BY service_code
) sub
WHERE sp.service_code = sub.service_code 
  AND sp.clinic_id = 'rosslyn'
  AND sub.most_common_desc IS NOT NULL;

-- Also update std_shoppability.service_name
UPDATE std_shoppability ss
SET service_name = sp.service_name
FROM std_service_prices sp
WHERE ss.service_code = sp.service_code 
  AND ss.clinic_id = sp.clinic_id
  AND sp.service_name IS NOT NULL;
