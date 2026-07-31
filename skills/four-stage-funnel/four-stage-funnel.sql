-- Four-Stage Cadence Funnel (weekly, zero-filled) for a single cadence.
-- Stages: 1 entries + control, 2 steps surfaced, 3 steps completed, 4 exits.
-- BEFORE RUNNING: confirm the exact cadence id (free text) —
--   SELECT DISTINCT TRIM(cadence_id) FROM analytics.main.fact_journey_progress_checkpoint
--   WHERE TRIM(cadence_id) ILIKE '%<keyword>%';
-- Then set the SAME literal in both <exact cadence id> spots below. Adjust ROWCOUNT for window.
-- Definitions: knowledge/resources-and-methodology.md · Caveats: knowledge/data-quality-caveats.md
WITH weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))          -- last 26 weeks; change as needed
),
entries_exits AS (   -- stages 1 & 4 + control, from the checkpoint fact
    SELECT DATE_TRUNC('week', event_timestamp::date) AS week_start,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Start' THEN email END) AS entries,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Test'  THEN email END) AS control,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Exit'  THEN email END) AS exits
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE TRIM(cadence_id) = '<exact cadence id>'
    GROUP BY 1
),
surfaced AS (        -- stage 2, from decision_engine_step__c, by createddate
    SELECT DATE_TRUNC('week', createddate::date) AS week_start,
           COUNT(*) AS steps_surfaced
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE cadence_id__c = '<exact cadence id>'
      AND step_id__c = 'Call attempt'
      AND name != 'clear_step'
    GROUP BY 1
),
completed AS (       -- stage 3, from decision_engine_step__c, by result_date_time__c
    SELECT DATE_TRUNC('week', result_date_time__c::date) AS week_start,
           COUNT(*) AS steps_completed
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE cadence_id__c = '<exact cadence id>'
      AND step_id__c = 'Call attempt'
      AND name != 'clear_step'
      AND result__c IS NOT NULL
      AND result__c != 'Displayed'
    GROUP BY 1
)
SELECT w.week_start,
       COALESCE(ee.entries, 0)         AS entries,
       COALESCE(ee.control, 0)         AS control,          -- held-out A/B population, not an entry
       COALESCE(s.steps_surfaced, 0)   AS steps_surfaced,
       COALESCE(c.steps_completed, 0)  AS steps_completed,
       COALESCE(ee.exits, 0)           AS exits
FROM weeks w
LEFT JOIN entries_exits ee ON ee.week_start = w.week_start
LEFT JOIN surfaced      s  ON s.week_start  = w.week_start
LEFT JOIN completed     c  ON c.week_start  = w.week_start
ORDER BY w.week_start;

-- ── Secondary: exit-reason mix by week (watch for enrolled → lost shifts) ──
-- SELECT DATE_TRUNC('week', event_timestamp::date) AS week_start,
--        cadence_step_value AS exit_reason,
--        COUNT(DISTINCT email) AS exits
-- FROM analytics.main.fact_journey_progress_checkpoint
-- WHERE TRIM(cadence_id) = '<exact cadence id>' AND cadence_step = 'Exit'
-- GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- ── Secondary: completed-step outcome mix (GROUP BY first to see casing variants) ──
-- SELECT result__c, COUNT(*) AS cnt
-- FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
-- WHERE cadence_id__c = '<exact cadence id>' AND step_id__c = 'Call attempt' AND name != 'clear_step'
-- GROUP BY result__c ORDER BY cnt DESC;
