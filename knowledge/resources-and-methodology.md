# Cadence Analytics — Resources & Methodology

The central knowledge doc: what a cadence is, the four-stage funnel, which table is
authoritative for each stage, and identity resolution. Distilled from the
`cadence-analytics-resources-and-methodology` skill. Pair with
[[data-quality-caveats]], [[schema]], and [[glossary]].

> Source: [Cadence Analytics](https://housecall.atlassian.net/wiki/spaces/LDU/pages/4208918641/Cadence+Analytics)
> and [Cadence Analytics - Marts Requirements](https://housecall.atlassian.net/wiki/spaces/LDU/pages/4209246250/Cadence+Analytics+-+Marts+Requirements).

## What is a cadence?
A cadence is a structured, multi-step outreach sequence (Iterable) that guides a pro
toward enrollment or upsell and surfaces instructions to reps in Salesforce. Cadences
(1) automate touchpoints, (2) surface rep instructions, and (3) monitor pro flow + rep
adherence via checkpoint data.

Orchestration path: **Iterable → Hightouch → Snowflake → Segment**, then back into
Salesforce for rep-facing instructions.

Every cadence event (Start, Break, Exit, checkpoint) is logged as a row in the raw
table `segment_events.iterable_http.journey_progress_checkpoint`, surfaced in analytics
as `analytics.main.fact_journey_progress_checkpoint` — **the source of truth for all
cadence analytics.**

## Cadence lifecycle
| Phase | `cadence_step` | Meaning |
|---|---|---|
| Entry | `Start` or `Test` | Pro/lead entered the cadence (`Start` = treatment; `Test` = control — see caveats) |
| Break | `Break` | Rep didn't complete a prescribed action in-window — `cadence_step_value` = break reason |
| Checkpoints | Call Disposition, Stage Update, Appcues segmentation, Request failed | Progress markers within the cadence |
| Exit | `Exit` | Left the cadence — `cadence_step_value` = exit reason (enrolled, LDS, lost, sequence end) |

## The four-stage cadence funnel
Read cadence health across four stages, not any single metric. A healthy cadence has all
four rising/falling together; a broken one has one stage decoupled (e.g. entries rising
while surfaced steps collapse to zero → an integration/routing break, not a demand
problem). **Always compute all four and chart them on the same x-axis so divergence is visible.**

### 1. Pros who entered — `SEGMENT_EVENTS.ITERABLE_HTTP.JOURNEY_PROGRESS_CHECKPOINT`
- "Entered" = `cadence_step = 'Start'`.
- Count **unique** pros (`COUNT(DISTINCT email)` or `COUNT(DISTINCT object_record_id)`), not rows.
- Match the cadence with `TRIM(cadence_id) ILIKE '%<keyword>%'` (free-text field).
- In-flight = a `Start` with no later `Exit` for the same `object_record_id`.

```sql
SELECT DATE_TRUNC('week', timestamp::date) AS week_start,
       COUNT(DISTINCT email) AS unique_entries
FROM segment_events.iterable_http.journey_progress_checkpoint
WHERE TRIM(cadence_id) ILIKE '%<cadence keyword>%'
  AND cadence_step = 'Start'
GROUP BY 1 ORDER BY 1;
```

**A/B rollouts:** a `cadence_step = 'Test'` row with `cadence_step_value = 'Control group:
Pro assigned to a rep not working in cadence'` = a pro who *qualified* but was *held out*
(rep not in the rollout). These never get a `Start` row — a separate parallel population,
not a funnel stage. Don't count them as entries. A shrinking control group alongside
flat/rising starts is expected as a rollout expands. Not every cadence uses this — check
for `Test` rows first.

### 2. Pros who had a step surfaced — `HCP_INTEGRATIONS.MULTI_SALESFORCE_PRODUCTION.DECISION_ENGINE_STEP__C`
The Salesforce-side raw table (Fivetran 1:1 replica of `Decision_Engine_Step__c`) — where
the rep-facing task actually gets created. Entries healthy but this flat/falling → the
break is most likely in the Iterable → Salesforce integration, not demand.
- Identify via `CADENCE_ID__C` (same free-text caveat).
- "Surfaced" = **any** row for that cadence, regardless of `RESULT__C`. Bucket by `CREATEDDATE`.
- **Filter `step_id__c = 'Call attempt'`** to isolate call instructions.
- **Always `AND name != 'clear_step'`** — system rows that look like a Call attempt but aren't rep-facing.
- Pro email is `email__c` here (not `email`).

```sql
SELECT DATE_TRUNC('week', createddate::date) AS week_start,
       COUNT(*) AS steps_surfaced
FROM hcp_integrations.multi_salesforce_production.decision_engine_step__c
WHERE cadence_id__c = '<exact cadence id, confirmed via ILIKE first>'
  AND step_id__c = 'Call attempt'
  AND name != 'clear_step'
GROUP BY 1 ORDER BY 1;
```

### 3. Pros who had a step completed — same table as stage 2
- "Completed" = `RESULT__C IS NOT NULL AND RESULT__C != 'Displayed'`.
  - `NULL` = surfaced but never actioned (still open); `'Displayed'` = shown but not worked
    (its own mid-funnel state, not a completion); any other non-null = completed.
- **Casing varies** (`'No contact - No Voicemail'` vs `'...voicemail'`) — `GROUP BY result__c`
  first to see every variant before folding them together.
- Bucket by `RESULT_DATE_TIME__C` (when the result was recorded), not `CREATEDDATE`.
- A step surfaced one week can complete a later week, so a week's completed count can
  exceed that week's surfaced count — not necessarily an error.

### 4. Pros who exited — `SEGMENT_EVENTS.ITERABLE_HTTP.JOURNEY_PROGRESS_CHECKPOINT`
- "Exited" = `cadence_step = 'Exit'`; `cadence_step_value` = exit reason.
- Count unique pros per week (`COUNT(DISTINCT email)`).
- Exit tracks entries with a **lag** — don't expect entries/exits to move in lockstep WoW.
- Compare exit-reason **mix** over time, not just volume (a flat total can mask a shift
  from `enrolled` to `lost`).
- Some exit reasons text-match `'cadence break'` and count toward break volume too — an
  exit row can be both a stage-4 exit and a break signal; note the overlap, don't
  double-suppress.

## Identity resolution
The fact table has 3 ID columns + email; which is populated depends on cadence type:

| Cadence name prefix | ID column | Resolves to |
|---|---|---|
| `Pre-Enroll Flywheel:` | `lead_id` | Salesforce **Lead** (prefix `00Q…`) |
| `Post-Enroll Flywheel:` | `user_id` | **Pro UUID** |
| `Demo Attendance` | `anonymous_id` | **Org UUID** |
| All cadences | `email` | Always-populated fallback |

- Derive one grouping key: `unique_id = COALESCE(lead_id, user_id, anonymous_id, email)`.
- `object_record_id` (prefix `a1n…`) is the custom-object id — **not** the same as `lead_id`.
- Resolve to an account via `dim_salesforce_account` (`pro_uuid` → `organization_id` → `account_id`).
- **Lead → Account conversion:** Marketing Attributions (MAs) generate/update Leads; a Lead
  converts to an Account when a pro **attends** a demo (attendance is the trigger, not booking).

## Source-of-record tables
Prefer these over ad-hoc joins when the field exists here (full detail in [[schema]]):

| Entity | Table |
|---|---|
| Lead | `hcp_integrations.housecallpro_salesforce.lead` |
| Account | `hcp_integrations.housecallpro_salesforce.account` |
| Marketing Attribution | `hcp_integrations.housecallpro_salesforce.marketing_attribution__c` |
| Lead/Account change history | `marts.sales.dim_lead_account_history` |
| Salesforce user / rep | `hcp_integrations.housecallpro_salesforce.user` |

## Cadence Analytics marts
**Status (verified against Snowflake 2026-07-23):** three of the four are **materialized**
in `MARTS.SALES` (dbt, owner `AE_DBT_CLOUD_PROD`) and queryable today; only
`fact_cadence_checkpoints` is still pending — use `analytics.main.fact_journey_progress_checkpoint`
for checkpoint-grain work until it lands.

| Dashboard | Mart | Status | Grain |
|---|---|---|---|
| Cadence Overview (entries/breaks/exits over time) | `marts.sales.fact_cadence_checkpoints` | ❌ pending | One row per checkpoint event per unique id |
| Cadence Entry Detail (entries + exit + SDR attribution) | `marts.sales.detail_cadence_entries` | ✅ live (~2.27M) | One row per unique id per cadence, first entry only |
| Cohort Performance (30/60-day funnel) | `marts.sales.cohort_cadence_performance` | ✅ live (~2.27M) | One row per entry + 30/60-day activity |
| Eligible Leads | `marts.sales.detail_outbound_eligible_leads` | ✅ live (~264M) | One row per lead/account per eligible date |

`cohort_cadence_performance` sums 30/60-day post-entry activity from
**`marts.sales.fact_sales_funnel_activity`** (~210M rows; calls/demos/enrollments keyed on
`lead_id`/`account_id`), joined by both `lead_id` and `account_id` over a 60-day window.
Full column lists are in [[schema]]. Full mart source SQL:
[Cadence Analytics - Marts Requirements](https://housecall.atlassian.net/wiki/spaces/LDU/pages/4209246250/Cadence+Analytics+-+Marts+Requirements).

## Related
- [[schema]] · [[data-quality-caveats]] · [[glossary]]
- Skills: `cadence-analytics-resources-and-methodology`, `cadence-bug-investigation`,
  `cadence-analysis-approaches`, `cadence-sop` (in `Individual Projects/Cadences/Context/`).
- [Additional Cadence Reporting Resources](https://housecall.atlassian.net/wiki/spaces/Monetizati/pages/4280746056/Additional+Cadence+Reporting+Resources)
- Questions on raw/analytics tables: #data-business-analytics
