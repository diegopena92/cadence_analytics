---
name: cadence-alerts
description: Run the batched Cadence Mechanical Alerts check across all active cadences and post threshold-breaching results to the #cadence-analytics-alerts Slack channel — "run the cadence alerts", "check for cadence mechanical issues", "post today's cadence alerts". Batches the same checks as `bug-diagnostic` (checks 1-4 daily, 5-7 weekly) across every active cadence instead of one at a time, adds numeric thresholds, and suppresses repeat noise via a state ledger. For a single-cadence deep dive use `bug-diagnostic` instead; for general performance use `four-stage-funnel`.
---

# Cadence Mechanical Alerts

Batched, thresholded version of `bug-diagnostic` checks 1-7, run across every active cadence and
posted to Slack instead of written up as a one-off report. Reference
`knowledge/resources-and-methodology.md` and `knowledge/schema.md` for tables/fields,
`knowledge/data-quality-caveats.md` for the traps. Query file: `cadence-alerts.sql` (7 checks,
standalone/runnable individually).

## Scope: 7 checks, two run frequencies
| # | Check | Frequency | Alert rule |
|---|---|---|---|
| 1 | No Starts in 7 days | Daily | `days_since_last_start >= 7` |
| 2 | Double Starts | Daily | new count today >=3σ above the cadence's own 34-day baseline (or any occurrence if baseline is ~0) |
| 3 | Double Exits | Daily | same baseline-relative rule as check 2 |
| 4 | Newly stuck >100 days (entered, no exit) | Daily | same baseline-relative rule, applied to *new* crossings/day, not the total open backlog |
| 5 | Drop in weekly entries/exits | Weekly (Mon) | drop >=25% WoW, prior week volume >=10 |
| 6 | Drop in steps surfaced | Weekly (Mon) | drop >=25% WoW, prior week volume >=10 |
| 7 | Drop in steps completed | Weekly (Mon) | drop >=25% WoW, prior week volume >=10 |

"Active cadence" = had at least one `Start` row in the trailing 180 days — no maintained list,
re-discovered fresh on every run (see the `active_cadences` CTE in each query).

Check 8 from `bug-diagnostic` (break/payload formatting) is intentionally **not** in this alert
set — it's a diagnostic check for a suspected bug, not a standing monitor. Add it here later if
that changes.

## Why checks 2-4 are baseline-relative, not "any occurrence" (important — read before changing)
`bug-diagnostic`'s single-cadence checks 2-4 flag *any* double-start/double-exit/stuck-pro as a
bug — reasonable when an analyst already knows the one cadence being examined. Batching that
literally across all cadences was tried and rejected: dry-run against real data (2026-07-30) found
**750K+ double-start rows and 307K+ stuck-100d rows historywide**, almost entirely concentrated in
a handful of cadences that are recurring/evergreen *by design* — `HCP NPS Survey
25-90-150-Recurring` (resent every 25/90/150 days, so "re-entry with no Exit" is normal), `Post-
Enroll Flywheel: Warming`, `Upsell`, `Retention - SaaS Cancellation`, `Abandoned My Apps Page`,
`Inbound In Trial` (long/indefinite dwell time is expected). Posting on any occurrence would make
the channel fire on these every single day from hour one.

The fix: compare each cadence's **today** count to **its own** trailing 34-day daily
mean/std-dev, and only alert if today is a genuine outlier for that specific cadence — a real
new spike, not that cadence's normal operating range. Validated live: `HCP NPS Survey` (945 vs.
mean 781, σ=109 → 1.5σ, not flagged), `Warming` (917 double-exits vs. mean 408, σ=396 → 1.3σ, not
flagged), while `Post-Enroll Flywheel: Type 1 to Type 3 Upsell` (51 double-starts vs. mean 6.5,
σ=14.6 → ~3.0σ) correctly stood out as the one real anomaly that day.

Rule: flag if `today > baseline_mean + 3*baseline_stddev AND today >= 3` (min-count floor avoids
paging on a 1-2 event blip in an otherwise-silent cadence), **or** `baseline_mean ~= 0 AND today >
0` (a brand-new anomaly in a cadence that has never done this before — the case the fixed-list
approach would otherwise need a human to notice). The 3σ multiplier and min-count-3 floor are
defaults, not derived from a formal cost-of-false-positive analysis — tune with real feedback.

An explicit per-cadence override/exclusion is also available if the statistics ever disagree with
known domain judgment for a specific cadence (mirrors the known-quiet-cadence list used in checks
6-7) — none is hardcoded today since the baseline rule already handled every case found in
validation; add one only if a specific cadence needs a permanent override regardless of its stats.

