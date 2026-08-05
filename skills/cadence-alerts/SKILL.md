---
name: cadence-alerts
description: Run the 9-check Multi-Cadence Bug Diagnostic across all active cadences and post to the #cadence-analytics-alerts Slack channel, split into two severity tiers — "run the cadence alerts", "check for cadence mechanical issues", "post today's cadence alerts". Urgent tier (checks 1,2,3,4,6) runs daily, silent on a clean day, immediate per-item posts. Report tier (checks 5,7,8,9, recapping all 9) runs Mon+Thu with a 3-way decision tree: nothing flagged → liveness ping only; one check flagged → top 3 cadences for that check; multiple checks flagged → top 3 repeat-offender cadences across checks — plus a published HTML artifact styled as a slide deck (max 10 sections) for the latter two cases. For a single-cadence deep dive use `bug-diagnostic` instead; for general performance use `four-stage-funnel`.
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
| 2 | Double Starts | Urgent (daily) | *Adapted* — double starts >10% of that same trailing-7-day window's total starts, excluding known-recurring cadences by name |
| 3 | Double Exits | Urgent (daily) | *Adapted* — same rule as check 2, on exits |
| 4 | Entered, Not Exited in 100+ Days | Urgent (daily) | *Adapted* — >=10% of the cadence's currently-active pool (entered, not exited) has been stuck 100+ days, same exclusion list |
| 5 | Drop in Weekly Entries/Exits | Report (Mon+Thu) | 8-week trailing baseline, drop >=2σ below mean, baseline mean >=10/week |
| 6 | Low Engagement on Recent Starts | Urgent (daily) | *Adapted* — <10% of the pros who started 3-10 days ago have any step surfaced, step completed, or email sent for that cadence since their Start, excluding known non-rep-driven cadences by name |
| 7 | Drop in Steps Surfaced | Report (Mon+Thu) | Same 8-week/2σ/min-10 rule as check 5 |
| 8 | Drop in Steps Completed | Report (Mon+Thu) | Same 8-week/2σ/min-10 rule as check 5 |
| 9 | Email Volume Drops/Spikes | Report (Mon+Thu) | Same 8-week/2σ/min-10 rule, flags **both** drop and spike |

Checks 2-4 exclude known-recurring-by-design cadences by name via `NOT TRIM(cadence_id) ILIKE ANY
(...)` — currently just `%HCP NPS%`. This is a maintained list, not automatic; see below.

