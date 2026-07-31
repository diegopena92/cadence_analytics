---
name: cadence-alerts
description: Run the 9-check Multi-Cadence Bug Diagnostic across all active cadences and post to the #cadence-analytics-alerts Slack channel, split into two severity tiers — "run the cadence alerts", "check for cadence mechanical issues", "post today's cadence alerts". Urgent tier (checks 1,2,3,4,6) runs daily, silent on a clean day; report tier (checks 5,7,8,9, recapping all 9) runs Mon+Thu and always posts something, with a full Google Doc report linked when anything's flagged. For a single-cadence deep dive use `bug-diagnostic` instead; for general performance use `four-stage-funnel`.
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
1. Build a Google Doc (via the Google Drive MCP connector) titled `Cadence Alerts Report —
   <date>` covering all 9 checks: for each, either "clean" or the flagged cadences with their
   numbers (actual, baseline mean, baseline stddev / threshold). This is the closest available
   substitute for a literal PDF — no PDF-rendering tool is available to the bot, but a Google Doc
   is a real, portable, downloadable document (anyone with the link can export it to PDF).
2. Post ONE short Slack message linking to it:
   - Nothing flagged anywhere: `**Cadence Alerts Report — <date>** — Nothing to call out this
     run. Full report: <link>` (this liveness ping is intentional — see tier design above).
   - Something flagged: `**Cadence Alerts Report — <date>** — <N> cadence(s) flagged across <M>
     check(s), see full report: <link>` plus a one-line list of which checks/cadences.
No new top-level message per item, no thread dedup — one message, one doc, twice a week.

Neither tier infers cause in the alert text (house rule — `context/analysis-approaches.md` #2):
state the number, not a guess at why it moved.

## Running it

### Live automated routines (production path)
Two durable cloud routines run against `#cadence-analytics-alerts` (channel_id `C0BMUN6PRGQ`),
created via the `schedule` skill / `RemoteTrigger`:
- **`cadence-alerts-urgent`** (`trig_01BkdGEqvTH2NMSpPvaree9p`) — checks 1, 2, 3, 4, 6, daily at
  14:00 UTC (~10am ET, after the nightly `ANALYTICS.MAIN` rebuild). Silent on a clean day.
- **`cadence-alerts-report`** (`trig_018zAoMWLt2snuhJm1cnJSfY`) — checks 5, 7, 8, 9 plus a recap
  of 1-4/6, **Monday and Thursday** at 14:00 UTC (`cron: 0 14 * * 1,4`). Always posts something —
  a liveness ping if clean, or a summary + Google Doc link if anything's flagged. Has the Google
  Drive MCP connector attached (connector_uuid `f25b56e1-3cbe-49ab-8356-baa87364d549`) in addition
  to Snowflake and Slack, to create the report doc.

Manage both at https://claude.ai/code/routines (list/update/run-now via `RemoteTrigger`; deletion
is web-UI only). Schedule note: Monday/Thursday was Mario's latest stated preference in the
requirements thread as of 2026-07-31, pending final confirmation against the team's sprint
grooming days — if that changes, update the `cadence-alerts-report` cron expression.

**Repo access:** this project is pushed to https://github.com/diegopena92/cadence_analytics
(public). Both routines have that repo attached as a `git_repository` source, so each run clones
it fresh and reads this file + `cadence-alerts.sql` directly — tuning a threshold here and pushing
is enough; no separate routine-prompt edit needed, UNLESS the set of checks assigned to a routine
changes (that's stated in the routine's prompt text itself and needs a `RemoteTrigger` `update`).

**Why not the local ledger file for the live routines:** cloud routines run in an isolated
environment with no shared filesystem across runs — even with the repo cloned fresh each time,
there's no persistent place to write back `outputs/alerts/cadence-alerts-state.json` between runs
(and it's gitignored, so committing it back isn't the intended pattern either). Each run instead
reads the channel's own recent message history (`slack_read_channel` on `C0BMUN6PRGQ`) and checks
whether a top-level message for the same check + cadence (and, for weekly checks, the same week)
already exists and is still open — if so, it replies in that thread instead of posting new. The
channel itself is the state store for the live routines.

### Manual/interactive run (ledger-based, for ad hoc use in this repo)
1. Run each check in `cadence-alerts.sql` via `mcp__claude_ai_Snowflake__sql_exec_tool`.
2. For each returned row, check the ledger (`outputs/alerts/cadence-alerts-state.json`) for
   `{check, cadence_id, key}`:
   - Not present → format and post a new top-level Slack message to `#cadence-analytics-alerts`
     via `mcp__claude_ai_Slack__slack_send_message`; record the returned `thread_ts` in the ledger.
   - Present → reply in that message's thread instead (or skip if already replied today).
3. Remove ledger entries for keys that no longer appear in the current run's results (resolved).

### Proposed: Hightouch → Google Sheet pipeline (not yet live)
Motivation: the Snowflake MCP connector's OAuth token expired mid-session twice during
development (2026-07-31), which would silently break the live routines with no visible error.
Routing the actual Snowflake execution through Hightouch (a separate, more stable
service-level Snowflake connection the team already operates) instead of this session's OAuth
removes that single point of failure — the routine would only need read access to a Google
Sheet, not a live Snowflake connection of its own.

**Design (agreed 2026-07-31):**
- One combined Hightouch model, `skills/cadence-alerts/hightouch-combined-model.sql` — all 9
  checks `UNION ALL`'d into one normalized schema (`check_number`, `check_name`, `cadence_id`,
  `metric_value`, `reference_value`, `detail`, `as_of`). Validated live against Snowflake
  (2026-07-31, 88 rows returned across all 9 checks) — this is the exact same filtering/logic as
  `cadence-alerts.sql`, not a simplified version.
- Hightouch syncs this model's **already-filtered result rows** (not raw underlying data) to a
  **single tab** in a Google Sheet, distinguished by `check_number`. An empty sync result for a
  check means clean — same "silence = clean" semantics as today.
- The sheet should be owned by or shared with the Google account connected to
  `mcp__claude_ai_Google_Drive` (believed to be `diego.pena@housecallpro.com` — confirm this,
  wasn't fully verifiable from Drive metadata alone).
- The routine would then: read the sheet via `mcp__claude_ai_Google_Drive__read_file_content`
  (supports `application/vnd.google-apps.spreadsheet`), filter rows by `check_number` per tier
  (urgent: 1,2,3,4,6; report: 5,7,8,9), and apply the exact same Slack-posting/dedup logic
  described above — the only thing that changes is where the check *results* come from.

**What's NOT done yet:**
- Hightouch model/sync creation itself — there's no Hightouch MCP connector available, so this
  has to happen in Hightouch's own UI/API, by whoever has Hightouch access. This skill only
  provides the ready-to-paste model SQL.
- The routine prompts still hit Snowflake directly as of this writing — they have NOT been
  switched to read the sheet. Do that only once the Hightouch sync is confirmed live and
  producing rows in the sheet, to avoid a silent gap where nothing points at real data.

**Known tradeoff:** the SQL now conceptually lives in two places — `cadence-alerts.sql` (the
per-check reference/documentation, and what `cadence-alerts-urgent`/`cadence-alerts-report`
currently execute directly) and `hightouch-combined-model.sql` (what Hightouch would run). They
must be updated together by hand whenever a threshold/filter/exclusion changes — there is no
automatic sync between them. This mirrors the same tradeoff already accepted for checks 2-4's
exclusion list.

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
