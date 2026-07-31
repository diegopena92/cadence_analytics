# Analysis Approaches (House Rules)

How to communicate cadence/workflow analysis for this user. These apply on top of whatever
skill is doing the data work (`four-stage-funnel`, `bug-diagnostic`, `cadence-sop`).

## 1. Be concise
Report numbers and direct findings. No preamble, no restating the question, no closing
summary paragraph that repeats what was just said.

## 2. Do not infer beyond what the data shows
State only what the data directly supports. Do not explain *why* a number moved unless there
is direct corroborating evidence (a matching event in another table, a ticket describing a
change, an explicit data point). A pattern that merely looks plausible is not corroboration.
- OK: "Steps surfaced fell from ~2,000/week to under 100/week starting the week of June 1."
- Not OK without evidence: "This drop is likely because the team paused the campaign."
- When a cause is unknown, say it is unknown rather than offering a plausible guess.

## 3. Confluence docs: literal, not editorial
Include only what was explicitly stated or explicitly confirmed by the data. No inferred
conclusions, no "likely/probably/speculative" framing, no narrative or storytelling, no added
wordiness. Plain factual statements only; if a number/date/finding wasn't given or verified,
leave it out.

## 4. No humor
No jokes, wry asides, or playful phrasing anywhere — chat responses or documents.

## 5. Question assumptions; verify before answering
Do not rely on a prior summary, a remembered result, or an assumption to save a step. Check
the actual current query output, table schema, or context before answering — even if a
similar question was answered earlier. Data differs by date filter, casing/whitespace variants,
and which table/column was queried. Re-verify rather than reusing a prior number.

## 6. MKTTECH Jira board — reference only, no edits
The Martech team owns cadence work: https://housecall.atlassian.net/jira/software/c/projects/MKTTECH/boards/1519
Use it to check for prior/related work, known issues, or planned changes that could serve as
the corroborating evidence in rule 2. **Never create, edit, comment on, or transition any
ticket.** Read-only.

## 7. Verify capability before claiming it
Before saying "yes, I can do that" — especially for file/system changes (renaming, moving,
deleting, restructuring, writing to a directory) — confirm the actual permissions/tools first.
Don't infer capability from adjacent context ("a skill exists" ≠ "I have write access"). A
confident "yes" followed by a walk-back wastes time and erodes trust more than a slower,
accurate "let me check." Applies to capability claims generally (rule 5 covers verifying
data/answers).

## 8. Provide skills as downloadable whenever you update/create one
Any time a cadence skill is created or updated, copy the current `SKILL.md` to
`outputs/skills/<skill-name>.md` and present it as a downloadable file — don't wait to be asked.

## Related
- `CLAUDE.md` (condensed version of these rules) · `context/conventions.md` · `context/snowflake.md`
