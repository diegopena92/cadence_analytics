-- Hightouch model SQL — all 9 Cadence Mechanical Alerts checks, UNION ALL'd into one normalized
-- result set for a single Google Sheets sync (one tab, a `check_number` column distinguishes
-- checks). Paste this whole file as the model's SQL in Hightouch.
--
-- This mirrors cadence-alerts.sql's logic exactly (same filters, same thresholds, same domain/
-- cadence exclusions) — it is NOT a different or simplified version. Keep it in sync with
-- cadence-alerts.sql by hand whenever a threshold/filter changes there; see SKILL.md's
-- "Hightouch pipeline" section for the tradeoff this creates (SQL now lives in two places).
--
-- Output schema (every check normalizes to these 7 columns):
--   check_number   INT     -- 1-9, matches cadence-alerts.sql / SKILL.md numbering
--   check_name     TEXT    -- human-readable check name, for the Slack message headline
--   cadence_id     TEXT    -- the flagged cadence
--   metric_value   NUMBER  -- the actual value that triggered the flag
--   reference_value NUMBER -- the baseline mean / threshold it's compared against (NULL if n/a)
--   detail         TEXT    -- extra context (affected pros, stddev, week_start, direction, etc.)
--   as_of          DATE    -- the date/week this row applies to
--
-- Only alert-worthy rows are emitted (same filtering as cadence-alerts.sql) — an empty result set
-- for a given sync run means that check found nothing, which the routine should read as "clean."

WITH
-- ── Check 1: No Starts in 7 Days ──────────────────────────────────────────
c1_events AS (
    SELECT TRIM(cadence_id) AS cadence_id, event_timestamp
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
),
c1_agg AS (
    SELECT cadence_id,
           COUNT_IF(event_timestamp >= DATEADD(month, -4, CURRENT_DATE())) AS starts_last_4mo,
           COUNT_IF(event_timestamp >= DATEADD(day, -7, CURRENT_DATE()))   AS starts_last_7d,
           MAX(event_timestamp) AS last_start_ts
    FROM c1_events
    GROUP BY cadence_id
),

-- ── Check 2: Double Starts (trailing 7 days, HCP NPS excluded) ───────────
c2_starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS start_seq,
           LAG(event_timestamp) OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS prev_start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
),
c2_exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
),
c2_agg AS (
    SELECT s.cadence_id, COUNT(*) AS double_start_count, COUNT(DISTINCT s.email) AS pros_affected
    FROM c2_starts s
    WHERE s.start_seq > 1
      AND s.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
      AND NOT EXISTS (SELECT 1 FROM c2_exits e
                      WHERE e.cadence_id = s.cadence_id AND e.email = s.email
                        AND e.exit_ts > s.prev_start_ts AND e.exit_ts < s.event_timestamp)
    GROUP BY s.cadence_id
),

-- ── Check 3: Double Exits (trailing 7 days, HCP NPS excluded) ────────────
c3_exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS exit_seq,
           LAG(event_timestamp) OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS prev_exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
),
c3_starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
),
c3_agg AS (
    SELECT e.cadence_id, COUNT(*) AS double_exit_count, COUNT(DISTINCT e.email) AS pros_affected
    FROM c3_exits e
    WHERE e.exit_seq > 1
      AND e.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
      AND NOT EXISTS (SELECT 1 FROM c3_starts s
                      WHERE s.cadence_id = e.cadence_id AND s.email = e.email
                        AND s.start_ts > e.prev_exit_ts AND s.start_ts < e.event_timestamp)
    GROUP BY e.cadence_id
),

-- ── Check 4: Newly stuck >100 days (crossed threshold in trailing 7 days) ──
c4_starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
    GROUP BY 1, 2
),
c4_exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
    GROUP BY 1, 2
),
c4_agg AS (
    SELECT s.cadence_id,
           COUNT(*) AS newly_stuck_pros,
           MAX(DATEDIFF(day, s.start_ts, CURRENT_DATE())) AS longest_days_in_cadence
    FROM c4_starts s
    LEFT JOIN c4_exits e ON e.cadence_id = s.cadence_id AND e.email = s.email AND e.exit_ts > s.start_ts
    WHERE e.email IS NULL
      AND DATEDIFF(day, s.start_ts, CURRENT_DATE()) >= 100
      AND DATEDIFF(day, s.start_ts, CURRENT_DATE()) < 107
    GROUP BY s.cadence_id
),

