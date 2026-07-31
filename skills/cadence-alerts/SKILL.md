---
name: cadence-alerts
description: Run the 9-check Multi-Cadence Bug Diagnostic across all active cadences and post to the #cadence-analytics-alerts Slack channel, split into two severity tiers — "run the cadence alerts", "check for cadence mechanical issues", "post today's cadence alerts". Urgent tier (checks 1,2,3,4,6) runs daily, silent on a clean day, immediate per-item posts. Report tier (checks 5,7,8,9, recapping all 9) runs Mon+Thu with a 3-way decision tree: nothing flagged → liveness ping only; one check flagged → top 3 cadences for that check; multiple checks flagged → top 3 repeat-offender cadences across checks — plus an HTML-built Google Doc styled as a slide deck (max 10 sections) for the latter two cases. For a single-cadence deep dive use `bug-diagnostic` instead; for general performance use `four-stage-funnel`.
---

# Cadence Mechanical Alerts

Batched version of the **Multi-Cadence Bug Diagnostic** methodology, run across every active
cadence and posted to Slack instead of written up as a one-off report. The 9-check methodology,
numbering, domain exclusion, and statistical thresholds below are adopted verbatim from a
"Multi-Cadence Bug Diagnostic" artifact shared by the requester's manager (2026-07-31, verified by
its author 2026-07-28/29) — treat that numbering and those thresholds as the source of truth;
where this skill's live-alerting version differs (checks 2-4, see below), the difference is called
out explicitly with the reason. Reference `knowledge/resources-and-methodology.md` and
`knowledge/schema.md` for tables/fields, `knowledge/data-quality-caveats.md` for the traps. Query
file: `cadence-alerts.sql` (9 checks, standalone/runnable individually).

## Domain exclusion (applies to every check)
Every query excludes internal/test traffic: `SPLIT_PART(email, '@', 2) NOT IN ('housecallpro.com',
'gethousecallpro.com')` (or `email__c` on `decision_engine_step__c`). The source doc found 23,198 +
913 rows of internal test-account activity inflating counts before this fix. `placeholder.email`
stays in scope (61 rows, legitimate test-persona traffic the team wants visibility into). This is
a correctness fix over the original version of this skill, which did not exclude internal traffic.

## Scope: 9 checks, two severity tiers
| # | Check | Tier | Alert rule |
|---|---|---|---|
| 1 | No Starts in 7 Days | Urgent (daily) | Silence gate: `>=1` real Start in trailing 4mo, `0` in trailing 7d |
| 2 | Double Starts | Urgent (daily) | *Adapted* — any occurrence in the trailing 7 days, excluding known-recurring cadences by name |
| 3 | Double Exits | Urgent (daily) | *Adapted* — same rule as check 2 |
| 4 | Entered, Not Exited in 100+ Days | Urgent (daily) | *Adapted* — any pro whose no-exit streak crossed 100 days in the trailing 7 days, same exclusion list |
| 5 | Drop in Weekly Entries/Exits | Report (Mon+Thu) | 8-week trailing baseline, drop >=2σ below mean, baseline mean >=10/week |
| 6 | No Steps Surfaced in 7 Days | Urgent (daily) | Silence gate, same shape as check 1, on `decision_engine_step__c` |
| 7 | Drop in Steps Surfaced | Report (Mon+Thu) | Same 8-week/2σ/min-10 rule as check 5 |
| 8 | Drop in Steps Completed | Report (Mon+Thu) | Same 8-week/2σ/min-10 rule as check 5 |
| 9 | Email Volume Drops/Spikes | Report (Mon+Thu) | Same 8-week/2σ/min-10 rule, flags **both** drop and spike |

Checks 2-4 exclude known-recurring-by-design cadences by name via `NOT TRIM(cadence_id) ILIKE ANY
(...)` — currently just `%HCP NPS%`. This is a maintained list, not automatic; see below.

