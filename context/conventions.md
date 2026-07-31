# Conventions

## File naming
- Findings / reports → `outputs/documents/<topic>_<YYYY-MM-DD>.md` (e.g. `outputs/documents/aged-mql-bug-diagnostic_2026-07-23.md`).
- Charts / visualizations → `outputs/charts/<topic>_<YYYY-MM-DD>.html` (self-contained).
- Downloadable skill copies → `outputs/skills/<skill-name>.md` (see house rule below).
- Raw query results → `data/<query>_<YYYY-MM-DD>.csv`.
- Use the current date; use the cadence/skill/topic name as `<topic>`/`<query>`.

## `outputs/` subfolders
| Subfolder | Holds |
|---|---|
| `outputs/documents/` | Generated insight reports / findings (markdown). |
| `outputs/charts/` | Generated charts / visualizations (self-contained HTML). |
| `outputs/skills/` | Downloadable `SKILL.md` copies (house rule 8). |

## Gitignored (do not commit)
`outputs/`, `data/*.csv`, `__pycache__/`, `*.pyc`, `.env`, `.DS_Store` (see `.gitignore`).
Treat reports and data pulls as artifacts, not source. `knowledge/`, `context/`,
`agents/`, `skills/`, and `helpers/` ARE committed.

## Where things live
| Folder | Purpose |
|---|---|
| `knowledge/` | Distilled domain truth (resources & methodology, schema/tables, caveats, glossary). Read first. |
| `context/` | Operating rules: `snowflake.md`, `conventions.md`, `analysis-approaches.md` (house rules). |
| `agents/` | Analyst personas: `cadence-analyst` (orchestrator), `cadence-health-analyst`, `cadence-bug-analyst`, `cohort-performance-analyst`. |
| `skills/` | Runnable assets: `four-stage-funnel`, `bug-diagnostic`, `cadence-sop` (each a folder with `SKILL.md`, + `.sql` where applicable). |
| `helpers/` | Reusable SQL building blocks (`helpers/sql/`): cadence resolver, break union, zero-fill weeks. |
| `inputs/` | Source material / uploads used to build analyses. |
| `data/` | Raw CSV pulls (gitignored). |
| `outputs/` | Generated artifacts (gitignored): `documents/` (reports), `charts/` (HTML), `skills/` (downloadable SKILL.md copies). |

## House rules (from `cadence-analysis-approaches`)
- Concise, numbers-first; no preamble or closing restatement.
- Don't infer cause without corroboration; say "cause unknown" when there's none.
- Confluence docs are literal, not editorial. No humor.
- Verify before answering; re-run the current query rather than reusing a remembered number.
- MKTTECH Jira board is read-only.
- Any time a cadence skill is created/updated, copy its `SKILL.md` to `outputs/skills/<skill-name>.md`
  and present it as a downloadable file.

## Refreshing knowledge
`knowledge/` distills the LDU / Monetizati Confluence space and the cadence skills. To
refresh, re-fetch the source pages via the Atlassian MCP (`getConfluencePage`) — links are
in each knowledge file — and update the affected file.