## Two-tier severity design (decided with the requester + their manager's team, 2026-07-31)
Original design ran everything daily; the requester's manager (Mario) and a stakeholder (Charlie)
flagged in a separate Slack thread that daily statistical-drop alerts would become white noise,
while genuinely broken cadences ("egregious" issues) still need to surface fast. Resolution:
- **Urgent tier** (checks 1, 2, 3, 4, 6) — these are silence gates (a cadence went completely
  dark), cohort-ratio anomalies (a cadence's own recent pros are behaving abnormally), or
  something new and abnormal just happened. All mean something likely just broke. Runs **daily**,
  posts **immediately** and **individually** per breaching check/cadence, **stays silent on a
  clean day** (no white noise — these should be rare).
- **Report tier** (checks 5, 7, 8, 9, plus a recap of 1-4/6's current status) — these are
  8-week statistical drops/spikes, inherently a weekly-grain signal; a routine dip doesn't need
  same-day attention. Runs **twice a week (Monday + Thursday)**, and — unlike the urgent tier —
  **always posts something**, even "nothing to call out," specifically so the team can tell the
  bot is still running. **This is NOT a plain sequential recap of all 9 checks** — it runs a
  3-way decision tree that always surfaces a ranked "who's most critical" answer (top-3 cadences,
  by single-check severity or by repeat-offense across checks) rather than just listing everything
  — see "Slack message format" below for the exact tree and required output shape; that section
  is authoritative over this paragraph if they ever seem to disagree.

## Why checks 2-4 differ from the source doc (important — read before changing)
The source doc's checks 2-4 are **all-time cumulative counts with no date window** — a one-time
diagnostic snapshot, explicitly flagged by its own author as needing "human review... before
confirming bugs versus expected behavior" for recurring cadences (verified: `HCP NPS Survey
25-90-150-Recurring` and `Post-Enroll Flywheel: Warming` dominate checks 2-3; the same NPS survey
tops check 4's backlog at 169,152 pros — all expected for a long-running recurring cadence, not a
bug). Posting that literal, ever-growing all-time number to Slack every day would repeat a huge,
barely-changing figure forever for those same cadences.

Three approaches were tried:
1. **34-day statistical baseline** (first version, 2026-07-30): compare each cadence's daily count
   to its own trailing 34-day mean/stddev, flag only outliers. Validated live: correctly suppressed
   `HCP NPS Survey` (945 vs. mean 781, σ=109 → 1.5σ) and `Warming` (917 double-exits vs. mean 408,
   σ=396 → 1.3σ) while catching `Post-Enroll Flywheel: Type 1 to Type 3 Upsell` (51 vs. mean 6.5,
   σ=14.6 → ~3.0σ) as a real anomaly. Worked, but harder to explain/reason about for the team.
2. **Trailing 7-day window + explicit exclusion list** (2026-07-31, requester's own SQL): count
   occurrences in the last 7 days, and hard-exclude cadences known to be recurring-by-design via
   `NOT TRIM(cadence_id) ILIKE ANY ('%HCP NPS%')`. Simpler and more explainable, but a raw count
   doesn't distinguish a high-volume cadence throwing off a handful of dupes from a low-volume one
   where every start is doubling — and still needed the exclusion list maintained by hand.
3. **% of the relevant denominator, same 7-day window + exclusion list** (current, 2026-08-03,
   Diego's manager's feedback via Diego): keep the trailing-7-day window and exclusion list from
   approach 2 (still needed — for recurring-by-design cadences, a "double start" can itself be the
   expected re-send mechanism, so a high % there isn't automatically a bug), but flag on a
   **percentage** instead of a raw count:
   - **Check 2**: `double_start_count / total_starts_7d > 10%` (both counted over the same trailing
     7-day window — using a single day's total was considered but rejected as too noisy for
     low-volume cadences).
   - **Check 3**: same shape, `double_exit_count / total_exits_7d > 10%`.
   - **Check 4**: redefined from "newly crossed 100 days in the trailing 7 days" (a count) to
     `stuck_pros / active_pros >= 10%`, where `active_pros` is the cadence's entire currently-active
     pool (entered, not yet exited, any duration) and `stuck_pros` is the subset of that pool at
     >=100 days. This is a snapshot ratio, not a "newly stuck" delta — self-normalizing across
     cadence size, so it no longer needs the "newly crossed" windowing that approach 2 used to avoid
     repeating a huge absolute backlog number daily. The existing per-check/cadence Slack-thread
     repeat-suppression (see "Anti-noise design") now does that job instead.
   10% was Diego's manager's own suggested starting point ("not positive what that % is, let's try
   10%") — revisit if live results show it's still too loose/tight per cadence.

**Check 4 validation result (2026-08-03, important — read before treating a quiet day as
"working as intended"):** live-queried at 10% before shipping. Checks 2 and 3 reduced cleanly —
double-starts went from 19 cadences with any occurrence to 2 clearing >10% (`Inbound KA Low
Intent` 34%, `Abandoned My Apps Page` 24%); double-exits went from 19 to 9 clearing >10%. Check 4
did not: **47 of 57 cadences (82%) clear 10% stuck**, most at literally 100%, even after
restricting to currently-live cadences (Start in trailing 4mo) with a 12-month entrant window and
a min-10-active-pros floor (still 18 of 27, 67%). The apparent cause — not confirmed, stated as a
data pattern only — is that a large share of pros in most cadences never get an `Exit` checkpoint
recorded within 100 days; this looks like the norm rather than the exception across the system,
echoing the already-documented `Exit`/`Break` recording inconsistency in `data-quality-caveats.md`.
Decision (Diego, 2026-08-03): ship the 10% threshold as literally requested anyway and let the
✅/❌ Slack reaction feedback loop (see "Anti-noise design") drive any retuning, rather than
picking a different cutoff unilaterally. **Expect check 4 to fire on most active cadences daily**
until that feedback loop pushes the threshold (or the definition) somewhere else — this is a
known, accepted tradeoff, not a bug in the query.

**Check 4 revised again (2026-08-05, Diego)** — added the trailing-120-day entrant window on
`Start` that the 2026-08-03 validation above had already tried (as a 4mo/12mo variant) and found
insufficient on its own; this time it's the only change and is applied directly in the `starts`
CTE (not a separate liveness gate), restricting the active-pool denominator to pros who started
within the last 120 days so pros stuck in a permanent no-Exit state for years don't dominate
`stuck_pct` forever. **First pasted with the sign flipped** — `DATEADD(day, 120, CURRENT_DATE())`
computes a date 120 days in the *future*, so `event_timestamp >= <future date>` matched nothing;
confirmed live at 0 rows (this is what produced the empty check-4 section in the 2026-08-05
artifact). Corrected to `DATEADD(day, -120, CURRENT_DATE())` before shipping. Live-validated
after the fix: **13 cadences clear 10% stuck** (down from 47 of 57), each capped at exactly 120
days for `longest_days_in_cadence` (confirms the window is binding as intended) — a large
reduction from the 82% fire rate, though still worth watching via the ✅/❌ reaction loop.

Checks 1, 5, 7, 8, 9 are used exactly as the source doc specifies — they're already windowed
(silence gates or 8-week rolling baselines) and never had this all-time-cumulative problem.

## Why check 6 differs from the source doc (redefined 2026-08-05 — Mario's request)
The source doc's check 6 (and this skill's first live version) was a **silence gate**: 0 steps
surfaced on `decision_engine_step__c` in the trailing 7 days, gated on >=1 surfaced in the
trailing 4 months. Mario flagged in Slack that "0 surfaced" tells you almost nothing for most
cadences — most weeks already look like 0 for anything but the highest-volume ones — and asked
for an engagement-*rate* check instead. His refined proposal (checkmarked in-thread): for each
cadence, take the pros whose Start fell in the rolling 3–10 day window; count how many of them
have a step surfaced, a step completed, or an email sent for that cadence within that window;
divide by the number of starts in the window; alert if the ratio is below 10%.

Two implementation questions weren't fully specified in the Slack thread and were resolved with
Diego, 2026-08-05, before shipping:
- **Window scope for the "success" event**: literally restricting the surfaced/completed/emailed
  event to the same 3-10-day-ago calendar band (vs. any time from the pro's own Start through
  today) would undercount pros who started 9 days ago and got surfaced yesterday, outside that
  band. Decision: count a success **any time from the pro's Start through today**, not restricted
  back into the 3-10 day band itself.
- **Email-sent data source**: `marts.communication.detail_communication_lifecycle` (the table
  check 9 already uses for comms volume) has no `email` column — only `pro_uuid`/`lead_id`, which
  would require branching the join by Pre- vs. Post-Enroll cadence type. Instead it's joined
  through `marts.communication.detail_emails` (`comm_id = message_id`) to get `pro_email_address`,
  then matched to the Start cohort by email directly — one join path for every cadence type.
  Cadence match is still `workflow_name ILIKE '%cadence_id%'`, the same substring approach check 9
  uses, with the same false-positive risk (see check 9's caveat #1 below) — spot-check flags.

This is now architecturally the same %-of-denominator pattern checks 2-4 moved to on 2026-08-03
(see above), just with a 3-10 day cohort window instead of a flat trailing-7-day one, and adds a
third success signal (email sent) beyond the original surfaced/completed-only design. The
known-quiet/non-rep-driven exclusion list carries over from the old check 6 unchanged.

**Validation result (2026-08-05, live-queried before shipping):** of the 19 cadences with a
3-10 day cohort right now, 4 cleared <10% engaged on first pass: `Post-Enroll Flywheel: Onboarding
Email` (0%, cohort 125), `HCP NPS Survey 25-90-150-Recurring` (0.03%, cohort 10,717), `Pre-Enroll
Flywheel: Inbound Demo Missed` (1.1%, cohort 623), `Post-Enroll Flywheel: Abandoned My Apps Page`
(1.8%, cohort 5,746). The first two look like the same non-rep-driven/inherently-sparse pattern
that got Warming/Activation excluded from the old check 6 (an NPS survey and a pure-email
onboarding cadence are unlikely to ever clear the surfaced/completed leg, and evidently aren't
matching on the email leg either — not confirmed why, could be workflow-name substring mismatch or
genuinely low volume).

**`HCP NPS Survey` added to the check-6 exclusion list (Diego, 2026-08-05)** — checks 2-4 already
exclude it by name (`%HCP NPS%`) as a known recurring-by-design cadence; check 6 had never carried
that same exclusion (its list is the separate "known-quiet" one: ARPA Engagement, Type 1
Onboarding, Type 1 Adoption, Type 1 Nurture, Activation, Warming), so it fired here on first
validation. Added `%HCP NPS%` to check 6's list in both SQL files.

`Post-Enroll Flywheel: Onboarding Email` (0%) was **not** added — following the check-4 precedent
(2026-08-03): ship the definition as requested and let the ✅/❌ Slack reaction feedback loop
decide whether it needs excluding, rather than adding exclusions unilaterally. **Treat this one as
a known first-week watch item**, not a confirmed bug in the query.

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
   `metric_value` descending) and take the top 3 (fewer if fewer exist). Post a structured
   multi-line message naming the check and those 3 cadences, plus the visual report (below).
3. **Two or more checks have flagged rows** → find the 3 **repeat offenders**: cadences appearing
   in the most *distinct* check_numbers this period. Normalize `cadence_id` casing (`UPPER()`)
   before grouping — otherwise the known casing-duplicate cadences (see check 9's caveats) would
   undercount as two different cadences instead of one repeat offender. Tie-break by combined
   severity (sum of each appearance's `ABS(metric_value - reference_value)`, treating null
   `reference_value` as 0). Post a structured multi-line message: how many of the 9 checks fired,
   the top 3 offenders and how many checks each appeared in (check names spelled out, never bare
   numbers), plus the visual report.

**Slack message shape** (revised 2026-07-31 — the requester found the original single-run-on-
sentence version hard to parse and explicitly preferred an earlier multi-line draft): headline on
its own line, a one-line summary sentence, a blank line, a bolded "Top ..." lead-in, a numbered
list with one cadence per line and check names spelled out (never `(2, 3, 4, 9)` — always
`(Double Starts, Double Exits, Entered Not Exited 100+ Days, Email Volume Spike)`), a blank line,
then the report link on its own line. Not a single dense paragraph.

**The visual report** (built for cases 2 and 3, skipped for case 1): a published **HTML
artifact** (switched from a Google-Doc-via-HTML-upload approach on 2026-07-31 — the requester
doesn't need Doc-style collaboration/commenting on this report, and an artifact is simpler to
build: write the file, call `Artifact`, done — no Drive mimetype-conversion step). **Redesigned
again same day** after the first artifact version (plain `<h1>`/`<ul>`/`<li>` text, ported straight
from the old slide-deck doc) was rejected as "awful" / visually flat. Current version, following
the `dataviz` skill's procedure (form → color-by-job → validated status/sequential palette → mark
spec → table-view accessibility twin):
- **Hero stat**: a big `<N>/9` figure with a status-colored chip (warning 1-3 flagged, serious 4-6,
  critical 7-9 — the `dataviz` skill's fixed status palette, never a themed/categorical hue).
- **Overview bar chart**: one horizontal bar per check (sequential single-hue blue, magnitude =
  cadence count that check flagged this period), muted/zero-width for the two clean checks — a
  real chart, not a bulleted count list.
- **Top-3 offenders bar chart**: horizontal bars in the status-critical hue, sized by checks-flagged
  (or by severity score in the single-check branch), each with a row of pill "chips" spelling out
  which checks it was flagged in.
- **Per-check detail sections**: real `<table>`s (not card/bullet lists) — columns tailored per
  check's actual semantics (e.g. check 2/3 get a `Count` column, check 4 gets `Days`, checks
  5/7/8/9 get `This week`/`Baseline`), sorted descending by the primary column, monospace
  right-aligned numbers. This is the accessible "table view" the `dataviz` skill calls for
  alongside any chart.
- Fixed CSS custom properties (light + dark, both `prefers-color-scheme` and the viewer's
  `data-theme` toggle) drawn from the `dataviz` skill's validated reference palette
  (`references/palette.md`) — sequential blue for magnitude, status red for the critical/offenders
  charts — not invented per-run.
- Written to `outputs/charts/cadence-alerts-report_<date>.html`, then published via the `Artifact`
  tool (favicon 🔔). The routine calls the `artifact-design` skill once first per that tool's own
  requirement.
- The live routine's `allowed_tools` needed `Write`, `Artifact`, and `Skill` added (previously
  just `Bash`, `Read`, `Grep`, `Glob`) for this to work — see trigger `job_config.session_context`.

**Access — fixed permanent URL (added 2026-07-31, important — do not regress this):** Artifacts
publish **private by default** (owner-only) with no API/tool to set sharing programmatically —
confirmed the requester's manager (boss) couldn't open the first two test-run artifacts. A raw
`.html` upload to Google Drive (`disableConversionToGoogleType: true`) was tried as a workaround —
it *does* inherit the same `tryhousecall.com` domain-wide reader permission Google Docs get, but
Drive's preview only shows the HTML as literal source code, not a rendered page, so that path was
abandoned. The actual fix: artifact sharing is a **per-artifact, not per-version** setting, so the
routine now **always redeploys to one fixed, permanent artifact URL** —
`https://claude.ai/code/artifact/5e2dfa30-279f-40de-a65b-517329740044` — instead of minting a new
one each run. That URL was manually shared **once** via the Share panel (General access:
"Everyone in Housecall Pro", Can view); every subsequent redeploy to the same URL keeps that
setting. The trigger's step 5c always passes `url: <that fixed URL>` to the `Artifact` tool and
never omits it — omitting `url` would mint a fresh, unshared artifact. If this URL is ever lost or
needs rotating, a human must open the new artifact once and re-set General access by hand — there
is no way to script that step.
- The exact CSS/HTML template (class names, palette variables, per-check column mapping) lives
  verbatim in the `cadence-alerts-report` trigger's instructions, not duplicated here — see
  `trig_018zAoMWLt2snuhJm1cnJSfY` via `RemoteTrigger` if it needs hand-editing again.

No new top-level message per item, no thread dedup — one message (+ report when applicable), twice
a week.

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
  a liveness ping if clean, or a summary + HTML artifact link if anything's flagged.

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
  before posting; report tier still posts one fresh consolidated message + HTML artifact per run.

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
  an explicit exclusion list** (originally corrected 2026-07-31 for the old silence-gate version;
  carried over into the 2026-08-05 cohort-ratio redefinition, plus `HCP NPS Survey` added the same
  day — see "Why check 6 differs" above): these cadences are non-rep-driven and inherently sparse
  on the surfaced/completed signal, so they'd otherwise show a near-0% engagement rate regardless
  of whether anything is actually broken. `cadence-alerts.sql`/`hightouch-combined-model.sql`
  check 6 filters `NOT TRIM(cadence_id) ILIKE ANY (...)` (now including `%HCP NPS%`, matching
  checks 2-4's own exclusion of it) before building the cohort.
- Governed tables (`ANALYTICS.MAIN`) rebuild nightly, not intraday — a same-day "no starts"
  won't show up until the next day's run; this is accepted latency, not a bug in the check.
- Free-text `cadence_id` is `TRIM()`'d but **not case-normalized** anywhere in this file — a
  known, shared limitation (see check 9's caveat #2 above; the source doc found this producing
  literal duplicate rows for at least one cadence pair).
- Cross-table joins (checkpoint ↔ `decision_engine_step__c`) assume the same literal id is used in
  both `cadence_id` and `cadence_id__c`; check 9's join to `detail_communication_lifecycle` is a
  substring `ILIKE` match instead (see check 9's caveat #1) — check 6's email-sent leg
  (added 2026-08-05) uses that same substring match and inherits the same risk.
- **`knowledge/schema.md` line 28 documents a `cadence_name` column on
  `fact_journey_progress_checkpoint` that does not exist** (verified live via `SHOW COLUMNS`).
  `cadence_id` itself is the free-text descriptive label — every query here filters/matches on
  `cadence_id` directly. Flag this doc line for correction.

## Corroboration (house rule)
State a cause only with corroborating evidence — see `context/analysis-approaches.md` #2 and
`bug-diagnostic/SKILL.md`'s corroboration section. An alert reports a number, not a diagnosis.
