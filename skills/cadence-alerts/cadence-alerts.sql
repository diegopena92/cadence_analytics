-- Cadence Mechanical Alerts — 9-check methodology, adopted from the "Multi-Cadence Bug
-- Diagnostic" artifact shared by the requester's manager (2026-07-31), verified 2026-07-28/29.
-- Numbering matches that source doc exactly (1-9) for traceability. Definitions:
-- knowledge/resources-and-methodology.md. Caveats: knowledge/data-quality-caveats.md.
-- Run checks 1,2,3,4,6 daily; checks 5,7,8,9 weekly (see SKILL.md). Standalone/runnable individually.
--
-- KEY FIX vs. the original 7-check version of this file: every check now excludes internal/test
-- traffic (`housecallpro.com`, `gethousecallpro.com` email domains) — the source artifact found
-- 23,198 + 913 rows of internal test-account activity inflating counts. `placeholder.email` stays
-- in scope. `cadence_name` does NOT exist on fact_journey_progress_checkpoint (verified live) —
-- `cadence_id` itself is the free-text descriptive label.
--
-- CHECKS 2-4 ADAPTATION FOR LIVE DAILY ALERTING (revised 2026-07-31): the source artifact's
-- checks 2-4 are all-time cumulative counts with no date window (a one-time diagnostic snapshot)
-- — posting that literally every day would repeat a huge, barely-changing number forever for
-- recurring/evergreen cadences (the source doc itself flags these as needing human review, not as
-- bugs). Current approach: window checks 2-4 to a trailing 7-day count (not all-time), and exclude
-- known recurring-by-design cadences by name via `NOT TRIM(cadence_id) ILIKE ANY (...)` — starting
-- with `HCP NPS Survey 25-90-150-Recurring` (resent every 25/90/150 days by design). This replaces
-- an earlier 34-day statistical-baseline-anomaly version of this file (kept simpler/more
-- explainable per the requester 2026-07-31) — add more cadences to the exclusion list as real
-- alerts surface them (Warming, Upsell, Abandoned My Apps Page, Retention - SaaS Cancellation, and
-- Inbound In Trial are also known-recurring from 2026-07-30 validation but not yet excluded; watch
-- for them). Checks 1, 5, 6, 7, 8, 9 are used as specified in the source doc (silence gates /
-- 8-week rolling 2-stddev baselines are already windowed and don't have this problem).

-- ── CHECK 1: No Starts in 7 Days ──────────────────────────────────────────
WITH cadence_events AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, cadence_step, event_timestamp
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
)
SELECT
    cadence_id,
    COUNT_IF(event_timestamp >= DATEADD(month, -4, CURRENT_DATE())) AS starts_last_4mo,
    COUNT_IF(event_timestamp >= DATEADD(day, -7, CURRENT_DATE()))   AS starts_last_7d,
    MAX(event_timestamp)                                             AS last_start_ts
FROM cadence_events
GROUP BY cadence_id
HAVING starts_last_4mo >= 1
   AND starts_last_7d = 0
ORDER BY last_start_ts DESC;

-- ── CHECK 2: Double Starts — trailing 7 days, recurring-cadence exclusion list ──
-- Source doc's exact filters (Start rows, domain exclusion, no-Exit-between-two-Starts logic);
-- windowed to 7 days + name-exclusion-gated per the adaptation note above (not in the source doc).
WITH starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS start_seq,
           LAG(event_timestamp) OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS prev_start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
),
exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
)
SELECT s.cadence_id, COUNT(*) AS double_start_count, COUNT(DISTINCT s.email) AS pros_affected
FROM starts s
WHERE s.start_seq > 1
  AND s.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
  AND NOT EXISTS (
      SELECT 1 FROM exits e
      WHERE e.cadence_id = s.cadence_id AND e.email = s.email
        AND e.exit_ts > s.prev_start_ts AND e.exit_ts < s.event_timestamp
  )
GROUP BY s.cadence_id
ORDER BY double_start_count DESC;
-- Drill-down (sample emails for a flagged cadence): rerun the `starts`/`exits` CTEs above, select
-- s.email, s.prev_start_ts, s.event_timestamp WHERE s.cadence_id = '<flagged>' (same WHERE clause).

