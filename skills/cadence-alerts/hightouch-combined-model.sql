-- Hightouch model SQL — all 9 Cadence Mechanical Alerts checks, UNION ALL'd into one normalized
-- result set for a single Google Sheets sync (one tab, a `check_number` column distinguishes
-- checks). Paste this whole file as the model's SQL in Hightouch.
--
-- This mirrors cadence-alerts.sql's logic exactly (same filters, same thresholds, same domain/
-- cadence exclusions) — it is NOT a different or simplified version. Keep it in sync with
-- cadence-alerts.sql by hand whenever a threshold/filter changes there; see SKILL.md's
-- "Hightouch pipeline" section for the tradeoff this creates (SQL now lives in two places).
--
-- Output schema (every check normalizes to these 9 columns):
--   id             TEXT    -- UNIQUE PER ROW — map this as the primary key in Hightouch's sync
--                             config. check_number|cadence_id|as_of, plus |sub_key for checks 5/9
--                             (see "id" note above the final UNION ALL for why it's built this way)
--   check_number   INT     -- 1-9, matches cadence-alerts.sql / SKILL.md numbering
--   check_name     TEXT    -- human-readable check name, for the Slack message headline
--   cadence_id     TEXT    -- the flagged cadence
--   sub_key        TEXT    -- disambiguates checks 5 ('entries'/'exits') and 9 ('drop'/'spike');
--                             NULL for every other check, which only ever emit one row per
--                             cadence+as_of
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

-- ── Check 2: Double Starts (>10% of trailing-7-day starts, HCP NPS excluded) ──
-- REVISED 2026-08-03 (manager feedback): raw count → % of trailing-7-day total starts.
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
c2_doubles AS (
    SELECT s.cadence_id, s.email
    FROM c2_starts s
    WHERE s.start_seq > 1
      AND s.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
      AND NOT EXISTS (SELECT 1 FROM c2_exits e
                      WHERE e.cadence_id = s.cadence_id AND e.email = s.email
                        AND e.exit_ts > s.prev_start_ts AND e.exit_ts < s.event_timestamp)
),
c2_totals AS (
    SELECT cadence_id, COUNT(*) AS total_starts_7d
    FROM c2_starts
    WHERE event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
    GROUP BY cadence_id
),
c2_agg AS (
    SELECT d.cadence_id,
           COUNT(*) AS double_start_count,
           COUNT(DISTINCT d.email) AS pros_affected,
           t.total_starts_7d,
           ROUND(COUNT(*) / NULLIF(t.total_starts_7d, 0), 4) AS double_start_pct
    FROM c2_doubles d
    JOIN c2_totals t ON t.cadence_id = d.cadence_id
    GROUP BY d.cadence_id, t.total_starts_7d
),

-- ── Check 3: Double Exits (>10% of trailing-7-day exits, HCP NPS excluded) ──
-- REVISED 2026-08-03 (manager feedback): raw count → % of trailing-7-day total exits.
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
c3_doubles AS (
    SELECT e.cadence_id, e.email
    FROM c3_exits e
    WHERE e.exit_seq > 1
      AND e.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
      AND NOT EXISTS (SELECT 1 FROM c3_starts s
                      WHERE s.cadence_id = e.cadence_id AND s.email = e.email
                        AND s.start_ts > e.prev_exit_ts AND s.start_ts < e.event_timestamp)
),
c3_totals AS (
    SELECT cadence_id, COUNT(*) AS total_exits_7d
    FROM c3_exits
    WHERE event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
    GROUP BY cadence_id
),
c3_agg AS (
    SELECT d.cadence_id,
           COUNT(*) AS double_exit_count,
           COUNT(DISTINCT d.email) AS pros_affected,
           t.total_exits_7d,
           ROUND(COUNT(*) / NULLIF(t.total_exits_7d, 0), 4) AS double_exit_pct
    FROM c3_doubles d
    JOIN c3_totals t ON t.cadence_id = d.cadence_id
    GROUP BY d.cadence_id, t.total_exits_7d
),

-- ── Check 4: Stuck >100 days (>=10% of currently-active pros in the cadence) ──
-- REVISED 2026-08-03 (manager feedback): "newly crossed in trailing 7 days" count → % of the
-- cadence's own currently-active pool (entered, not yet exited) that's stuck >=100 days.
-- REVISED AGAIN 2026-08-05 (Diego): trailing-120-day entrant window on Start, to keep ancient
-- perpetual-not-exited pros from dominating the active-pool denominator (see cadence-alerts.sql's
-- check-4 header comment for the sign-bug catch/fix history — the shipped filter is `-120`, not
-- `+120`).
c4_starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
      AND event_timestamp >= DATEADD(day, -120, CURRENT_DATE())
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
c4_active AS (
    SELECT s.cadence_id, s.email, DATEDIFF(day, s.start_ts, CURRENT_DATE()) AS days_in_cadence
    FROM c4_starts s
    LEFT JOIN c4_exits e ON e.cadence_id = s.cadence_id AND e.email = s.email AND e.exit_ts > s.start_ts
    WHERE e.email IS NULL
),
c4_agg AS (
    SELECT cadence_id,
           COUNT(*) AS active_pros,
           COUNT_IF(days_in_cadence >= 100) AS stuck_pros,
           ROUND(COUNT_IF(days_in_cadence >= 100) / NULLIF(COUNT(*), 0), 4) AS stuck_pct,
           MAX(days_in_cadence) AS longest_days_in_cadence
    FROM c4_active
    GROUP BY cadence_id
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

-- ── Check 6: Low Engagement on Recent Starts (<10% of the 3-10 day cohort engaged) ──
-- REDEFINED 2026-08-05 (Mario's request via Slack thread) — mirrors cadence-alerts.sql's check 6
-- exactly; see that file's header comment for the full rationale/history. Cohort = pros whose
-- Start fell 3-10 days ago; engaged = ANY step surfaced, step completed, or email sent for that
-- cadence, any time from their Start through today; alert if engaged_pct < 10%.
-- 2026-08-05 live validation (19 cadences currently have a 3-10 day cohort): 4 cleared <10% on
-- first pass, incl. `HCP NPS Survey 25-90-150-Recurring` (0.03%) — added to the exclusion list
-- below (Diego, 2026-08-05) since it's non-rep-driven the same way Warming/Activation are, and
-- checks 2-4 already exclude it by name. `Post-Enroll Flywheel: Onboarding Email` (0%) still
-- clears <10% and is NOT excluded yet — same non-rep-driven/inherently-sparse pattern, but left as
-- a first-week watch item per the check-4 precedent (ship as requested, let the (checkmark)/(x)
-- reaction loop decide) rather than adding it unilaterally.
c6_cohort AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%ARPA Engagement%', '%Type 1 Onboarding%', '%Type 1 Adoption%',
                                            '%Type 1 Nurture%', '%Activation%', '%Warming%', '%HCP NPS%')
      AND event_timestamp::date BETWEEN DATEADD(day, -10, CURRENT_DATE()) AND DATEADD(day, -3, CURRENT_DATE())
),
c6_steps AS (
    SELECT TRIM(cadence_id__c) AS cadence_id, email__c AS email, createddate, result_date_time__c
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
),
c6_emails_sent AS (
    SELECT dcl.workflow_name, de.pro_email_address AS email, dcl.comm_date
    FROM marts.communication.detail_communication_lifecycle dcl
    JOIN marts.communication.detail_emails de ON dcl.comm_id = de.message_id
    WHERE dcl.workflow_name IS NOT NULL
),
c6_engaged AS (
    SELECT c.cadence_id, c.email
    FROM c6_cohort c
    JOIN c6_steps s ON s.cadence_id = c.cadence_id AND s.email = c.email
                    AND (s.createddate >= c.start_ts OR s.result_date_time__c >= c.start_ts)
    UNION
    SELECT c.cadence_id, c.email
    FROM c6_cohort c
    JOIN c6_emails_sent e ON e.workflow_name ILIKE '%' || c.cadence_id || '%' AND e.email = c.email
                          AND e.comm_date >= c.start_ts
),
c6_agg AS (
    SELECT c.cadence_id,
           COUNT(DISTINCT c.email)  AS cohort_size,
           COUNT(DISTINCT eg.email) AS engaged_count,
           ROUND(COUNT(DISTINCT eg.email) / NULLIF(COUNT(DISTINCT c.email), 0), 4) AS engaged_pct
    FROM c6_cohort c
    LEFT JOIN c6_engaged eg ON eg.cadence_id = c.cadence_id AND eg.email = c.email
    GROUP BY c.cadence_id
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

-- ── Final UNION ALL — normalized to the common schema, plus a unique `id` ──
-- Hightouch (like any sync tool) requires a primary-key column to tell rows apart between runs.
-- `check_number` + `cadence_id` + `as_of` is unique for every check EXCEPT 5 and 9, which can
-- emit two rows for the same cadence/week (entries vs. exits; drop vs. spike) — `sub_key` carries
-- that differentiator (NULL everywhere else). `id` concatenates all four into one text column so
-- Hightouch has a single field to map as the primary key, regardless of whether composite keys
-- are supported for the destination. Built to be STABLE across re-runs of the same period (same
-- check+cadence+as_of+sub_key → same id → Hightouch updates that row in place with fresher
-- numbers) but CHANGE when the period rolls over (as_of advances daily for checks 1-4/6, weekly
-- for 5/7/8/9) — so history accumulates as new rows instead of being silently overwritten.
SELECT '1|' || cadence_id || '|' || TO_VARCHAR(CURRENT_DATE()) AS id,
       1 AS check_number, 'No Starts in 7 Days' AS check_name, cadence_id, NULL AS sub_key,
       starts_last_7d AS metric_value, 7 AS reference_value,
       'last_start_ts=' || TO_VARCHAR(last_start_ts) AS detail, CURRENT_DATE() AS as_of
FROM c1_agg WHERE starts_last_4mo >= 1 AND starts_last_7d = 0

UNION ALL
SELECT '2|' || cadence_id || '|' || TO_VARCHAR(CURRENT_DATE()),
       2, 'Double Starts', cadence_id, NULL,
       double_start_pct, 0.10,
       'double_start_count=' || double_start_count || '; total_starts_7d=' || total_starts_7d
           || '; pros_affected=' || pros_affected,
       CURRENT_DATE()
FROM c2_agg WHERE double_start_pct > 0.10

UNION ALL
SELECT '3|' || cadence_id || '|' || TO_VARCHAR(CURRENT_DATE()),
       3, 'Double Exits', cadence_id, NULL,
       double_exit_pct, 0.10,
       'double_exit_count=' || double_exit_count || '; total_exits_7d=' || total_exits_7d
           || '; pros_affected=' || pros_affected,
       CURRENT_DATE()
FROM c3_agg WHERE double_exit_pct > 0.10

UNION ALL
SELECT '4|' || cadence_id || '|' || TO_VARCHAR(CURRENT_DATE()),
       4, 'Entered Not Exited in 100+ Days', cadence_id, NULL,
       stuck_pct, 0.10,
       'stuck_pros=' || stuck_pros || '; active_pros=' || active_pros
           || '; longest_days_in_cadence=' || longest_days_in_cadence,
       CURRENT_DATE()
FROM c4_agg WHERE stuck_pct >= 0.10

UNION ALL
SELECT '5|' || cadence_id || '|' || TO_VARCHAR(week_start) || '|' || metric_name,
       5, 'Drop in Weekly Entries/Exits', cadence_id, metric_name,
       value, ROUND(baseline_mean, 1),
       'metric=' || metric_name || '; baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c5_agg

UNION ALL
SELECT '6|' || cadence_id || '|' || TO_VARCHAR(CURRENT_DATE()),
       6, 'Low Engagement on Recent Starts', cadence_id, NULL,
       engaged_pct, 0.10,
       'cohort_size=' || cohort_size || '; engaged_count=' || engaged_count,
       CURRENT_DATE()
FROM c6_agg WHERE engaged_pct < 0.10

UNION ALL
SELECT '7|' || cadence_id || '|' || TO_VARCHAR(week_start),
       7, 'Drop in Steps Surfaced', cadence_id, NULL,
       value, ROUND(baseline_mean, 1),
       'baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c7_agg

UNION ALL
SELECT '8|' || cadence_id || '|' || TO_VARCHAR(week_start),
       8, 'Drop in Steps Completed', cadence_id, NULL,
       value, ROUND(baseline_mean, 1),
       'baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c8_agg

UNION ALL
SELECT '9|' || cadence_id || '|' || TO_VARCHAR(week_start) || '|' || direction,
       9, 'Email Volume Drops/Spikes', cadence_id, direction,
       value, ROUND(baseline_mean, 1),
       'direction=' || direction || '; baseline_sd=' || ROUND(baseline_sd, 1) || '; week_start=' || TO_VARCHAR(week_start),
       week_start
FROM c9_agg

ORDER BY check_number, cadence_id;
