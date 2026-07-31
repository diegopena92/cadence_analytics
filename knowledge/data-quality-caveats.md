# Data Quality Caveats

Cross-cutting traps that MUST be applied (or at least stated) in every cadence analysis.
If an analysis ignores one of these, its numbers are probably wrong. Distilled from the
`cadence-analytics-resources-and-methodology` and `cadence-bug-investigation` skills.

## 1. Breaks are recorded inconsistently — take the union of three signals
A "break" can appear in three different places, and which one a cadence uses varies. Never
trust `cadence_step = 'Break'` alone — it can be near-empty even on a cadence with heavy
real break volume. Before reporting any break count, check all three and take the union:
1. `cadence_step = 'Break'` — a dedicated break row.
2. `cadence_step = 'Exit'` **and** `cadence_step_value ILIKE '%cadence break%'` — a break
   recorded as an exit reason (e.g. `'Cadence break - no task created'`).
3. `cadence_step_status = 'Break'` on a row whose `cadence_step` is something else
   (commonly `'Call Disposition'`, `cadence_step_value` like `'No call disposition
   provided'`). Confirmed on `Pre-Enroll Flywheel: Inbound Demo Attended`, where this
   pattern is the large majority of real breaks (hundreds/week) while `cadence_step =
   'Break'` alone shows almost nothing.

```sql
... AND ( cadence_step = 'Break'
       OR cadence_step_status = 'Break'
       OR (cadence_step = 'Exit' AND cadence_step_value ILIKE '%cadence break%') )
```

## 2. Counterintuitive A/B naming: `Test` = Control, `Start` = treatment
`cadence_step = 'Test'` means the **Control** group (held out, no treatment).
`cadence_step = 'Start'` means the **Test/treatment** group (entered). Control rows always
have `cadence_step_value` starting `"Control group: ..."`. Control pros never get a `Start`
row — they are a separate parallel population, **not** a funnel stage between qualification
and entry. Don't count them as entries; check for `Test` rows before assuming `Start`
volume is the full qualified population.

## 3. Free-text cadence ids — whitespace & casing
`cadence_id`, `cadence_name`, and `cadence_id__c` are free text with leading/trailing
whitespace and inconsistent casing. Always discover the exact stored value with
`TRIM(cadence_id) ILIKE '%<keyword>%'` first, then filter on the confirmed exact value.
Never assume an exact `=` match without confirming the literal.

## 4. Surfaced vs completed use different dates
On `decision_engine_step__c`: bucket **surfaced** steps by `createddate`, **completed**
steps by `result_date_time__c`. These are different events — a step surfaced in one week
can complete in a later week, so a week's completed count can exceed that week's surfaced
count. This is not necessarily a data error.

## 5. `clear_step` and step-type filters
Always `AND name != 'clear_step'` on `decision_engine_step__c` — those are
system-generated rows that look like a `Call attempt` but are not rep-facing; leaving them
in inflates surfaced counts and distorts completion rate. Filter `step_id__c = 'Call
attempt'` to isolate call instructions; an unfiltered row count is not "call attempts."

## 6. Result casing varies
`result__c` has casing variants (e.g. `'No contact - No Voicemail'` and `'No contact - No
voicemail'` both appear). `GROUP BY result__c` first to see every variant before deciding
whether to fold them together. `cadence_step_status` casing is also inconsistent —
normalize with `lower()`.

## 7. "Completed" excludes `Displayed` and NULL
Completed = `result__c IS NOT NULL AND result__c != 'Displayed'`. `NULL` = surfaced but
never actioned (still open). `'Displayed'` = shown to the rep but not worked — its own
mid-funnel state, not a completion.

## 8. Identity column depends on cadence type
Only one of `lead_id` / `user_id` / `anonymous_id` is populated per cadence type (Pre-Enroll
→ `lead_id`, Post-Enroll → `user_id`, Demo Attendance → `anonymous_id`); `email` is always
populated. Group by `unique_id = COALESCE(lead_id, user_id, anonymous_id, email)`.
`object_record_id` (`a1n…`) is **not** `lead_id` (`00Q…`) — don't join them.

## 9. Count unique pros, not rows (entries/exits)
One pro generates multiple `Start`/`Exit` events. For stage 1 and stage 4 use
`COUNT(DISTINCT email)` (or `object_record_id`), never `COUNT(*)`.

## 10. Some cadences are not supposed to surface steps
Zero/near-zero `decision_engine_step__c` rows is **expected** for these — do not flag as
broken on surfaced-step volume alone: Post-Enroll Flywheel **ARPA Engagement**, **Type 1
Onboarding**, **Type 1 Adoption**, **Type 1 Nurture**, **Activation**, **Warming**. A
cadence *not* on this list showing the same near-zero pattern is a real finding.

## 11. Zero-fill weeks for charting
Weeks with no activity won't appear in a plain `GROUP BY` and read as "no data" instead of
"zero." Generate the week series with `GENERATOR`/`seq4()` and left join (see
`cadence-bug-investigation` §"Zero-filling weeks").

## 12. Timezone — `event_timestamp` is UTC
The checkpoint `event_timestamp`/`timestamp` is UTC. `HCP_INTEGRATIONS` raw objects are
UTC. Wrap in `CONVERT_TIMEZONE('America/Los_Angeles', <ts>)` for PT day/week bucketing.
Governed `MARTS`/`ANALYTICS` tables are typically PT and rebuilt nightly (prior full day),
not intraday — see `context/snowflake.md`.

## 13. Don't infer cause without corroboration
A data movement is not an explanation. State a cause only with direct corroborating
evidence (a matching event in another table, an MKTTECH ticket describing a change, an
explicit data point). Otherwise say the cause is unknown. (House rule — see
`cadence-analysis-approaches`.)

## 14. Tying comms to a cadence — match by `workflow_name`, not `workflow_id`
`marts.communication.detail_communication_lifecycle` and `analytics.main.fact_journey_progress_checkpoint`
frequently use **different `workflow_id` values for the same cadence** — for `Pre-Enroll Flywheel:
Inbound In Trial`, only 5 of ~59 checkpoint workflow_ids had a matching named workflow in the comms
table. Do not join the two tables on `workflow_id` and expect complete coverage.

What works: filter comms on `workflow_name ILIKE '%<current cadence name>%'` (e.g. `'%Pre-Enroll
Flywheel: Inbound In Trial%'`) — comms carries the cadence's current name in `workflow_name` even when
the underlying id doesn't match the checkpoint table's id for the same cadence. Verified across
`comm_type` — email, sms, and push notification all carry this naming, so the same filter works for
all three.

This only catches comms tagged with the **current** "Pre-Enroll Flywheel:" (martech) naming —
older/legacy workflow names for the same conceptual cadence (e.g. `3Q24 In-Trial Overhaul`, `Lead In
Trial Submission`) predate the naming rebrand and won't match. Only use this name-match approach for
cadences already on the current martech naming convention.

## 15. Excluding "lost" leads — check `lost_lead_reason__c`, not just `status`
`hcp_integrations.housecallpro_salesforce.lead.lost_lead_reason__c` can be populated (e.g. `Not
Ready`, `Bad Contact Info`, `Not Target Prospect`, `Do Not Call`) even when `status` is something
else entirely (`Exhausted`, `New`) — the reason field persists independent of current status.
Filtering only on `status != 'Lost Lead'` will not catch these. When excluding lost/DNC leads from
an output list, filter (or at minimum surface) `lost_lead_reason__c` directly rather than relying on
`status` alone.

## Related
- [[resources-and-methodology]] · [[schema]] · [[glossary]]