-- ── Check 5: Drop in Weekly Entries/Exits (8-week baseline, 2 SD, min 10) ──
c5_cadence_list AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
),
c5_weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
c5_grid AS (
    SELECT c.cadence_id, w.week_start FROM c5_cadence_list c CROSS JOIN c5_weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
c5_weekly AS (
    SELECT TRIM(cadence_id) AS cadence_id,
           DATE_TRUNC('week', event_timestamp::date) AS week_start,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Start' THEN email END) AS entries,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Exit'  THEN email END) AS exits
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
    GROUP BY 1, 2
),
c5_filled AS (
    SELECT g.cadence_id, g.week_start,
           COALESCE(wk.entries, 0) AS entries, COALESCE(wk.exits, 0) AS exits
    FROM c5_grid g LEFT JOIN c5_weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
c5_stats AS (
    SELECT *,
           AVG(entries) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS entries_baseline_mean,
           STDDEV(entries) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS entries_baseline_sd,
           COUNT(entries) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS entries_baseline_weeks,
           AVG(exits) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS exits_baseline_mean,
           STDDEV(exits) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS exits_baseline_sd,
           COUNT(exits) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS exits_baseline_weeks
    FROM c5_filled
),
c5_agg AS (
    SELECT cadence_id, week_start, 'entries' AS metric_name, entries AS value,
           entries_baseline_mean AS baseline_mean, entries_baseline_sd AS baseline_sd
    FROM c5_stats
    WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
      AND entries_baseline_weeks >= 8 AND entries_baseline_mean >= 10
      AND entries <= entries_baseline_mean - 2 * entries_baseline_sd
    UNION ALL
    SELECT cadence_id, week_start, 'exits' AS metric_name, exits AS value,
           exits_baseline_mean AS baseline_mean, exits_baseline_sd AS baseline_sd
    FROM c5_stats
    WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
      AND exits_baseline_weeks >= 8 AND exits_baseline_mean >= 10
      AND exits <= exits_baseline_mean - 2 * exits_baseline_sd
),

-- ── Check 6: No Steps Surfaced in 7 Days ──────────────────────────────────
-- Explicit known-quiet exclusion required — see cadence-alerts.sql check 6's 2026-07-31 comment
-- (the 4-month liveness gate alone does NOT exclude these; confirmed live).
c6_surfaced AS (
    SELECT cadence_id__c AS cadence_id, createddate
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT cadence_id__c ILIKE ANY ('%ARPA Engagement%', '%Type 1 Onboarding%', '%Type 1 Adoption%',
                                        '%Type 1 Nurture%', '%Activation%', '%Warming%')
),
c6_agg AS (
    SELECT cadence_id,
           COUNT_IF(createddate >= DATEADD(month, -4, CURRENT_DATE())) AS surfaced_last_4mo,
           COUNT_IF(createddate >= DATEADD(day, -7, CURRENT_DATE()))   AS surfaced_last_7d,
           MAX(createddate) AS last_surfaced_ts
    FROM c6_surfaced
    GROUP BY cadence_id
),

-- ── Check 7: Drop in Steps Surfaced (8-week baseline, 2 SD, min 10) ───────
c7_cadence_list AS (
    SELECT DISTINCT cadence_id__c AS cadence_id
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
),
c7_weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
c7_grid AS (
    SELECT c.cadence_id, w.week_start FROM c7_cadence_list c CROSS JOIN c7_weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
c7_weekly AS (
    SELECT cadence_id__c AS cadence_id, DATE_TRUNC('week', createddate::date) AS week_start, COUNT(*) AS steps_surfaced
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
    GROUP BY 1, 2
),
c7_filled AS (
    SELECT g.cadence_id, g.week_start, COALESCE(wk.steps_surfaced, 0) AS steps_surfaced
    FROM c7_grid g LEFT JOIN c7_weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
c7_stats AS (
    SELECT *,
           AVG(steps_surfaced) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_mean,
           STDDEV(steps_surfaced) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_sd,
           COUNT(steps_surfaced) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_weeks
    FROM c7_filled
),
c7_agg AS (
    SELECT cadence_id, week_start, steps_surfaced AS value, baseline_mean, baseline_sd
    FROM c7_stats
    WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
      AND baseline_weeks >= 8 AND baseline_mean >= 10
      AND steps_surfaced <= baseline_mean - 2 * baseline_sd
),

-- ── Check 8: Drop in Steps Completed (8-week baseline, 2 SD, min 10) ──────
c8_cadence_list AS (
    SELECT DISTINCT cadence_id__c AS cadence_id
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
),
c8_weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
c8_grid AS (
    SELECT c.cadence_id, w.week_start FROM c8_cadence_list c CROSS JOIN c8_weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
c8_weekly AS (
    SELECT cadence_id__c AS cadence_id, DATE_TRUNC('week', result_date_time__c::date) AS week_start, COUNT(*) AS steps_completed
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND result__c IS NOT NULL AND result__c NOT IN ('', 'Displayed')
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
    GROUP BY 1, 2
),
c8_filled AS (
    SELECT g.cadence_id, g.week_start, COALESCE(wk.steps_completed, 0) AS steps_completed
    FROM c8_grid g LEFT JOIN c8_weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
c8_stats AS (
    SELECT *,
           AVG(steps_completed) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_mean,
           STDDEV(steps_completed) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_sd,
           COUNT(steps_completed) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_weeks
    FROM c8_filled
),
c8_agg AS (
    SELECT cadence_id, week_start, steps_completed AS value, baseline_mean, baseline_sd
    FROM c8_stats
    WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
      AND baseline_weeks >= 8 AND baseline_mean >= 10
      AND steps_completed <= baseline_mean - 2 * baseline_sd
),

-- ── Check 9: Email Volume Drops/Spikes (8-week baseline, 2 SD, min 10) ────
c9_cadence_list AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
      AND (TRIM(cadence_id) ILIKE 'Pre-Enroll Flywheel:%' OR TRIM(cadence_id) ILIKE 'Post-Enroll Flywheel:%')
),
c9_weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
c9_grid AS (
    SELECT c.cadence_id, w.week_start FROM c9_cadence_list c CROSS JOIN c9_weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
c9_weekly AS (
    SELECT cl.cadence_id, DATE_TRUNC('week', dcl.comm_date) AS week_start, COUNT(*) AS email_volume
    FROM marts.communication.detail_communication_lifecycle dcl
    JOIN c9_cadence_list cl ON dcl.workflow_name ILIKE '%' || cl.cadence_id || '%'
    WHERE dcl.comm_type = 'email'
    GROUP BY 1, 2
),
c9_filled AS (
    SELECT g.cadence_id, g.week_start, COALESCE(wk.email_volume, 0) AS email_volume
    FROM c9_grid g LEFT JOIN c9_weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
c9_stats AS (
    SELECT *,
           AVG(email_volume) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_mean,
           STDDEV(email_volume) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_sd,
           COUNT(email_volume) OVER (PARTITION BY cadence_id ORDER BY week_start ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_weeks
    FROM c9_filled
),
c9_agg AS (
    SELECT cadence_id, week_start, email_volume AS value, baseline_mean, baseline_sd, 'drop' AS direction
    FROM c9_stats
    WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
      AND baseline_weeks >= 8 AND baseline_mean >= 10 AND email_volume <= baseline_mean - 2 * baseline_sd
    UNION ALL
    SELECT cadence_id, week_start, email_volume AS value, baseline_mean, baseline_sd, 'spike' AS direction
    FROM c9_stats
    WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
      AND baseline_weeks >= 8 AND baseline_mean >= 10 AND email_volume >= baseline_mean + 2 * baseline_sd
)

-- ── Final UNION ALL — normalized to the common 7-column schema ───────────
SELECT 1 AS check_number, 'No Starts in 7 Days' AS check_name, cadence_id,
       starts_last_7d AS metric_value, 7 AS reference_value,
       'last_start_ts=' || TO_VARCHAR(last_start_ts) AS detail, CURRENT_DATE() AS as_of
FROM c1_agg WHERE starts_last_4mo >= 1 AND starts_last_7d = 0

UNION ALL
SELECT 2, 'Double Starts', cadence_id,
       double_start_count, NULL,
       'pros_affected=' || pros_affected, CURRENT_DATE()
FROM c2_agg

UNION ALL
SELECT 3, 'Double Exits', cadence_id,
       double_exit_count, NULL,
       'pros_affected=' || pros_affected, CURRENT_DATE()
FROM c3_agg

UNION ALL
SELECT 4, 'Entered Not Exited in 100+ Days', cadence_id,
       newly_stuck_pros, 100,
       'longest_days_in_cadence=' || longest_days_in_cadence, CURRENT_DATE()
FROM c4_agg

UNION ALL
SELECT 5, 'Drop in Weekly Entries/Exits', cadence_id,
       value, ROUND(baseline_mean, 1),
       'metric=' || metric_name || '; baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c5_agg

UNION ALL
SELECT 6, 'No Steps Surfaced in 7 Days', cadence_id,
       surfaced_last_7d, 7,
       'last_surfaced_ts=' || TO_VARCHAR(last_surfaced_ts), CURRENT_DATE()
FROM c6_agg WHERE surfaced_last_4mo >= 1 AND surfaced_last_7d = 0

UNION ALL
SELECT 7, 'Drop in Steps Surfaced', cadence_id,
       value, ROUND(baseline_mean, 1),
       'baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c7_agg

UNION ALL
SELECT 8, 'Drop in Steps Completed', cadence_id,
       value, ROUND(baseline_mean, 1),
       'baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c8_agg

UNION ALL
SELECT 9, 'Email Volume Drops/Spikes', cadence_id,
       value, ROUND(baseline_mean, 1),
       'direction=' || direction || '; baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c9_agg

ORDER BY check_number, cadence_id;
