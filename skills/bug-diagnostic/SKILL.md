---
name: bug-diagnostic
description: Run a Bug Detection Diagnostic to find mechanical/structural/payload problems in a cadence — "run a bug diagnostic", "is this cadence broken", "double starts", "pros stuck in cadence", "cadence seems broken". Runs all 8 checks and reports confirmed checkpoint/payload formatting issues in the bug-ticket format. This is bug detection, NOT general performance reporting (use `four-stage-funnel` for that).
---

# Cadence Bug Detection Diagnostic

Finds bugs or mechanical issues in a cadence — not general performance. Reference
`knowledge/resources-and-methodology.md` and `knowledge/schema.md` for tables/fields and
the four-stage funnel; `knowledge/data-quality-caveats.md` for the traps. Query file:
`bug-diagnostic.sql` (the 8 checks, in order).

## Run all 8 checks — always
Report a cadence "clean" only after checking all 8; a bug can be present in one check while
every other metric looks healthy. Confirm the exact `cadence_id` (free text) via
`TRIM(cadence_id) ILIKE '%<keyword>%'` before running.

1. **No Starts in 7 days** — cadence gone silent on entries (upstream trigger/audience/workflow).
   Cross-check historical entry volume before flagging (naturally sparse cadences exist).
2. **Double Starts** — a 2nd `Start` with no `Exit` between → re-entry/dedup bug.
3. **Double Exits** — a 2nd `Exit` with no `Start` between → downstream automation firing twice.
4. **Stuck >100 days** — entered, no exit in 100+ days → exit automation not firing for a subset.
   Adjust the threshold to the cadence's expected run length if the user gives one.
5. **Drop in weekly entries/exits** — WoW, zero-filled; flag weeks that break the trend
   (report % change, not just raw numbers).
6. **Drop in steps surfaced** — same WoW logic on `decision_engine_step__c`, `step_id__c='Call
   attempt'`, `name!='clear_step'`, by `createddate`.
7. **Drop in steps completed** — same WoW logic, `result__c IS NOT NULL AND result__c!='Displayed'`,
   by `result_date_time__c` (can differ from the surfaced week).
8. **Break/exit/payload formatting discrepancy** — run the three break signals separately and
   compare volumes. If one field/value combo doesn't match any known break signal, or
   `cadence_step`/`cadence_step_status` look malformed, that is a formatting bug → report it.

## Break counting (critical)
Never filter `cadence_step='Break'` alone — breaks are recorded inconsistently and this can
undercount by orders of magnitude. Take the union of the three signals
(`cadence_step='Break'`; `cadence_step='Exit'` with `cadence_step_value ILIKE '%cadence break%'`;
`cadence_step_status='Break'` on another step such as `Call Disposition`). See caveats §1.

## Known-quiet cadences (don't flag on surfaced-step volume)
Post-Enroll Flywheel: **ARPA Engagement, Type 1 Onboarding, Type 1 Adoption, Type 1 Nurture,
Activation, Warming** are designed to (almost) never surface steps. A cadence NOT on this
list showing the same near-zero pattern is a real finding.

## Bug-ticket reporting format
When a diagnostic surfaces a data/checkpoint **formatting** issue (not just adherence),
package it as:
- **Cadence ID** — exact trimmed `cadence_id`.
- **Workflow/journey IDs impacted** — group by `workflow_id`/`journey_id` to confirm scope.
- **Wrong checkpoint formatting (current)** — the exact field/value combo written now, stated
  literally, + affected row count over a stated window.
- **Correct checkpoint formatting (expected)** — the pattern that should be used, ideally
  citing a sibling cadence that does it correctly.
- **Sample affected records** — a handful of emails + timestamps pulled from the raw table.

**Worked example — `Pre-Enroll Flywheel: Inbound Demo Attended` break bug (filed July 2026):**
Wrong: `cadence_step='Call Disposition'`, `cadence_step_status='Break'`, `cadence_step_value=
'No call disposition provided'` (~800 rows/35 days). Correct: dedicated `cadence_step='Break'`
row (as sibling `Demo Missed` does). Until fixed, use the multi-field break union for that cadence.

## Corroboration (house rule)
State a cause only with corroborating evidence — a matching event in another table or an
MKTTECH Jira ticket (read-only). Otherwise say the cause is unknown. See
`context/analysis-approaches.md`.

## Optional context
Email/SMS/push volume: `marts.communication.detail_communication_lifecycle` (`comm_type` = `email`,
`sms`, or `push notification`; bucket by `comm_date`). Tie to a specific cadence with
`workflow_name ILIKE '%<current martech cadence name>%'` — do NOT join on `workflow_id`, checkpoint
and comms frequently use different workflow_ids for the same cadence (verified on In Trial: only 5 of
~59 checkpoint workflow_ids matched a named comms workflow). Name-matching only catches cadences on
the current "Pre-Enroll Flywheel:"-style martech naming — older/legacy workflow names for the same
cadence predate the rebrand and won't match. See `knowledge/data-quality-caveats.md` #14.
