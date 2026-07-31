-- Break detection — take the UNION of all three signals. Never filter cadence_step='Break'
-- alone; which mechanism a cadence uses varies, and one field can undercount by orders of
-- magnitude. See knowledge/data-quality-caveats.md §1.

-- Reusable predicate (drop into any WHERE against the checkpoint fact):
--   AND ( cadence_step = 'Break'
--      OR cadence_step_status = 'Break'
--      OR (cadence_step = 'Exit' AND cadence_step_value ILIKE '%cadence break%') )

-- Break reasons for a cadence (last 30 days), union applied:
SELECT cadence_step_value AS break_reason, COUNT(*) AS total_breaks
FROM analytics.main.fact_journey_progress_checkpoint
WHERE TRIM(cadence_id) = '<exact cadence id>'
  AND event_timestamp >= DATEADD(day, -30, CURRENT_DATE())
  AND ( cadence_step = 'Break'
     OR cadence_step_status = 'Break'
     OR (cadence_step = 'Exit' AND cadence_step_value ILIKE '%cadence break%') )
GROUP BY 1
ORDER BY 2 DESC;

-- Diagnostic: the three signals side by side (see whether one carries the volume):
SELECT
  SUM(CASE WHEN cadence_step = 'Break' THEN 1 ELSE 0 END) AS break_step_cnt,
  SUM(CASE WHEN cadence_step_status = 'Break' THEN 1 ELSE 0 END) AS break_status_cnt,
  SUM(CASE WHEN cadence_step = 'Exit' AND cadence_step_value ILIKE '%cadence break%' THEN 1 ELSE 0 END) AS break_exit_cnt
FROM analytics.main.fact_journey_progress_checkpoint
WHERE TRIM(cadence_id) = '<exact cadence id>'
  AND event_timestamp >= DATEADD(day, -30, CURRENT_DATE());