## Two-tier severity design (decided with the requester + their manager's team, 2026-07-31)
Original design ran everything daily; the requester's manager (Mario) and a stakeholder (Charlie)
flagged in a separate Slack thread that daily statistical-drop alerts would become white noise,
while genuinely broken cadences ("egregious" issues) still need to surface fast. Resolution:
- **Urgent tier** (checks 1, 2, 3, 4, 6) — these are either silence gates (a cadence went
  completely dark) or baseline anomalies (something new and abnormal just happened). Both mean
  something likely just broke. Runs **daily**, posts **immediately** and **individually** per
  breaching check/cadence, **stays silent on a clean day** (no white noise — these should be rare).
- **Report tier** (checks 5, 7, 8, 9, plus a recap of 1-4/6's current status) — these are
  8-week statistical drops/spikes, inherently a weekly-grain signal; a routine dip doesn't need
  same-day attention. Runs **twice a week (Monday + Thursday)**, and — unlike the urgent tier —
  **always posts something**, even "nothing to call out," specifically so the team can tell the
  bot is still running. When something is flagged, the Slack post links to a full **Google Doc**
  report with the detail (see "Slack message format" and "Running it" below).

## Why checks 2-4 differ from the source doc (important — read before changing)
The source doc's checks 2-4 are **all-time cumulative counts with no date window** — a one-time
diagnostic snapshot, explicitly flagged by its own author as needing "human review... before
confirming bugs versus expected behavior" for recurring cadences (verified: `HCP NPS Survey
25-90-150-Recurring` and `Post-Enroll Flywheel: Warming` dominate checks 2-3; the same NPS survey
tops check 4's backlog at 169,152 pros — all expected for a long-running recurring cadence, not a
bug). Posting that literal, ever-growing all-time number to Slack every day would repeat a huge,
barely-changing figure forever for those same cadences.

Two approaches were tried:
1. **34-day statistical baseline** (first version, 2026-07-30): compare each cadence's daily count
   to its own trailing 34-day mean/stddev, flag only outliers. Validated live: correctly suppressed
   `HCP NPS Survey` (945 vs. mean 781, σ=109 → 1.5σ) and `Warming` (917 double-exits vs. mean 408,
   σ=396 → 1.3σ) while catching `Post-Enroll Flywheel: Type 1 to Type 3 Upsell` (51 vs. mean 6.5,
   σ=14.6 → ~3.0σ) as a real anomaly. Worked, but harder to explain/reason about for the team.
2. **Trailing 7-day window + explicit exclusion list** (current, 2026-07-31, requester's own SQL):
   count occurrences in the last 7 days, and hard-exclude cadences known to be recurring-by-design
   via `NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')`. Simpler and more explainable, at the cost of
   needing the exclusion list maintained by hand — other known-recurring cadences (`Warming`,
   `Upsell`, `Abandoned My Apps Page`, `Retention - SaaS Cancellation`, `Inbound In Trial`, all
   confirmed recurring-by-design in the 2026-07-30 validation) are **not yet excluded** and will
   likely fire weekly until added. Add a cadence to the `ILIKE ANY (...)` list in checks 2-4 (three
   places each) once it's confirmed to be by-design, not a bug — the ✅/❌ reaction feedback loop
   (see "Anti-noise design") is the intended way to surface candidates.

Checks 1, 5, 6, 7, 8, 9 are used exactly as the source doc specifies — they're already windowed
(silence gates or 8-week rolling baselines) and never had this all-time-cumulative problem.

## Check 9's two known caveats (documented, not fixed — from the source doc, verified 2026-07-29)
1. **Name-match false positive**: the join to `marts.communication.detail_communication_lifecycle`
   is `workflow_name ILIKE '%'||cadence_id||'%'` (not an ID join — comms and checkpoint tables use
   different `workflow_id`s for the same cadence, see `data-quality-caveats.md` #14). A shorter
   cadence name can substring-match comms belonging to a longer, related cadence sharing the same
   prefix. Spot-check any check-9 flag before acting on it.
2. **Casing-duplicate cadence_ids** produce duplicate identical-looking flags — e.g. "Retention -
   SaaS Cancellation" and "Retention - SAAS Cancellation" returned the exact same numbers as two
   separate rows (`cadence_id` is `TRIM()`'d but not case-normalized, in this check and everywhere
   else in this file — a shared limitation, not unique to check 9).

## Anti-noise design ("don't become white noise")
1. **Silence on a clean urgent-tier day.** No "all clear" message from the daily routine — only
   post when checks 1/2/3/4/6 actually breach. (The report tier is the exception — see tier
   design above — it always posts something, by design, twice a week only.)
2. **One message per breaching check per cadence** on the urgent tier, not a giant combined
   digest — mirrors `#hcp_kpi_alerts`' granularity so each issue can be reacted to/threaded
   independently. The report tier is the opposite on purpose: one consolidated digest, not nine
   separate messages, because it's meant to be skimmed twice a week, not reacted to per-item.
3. **Repeat-suppression via Slack history** (live routines, urgent tier only) or a local ledger
   (manual runs) — see "Running it" below. The report tier doesn't need this: each Mon/Thu run is
   a fresh periodic digest, not a persistent alert needing suppression.
4. **Feedback loop** — ask people to react ✅ (expected/legit) or ❌ (false positive/not useful) on
   urgent-tier alerts, same convention as `#hcp_kpi_alerts`. Review reactions periodically and use
   ❌ patterns to adjust thresholds — this repo has no automated model-retraining loop, so that
   review is manual.

## Slack message format

### Urgent tier (checks 1, 2, 3, 4, 6 — immediate, per breaching check/cadence)
Sent via `mcp__claude_ai_Slack__slack_send_message`, which renders standard markdown (`**bold**`,
`_italic_`), not Slack's native `*bold*` mrkdwn — use `**...**` for the headline:
```
**<Check name> — <cadence name>**
• <concrete numbers: actual vs. threshold/baseline, count of affected pros, sample emails>
_React ✅ if expected, ❌ if this shouldn't have fired. @Claude in this thread for more detail._
```
Repeat occurrences of an already-open alert are posted as a **reply in that message's thread**, not
a new top-level message.

### Report tier (checks 5, 7, 8, 9 + full recap — twice a week, one consolidated post)
Three-way decision tree (agreed with the requester 2026-07-31), evaluated over all 9 checks for
the current period (checks 1-4/6: today; checks 5/7/8/9: the most recent week in the sheet):

1. **Nothing flagged in any of the 9 checks** → post only: `**Cadence Alerts Report — <date>** —
   Nothing to report this run.` No attachment, no doc. (Liveness ping — confirms the bot ran.)
2. **Exactly one check has flagged rows** → rank that check's flagged cadences by severity
   (`ABS(metric_value - reference_value)` descending when `reference_value` isn't null, else
   `metric_value` descending) and take the top 3 (fewer if fewer exist). Post a short message
   naming the check and those 3 cadence IDs, plus the slide-deck doc (below).
3. **Two or more checks have flagged rows** → find the 3 **repeat offenders**: cadences appearing
   in the most *distinct* check_numbers this period. Normalize `cadence_id` casing (`UPPER()`)
   before grouping — otherwise the known casing-duplicate cadences (see check 9's caveats) would
   undercount as two different cadences instead of one repeat offender. Tie-break by combined
   severity (sum of each appearance's `ABS(metric_value - reference_value)`, treating null
   `reference_value` as 0). Post a short message: how many of the 9 checks fired, the top 3
   offenders and how many checks each appeared in, plus the slide-deck doc.

**The "slide-deck" doc** (built for cases 2 and 3, skipped for case 1): a Google Doc built from
**HTML content** (not plain text — plain text doesn't convert to real headings/bullets; HTML does,
verified 2026-07-31), styled to read like a presentation, max 10 sections total:
- **Section 1 ("Slide 1 — Overview")**: a list of all 9 checks with how many cadences each
  flagged this period (0 for clean ones — full landscape, not just the active ones), followed by
  the top-3 offenders/cadences callout from whichever branch (2 or 3) applied.
- **Sections 2+ ("Slide 2 — <Check Name>", "Slide 3 — <Check Name>", ...)**: one section per
  check_number that has >=1 flagged row this period, in ascending check_number order (lowest
  flagged check_number = "first misalert" = slide 2) — each listing its flagged cadences with
  `cadence_id`, `metric_value`, `reference_value`, `detail`.
- Since there are exactly 9 possible checks, worst case is 1 overview + 9 detail sections = 10 —
  matches the stated 10-slide cap exactly, no truncation logic needed.
- This is the closest achievable substitute for a literal PDF slide deck — true Google Slides
  requires uploading a real `.pptx` binary (confirmed 2026-07-31: `create_file` rejects plain-text
  content for the native presentation mime type), which isn't reliably buildable without a
  presentation-generation library that may not exist in the routine's sandbox. An HTML-sourced
  Google Doc, structured with one heading per "slide," is downloadable as an actual PDF by anyone
  with the link and was validated to convert with real headings/bullets (not literal `#`/`-`
  characters, which is what plain-text upload produces).

No new top-level message per item, no thread dedup — one message (+ doc when applicable), twice a
week.

Neither tier infers cause in the alert text (house rule — `context/analysis-approaches.md` #2):
state the number, not a guess at why it moved.

## Running it

### Live automated routines (production path)
Two durable cloud routines run against `#cadence-analytics-alerts` (channel_id `C0BMUN6PRGQ`),
created via the `schedule` skill / `RemoteTrigger`:
- **`cadence-alerts-urgent`** (`trig_01BkdGEqvTH2NMSpPvaree9p`) — checks 1, 2, 3, 4, 6, daily at
  14:00 UTC (~10am ET). Silent on a clean day.
- **`cadence-alerts-report`** (`trig_018zAoMWLt2snuhJm1cnJSfY`) — checks 5, 7, 8, 9 plus a recap
  of 1-4/6, **Monday and Thursday** at 14:00 UTC (`cron: 0 14 * * 1,4`). Always posts something —
  a liveness ping if clean, or a summary + Google Doc link if anything's flagged.

Manage both at https://claude.ai/code/routines (list/update/run-now via `RemoteTrigger`; deletion
is web-UI only). Schedule note: Monday/Thursday was Mario's latest stated preference in the
requirements thread as of 2026-07-31, pending final confirmation against the team's sprint
grooming days — if that changes, update the `cadence-alerts-report` cron expression.

### Data source: Hightouch → Google Sheet (live as of 2026-07-31)
Neither routine queries Snowflake directly anymore. **Why:** the Snowflake MCP connector's OAuth
token expired mid-session twice during development, which would have silently broken the live
routines with no visible error. Instead:
- A Hightouch model, `skills/cadence-alerts/hightouch-combined-model.sql`, runs all 9 checks
  (`UNION ALL`'d into one normalized schema — see the file's header comment for the exact column
  list) on Hightouch's own schedule, using Hightouch's own (more stable, service-level) Snowflake
  connection — not this session's OAuth.
- Hightouch syncs the already-filtered result rows to a single tab in a Google Sheet:
  https://docs.google.com/spreadsheets/d/1SJ15lieGu4QiX50LQO8huifU-FTZ9qxXWp-J8rGg7Fs — shared
  with the Google account connected to `mcp__claude_ai_Google_Drive`. Primary key for the sync is
  the model's `id` column (see the file for how it's built — `check_number|cadence_id|as_of`,
  plus `sub_key` for checks 5/9, which can emit two rows per cadence/period).
- Each routine reads that sheet (`mcp__claude_ai_Google_Drive__read_file_content`), filters to its
  tier's `CHECK_NUMBER`s, and — **before treating an empty result as "clean"** — runs a staleness
  guard: if the max `AS_OF` across the whole sheet is more than 8 days old, it posts a warning
  that the Hightouch sync may have stalled instead of silently assuming a clean day. There's no
  "last synced at" column, so this is a heuristic, not a guarantee — if Hightouch ever syncs an
  empty/partial result within that 8-day window, it would look identical to "genuinely clean."
- Dedup logic is otherwise unchanged: urgent tier still checks Slack history per check+cadence
  before posting; report tier still posts one fresh consolidated message + Google Doc per run.

**Known tradeoff:** the check SQL now lives in two files — `cadence-alerts.sql` (reference/
documentation of the per-check logic; not directly executed by the live routines anymore) and
`hightouch-combined-model.sql` (what Hightouch actually runs). They must be updated together by
hand whenever a threshold/filter/exclusion changes — no automatic sync between them. This mirrors
the tradeoff already accepted for checks 2-4's exclusion list, just one level up.

### Manual/interactive run (ledger-based, for ad hoc use in this repo)
For ad hoc analyst use (not the live routines), run `cadence-alerts.sql` directly against
Snowflake rather than reading the sheet — it's the more current/flexible reference copy.
1. Run each check via `mcp__claude_ai_Snowflake__sql_exec_tool`.
2. For each returned row, check the ledger (`outputs/alerts/cadence-alerts-state.json`) for
   `{check, cadence_id, key}`:
   - Not present → format and post a new top-level Slack message to `#cadence-analytics-alerts`
     via `mcp__claude_ai_Slack__slack_send_message`; record the returned `thread_ts` in the ledger.
   - Present → reply in that message's thread instead (or skip if already replied today).
3. Remove ledger entries for keys that no longer appear in the current run's results (resolved).

## Follow-up Q&A in Slack
This repo runs as scheduled batch jobs, not a hosted Slack app — it cannot itself listen for
@-mentions and reply live. Follow-up questions in an alert thread are answered by enabling the
**Claude Tag** (Claude in Slack) app on `#cadence-analytics-alerts`; it can run fresh Snowflake
queries against the same tables/knowledge base to answer in-thread.

## Caveats (see `knowledge/data-quality-caveats.md`)
- Count **unique pros** (`COUNT(DISTINCT email)`), never `COUNT(*)`, for entries/exits.
- `cadence_step='Test'` = Control (held out) — never produces a `Start` row, so no separate
  exclusion is needed.
- Known-quiet cadences (Post-Enroll Flywheel: ARPA Engagement, Type 1 Onboarding, Type 1
  Adoption, Type 1 Nurture, Activation, Warming): checks 7/8's min-10-baseline-volume floor
  naturally excludes them (they never clear it) — no explicit list needed there. **Check 6 needs
  an explicit exclusion list** (corrected 2026-07-31, caught by live validation): the 4-month
  liveness gate does NOT exclude them the way it does for check 1 — a cadence can clear
  `surfaced_last_4mo >= 1` on a single stray surfaced step and then trivially show `0` every
  week after, since it's inherently sparse. Confirmed live: `Warming` and `Activation` fired on
  check 6 before this fix. `cadence-alerts.sql`/`hightouch-combined-model.sql` check 6 now filters
  `NOT cadence_id ILIKE ANY (...)` on the same name list.
- Governed tables (`ANALYTICS.MAIN`) rebuild nightly, not intraday — a same-day "no starts"
  won't show up until the next day's run; this is accepted latency, not a bug in the check.
- Free-text `cadence_id` is `TRIM()`'d but **not case-normalized** anywhere in this file — a
  known, shared limitation (see check 9's caveat #2 above; the source doc found this producing
  literal duplicate rows for at least one cadence pair).
- Cross-table joins (checkpoint ↔ `decision_engine_step__c`) assume the same literal id is used in
  both `cadence_id` and `cadence_id__c`; check 9's join to `detail_communication_lifecycle` is a
  substring `ILIKE` match instead (see check 9's caveat #1).
- **`knowledge/schema.md` line 28 documents a `cadence_name` column on
  `fact_journey_progress_checkpoint` that does not exist** (verified live via `SHOW COLUMNS`).
  `cadence_id` itself is the free-text descriptive label — every query here filters/matches on
  `cadence_id` directly. Flag this doc line for correction.

## Corroboration (house rule)
State a cause only with corroborating evidence — see `context/analysis-approaches.md` #2 and
`bug-diagnostic/SKILL.md`'s corroboration section. An alert reports a number, not a diagnosis.