-- ── CHECK 3: Double Exits — trailing 7 days, recurring-cadence exclusion list ──
-- Mirror of check 2 on Exit rows. Same adaptation rationale.
WITH exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS exit_seq,
           LAG(event_timestamp) OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS prev_exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
),
starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
)
SELECT e.cadence_id, COUNT(*) AS double_exit_count, COUNT(DISTINCT e.email) AS pros_affected
FROM exits e
WHERE e.exit_seq > 1
  AND e.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
  AND NOT EXISTS (
      SELECT 1 FROM starts s
      WHERE s.cadence_id = e.cadence_id AND s.email = e.email
        AND s.start_ts > e.prev_exit_ts AND s.start_ts < e.event_timestamp
  )
GROUP BY e.cadence_id
ORDER BY double_exit_count DESC;

-- ── CHECK 4: Newly stuck >100 days — crossed the threshold in the trailing 7 days ──
-- "Newly stuck" = pros whose no-exit streak crossed 100 days sometime in the last 7 days (100 <=
-- days_in_cadence < 107), not the total open backlog (the backlog is dominated by long-running
-- evergreen cadences by design — the source doc's own check found HCP NPS Survey 25-90-150-
-- Recurring topping the backlog at 169,152 pros, consistent with being a long-running recurring
-- cadence, not a bug). Same recurring-cadence exclusion list as checks 2-3.
WITH starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
    GROUP BY 1, 2
),
exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
    GROUP BY 1, 2
)
SELECT s.cadence_id,
       COUNT(*) AS newly_stuck_pros,
       MAX(DATEDIFF(day, s.start_ts, CURRENT_DATE())) AS longest_days_in_cadence
FROM starts s
LEFT JOIN exits e ON e.cadence_id = s.cadence_id AND e.email = s.email AND e.exit_ts > s.start_ts
WHERE e.email IS NULL
  AND DATEDIFF(day, s.start_ts, CURRENT_DATE()) >= 100
  AND DATEDIFF(day, s.start_ts, CURRENT_DATE()) < 107
GROUP BY s.cadence_id
ORDER BY newly_stuck_pros DESC;

