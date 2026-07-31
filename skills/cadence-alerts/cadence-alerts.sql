-- Cadence Mechanical Alerts — batched across ALL active cadences (unlike bug-diagnostic.sql,
-- which runs one cadence at a time). "Active" = had a Start row in the trailing 180 days.
-- Definitions: knowledge/resources-and-methodology.md. Caveats: knowledge/data-quality-caveats.md.
-- Run checks 1-4 daily, checks 5-7 weekly (see SKILL.md). Each check is standalone/runnable alone.
--
-- NOTE: `cadence_name` does NOT exist on fact_journey_progress_checkpoint (verified live —
-- knowledge/schema.md line 28 is wrong on this point, flag for correction). `cadence_id` IS the
-- free-text descriptive label (e.g. "Post-Enroll Flywheel: Warming") — filter/match on it directly.
--
-- Checks 2-4 use a baseline-relative anomaly rule, NOT "any occurrence" — validated against real
-- data (2026-07-30): several cadences are recurring/evergreen by design (HCP NPS Survey
-- 25-90-150-Recurring, Warming, Upsell, Abandoned My Apps Page, Inbound In Trial) and have
-- permanently high double-start/double-exit/stuck counts. "Any occurrence" would alert on all of
-- them daily. Instead: flag a cadence only if today's count is either (a) a brand-new anomaly in
-- a cadence with ~zero historical baseline, or (b) >=3 std devs above its own 34-day trailing mean
-- AND the absolute count is >=3 (avoids noise on cadences where 1-2 events is a huge % swing but a
-- trivial absolute count). Both the 3-stddev multiplier and the min-count-3 floor are defaults —
-- adjust with real alert volume/false-positive feedback (see SKILL.md).

-- ── 1. No Starts in 7 days (all active cadences) ─────────────────────────
SELECT TRIM(cadence_id) AS cadence_id,
       MAX(event_timestamp) AS last_start_ts,
       DATEDIFF(day, MAX(event_timestamp), CURRENT_DATE()) AS days_since_last_start
FROM analytics.main.fact_journey_progress_checkpoint
WHERE cadence_step = 'Start'
  AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())   -- defines "active"; bounds the scan
GROUP BY 1
HAVING DATEDIFF(day, MAX(event_timestamp), CURRENT_DATE()) >= 7
ORDER BY days_since_last_start DESC;

