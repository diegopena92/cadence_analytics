-- Zero-fill weeks for charting. Weeks with no activity won't appear in a plain GROUP BY,
-- which reads as "no data" instead of "zero" and distorts trend charts / WoW deltas.
-- Generate the week series and LEFT JOIN the metric onto it.

WITH weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))          -- N weeks back; adjust
)
SELECT w.week_start, COALESCE(x.metric, 0) AS metric
FROM weeks w
LEFT JOIN (
    -- <any weekly aggregate that returns (week_start, metric)>
    SELECT DATE_TRUNC('week', event_timestamp::date) AS week_start,
           COUNT(DISTINCT email) AS metric
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Start'
    GROUP BY 1
) x ON x.week_start = w.week_start
ORDER BY w.week_start;
