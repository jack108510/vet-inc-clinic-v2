-- Fix type mismatches

-- campaign_id in baselines should be BIGINT to match std_approval_queue.id
ALTER TABLE std_service_baselines ALTER COLUMN campaign_id TYPE BIGINT USING campaign_id::BIGINT;

-- price_implemented should be NUMERIC not BOOLEAN
ALTER TABLE std_service_baselines ALTER COLUMN price_implemented TYPE NUMERIC(10,2) USING NULL;
ALTER TABLE std_campaign_results ALTER COLUMN price_implemented TYPE NUMERIC(10,2) USING NULL;
