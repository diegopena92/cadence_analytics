---
name: four-stage-funnel
description: Run the canonical four-stage cadence funnel (entries → steps surfaced → steps completed → exits) for a cadence, weekly and zero-filled, with Test-vs-Control entries and exit-reason mix. Use for a general performance read of a cadence ("how is this cadence doing", entries/exits over time, surfaced/completed volume). For bug/mechanical checks use `bug-diagnostic` instead.
---

# Four-Stage Cadence Funnel

Reads a cadence's health across the four stages — never a single metric. A healthy cadence
has all four rising/falling together; a broken one has one stage decoupled (e.g. entries
rising while surfaced steps collapse → an Iterable→Salesforce integration break, not a
demand problem). Always compute all four and chart them on one x-axis so divergence shows.

Query file: `four-stage-funnel.sql`. Definitions & tables: `knowledge/resources-and-methodology.md`
and `knowledge/schema.md`. Caveats: `knowledge/data-quality-caveats.md`.

## The four stages
| Stage | Source table | "Counts as" |
|---|---|---|
| 1. Entered | `analytics.main.fact_journey_progress_checkpoint` | `cadence_step='Start'`, `COUNT(DISTINCT email)` |
| 2. Step surfaced | `hcp_integrations.multi_salesforce_production.decision_engine_step__c` | any row, `step_id__c='Call attempt'`, `name!='clear_step'`, by `createddate` |
| 3. Step completed | same as stage 2 | `result__c IS NOT NULL AND result__c!='Displayed'`, by `result_date_time__c` |
| 4. Exited | `analytics.main.fact_journey_progress_checkpoint` | `cadence_step='Exit'`, `COUNT(DISTINCT email)` |

## Process
1. **Confirm the exact `cadence_id` first** — it is free text with whitespace/casing variants.
   Run `SELECT DISTINCT TRIM(cadence_id) FROM analytics.main.fact_journey_progress_checkpoint
   WHERE TRIM(cadence_id) ILIKE '%<keyword>%'` and use the confirmed literal in the query.
2. Set the same exact id in both the checkpoint filter and the `cadence_id__c` filter.
3. Adjust the week window (`ROWCOUNT => N`) as needed.
4. `pbcopy`/print, run via `mcp__claude_ai_Snowflake__sql_exec_tool`, save CSV to
   `data/four-stage-funnel_<cadence>_<YYYY-MM-DD>.csv`.
5. Compute WoW % change per stage and flag divergence; hand to the `cadence-health-analyst`
   agent (or apply the analysis method).

## Caveats (see `knowledge/data-quality-caveats.md`)
- Count **unique pros** for entries/exits (`COUNT(DISTINCT email)`), never `COUNT(*)`.
- `cadence_step='Test'` = **Control** (held out), not an entry — reported separately.
- Surfaced dated by `createddate`, completed by `result_date_time__c`; a week's completed
  can exceed that week's surfaced (steps completed in a later week). Not an error.
- Zero-fill weeks (the query does this) so empty weeks read as 0, not "no data".
- Some cadences are **not supposed to surface steps** — near-zero stage 2/3 is expected
  for the Post-Enroll list in the caveats file; don't read it as a break.
- `event_timestamp` is UTC — the query buckets in UTC; wrap in
  `CONVERT_TIMEZONE('America/Los_Angeles', …)` if PT day/week boundaries are required.