-- ── CHECK 5: Drop in Weekly Entries/Exits — 8-week baseline, 2 stddev, min 10/week ──
-- Verbatim from the source doc. Excludes the in-progress current week (required — without it,
-- the partial current week tripped the drop flag on nearly every cadence in testing).
WITH cadence_list AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM cadence_list c CROSS JOIN weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
weekly AS (
    SELECT TRIM(cadence_id) AS cadence_id,
           DATE_TRUNC('week', event_timestamp::date) AS week_start,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Start' THEN email END) AS entries,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Exit'  THEN email END) AS exits
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
    GROUP BY 1, 2
),
filled AS (
    SELECT g.cadence_id, g.week_start,
           COALESCE(wk.entries, 0) AS entries,
           COALESCE(wk.exits, 0)   AS exits
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
stats AS (
    SELECT *,
           AVG(entries) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS entries_baseline_mean,
           STDDEV(entries) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS entries_baseline_sd,
           COUNT(entries) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS entries_baseline_weeks,
           AVG(exits) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS exits_baseline_mean,
           STDDEV(exits) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS exits_baseline_sd,
           COUNT(exits) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS exits_baseline_weeks
    FROM filled
)
SELECT cadence_id, week_start, entries, exits,
       ROUND(entries_baseline_mean, 1) AS entries_baseline_mean,
       ROUND(entries_baseline_sd, 1)   AS entries_baseline_sd,
       ROUND(exits_baseline_mean, 1)   AS exits_baseline_mean,
       ROUND(exits_baseline_sd, 1)     AS exits_baseline_sd,
       (entries_baseline_weeks >= 8 AND entries_baseline_mean >= 10
            AND entries <= entries_baseline_mean - 2 * entries_baseline_sd) AS entries_drop_flag,
       (exits_baseline_weeks >= 8 AND exits_baseline_mean >= 10
            AND exits <= exits_baseline_mean - 2 * exits_baseline_sd)       AS exits_drop_flag
FROM stats
WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
  AND (entries_drop_flag OR exits_drop_flag)
ORDER BY cadence_id, week_start DESC;

-- ── CHECK 6: No Steps Surfaced in 7 Days ──────────────────────────────────
-- NEW (not in the original 7-check version). Same silence-gate shape as check 1, on the
-- Salesforce step-surfacing side — catches Iterable-to-Salesforce integration breaks.
-- CORRECTED 2026-07-31 (live validation caught this): the 4-month liveness gate does NOT
-- naturally exclude known-quiet cadences here — unlike check 1 (Start events, unrelated to the
-- known-quiet designation), a cadence designed to almost-never surface steps can still clear
-- `surfaced_last_4mo >= 1` (one stray surfaced step in 4 months is enough) and then trivially
-- show `surfaced_last_7d = 0` every single week, since it's inherently sparse. Confirmed live:
-- `Post-Enroll Flywheel: Warming` and `Post-Enroll Flywheel: Activation` (both known-quiet) fired
-- here before this fix. Explicit exclusion required, matching data-quality-caveats.md's list.
WITH surfaced_steps AS (
    SELECT cadence_id__c AS cadence_id, email__c AS email, createddate
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt'
      AND name != 'clear_step'
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT cadence_id__c ILIKE ANY ('%ARPA Engagement%', '%Type 1 Onboarding%', '%Type 1 Adoption%',
                                        '%Type 1 Nurture%', '%Activation%', '%Warming%')
)
SELECT
    cadence_id,
    COUNT_IF(createddate >= DATEADD(month, -4, CURRENT_DATE())) AS surfaced_last_4mo,
    COUNT_IF(createddate >= DATEADD(day, -7, CURRENT_DATE()))   AS surfaced_last_7d,
    MAX(createddate)                                             AS last_surfaced_ts
FROM surfaced_steps
GROUP BY cadence_id
HAVING surfaced_last_4mo >= 1
   AND surfaced_last_7d = 0
ORDER BY last_surfaced_ts DESC;

-- ── CHECK 7: Drop in Steps Surfaced — 8-week baseline, 2 stddev, min 10/week ──
-- Verbatim from the source doc. The min-10-volume floor naturally excludes known-quiet cadences
-- (their baseline_mean stays under 10) — no separate exclusion list needed.
WITH cadence_list AS (
    SELECT DISTINCT cadence_id__c AS cadence_id
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM cadence_list c CROSS JOIN weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
weekly AS (
    SELECT cadence_id__c AS cadence_id,
           DATE_TRUNC('week', createddate::date) AS week_start,
           COUNT(*) AS steps_surfaced
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
    GROUP BY 1, 2
),
filled AS (
    SELECT g.cadence_id, g.week_start, COALESCE(wk.steps_surfaced, 0) AS steps_surfaced
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
stats AS (
    SELECT *,
           AVG(steps_surfaced) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_mean,
           STDDEV(steps_surfaced) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_sd,
           COUNT(steps_surfaced) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_weeks
    FROM filled
)
SELECT cadence_id, week_start, steps_surfaced,
       ROUND(baseline_mean, 1) AS baseline_mean, ROUND(baseline_sd, 1) AS baseline_sd
FROM stats
WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
  AND baseline_weeks >= 8 AND baseline_mean >= 10
  AND steps_surfaced <= baseline_mean - 2 * baseline_sd
ORDER BY cadence_id, week_start DESC;

-- ── CHECK 8: Drop in Steps Completed — 8-week baseline, 2 stddev, min 10/week ──
-- Verbatim from the source doc. Completion excludes NULL and 'Displayed'; buckets by
-- result_date_time__c (can differ from the surfaced week).
WITH cadence_list AS (
    SELECT DISTINCT cadence_id__c AS cadence_id
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM cadence_list c CROSS JOIN weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
weekly AS (
    SELECT cadence_id__c AS cadence_id,
           DATE_TRUNC('week', result_date_time__c::date) AS week_start,
           COUNT(*) AS steps_completed
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND result__c IS NOT NULL AND result__c NOT IN ('', 'Displayed')
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
    GROUP BY 1, 2
),
filled AS (
    SELECT g.cadence_id, g.week_start, COALESCE(wk.steps_completed, 0) AS steps_completed
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
stats AS (
    SELECT *,
           AVG(steps_completed) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_mean,
           STDDEV(steps_completed) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_sd,
           COUNT(steps_completed) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_weeks
    FROM filled
)
SELECT cadence_id, week_start, steps_completed,
       ROUND(baseline_mean, 1) AS baseline_mean, ROUND(baseline_sd, 1) AS baseline_sd
FROM stats
WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
  AND baseline_weeks >= 8 AND baseline_mean >= 10
  AND steps_completed <= baseline_mean - 2 * baseline_sd
ORDER BY cadence_id, week_start DESC;

-- ── CHECK 9: Email Volume Drops/Spikes — 8-week baseline, 2 stddev, min 10/week ──
-- NEW (not in the original 7-check version). Verbatim from the source doc. Flags BOTH drops and
-- spikes (unlike checks 5/7/8, which only flag drops). Two known caveats from the source doc,
-- verified 2026-07-29, NOT fixed here (documented, not solved — spot-check any flag):
--   (1) name-match false positive: a shorter cadence name can substring-match comms belonging to
--       a longer, related cadence sharing the same prefix (join is workflow_name ILIKE
--       '%'||cadence_id||'%', not an exact/ID join — comms and checkpoint tables use different
--       workflow_ids for the same cadence, see data-quality-caveats.md #14).
--   (2) casing-duplicate cadence_ids produce duplicate identical-looking flags — e.g.
--       "Retention - SaaS Cancellation" and "Retention - SAAS Cancellation" returned the exact
--       same numbers as two separate rows (cadence_id is TRIM()'d but not case-normalized).
WITH cadence_list AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
      AND (TRIM(cadence_id) ILIKE 'Pre-Enroll Flywheel:%'
           OR TRIM(cadence_id) ILIKE 'Post-Enroll Flywheel:%')
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 26))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM cadence_list c CROSS JOIN weeks w
    WHERE w.week_start < DATE_TRUNC('week', CURRENT_DATE())
),
weekly AS (
    SELECT cl.cadence_id,
           DATE_TRUNC('week', dcl.comm_date) AS week_start,
           COUNT(*) AS email_volume
    FROM marts.communication.detail_communication_lifecycle dcl
    JOIN cadence_list cl ON dcl.workflow_name ILIKE '%' || cl.cadence_id || '%'
    WHERE dcl.comm_type = 'email'
    GROUP BY 1, 2
),
filled AS (
    SELECT g.cadence_id, g.week_start, COALESCE(wk.email_volume, 0) AS email_volume
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
),
stats AS (
    SELECT *,
           AVG(email_volume) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_mean,
           STDDEV(email_volume) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_sd,
           COUNT(email_volume) OVER (PARTITION BY cadence_id ORDER BY week_start
                               ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS baseline_weeks
    FROM filled
)
SELECT cadence_id, week_start, email_volume,
       ROUND(baseline_mean, 1) AS baseline_mean, ROUND(baseline_sd, 1) AS baseline_sd,
       (baseline_weeks >= 8 AND baseline_mean >= 10
            AND email_volume <= baseline_mean - 2 * baseline_sd) AS drop_flag,
       (baseline_weeks >= 8 AND baseline_mean >= 10
            AND email_volume >= baseline_mean + 2 * baseline_sd) AS spike_flag
FROM stats
WHERE week_start >= DATEADD(week, -4, CURRENT_DATE())
  AND ((baseline_weeks >= 8 AND baseline_mean >= 10 AND email_volume <= baseline_mean - 2 * baseline_sd)
    OR (baseline_weeks >= 8 AND baseline_mean >= 10 AND email_volume >= baseline_mean + 2 * baseline_sd))
ORDER BY cadence_id, week_start DESC;
