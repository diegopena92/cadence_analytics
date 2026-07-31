# Snowflake Operating Rules

How to run queries in this project.

## Defaults
- **Source of truth:** `analytics.main.fact_journey_progress_checkpoint` for cadence
  entries/exits/breaks and checkpoint fields.
- Always use **three-part identifiers** (`DB.SCHEMA.TABLE`). No `USE DATABASE` prefix.
- Always end queries with `;`.
- Execute via the `mcp__claude_ai_Snowflake__sql_exec_tool` MCP tool.

## Where each thing lives
| Need | Table |
|---|---|
| Entries / exits / breaks / checkpoint fields | `analytics.main.fact_journey_progress_checkpoint` (raw twin: `segment_events.iterable_http.journey_progress_checkpoint`) |
| Steps surfaced / completed (rep-facing) | `hcp_integrations.multi_salesforce_production.decision_engine_step__c` |
| Lead / Account / MA / rep raw fields | `hcp_integrations.housecallpro_salesforce.{lead, account, marketing_attribution__c, user}` |
| Cadence entries (clean, first-entry) | `marts.sales.detail_cadence_entries` ✅ live |
| Cadence 30/60-day cohort performance | `marts.sales.cohort_cadence_performance` ✅ live |
| Downstream calls/demos/enrollments | `marts.sales.fact_sales_funnel_activity` ✅ live |
| Outbound eligibility snapshots | `marts.sales.detail_outbound_eligible_leads` ✅ live |
| Lead/Account change history | `marts.sales.dim_lead_account_history` |
| Pro → org → account | `dim_salesforce_account` |
| Email/SMS comms (secondary) | `marts.communication.detail_communication_lifecycle` |

See [[schema]] for the full field dictionary. **Status (verified 2026-07-23):** three of
the four cadence marts in `marts.sales.*` are **materialized** and queryable directly
(`detail_cadence_entries`, `cohort_cadence_performance`, `detail_outbound_eligible_leads`).
Only `fact_cadence_checkpoints` is **still pending** — for checkpoint-event-grain work,
query `analytics.main.fact_journey_progress_checkpoint` until it lands.

## Governance & freshness
- Prefer the **governed** layer (`ANALYTICS.MAIN`, `MARTS.*`) over raw replicas when the
  field exists there. When you must query a raw source (`SEGMENT_EVENTS`,
  `HCP_INTEGRATIONS.*`), state that the result is raw/ungoverned.
- Governed tables are typically rebuilt **nightly** (data through the prior full day),
  **not intraday** — today's counts on a governed table may be incomplete. Check the
  schema-level `COMMENT` for refresh cadence when recency matters.
- To locate the right object, read `COMMENT`s (`SHOW DATABASES/SCHEMAS/TABLES/COLUMNS`,
  or `INFORMATION_SCHEMA`) rather than guessing at names.

## Timezone
- The checkpoint `event_timestamp` / `timestamp` is **UTC**. `HCP_INTEGRATIONS` raw
  objects (incl. `decision_engine_step__c.createddate`, `result_date_time__c`) are UTC.
- Wrap in `CONVERT_TIMEZONE('America/Los_Angeles', <ts>)` for PT day/week bucketing.
  Note: `createddate` and `result_date_time__c` are `TIMESTAMP_TZ` — use the **two-arg**
  form `CONVERT_TIMEZONE('America/Los_Angeles', ts)`, not the three-arg `('UTC', ...)` form.
- `MARTS`/`ANALYTICS.MAIN` governed columns are generally already PT — don't double-convert.
- Pruning trade-off: wrapping a timestamp in `CONVERT_TIMEZONE` inside `WHERE` blocks
  partition pruning. For big scans, keep the floor on the raw UTC column (a slightly wider
  window is harmless) and apply the PT conversion only to the `::date`/`DATE_TRUNC` bucket.

## Efficiency
- Filter early on timestamps, ids, and status fields. No `SELECT *`; prefer `COUNT(1)`.
- Confirm free-text `cadence_id` values with `TRIM(...) ILIKE '%kw%'` before an exact filter.
- Use `LIMIT` for samples. Prefer CTEs for readability without losing pruning.

## Canonical query patterns
Live in the cadence skills (`Individual Projects/Cadences/Context/`):
- Four-stage funnel + A/B + exit-reason mix → `cadence-analytics-resources-and-methodology`.
- 8-check Bug Detection Diagnostic, zero-fill, break union → `cadence-bug-investigation`.

## Always apply
`knowledge/data-quality-caveats.md` — break union, Test=Control, free-text ids, surfaced-vs-completed
dating, `clear_step`, result casing, identity resolution, unique-pro counting, timezone.
