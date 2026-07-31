-- Resolve the exact, canonical cadence id before filtering on it.
-- cadence_id / cadence_id__c / cadence_name are free text with leading/trailing whitespace
-- and inconsistent casing — never assume an exact '=' without confirming the literal first.

-- Step 1: discover the exact stored value(s) for a keyword.
SELECT DISTINCT TRIM(cadence_id) AS cadence_id, COUNT(*) AS rows
FROM analytics.main.fact_journey_progress_checkpoint
WHERE TRIM(cadence_id) ILIKE '%<keyword>%'
GROUP BY 1
ORDER BY rows DESC;

-- Step 2: once confirmed, filter on the exact literal (fast, unambiguous):
--   WHERE TRIM(cadence_id) = '<exact cadence id>'
-- On the Salesforce step table the field is cadence_id__c (same caveat):
--   WHERE cadence_id__c = '<exact cadence id>'

-- Single grouping key across cadence types (Pre-Enroll→lead_id, Post-Enroll→user_id,
-- Demo Attendance→anonymous_id; email always populated):
--   COALESCE(lead_id, user_id, anonymous_id, email) AS unique_id
-- NB: object_record_id (prefix 'a1n…') is NOT lead_id (prefix '00Q…') — do not join them.