-- ── 2. Double Starts — anomaly vs. each cadence's own 34-day baseline ────
WITH active_cadences AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start' AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())
),
days AS (
    SELECT DATEADD(day, -seq4(), CURRENT_DATE()) AS day
    FROM TABLE(GENERATOR(ROWCOUNT => 35))              -- yesterday + 34 prior days for baseline
),
grid AS (
    SELECT c.cadence_id, d.day FROM active_cadences c CROSS JOIN days d
),
starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS start_seq,
           LAG(event_timestamp) OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS prev_start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
),
exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
),
double_starts AS (
    SELECT s.cadence_id, s.email, s.prev_start_ts, s.event_timestamp AS this_start_ts,
           s.event_timestamp::date AS event_date
    FROM starts s
    WHERE s.start_seq > 1
      AND s.event_timestamp >= DATEADD(day, -36, CURRENT_DATE())
      AND NOT EXISTS (SELECT 1 FROM exits e
                      WHERE e.cadence_id = s.cadence_id AND e.email = s.email
                        AND e.exit_ts > s.prev_start_ts AND e.exit_ts < s.event_timestamp)
),
daily AS (
    SELECT cadence_id, event_date, COUNT(*) AS cnt FROM double_starts GROUP BY 1, 2
),
joined AS (
    SELECT g.cadence_id, g.day, COALESCE(dl.cnt, 0) AS cnt
    FROM grid g LEFT JOIN daily dl ON dl.cadence_id = g.cadence_id AND dl.event_date = g.day
),
stats AS (
    SELECT cadence_id,
           AVG(CASE WHEN day < DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS baseline_mean,
           STDDEV(CASE WHEN day < DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS baseline_stddev,
           MAX(CASE WHEN day = DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS latest_cnt
    FROM joined GROUP BY cadence_id
)
SELECT cadence_id, latest_cnt, ROUND(baseline_mean, 2) AS baseline_mean, ROUND(baseline_stddev, 2) AS baseline_stddev
FROM stats
WHERE (COALESCE(baseline_mean, 0) = 0 AND latest_cnt > 0)
   OR (latest_cnt >= 3 AND latest_cnt > baseline_mean + 3 * COALESCE(baseline_stddev, 0))
ORDER BY latest_cnt DESC;
-- Drill-down (run only for a flagged cadence, to get sample emails for the alert/ledger):
--   SELECT email, prev_start_ts, this_start_ts FROM <double_starts CTE above>
--   WHERE cadence_id = '<flagged cadence>' AND event_date = DATEADD(day,-1,CURRENT_DATE());

-- ── 3. Double Exits — anomaly vs. each cadence's own 34-day baseline ─────
WITH active_cadences AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start' AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())
),
days AS (
    SELECT DATEADD(day, -seq4(), CURRENT_DATE()) AS day
    FROM TABLE(GENERATOR(ROWCOUNT => 35))
),
grid AS (
    SELECT c.cadence_id, d.day FROM active_cadences c CROSS JOIN days d
),
exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp,
           ROW_NUMBER() OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS exit_seq,
           LAG(event_timestamp) OVER (PARTITION BY TRIM(cadence_id), email ORDER BY event_timestamp) AS prev_exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
),
starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
),
double_exits AS (
    SELECT e.cadence_id, e.email, e.prev_exit_ts, e.event_timestamp AS this_exit_ts,
           e.event_timestamp::date AS event_date
    FROM exits e
    WHERE e.exit_seq > 1
      AND e.event_timestamp >= DATEADD(day, -36, CURRENT_DATE())
      AND NOT EXISTS (SELECT 1 FROM starts s
                      WHERE s.cadence_id = e.cadence_id AND s.email = e.email
                        AND s.start_ts > e.prev_exit_ts AND s.start_ts < e.event_timestamp)
),
daily AS (
    SELECT cadence_id, event_date, COUNT(*) AS cnt FROM double_exits GROUP BY 1, 2
),
joined AS (
    SELECT g.cadence_id, g.day, COALESCE(dl.cnt, 0) AS cnt
    FROM grid g LEFT JOIN daily dl ON dl.cadence_id = g.cadence_id AND dl.event_date = g.day
),
stats AS (
    SELECT cadence_id,
           AVG(CASE WHEN day < DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS baseline_mean,
           STDDEV(CASE WHEN day < DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS baseline_stddev,
           MAX(CASE WHEN day = DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS latest_cnt
    FROM joined GROUP BY cadence_id
)
SELECT cadence_id, latest_cnt, ROUND(baseline_mean, 2) AS baseline_mean, ROUND(baseline_stddev, 2) AS baseline_stddev
FROM stats
WHERE (COALESCE(baseline_mean, 0) = 0 AND latest_cnt > 0)
   OR (latest_cnt >= 3 AND latest_cnt > baseline_mean + 3 * COALESCE(baseline_stddev, 0))
ORDER BY latest_cnt DESC;
-- Drill-down (sample emails, same pattern as check 2's double_starts CTE, on double_exits).

-- ── 4. Newly stuck >100 days — anomaly vs. each cadence's own 34-day baseline ──
-- "Newly stuck" = pros who crossed the 100-day-no-exit mark on that specific day, not the total
-- open backlog (the backlog itself is dominated by long-running/evergreen cadences by design —
-- see the note at the top of this file). This tracks whether NEW pros are getting stuck, i.e.
-- whether exit automation just started failing for a subset, not the steady-state population.
WITH active_cadences AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start' AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())
),
days AS (
    SELECT DATEADD(day, -seq4(), CURRENT_DATE()) AS day
    FROM TABLE(GENERATOR(ROWCOUNT => 35))
),
grid AS (
    SELECT c.cadence_id, d.day FROM active_cadences c CROSS JOIN days d
),
starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp)::date AS start_date
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
    GROUP BY 1, 2
),
exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
    GROUP BY 1, 2
),
crossings AS (
    SELECT d.day, s.cadence_id, s.email
    FROM days d
    JOIN starts s ON s.start_date = DATEADD(day, -100, d.day)
    LEFT JOIN exits e ON e.cadence_id = s.cadence_id AND e.email = s.email
    WHERE e.email IS NULL OR e.exit_ts > d.day
),
daily AS (
    SELECT cadence_id, day, COUNT(*) AS cnt FROM crossings GROUP BY 1, 2
),
joined AS (
    SELECT g.cadence_id, g.day, COALESCE(dl.cnt, 0) AS cnt
    FROM grid g LEFT JOIN daily dl ON dl.cadence_id = g.cadence_id AND dl.day = g.day
),
stats AS (
    SELECT cadence_id,
           AVG(CASE WHEN day < DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS baseline_mean,
           STDDEV(CASE WHEN day < DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS baseline_stddev,
           MAX(CASE WHEN day = DATEADD(day, -1, CURRENT_DATE()) THEN cnt END) AS latest_cnt
    FROM joined GROUP BY cadence_id
)
SELECT cadence_id, latest_cnt, ROUND(baseline_mean, 2) AS baseline_mean, ROUND(baseline_stddev, 2) AS baseline_stddev
FROM stats
WHERE (COALESCE(baseline_mean, 0) = 0 AND latest_cnt > 0)
   OR (latest_cnt >= 3 AND latest_cnt > baseline_mean + 3 * COALESCE(baseline_stddev, 0))
ORDER BY latest_cnt DESC;
-- Drill-down (sample emails for a flagged cadence):
--   SELECT email FROM <crossings CTE above> WHERE cadence_id = '<flagged cadence>'
--   AND day = DATEADD(day,-1,CURRENT_DATE());

-- ── 5. Drop in weekly entries/exits — all cadences, fixed threshold ──────
-- Alert: >=25% drop vs. prior week AND prior week volume >=10 (avoids noise on low-volume
-- cadences where a 25% swing is 1-2 pros). Both adjustable — see SKILL.md. Weekly grain is much
-- less noisy than daily (validated against real data: 5 cadences flagged, all plausible).
-- Only evaluates the most recently *complete* week (excludes the in-progress current week).
WITH active_cadences AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start' AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 12))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM active_cadences c CROSS JOIN weeks w
),
weekly AS (
    SELECT TRIM(cadence_id) AS cadence_id,
           DATE_TRUNC('week', event_timestamp::date) AS week_start,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Start' THEN email END) AS entries,
           COUNT(DISTINCT CASE WHEN cadence_step = 'Exit'  THEN email END) AS exits
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step IN ('Start', 'Exit')
    GROUP BY 1, 2
),
joined AS (
    SELECT g.cadence_id, g.week_start,
           COALESCE(wk.entries, 0) AS entries,
           COALESCE(wk.exits, 0)   AS exits,
           LAG(COALESCE(wk.entries, 0)) OVER (PARTITION BY g.cadence_id ORDER BY g.week_start) AS prior_week_entries,
           LAG(COALESCE(wk.exits, 0))   OVER (PARTITION BY g.cadence_id ORDER BY g.week_start) AS prior_week_exits
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
)
SELECT cadence_id, week_start, entries, prior_week_entries,
       ROUND(100.0 * (entries - prior_week_entries) / NULLIF(prior_week_entries, 0), 1) AS entries_pct_change,
       exits, prior_week_exits,
       ROUND(100.0 * (exits - prior_week_exits) / NULLIF(prior_week_exits, 0), 1) AS exits_pct_change
FROM joined
WHERE week_start = DATE_TRUNC('week', DATEADD('week', -1, CURRENT_DATE()))   -- last complete week
  AND ((prior_week_entries >= 10 AND (entries - prior_week_entries) / NULLIF(prior_week_entries, 0) <= -0.25)
    OR (prior_week_exits   >= 10 AND (exits   - prior_week_exits)   / NULLIF(prior_week_exits, 0)   <= -0.25))
ORDER BY cadence_id;

-- ── 6. Drop in steps surfaced — all cadences except known-quiet ones ─────
-- Known-quiet cadences (Post-Enroll Flywheel: ARPA Engagement, Type 1 Onboarding, Type 1
-- Adoption, Type 1 Nurture, Activation, Warming) are excluded — near-zero surfaced volume is
-- expected there, not a bug. See knowledge/data-quality-caveats.md #10. Matched on `cadence_id`
-- directly (there is no separate `cadence_name` column — see note at top of this file).
WITH known_quiet_ids AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_id ILIKE ANY ('%ARPA Engagement%', '%Type 1 Onboarding%', '%Type 1 Adoption%',
                                 '%Type 1 Nurture%', '%Activation%', '%Warming%')
),
active_cadences AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start' AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())
      AND TRIM(cadence_id) NOT IN (SELECT cadence_id FROM known_quiet_ids)
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 12))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM active_cadences c CROSS JOIN weeks w
),
weekly AS (
    SELECT cadence_id__c AS cadence_id, DATE_TRUNC('week', createddate::date) AS week_start,
           COUNT(*) AS steps_surfaced
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
    GROUP BY 1, 2
),
joined AS (
    SELECT g.cadence_id, g.week_start,
           COALESCE(wk.steps_surfaced, 0) AS steps_surfaced,
           LAG(COALESCE(wk.steps_surfaced, 0)) OVER (PARTITION BY g.cadence_id ORDER BY g.week_start) AS prior_week
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
)
SELECT cadence_id, week_start, steps_surfaced, prior_week,
       ROUND(100.0 * (steps_surfaced - prior_week) / NULLIF(prior_week, 0), 1) AS pct_change
