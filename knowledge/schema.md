# Schema Reference (AUTHORITATIVE)

Source of truth for which table holds which entity and what each field means. Wins over
any Confluence SQL. Always use three-part identifiers. Distilled from the
`cadence-analytics-resources-and-methodology` and `cadence-bug-investigation` skills.

## Databases at a glance
| Database.schema | What it holds | Governance |
|---|---|---|
| `SEGMENT_EVENTS.ITERABLE_HTTP` | Raw Iterable checkpoint event stream | Raw |
| `ANALYTICS.MAIN` | `fact_journey_progress_checkpoint` — **source of truth for cadence analytics** | Governed |
| `HCP_INTEGRATIONS.MULTI_SALESFORCE_PRODUCTION` | SF raw replica — `decision_engine_step__c` (surfaced/completed steps) | Raw (Fivetran 1:1) |
| `HCP_INTEGRATIONS.HOUSECALLPRO_SALESFORCE` | SF raw objects — `lead`, `account`, `marketing_attribution__c`, `user` | Raw |
| `MARTS.SALES` | Cadence marts (3 of 4 live — see below), `fact_sales_funnel_activity`, `dim_lead_account_history`, `dim_salesforce_account` | Governed |
| `MARTS.COMMUNICATION` | `detail_communication_lifecycle` (email/SMS comms) | Governed |

## Checkpoint fact — `analytics.main.fact_journey_progress_checkpoint`
(raw twin: `segment_events.iterable_http.journey_progress_checkpoint`)

| Field | Definition |
|---|---|
| `user_id` | Pro UUID — populated on **Post-Enroll** cadences |
| `lead_id` | Salesforce Lead Id (prefix `00Q…`) — populated on **Pre-Enroll** cadences |
| `anonymous_id` | Org UUID — **Demo Attendance** cadences only |
| `email` | Always populated; fallback identifier |
| `object_record_id` | Custom-object id (prefix `a1n…`) — **not** the same as `lead_id` |
| `cadence_id` | Cadence **name** despite the "id" suffix; free text (whitespace/casing vary) |
| `cadence_name` | Free-text cadence name (same caveats) |
| `cadence_step` | Event type: `Start`, `Test`, `Break`, `Exit` (raw also carries Call Disposition, Stage Update, etc.) |
| `cadence_step_status` | Outcome flag (`Success`/`Failure`/`Break`) — casing inconsistent, normalize with `lower()` |
| `cadence_step_value` | Context for the event; meaning depends on `cadence_step` (control reason / break reason / exit reason) |
| `workflow_id` | Iterable workflow/branch id — one cadence can have many (~39 for Outbound Aged MQL) |
| `timestamp` / `event_timestamp` | Event time (**UTC** — see [[data-quality-caveats]] and `context/snowflake.md`) |
| `entry_group` | A/B test landing group (used in rollout analysis) |

## Surfaced/completed steps — `hcp_integrations.multi_salesforce_production.decision_engine_step__c`
Fivetran 1:1 replica of the Salesforce `Decision_Engine_Step__c` object. Where the
rep-facing task/step is actually created.

| Field | Definition |
|---|---|
| `cadence_id__c` | Cadence identifier (free text; confirm exact value via `ILIKE` first) |
| `step_id__c` | Type of instruction surfaced — filter to `'Call attempt'` to isolate call instructions |
| `object_type__c` / `object_record_id__c` | SF object type and id the step was surfaced on |
| `createddate` | When the instruction was **surfaced** (stage 2 dating) |
| `result__c` | `NULL` = not seen/completed; `'Displayed'` = seen not completed; any other value = completed by rep |
| `result_date_time__c` | When the outcome was **recorded** (stage 3 dating) — not the same event as `createddate` |
| `email__c` | Pro's email (note `__c` — distinct from `email` on the checkpoint table) |
| `name` | Internal record name — filter `!= 'clear_step'` to exclude system-generated non-rep-facing rows |

## Source-of-record Salesforce objects (`hcp_integrations.housecallpro_salesforce`)
| Entity | Table | Notes |
|---|---|---|
| Lead | `lead` | Preferred source for lead-level fields |
| Account | `account` | Preferred source for account-level fields |
| Marketing Attribution | `marketing_attribution__c` | MAs generate/update Leads |
| Salesforce user / rep | `user` | Rep/user profile (name, role, etc.) |

