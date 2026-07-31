-- Cadence Bug Detection Diagnostic — 8 checks, run in order for one cadence.
-- Confirm the exact cadence id first (free text):
--   SELECT DISTINCT TRIM(cadence_id) FROM analytics.main.fact_journey_progress_checkpoint
--   WHERE TRIM(cadence_id) ILIKE '%<keyword>%';
-- Substitute <exact cadence id> below. Definitions: knowledge/resources-and-methodology.md

-- ── 1. No Starts in 7 days ───────────────────────────────────────────────
SELECT TRIM(cadence_id) AS cadence_id,
       MAX(event_timestamp) AS last_start_ts,
       DATEDIFF(day, MAX(event_timestamp), CURRENT_DATE()) AS days_since_last_start
FROM analytics.main.fact_journey_progress_checkpoint
WHERE TRIM(cadence_id) = '<exact cadence id>'
  AND cadence_step = 'Start'
GROUP BY 1
HAVING DATEDIFF(day, MAX(event_timestamp), CURRENT_DATE()) >= 7;

-- ── 2. Double Starts (2nd Start, no Exit between) ────────────────────────
WITH starts AS (
    SELECT email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY event_timestamp) AS start_seq,
           LAG(event_timestamp) OVER (PARTITION BY email ORDER BY event_timestamp) AS prev_start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Start'
),
exits AS (
    SELECT email, event_timestamp AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Exit'
)
SELECT s.email, s.prev_start_ts, s.event_timestamp AS this_start_ts
FROM starts s
WHERE s.start_seq > 1
  AND NOT EXISTS (SELECT 1 FROM exits e
                  WHERE e.email = s.email
                    AND e.exit_ts > s.prev_start_ts AND e.exit_ts < s.event_timestamp);

-- ── 3. Double Exits (2nd Exit, no Start between) ─────────────────────────
WITH exits AS (
    SELECT email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY event_timestamp) AS exit_seq,
           LAG(event_timestamp) OVER (PARTITION BY email ORDER BY event_timestamp) AS prev_exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Exit'
),
starts AS (
    SELECT email, event_timestamp AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Start'
)
SELECT e.email, e.prev_exit_ts, e.event_timestamp AS this_exit_ts
FROM exits e
WHERE e.exit_seq > 1
  AND NOT EXISTS (SELECT 1 FROM starts s
                  WHERE s.email = e.email
                    AND s.start_ts > e.prev_exit_ts AND s.start_ts < e.event_timestamp);

-- ── 4. Entered but not exited in 100+ days ───────────────────────────────
WITH starts AS (
    SELECT email, MIN(event_timestamp) AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Start'
    GROUP BY email
),
exits AS (
    SELECT email, MIN(event_timestamp) AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Exit'
    GROUP BY email
)
SELECT s.email, s.start_ts, DATEDIFF(day, s.start_ts, CURRENT_DATE()) AS days_in_cadence
FROM starts s
LEFT JOIN exits e ON s.email = e.email AND e.exit_ts > s.start_ts
WHERE e.email IS NULL AND DATEDIFF(day, s.start_ts, CURRENT_DATE()) >= 100
ORDER BY days_in_cadence DESC;

-- ── 5. Drops in weekly entries/exits (zero-filled) ───────────────────────
WITH weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
weekly AS (
    SELECT DATE_TRUNC('week', event_timestamp::date) AS week_start,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Start' THEN email END) AS entries,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Exit'  THEN email END) AS exits
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>'
    GROUP BY 1
)
SELECT w.week_start,
       COALESCE(wk.entries, 0) AS entries,
       COALESCE(wk.exits, 0)   AS exits,
       LAG(COALESCE(wk.entries,0)) OVER (ORDER BY w.week_start) AS prior_week_entries,
       LAG(COALESCE(wk.exits,0))   OVER (ORDER BY w.week_start) AS prior_week_exits
FROM weeks w
LEFT JOIN weekly wk ON w.week_start = wk.week_start
ORDER BY w.week_start;   -- compute % change vs prior week in the writeup; flag the breaks

-- ── 6. Drop in steps surfaced (zero-filled, by createddate) ──────────────
WITH weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
weekly AS (
    SELECT DATE_TRUNC('week', createddate::date) AS week_start, COUNT(*) AS steps_surfaced
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE cadence_id__c = '<exact cadence id>' AND step_id__c = 'Call attempt' AND name != 'clear_step'
    GROUP BY 1
)
SELECT w.week_start, COALESCE(wk.steps_surfaced, 0) AS steps_surfaced,
       LAG(COALESCE(wk.steps_surfaced,0)) OVER (ORDER BY w.week_start) AS prior_week
FROM weeks w LEFT JOIN weekly wk ON w.week_start = wk.week_start
ORDER BY w.week_start;

-- ── 7. Drop in steps completed (zero-filled, by result_date_time__c) ─────
WITH weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
weekly AS (
    SELECT DATE_TRUNC('week', result_date_time__c::date) AS week_start, COUNT(*) AS steps_completed
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE cadence_id__c = '<exact cadence id>' AND step_id__c = 'Call attempt' AND name != 'clear_step'
      AND result__c IS NOT NULL AND result__c != 'Displayed'
    GROUP BY 1
)
SELECT w.week_start, COALESCE(wk.steps_completed, 0) AS steps_completed,
       LAG(COALESCE(wk.steps_completed,0)) OVER (ORDER BY w.week_start) AS prior_week
FROM weeks w LEFT JOIN weekly wk ON w.week_start = wk.week_start
ORDER BY w.week_start;

-- ── 8. Break/exit payload formatting — three signals side by side ────────
SELECT
  SUM(CASE WHEN cadence_step = 'Break' THEN 1 ELSE 0 END) AS break_step_cnt,
  SUM(CASE WHEN cadence_step_status = 'Break' THEN 1 ELSE 0 END) AS break_status_cnt,
  SUM(CASE WHEN cadence_step = 'Exit' AND cadence_step_value ILIKE '%cadence break%' THEN 1 ELSE 0 END) AS break_exit_cnt
FROM analytics.main.fact_journey_progress_checkpoint
WHERE TRIM(cadence_id) = '<exact cadence id>'
  AND event_timestamp >= DATEADD(day, -30, CURRENT_DATE());
-- If one signal near-zero while another carries the volume → expected variation, not a bug.
-- If the payload uses a combo matching none of the three, or values look malformed → formatting bug.
