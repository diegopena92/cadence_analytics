---
name: cadence-sop
description: Create/write/document a sales or operational cadence SOP (Standard Operating Procedure) for a front-line team, then publish it to Confluence. Trigger on "cadence", "SOP", "cadence doc", "outreach cadence", "sales cadence", "rep workflow", "conversation outcomes", or documenting how reps should work a set of leads (MQL, aged leads, trial users, churned customers). Gathers the right inputs and produces a fully structured cadence SOP in the standard Monetization-team format.
---

# Cadence SOP Skill

Guides writing a complete, publication-ready Cadence SOP for front-line teams, following the
standard structure used by HousecallPro's Monetization team, then publishing it to Confluence.
This is a **document-authoring** workflow, not a data-analysis one.

---

## Step 0: Gather Required Information
Interview the user conversationally (not all at once; group related questions). Use `[WIP]`
for anything unconfirmed — you don't need every field to start.

**1. Cadence identity** — name; one-sentence description; target audience/lead type; which
Salesforce object it's anchored to (Lead, Enrollment Opportunity, Contact); which front-line
team works it (ES, SDRs, Account Managers).
**2. Cadence goals** — the 2–3 goals.
**3. Resources** — Miro board link for the design (**required**; read it to inform Motion
Design); optional Excel with additional design input; Business Logic / Available Reporting /
Iterable Journeys links (placeholders if not yet available).
**4. Motion design** — from the Miro board, extract the flow, stages, and conditional logic
notes (e.g. "only if call length ≥ 1 min"); supplement from the Excel if provided.
**5. User interface** — which SF object reps work in; how cadence instructions are surfaced.
**6. Conversation outcomes** — every possible outcome with name, description/meaning, and any
required follow-up action + timing (e.g. "within 2 hours").
**7. Automated touchpoints** — automated outbound touchpoints; trigger for each; dynamic
content (rep name/phone/email); where reps see sent history.
**8. Rep workflow (step-by-step)** — walk start→finish (usually: identify leads via SalesApp →
access record/dial → call & log outcome → follow-ups → done).
**9. Confluence publishing** — target space; parent page (default **Documentation on Live
Cadences**, page ID 2053311795, Monetizati space — confirm); page title.

---

## Step 1: Write the Document
Use `[WIP]` for anything unconfirmed. Follow this exact section order and formatting.

```markdown
{One-sentence description of the cadence}

Jump to:
1. [Summary](#summary)
2. [Resources](#resources)
3. [Motion Design](#motion-design)
4. [How Reps Work Leads](#how-reps-will-work-leads)

---

# Summary
* {Cadence name} is part of {context — e.g., "an end-to-end customer journey designed as a flywheel, where generally a pro should be in only one cadence at a time"}.
* **{One bold sentence describing who is targeted and when}**.
* The goal of the cadence is to:
    * {Goal 1}
    * {Goal 2}

---

# Resources
* Business Logic: {highlight in yellow as placeholder link}
* Available Reporting: {highlight in yellow as placeholder link}
* Iterable Journeys: {highlight in yellow as placeholder link}

---

# Motion Design
{High-level call flow. Embed the diagram link if available; else describe in bullets.}
{Conditional logic notes prefixed with an asterisk, e.g.:}
* Only if {condition}

---

# How Reps Will Work Leads

## User Interface
* Reps will identify leads to be called through **SalesApp** in Salesforce
* By clicking on the lead's phone number to dial, the rep will access the Lead object in Salesforce where they will see displayed Cadence instructions
* If a cadence step is due, Reps will be asked to provide the outcome of _**Cadence Instructions**_ through the _**Conversation Outcomes**_

## Conversation Outcomes
### When to Provide One
Reps are asked to provide a **Conversation Outcome** in two instances:
1. They attempt to call the lead
2. The lead reaches out to the rep through call, email, or SMS (inbound touchpoints)

**PLEASE NOTE**: Some conversation outcomes require a follow-up action **within {timeframe} after** providing a call outcome, as follows:

| **Conversation Outcome** | **Details** | **Follow-up Actions Required** |
|---|---|---|
| {Outcome Name} | {Description} | {Follow-up action, or blank if none} |

---

## Automated Touchpoints
### Outbound Touchpoints
#### Triggers
An outbound touchpoint is a touchpoint from the rep to the lead. For each lead worked through the cadence, the following are triggered automatically based on the logic below:

| **Touchpoint** | **Trigger** |
|---|---|
| {Touchpoint type} | {What triggers it} |

#### Dynamic Content
* Automated outbound touchpoints will automatically surface the following for the rep assigned to the lead:
    * {Dynamic field 1 — e.g., Name}
    * {Dynamic field 2 — e.g., Phone}
    * {Dynamic field 3 — e.g., Email}

#### Touchpoint Sent History
* All outbound touchpoints will be displayed in {where — e.g., "the Lead object, under the Activity view"}

## Rep Workflow
* **Step 1: {Step title}**
    * {Details / notes}
* **Step 2: {Step title}**
* **Step 3: {Step title}**
* **Step 4: {Step title}**
* **Step 5: {Step title}**
* **Step 6: {Step title}**
* **Step 7: Done!**

---
```

---

## Step 2: Review with User
Present the draft in chat and ask: "Does this look right? Any sections to adjust, add, or
mark WIP?" Offer to iterate before publishing.

## Step 3: Publish to Confluence
Once approved, publish via `createConfluencePage`: `cloudId` (typically `housecall.atlassian.net`),
`spaceId`, `parentId` (if applicable), `title` (cadence name), `contentFormat: "markdown"`,
`body` (full markdown). To find space/parent IDs: `searchAtlassian` by space/parent title, or
`getConfluenceSpaces`; in a URL like `.../spaces/Monetizati/pages/3160540415/...` the page ID is
the numeric segment. Share the published URL afterward.

## Formatting notes
`**bold**` for key terms/outcome names; `[WIP]` for unfinalized sections; tables have a header
row + ≥2 columns; rep workflow steps numbered and bolded; intro blurb one sentence (above the
jump-to links); `#`/`##`/`###` for headers.

## Reference example
**Aged MQL Cadence** — https://housecall.atlassian.net/wiki/spaces/Monetizati/pages/3162341387/Aged+MQL+Cadence
(Monetizati, spaceId 1902052793, parent page ID 3160540415). Use for tone, structure, detail.

> House rules (`context/analysis-approaches.md`): Confluence docs are literal, not editorial —
> no "likely/probably", no narrative arc, no added wordiness. No humor.
