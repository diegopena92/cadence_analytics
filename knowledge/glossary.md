# Glossary

Terms used across Cadence Analytics. Definitions are grounded in the cadence skills; where
a term maps to a specific field/value, that is noted. See [[resources-and-methodology]],
[[schema]], [[data-quality-caveats]].

| Term | Meaning |
|---|---|
| **Cadence** | A structured, multi-step Iterable outreach sequence that guides a pro toward enrollment/upsell and surfaces rep instructions in Salesforce. |
| **Checkpoint** | A logged cadence event (Start, Break, Exit, or a progress marker) — one row in `journey_progress_checkpoint`. |
| **Four-stage funnel** | Entries → steps surfaced → steps completed → exits. Read cadence health across all four, never one metric. |
| **Entry / Start** | Pro entered the cadence — `cadence_step = 'Start'` (the **treatment** group in an A/B rollout). |
| **Test (Control)** | `cadence_step = 'Test'` — a pro who qualified but was **held out** (rep not in the rollout). `cadence_step_value` starts `"Control group: ..."`. A parallel population, not a funnel stage. |
| **Break** | A prescribed rep action not completed in-window. Recorded in three inconsistent ways — take the union (see [[data-quality-caveats]] §1). |
| **Exit** | Pro left the cadence — `cadence_step = 'Exit'`; `cadence_step_value` = exit reason. |
| **Step surfaced** | A rep-facing instruction created on `decision_engine_step__c` (any `result__c`), `step_id__c = 'Call attempt'`, `name != 'clear_step'`. Dated by `createddate`. |
| **Step completed** | `result__c IS NOT NULL AND result__c != 'Displayed'`. Dated by `result_date_time__c`. |
| **Displayed** | `result__c = 'Displayed'` — step shown to the rep but not yet worked; a mid-funnel state, not a completion. |
| **clear_step** | System-generated `decision_engine_step__c` row that mimics a Call attempt but isn't rep-facing — always excluded (`name != 'clear_step'`). |
| **Pre-Enroll (Flywheel)** | Cadence targeting pros before enrollment; identity column `lead_id` (Salesforce Lead). |
| **Post-Enroll (Flywheel)** | Cadence targeting enrolled pros; identity column `user_id` (Pro UUID). |
| **Demo Attendance cadence** | Cadence keyed on `anonymous_id` (Org UUID). |
| **unique_id** | Derived grouping key `COALESCE(lead_id, user_id, anonymous_id, email)`. |
| **object_record_id** | Custom-object id (prefix `a1n…`); **not** the Salesforce `lead_id` (`00Q…`). |
| **MA (Marketing Attribution)** | Record that generates/updates a Lead — `marketing_attribution__c`. |
| **Lead → Account conversion** | A Lead converts to an Account when a pro **attends** a demo (attendance, not booking, is the trigger). |
| **LDS** | An exit reason value (appears in `cadence_step_value` on Exit rows). |
| **Enrolled / Lost / Sequence end** | Common exit reasons in `cadence_step_value`. |
| **Type 1 (Lite) / Type 3 enrollment** | Enrollment tiers tracked in `cohort_cadence_performance`; Type 3 excludes Lite/Type 1/Type 2. |
| **Workflow / journey** | Iterable workflow/branch within a cadence (`workflow_id`); one cadence can have many. |
| **SDR / rep adherence** | Whether the rep completed prescribed cadence steps; monitored via checkpoint + surfaced/completed step data (Tableau Cadence Dashboard). |
| **Eligible lead** | A lead/account eligible for outbound assignment on a snapshot date (`detail_outbound_eligible_leads`). |
| **Orchestration path** | Iterable → Hightouch → Snowflake → Segment → back to Salesforce. |
| **MKTTECH** | Martech Jira board that owns cadence work — read-only for analysis corroboration. |

## Related
- [[resources-and-methodology]] · [[schema]] · [[data-quality-caveats]]
