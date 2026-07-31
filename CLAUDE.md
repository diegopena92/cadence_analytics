# CLAUDE.md

## What this project is
A business-analyst workspace for **Cadence Analytics** at HCP — the Iterable/Salesforce
outreach cadences that guide pros through the lead/account lifecycle and surface
rep-facing instructions in Salesforce. The goal is to turn cadence questions into
written, evidence-backed findings: read cadence health across the four-stage funnel,
detect mechanical bugs, trace identity/attribution, and document cadences — not just
run SQL.

## How to work here
1. **Read `knowledge/` before any analysis.** Start with `knowledge/resources-and-methodology.md`
   (the four-stage funnel, tables, identity resolution), then `knowledge/data-quality-caveats.md`,
   `knowledge/schema.md`, and `knowledge/glossary.md`.
2. **For the actual data work, use the skills and agents.** Runnable skills in `skills/`:
   `four-stage-funnel` (entries → surfaced → completed → exits) and `bug-diagnostic` (the
   8-check Bug Detection Diagnostic), plus `cadence-sop` (writing/publishing a rep-facing SOP).
   Analyst personas in `agents/`: `cadence-analyst` (orchestrator) routes to
   `cadence-health-analyst`, `cadence-bug-analyst`, and `cohort-performance-analyst`. House
   rules for communicating findings live in `context/analysis-approaches.md`.
3. **Compute all four funnel stages, not one metric.** A cadence's health is entries →
   steps surfaced → steps completed → exits. A broken cadence usually has one stage
   decoupled from the others; always compute all four even if only one was asked about.

## Hard rules
- **Source of truth:** `analytics.main.fact_journey_progress_checkpoint` is the source of
  truth for all cadence analytics. `knowledge/schema.md` is authoritative for which table
  holds which entity (lead, account, marketing attribution, rep, checkpoint, surfaced step).
- **Snowflake:** three-part identifiers, end with `;`, execute via
  `mcp__claude_ai_Snowflake__sql_exec_tool`. Key databases: `SEGMENT_EVENTS` (raw Iterable),
  `ANALYTICS.MAIN` (governed checkpoint fact), `HCP_INTEGRATIONS.MULTI_SALESFORCE_PRODUCTION`
  (SF raw replica — `decision_engine_step__c`), `HCP_INTEGRATIONS.HOUSECALLPRO_SALESFORCE`
  (SF raw objects), `MARTS.*` (governed marts). See `context/snowflake.md`.
- **Free-text cadence ids:** `cadence_id` / `cadence_id__c` / `cadence_name` have leading/trailing
  whitespace and inconsistent casing. Always discover the exact value with
  `TRIM(cadence_id) ILIKE '%<keyword>%'` first, then filter on the confirmed value.
- **Breaks are recorded inconsistently** — take the union of all three signals
  (`cadence_step='Break'`, `cadence_step_status='Break'`, `cadence_step='Exit'` with
  `cadence_step_value ILIKE '%cadence break%'`). Never trust `cadence_step='Break'` alone.
- **Counterintuitive A/B naming:** `cadence_step='Test'` = **Control** (held out);
  `cadence_step='Start'` = **Test/treatment** (entered). Confirm via `cadence_step_value`
  (`"Control group: ..."`).
- **`clear_step` exclusion + step filters:** on `decision_engine_step__c`, always
  `AND name != 'clear_step'`, filter `step_id__c = 'Call attempt'` to isolate call
  instructions, bucket surfaced by `createddate` and completed by `result_date_time__c`.
- **Always apply** `knowledge/data-quality-caveats.md` (break union, Test=Control, casing/whitespace,
  surfaced-vs-completed dating, identity resolution, cadences not meant to surface steps).

## House rules for output (see `cadence-analysis-approaches`)
- Be concise: report numbers and direct findings; no preamble or closing restatement.
- **Do not infer beyond what the data shows.** State a cause only with direct corroborating
  evidence (another table, a ticket, an explicit data point) — otherwise say the cause is unknown.
- Confluence docs are literal, not editorial: no "likely/probably," no narrative arc.
- No humor. Verify before answering (re-run the current query; don't reuse a remembered number).
- MKTTECH Jira board is **read-only** — use it to corroborate, never edit.
- **Verify capability before claiming it** — confirm tools/permissions before saying "yes I can."
- When a cadence skill is created/updated, copy its `SKILL.md` to `outputs/skills/<skill-name>.md`
  and present it as a downloadable file.

## Output conventions
- Findings/reports → `outputs/documents/<topic>_<YYYY-MM-DD>.md`.
- Charts → `outputs/charts/<topic>_<YYYY-MM-DD>.html`. Skill copies → `outputs/skills/<skill-name>.md`.
- Raw data → `data/<query>_<YYYY-MM-DD>.csv`.
- `outputs/` and `data/*.csv` are **gitignored** — artifacts, not source. `knowledge/`,
  `context/`, `agents/`, `skills/`, `helpers/` are committed. See `context/conventions.md`.

## Refreshing knowledge
`knowledge/` distills the LDU / Monetizati Confluence space and the cadence skills. Re-fetch
via the Atlassian MCP (`getConfluencePage`) to update — source page links are in each file.
