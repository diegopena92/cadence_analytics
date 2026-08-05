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
-- CHECKS 2-4 ADAPTATION FOR LIVE DAILY ALERTING (revised 2026-07-31, thresholds revised again
-- 2026-08-03): the source artifact's checks 2-4 are all-time cumulative counts with no date
-- window (a one-time diagnostic snapshot) — posting that literally every day would repeat a huge,
-- barely-changing number forever for recurring/evergreen cadences (the source doc itself flags
-- these as needing human review, not as bugs). Current approach: window checks 2-4 to a trailing
-- 7-day count (not all-time), exclude known recurring-by-design cadences by name via `NOT
-- TRIM(cadence_id) ILIKE ANY (...)` — starting with `HCP NPS Survey 25-90-150-Recurring` (resent
-- every 25/90/150 days by design) — and, as of 2026-08-03 (requester's manager feedback), flag on
-- a **percentage** of the relevant denominator rather than a raw count: checks 2/3 as % of that
-- same trailing-7-day window's total starts/exits (>10%), check 4 as % of the cadence's own
-- currently-active pool that's stuck >=100 days (>=10%) instead of a "newly crossed" count. This
-- replaces an earlier 34-day statistical-baseline-anomaly version of this file (kept simpler/more
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

-- ── CHECK 2: Double Starts — >10% of trailing-7-day starts, recurring-cadence exclusion list ──
-- REVISED 2026-08-03 (requester's manager feedback, reducing alert volume): threshold changed
-- from "any occurrence in 7 days" to "double starts are >10% of total starts in that same 7-day
-- window" — a raw count doesn't distinguish a high-volume cadence throwing off a handful of
-- dupes from a low-volume one where every start is doubling. Denominator uses the same trailing
-- 7-day window as the numerator (not a single day) to avoid noisy/volatile % on low-volume
-- cadences — a single day's total starts can be too small a sample. Exclusion list is still
-- needed even with % framing: for recurring-by-design cadences a "double start" (2nd Start with
-- no Exit between) can itself be the expected re-send mechanism, so a high % there isn't a bug.
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
),
doubles AS (
    SELECT s.cadence_id, s.email
    FROM starts s
    WHERE s.start_seq > 1
      AND s.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
      AND NOT EXISTS (
          SELECT 1 FROM exits e
          WHERE e.cadence_id = s.cadence_id AND e.email = s.email
            AND e.exit_ts > s.prev_start_ts AND e.exit_ts < s.event_timestamp
      )
),
totals AS (
    SELECT cadence_id, COUNT(*) AS total_starts_7d
    FROM starts
    WHERE event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
    GROUP BY cadence_id
)
SELECT d.cadence_id,
       COUNT(*) AS double_start_count,
       COUNT(DISTINCT d.email) AS pros_affected,
       t.total_starts_7d,
       ROUND(COUNT(*) / NULLIF(t.total_starts_7d, 0), 4) AS double_start_pct
FROM doubles d
JOIN totals t ON t.cadence_id = d.cadence_id
GROUP BY d.cadence_id, t.total_starts_7d
HAVING double_start_pct > 0.10
ORDER BY double_start_pct DESC;
-- Drill-down (sample emails for a flagged cadence): rerun the `starts`/`exits` CTEs above, select
-- s.email, s.prev_start_ts, s.event_timestamp WHERE s.cadence_id = '<flagged>' (same WHERE clause).

-- ── CHECK 3: Double Exits — >10% of trailing-7-day exits, recurring-cadence exclusion list ──
-- Mirror of check 2 on Exit rows. Same 2026-08-03 % revision and rationale.
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
),
doubles AS (
    SELECT e.cadence_id, e.email
    FROM exits e
    WHERE e.exit_seq > 1
      AND e.event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
      AND NOT EXISTS (
          SELECT 1 FROM starts s
          WHERE s.cadence_id = e.cadence_id AND s.email = e.email
            AND s.start_ts > e.prev_exit_ts AND s.start_ts < e.event_timestamp
      )
),
totals AS (
    SELECT cadence_id, COUNT(*) AS total_exits_7d
    FROM exits
    WHERE event_timestamp >= DATEADD(day, -7, CURRENT_DATE())
    GROUP BY cadence_id
)
SELECT d.cadence_id,
       COUNT(*) AS double_exit_count,
       COUNT(DISTINCT d.email) AS pros_affected,
       t.total_exits_7d,
       ROUND(COUNT(*) / NULLIF(t.total_exits_7d, 0), 4) AS double_exit_pct
FROM doubles d
JOIN totals t ON t.cadence_id = d.cadence_id
GROUP BY d.cadence_id, t.total_exits_7d
HAVING double_exit_pct > 0.10
ORDER BY double_exit_pct DESC;

-- ── CHECK 4: Stuck >100 days — >10% of currently-active pros in the cadence ──
-- REVISED 2026-08-03 (requester's manager feedback): threshold changed from an absolute
-- "newly crossed 100 days in the trailing 7 days" count to a % of the cadence's own currently-
-- active pool — pros entered-but-not-exited with days_in_cadence >= 100, divided by all pros
-- entered-but-not-exited regardless of duration. This replaces the "newly stuck" windowing that
-- existed specifically to avoid repeating a huge, barely-changing absolute backlog number every
-- day (source doc found HCP NPS Survey 25-90-150-Recurring topping the backlog at 169,152 pros,
-- expected for a long-running recurring cadence, not a bug) — a %-of-active-pool metric is
-- self-normalizing across cadence size, so the same anti-noise goal is now served by the % framing
-- itself plus the urgent tier's existing per-check/cadence Slack-thread repeat-suppression (see
-- "Anti-noise design" in SKILL.md), rather than by a "newly crossed" time window. Same recurring-
-- cadence exclusion list as checks 2-3, kept for consistency — re-validate empirically (see
-- SKILL.md) whether it's still needed once % results are in.
-- REVISED AGAIN 2026-08-05 (Diego): added a trailing-120-day entrant window on Start, matching the
-- "12-month/4-month entrant window" idea already discussed in the check-4 validation notes below
-- for taming the 82%-fire-rate problem. First pasted with the DATEADD sign flipped
-- (`DATEADD(day, 120, CURRENT_DATE())`, a FUTURE date — `event_timestamp >= <future date>` can
-- never match anything, confirmed live at 0 rows); corrected to `-120` (trailing 120 days) before
-- shipping.
WITH starts AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
      AND event_timestamp >= DATEADD(day, -120, CURRENT_DATE())
    GROUP BY 1, 2
),
exits AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, MIN(event_timestamp) AS exit_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Exit'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')
    GROUP BY 1, 2
),
active AS (
    SELECT s.cadence_id, s.email, DATEDIFF(day, s.start_ts, CURRENT_DATE()) AS days_in_cadence
    FROM starts s
    LEFT JOIN exits e ON e.cadence_id = s.cadence_id AND e.email = s.email AND e.exit_ts > s.start_ts
    WHERE e.email IS NULL
)
SELECT cadence_id,
       COUNT(*) AS active_pros,
       COUNT_IF(days_in_cadence >= 100) AS stuck_pros,
       ROUND(COUNT_IF(days_in_cadence >= 100) / NULLIF(COUNT(*), 0), 4) AS stuck_pct,
       MAX(days_in_cadence) AS longest_days_in_cadence
