-- Fix: add missing columns and fix status constraint

-- Add price_implemented to baselines
ALTER TABLE std_service_baselines ADD COLUMN IF NOT EXISTS price_implemented NUMERIC(10,2);

-- Drop old status constraint and add new one
ALTER TABLE std_service_baselines DROP CONSTRAINT IF EXISTS std_service_baselines_status_check;
ALTER TABLE std_service_baselines ADD CONSTRAINT std_service_baselines_status_check 
  CHECK (status IN ('approved', 'active', 'paused', 'completed', 'cancelled'));

-- Add price_implemented to campaign_results too
ALTER TABLE std_campaign_results ADD COLUMN IF NOT EXISTS price_implemented NUMERIC(10,2);