## Derived / governed
| Purpose | Table |
|---|---|
| Lead/Account field-level change history | `marts.sales.dim_lead_account_history` |
| Pro → org → account resolution | `dim_salesforce_account` (`pro_uuid` → `organization_id` → `account_id`) |
| Email/SMS comms volume (secondary signal) | `marts.communication.detail_communication_lifecycle` (`comm_type`, `comm_date`, `campaign_id/name`, `workflow_id/name`) — tie to a cadence via `workflow_name ILIKE`, not `workflow_id` (see [[data-quality-caveats]] #14) |

## Cadence marts — verified status (Snowflake, 2026-07-23)
Three of the four are **materialized** in `MARTS.SALES` (dbt, owner `AE_DBT_CLOUD_PROD`)
and queryable today; only `fact_cadence_checkpoints` is still pending — use
`analytics.main.fact_journey_progress_checkpoint` for checkpoint-grain work until it lands.
Columns below are the **actual** materialized columns (not the earlier proposed shape).

- **`fact_cadence_checkpoints`** — ❌ **not yet materialized.** Proposed: `unique_id`,
  `cadence_id`, `cadence_step`, `cadence_step_value`, `valid_entry/valid_exit/valid_break`,
  `entry_group`, `entry_dt`, `exit_group`, `exit_dt`, `sdr_id/sdr_name/sdr_pod_role`,
  `opportunity_id`, `case_id`, `object_record_id`, `rep_id`.
- **`detail_cadence_entries`** — ✅ **materialized (~2.27M rows)**, one row per unique id per
  cadence (first entry). Columns: `unique_id`, `user_type`, `account_lead_id`, `account_id`,
  `user_id`, `cadence_id`, `email`, `lead_id`, `workflow_id`, `anonymous_id`, `test_flag`,
  `entry_group`, `entry_timestamp`, `entry_dt`, `rep_id`, `object_record_id`,
  `cadence_time_required`, `sdr_id`, `sdr_name`, `sdr_pod_role`, `opportunity_id`, `case_id`,
  `case_owner_id`, `exit_group`, `exit_dt`, `exit_timestamp`.
- **`cohort_cadence_performance`** — ✅ **materialized (~2.27M rows)**, one row per entry
  (`unique_id` × `cadence_id`) + 30/60-day activity. Entry/SDR/exit columns match
  `detail_cadence_entries`; each activity measure has a `_30_DAYS` and `_60_DAYS` variant:
  `calls`, `connect_calls`, `contact_calls`, `conversation_calls`, `demo_booked`,
  `demo_attended`, `enroll_type_3` (excludes Lite/Type 1/Type 2), `enroll_type_1` (Lite).
- **`detail_outbound_eligible_leads`** — ✅ **materialized (~264M rows)**, one row per
  lead/account per eligible date. Columns: `eligible_dt`, `id`, `previous_assignment`,
  `lead_category`, `object_type`, `assignment_priority_text`, `assignment_priority_number`,
  `lead_specialization_segment`, `lead_segment_priority`, `assigned_flag`, `sdr_decile`,
  `sdr_segment`, `industry`, `eltv_cac_bucket`.

## `fact_sales_funnel_activity` (activity source for the cohort mart) — ✅ materialized (~210M rows)
Event-grain sales activity keyed on `lead_id` / `account_id` / `organization_id` (also
`opportunity_id`, `demo_id`, `call_id`). Bucket by `activity_date`. Key flag measures:
`call_flag`, `connected_call_flag`, `contact_call_flag`, `conversation_call_flag`,
`demo_created_flag`, `demo_attended_flag`, `demo_failed_contact_flag`, `enroll_flag`,
`same_day_enrolled`. Value: `gross_mrr`, `net_mrr`, `saas_mrr`, `feature_mrr`,
`enrollment_eltv`. Rich dims: `sdr_*`/`es_*` rep attribution, `industry`,
`industry_segment`/`industry_segment_2`, `marketing_channel[_sub_group/_super_group]`,
`lead_category`, `account_type`, `sales_motion`. This is `cohort_cadence_performance`'s
source (joined by `lead_id` and `account_id`, 60-day window) and is the source of record
for cadence downstream calls/demos/enrollments.

## Related
- [[resources-and-methodology]] · [[data-quality-caveats]] · [[glossary]]