FROM joined
WHERE week_start = DATE_TRUNC('week', DATEADD('week', -1, CURRENT_DATE()))
  AND prior_week >= 10
  AND (steps_surfaced - prior_week) / NULLIF(prior_week, 0) <= -0.25
ORDER BY cadence_id;

-- ── 7. Drop in steps completed — all cadences except known-quiet ones ────
-- Same exclusion list as check 6 (near-zero completed follows from near-zero surfaced there).
WITH known_quiet_ids AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_id ILIKE ANY ('%ARPA Engagement%', '%Type 1 Onboarding%', '%Type 1 Adoption%',
                                 '%Type 1 Nurture%', '%Activation%', '%Warming%')
),
active_cadences AS (
    SELECT DISTINCT TRIM(cadence_id) AS cadence_id
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start' AND event_timestamp >= DATEADD(day, -180, CURRENT_DATE())
      AND TRIM(cadence_id) NOT IN (SELECT cadence_id FROM known_quiet_ids)
),
weeks AS (
    SELECT DATE_TRUNC('week', DATEADD('week', -seq4(), CURRENT_DATE())) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 12))
),
grid AS (
    SELECT c.cadence_id, w.week_start FROM active_cadences c CROSS JOIN weeks w
),
weekly AS (
    SELECT cadence_id__c AS cadence_id, DATE_TRUNC('week', result_date_time__c::date) AS week_start,
           COUNT(*) AS steps_completed
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND result__c IS NOT NULL AND result__c != 'Displayed'
    GROUP BY 1, 2
),
joined AS (
    SELECT g.cadence_id, g.week_start,
           COALESCE(wk.steps_completed, 0) AS steps_completed,
           LAG(COALESCE(wk.steps_completed, 0)) OVER (PARTITION BY g.cadence_id ORDER BY g.week_start) AS prior_week
    FROM grid g
    LEFT JOIN weekly wk ON wk.cadence_id = g.cadence_id AND wk.week_start = g.week_start
)
SELECT cadence_id, week_start, steps_completed, prior_week,
       ROUND(100.0 * (steps_completed - prior_week) / NULLIF(prior_week, 0), 1) AS pct_change
FROM joined
WHERE week_start = DATE_TRUNC('week', DATEADD('week', -1, CURRENT_DATE()))
  AND prior_week >= 10
  AND (steps_completed - prior_week) / NULLIF(prior_week, 0) <= -0.25
ORDER BY cadence_id;