FROM active
GROUP BY cadence_id
HAVING stuck_pct >= 0.10
ORDER BY stuck_pct DESC;

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

-- ── CHECK 6: Low Engagement on Recent Starts — <10% of the 3-10 day cohort engaged ──
-- REDEFINED 2026-08-05 (Mario's request via Slack thread, refined proposal checkmarked
-- 2026-08-05 — see SKILL.md's check-6 section for the full history). Replaces the old
-- silence-gate shape (0 surfaced in trailing 7d) with a per-cohort engagement ratio, the same
-- %-of-denominator pattern checks 2-4 moved to on 2026-08-03. For each cadence: cohort = pros
-- whose Start fell 3-10 days ago; a pro counts as "engaged" if they have ANY step surfaced, step
-- completed, or email sent for that cadence, any time from their Start through today (Diego's
-- call, 2026-08-05 — not restricted back to the 3-10 day window itself); alert if
-- engaged_pct < 10%. Keeps the known-quiet/non-rep-driven exclusion list from the old check 6
-- (Mario flagged this need too, e.g. Warming) — live-validate whether it's still needed now that
-- "email sent" is part of the success criteria (a nurture-only cadence may now clear 10% on the
-- email leg alone).
-- Email-sent leg: `marts.communication.detail_communication_lifecycle` has no email column, so
-- it's joined through `marts.communication.detail_emails` (`comm_id = message_id`) to get
-- `pro_email_address`, then matched to the cohort by email. Cadence match is still
-- `workflow_name ILIKE '%cadence_id%'`, the same substring approach check 9 uses (same
-- false-positive risk on short/prefix-sharing cadence names — spot-check flags).
WITH cohort AS (
    SELECT TRIM(cadence_id) AS cadence_id, email, event_timestamp AS start_ts
    FROM analytics.main.fact_journey_progress_checkpoint
    WHERE cadence_step = 'Start'
      AND SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
      AND NOT TRIM(cadence_id) ILIKE ANY ('%ARPA Engagement%', '%Type 1 Onboarding%', '%Type 1 Adoption%',
                                            '%Type 1 Nurture%', '%Activation%', '%Warming%', '%HCP NPS%')
      AND event_timestamp::date BETWEEN DATEADD(day, -10, CURRENT_DATE()) AND DATEADD(day, -3, CURRENT_DATE())
),
steps AS (
    SELECT TRIM(cadence_id__c) AS cadence_id, email__c AS email, createddate, result_date_time__c
    FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
    WHERE step_id__c = 'Call attempt' AND name != 'clear_step'
      AND SPLIT_PART(email__c, '@', 2) NOT IN ('housecallpro.com', 'gethousecallpro.com')
),
emails_sent AS (
    SELECT dcl.workflow_name, de.pro_email_address AS email, dcl.comm_date
    FROM marts.communication.detail_communication_lifecycle dcl
    JOIN marts.communication.detail_emails de ON dcl.comm_id = de.message_id
    WHERE dcl.workflow_name IS NOT NULL
),
engaged AS (
    SELECT c.cadence_id, c.email
    FROM cohort c
    JOIN steps s ON s.cadence_id = c.cadence_id AND s.email = c.email
                 AND (s.createddate >= c.start_ts OR s.result_date_time__c >= c.start_ts)
    UNION
    SELECT c.cadence_id, c.email
    FROM cohort c
    JOIN emails_sent e ON e.workflow_name ILIKE '%' || c.cadence_id || '%' AND e.email = c.email
                       AND e.comm_date >= c.start_ts
)
SELECT
    c.cadence_id,
    COUNT(DISTINCT c.email)  AS cohort_size,
    COUNT(DISTINCT eg.email) AS engaged_count,
    ROUND(COUNT(DISTINCT eg.email) / NULLIF(COUNT(DISTINCT c.email), 0), 4) AS engaged_pct
FROM cohort c
LEFT JOIN engaged eg ON eg.cadence_id = c.cadence_id AND eg.email = c.email
GROUP BY c.cadence_id
HAVING engaged_pct < 0.10
ORDER BY engaged_pct ASC;

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