## Thresholds are defaults, not settled — revisit after a week of real volume
Checks 5-7 use a fixed 25%-drop/minimum-10-volume threshold (validated: 5, 1, and 2 cadences
flagged respectively on real data — a reasonable weekly volume, no rework needed there). No prior
doc in this repo defines a numeric "drop" threshold — the defaults above were chosen to avoid
flagging noise on small cadences (see caveats: "cross-check historical volume before flagging —
naturally sparse cadences exist"), not derived from historical data. Watch real alert volume for a
week and tune with the requester before treating any of these as final.

## Anti-noise design ("don't become white noise")
1. **Silence on a clean run.** No "all clear" digest message — only post when a check breaches.
2. **One message per breaching check per cadence**, not a giant combined digest — mirrors
   `#hcp_kpi_alerts`' granularity so each issue can be reacted to/threaded independently.
3. **Repeat-suppression ledger** — `outputs/alerts/cadence-alerts-state.json` (gitignored, like
   the rest of `outputs/`) tracks `{check, cadence_id, key, thread_ts, first_seen_date,
   last_alerted_date}`. `key` is `week_start` for checks 5-7; for checks 2-4 (now a per-cadence
   daily anomaly, not a per-email check — see above) `key` is just the flagged date, and "still
   open" means the same `{check, cadence_id}` pair fired again within the last 7 days. Before
   posting:
   - **No open entry for `{check, cadence_id}`** → post a new top-level alert (include a few
     sample affected emails, pulled via the drill-down query in `cadence-alerts.sql`), record it
     in the ledger with the returned `thread_ts`.
   - **Open entry still firing** → reply in the *original* alert's thread instead of a new
     top-level post. Don't re-alert top-level for something already flagged and still ongoing.
   - An entry that stops firing ages out of the ledger on the next run (it resolved).
4. **Feedback loop** — ask people to react ✅ (expected/legit) or ❌ (false positive/not useful) on
   alerts, same convention as `#hcp_kpi_alerts`. Review reactions periodically and use ❌ patterns
   to adjust thresholds or extend the known-quiet-cadence list — this repo has no automated
   model-retraining loop, so that review is manual.

## Slack message format
Sent via `mcp__claude_ai_Slack__slack_send_message`, which renders standard markdown (`**bold**`,
`_italic_`), not Slack's native `*bold*` mrkdwn — use `**...**` for the headline:
```
**<Check name> — <cadence name>**
• <concrete numbers: actual vs. threshold/baseline, count of affected pros, sample emails>
_React ✅ if expected, ❌ if this shouldn't have fired. @Claude in this thread for more detail._
```
Repeat occurrences of an already-open alert are posted as a **reply in that message's thread**
(`thread_ts` = the parent alert's timestamp, from the ledger), not a new top-level message.
No cause inference in the alert text (house rule — `context/analysis-approaches.md` #2): state the
number, not a guess at why it moved.

## Running it

### Live automated routines (production path)
Two durable cloud routines are running against `#cadence-analytics-alerts`
(channel_id `C0BMUN6PRGQ`), created via the `schedule` skill / `RemoteTrigger`:
- **`cadence-alerts-daily`** (`trig_01BkdGEqvTH2NMSpPvaree9p`) — checks 1-4, daily at 14:00 UTC
  (~10am ET, after the nightly `ANALYTICS.MAIN` rebuild).
- **`cadence-alerts-weekly`** (`trig_018zAoMWLt2snuhJm1cnJSfY`) — checks 5-7, Mondays at
  14:00 UTC.

Manage both at https://claude.ai/code/routines (list/update/run-now via `RemoteTrigger`; deletion
is web-UI only).

**Repo access:** this project is pushed to https://github.com/diegopena92/cadence_analytics
(public). Both routines have that repo attached as a `git_repository` source, so each run clones
it fresh and reads `skills/cadence-alerts/SKILL.md` + `cadence-alerts.sql` directly — tuning a
threshold here and pushing is enough; no separate routine-prompt edit needed. (Earlier versions of
these routines carried the SQL inline in the prompt because this project wasn't yet a pushed repo —
if repo access ever breaks, that's the fallback: embed the SQL directly in the routine prompt via
`RemoteTrigger` `update` instead of relying on the clone.)

**Why not the local ledger file:** cloud routines run in an isolated environment with no shared
filesystem across runs — even with the repo cloned fresh each time, there's no persistent place to
write back `outputs/alerts/cadence-alerts-state.json` between runs (and it's gitignored, so
committing it back isn't the intended pattern either). Hence the Slack-history dedup below instead.

**Repeat-suppression without a ledger file:** each run reads the channel's own recent message
history (`slack_read_channel` on `C0BMUN6PRGQ`) and looks for an existing top-level message
matching the same check + cadence (and, for checks 5-7, the same week). If found and still open,
it replies in that thread instead of posting a new top-level message; otherwise it posts new. The
channel itself is the state store — no separate file. The `outputs/alerts/cadence-alerts-state.json`
ledger below is for **manual/interactive** runs of this skill from within a Claude Code session
on this repo (e.g. `bug-diagnostic`-style ad hoc runs), where local file persistence across
invocations is actually available.

### Manual/interactive run (ledger-based, for ad hoc use in this repo)
1. Run each check in `cadence-alerts.sql` via `mcp__claude_ai_Snowflake__sql_exec_tool`.
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
  exclusion is needed in checks 1-5.
- Known-quiet cadences (Post-Enroll Flywheel: ARPA Engagement, Type 1 Onboarding, Type 1
  Adoption, Type 1 Nurture, Activation, Warming) are excluded from checks 6-7 — near-zero
  surfaced/completed volume is expected there, not a bug.
- Governed tables (`ANALYTICS.MAIN`) rebuild nightly, not intraday — a same-day "no starts"
  won't show up until the next day's run; this is accepted latency, not a bug in the check.
- Free-text `cadence_id` casing/whitespace — every query `TRIM()`s the id; cross-table joins
  (checkpoint ↔ `decision_engine_step__c`) assume the same literal id is used in both `cadence_id`
  and `cadence_id__c`, per the existing `four-stage-funnel` convention.
- **`knowledge/schema.md` line 28 documents a `cadence_name` column on
  `fact_journey_progress_checkpoint` that does not exist** (verified live via `SHOW COLUMNS` —
  the table has no such column). `cadence_id` itself is the free-text descriptive label (e.g.
  "Post-Enroll Flywheel: Warming") — every query here filters/matches on `cadence_id` directly.
  Flag this doc line for correction; don't reintroduce a `cadence_name` reference elsewhere.

## Corroboration (house rule)
State a cause only with corroborating evidence — see `context/analysis-approaches.md` #2 and
`bug-diagnostic/SKILL.md`'s corroboration section. An alert reports a number, not a diagnosis.
