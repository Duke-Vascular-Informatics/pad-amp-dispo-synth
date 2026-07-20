# OMOP CDM Primer for New Analysts

This document is a practical introduction to the OMOP Common Data Model (CDM) and the
concepts you need to understand before configuring and running a study in this repository.
It assumes no prior experience with OMOP or clinical databases.

---

## 1. Why OMOP Exists

Electronic health records (EHRs) and claims databases look different at every institution.
A "diabetes" diagnosis might be stored as ICD-10 code `E11.9` at one hospital,
as a SNOMED concept at another, and as a free-text string at a third. This makes it nearly
impossible to run the same analysis across multiple data sources.

**OMOP (Observational Medical Outcomes Partnership) solves this by converting every data
source into a single common structure using shared, standardized vocabulary.**

After OMOP conversion ("ETL"):
- Every condition is stored as a SNOMED concept ID.
- Every drug is stored as an RxNorm concept ID.
- Every procedure is stored as a SNOMED or CPT4 concept ID.
- Every lab is stored as a LOINC concept ID.

The same analysis code works against any OMOP database, regardless of the original EHR system.

---

## 2. The Five Tables You Will Use Most

The OMOP CDM has ~40 tables, but five cover the vast majority of clinical data:

### `person`
One row per patient. Contains demographics: year of birth, sex, race/ethnicity.

```
person_id  |  year_of_birth  |  gender_concept_id  |  race_concept_id
----------------------------------------------------------------------
12345      |  1962           |  8507 (Male)         |  8527 (White)
```

`person_id` is the key that links every other table back to the patient.

### `condition_occurrence`
Every diagnosis ever recorded for a patient — one row per diagnosis event.

```
person_id  |  condition_concept_id  |  condition_start_date
------------------------------------------------------------
12345      |  201826 (Type 2 DM)    |  2018-03-15
12345      |  4185932 (Hypertension)|  2015-07-01
```

### `procedure_occurrence`
Every procedure performed — surgeries, imaging, lab draws.

```
person_id  |  procedure_concept_id      |  procedure_date
---------------------------------------------------------
12345      |  4301351 (CABG)            |  2021-06-10
```

### `drug_exposure`
Every drug prescribed or dispensed.

```
person_id  |  drug_concept_id          |  drug_exposure_start_date
------------------------------------------------------------------
12345      |  1545958 (Metformin 500mg) |  2018-04-01
```

### `visit_occurrence`
Every encounter with the healthcare system — admissions, outpatient visits, ED visits.

```
person_id  |  visit_concept_id   |  visit_start_date  |  visit_end_date
-----------------------------------------------------------------------
12345      |  9201 (Inpatient)   |  2021-06-09        |  2021-06-14
```

Common `visit_concept_id` values:
- `9201` — Inpatient Visit (hospital admission)
- `9202` — Outpatient Visit
- `9203` — Emergency Room Visit

---

## 3. Concept IDs — The Core of OMOP Vocabulary

Every clinical entity in OMOP is identified by a **concept ID** — an integer that maps to
a specific clinical meaning in a standard vocabulary (SNOMED, RxNorm, LOINC, CPT4, etc.).

### Standard concepts vs. source codes

When EHR data is converted to OMOP, two concept IDs are stored for each record:

| Column | What it stores | Example |
|--------|---------------|---------|
| `condition_concept_id` | Standard OMOP concept | `201826` (Type 2 DM, SNOMED) |
| `condition_source_concept_id` | The original source code | `E11` (ICD-10-CM code) |

**Always use the standard `*_concept_id` column in your queries, not the source column.**

A standard concept has `standard_concept = 'S'` in the `concept` table. Non-standard
concepts (source codes) have `standard_concept = NULL` or `'C'` and should not be used
for analysis — they may mean different things across databases.

### Finding the right concept ID

You cannot guess concept IDs. Always query the vocabulary:

```sql
SELECT concept_id, concept_name, vocabulary_id, domain_id, standard_concept
FROM omop_vocab.concept
WHERE concept_name LIKE '%type 2 diabetes%'
  AND standard_concept = 'S'
  AND invalid_reason IS NULL;
```

In this repository, use the `/concept-lookup` command to do this interactively:

```
/concept-lookup type 2 diabetes mellitus condition
/concept-lookup cefazolin drug
/concept-lookup hip replacement procedure
```

### Verifying a concept ID before using it

Before writing any concept ID into a SQL file or CSV:

1. Confirm `standard_concept = 'S'` — non-standard concepts are not in clinical tables.
2. Confirm `invalid_reason IS NULL` — invalid concepts have been retired.
3. Label the ID in your code: `-- [vocab query] SNOMED: Type 2 diabetes mellitus`

---

## 4. Ancestors and Descendants — The OMOP Hierarchy

Clinical concepts are organized in hierarchies. For example:

```
Diabetes mellitus (ancestor)
  ├── Type 1 diabetes mellitus
  ├── Type 2 diabetes mellitus       ← what you usually want
  │     ├── Type 2 DM with hyperglycemia
  │     ├── Type 2 DM with neuropathy
  │     └── Type 2 DM, insulin-treated
  └── Gestational diabetes mellitus
```

If you query `condition_concept_id = 201826` (Type 2 DM), you will only match records
coded with that *exact* concept. You will *miss* records coded as "Type 2 DM with
neuropathy" even though that is clearly a subtype of Type 2 DM.

**The solution is `concept_ancestor` rollup:**

```sql
-- Match Type 2 DM AND all its sub-types (descendants)
INNER JOIN omop_vocab.concept_ancestor ca
  ON ca.descendant_concept_id = co.condition_concept_id
WHERE ca.ancestor_concept_id = 201826   -- Type 2 DM (ancestor)
```

This is the standard OHDSI pattern for capturing a full clinical concept and all its
sub-types. The cohort SQL templates in `cohorts/` use this pattern for both the index
event and the outcome.

### When to use a single concept vs. an ancestor rollup

| Use case | Approach |
|----------|----------|
| Very specific condition (one exact code) | `condition_concept_id = X` |
| Broad category (e.g. "any SSI") | `concept_ancestor` rollup from the category ancestor |
| Drug class (e.g. "any statin") | `concept_ancestor` rollup from drug class ancestor |
| Procedure family (e.g. "any colectomy") | `concept_ancestor` rollup |

---

## 5. What Is a Cohort?

In OMOP studies, a **cohort** is a group of patients who:
1. Met a set of criteria (the cohort definition) at a specific point in time.
2. Have a defined **index date** (cohort_start_date) — the date they entered the cohort.
3. Have a defined **exit date** (cohort_end_date) — when their follow-up ends.

Cohorts are stored in a flat table:

```
cohort_definition_id  |  subject_id  |  cohort_start_date  |  cohort_end_date
------------------------------------------------------------------------------
1                     |  12345       |  2021-06-09         |  2021-06-14
1                     |  67890       |  2019-11-02         |  2019-11-07
2                     |  12345       |  2021-06-22         |  2021-06-23
```

- `cohort_definition_id = 1` is the **target cohort** (e.g. patients who had surgery).
- `cohort_definition_id = 2` is the **outcome cohort** (e.g. patients who had an SSI).

The analysis in Step 8 joins these two cohorts to determine which target patients
developed the outcome within the prediction window after their index date.

### Index date and index event

The **index event** is the clinical event that triggers cohort entry (e.g. a surgery,
a drug prescription, a diagnosis). The **index date** is the date of that event.

Everything measured **before** the index date is a covariate (baseline characteristic).
Everything measured **after** the index date is a potential outcome.

---

## 6. The Prediction Window

For prognostic models and causal designs, you define a **prediction window** — how many
days after the index date you look for the outcome.

```
Index date (day 0)
    │
    ├── Day 0:  surgery (index event)
    ├── Day 1:  start of risk window (riskWindowStart = 1, not 0)
    │           Why 1 and not 0? The index event itself (the surgery) is
    │           not the outcome. We start looking for the outcome the day
    │           AFTER the procedure.
    │
    ├── Days 1–90: follow-up window (prediction_window_days = 90)
    │           Any outcome event in this window is counted as a case.
    │
    └── Day 91+: outside the prediction window (not counted)
```

`prediction_window_days` in `config.R` sets this window. It must match the
`riskWindowEnd` argument in the Step 8 analysis starter patterns.

---

## 7. Prior Observation and Washout

### Prior observation
Patients need sufficient history in the database for their baseline covariates to be
meaningful. `min_prior_observation_days` in `workflow/02` excludes patients who entered
the database too recently (e.g. new insurance enrollees with < 365 days of history).

### Washout period
The washout period in the target cohort SQL excludes patients who already had the
outcome **before** the index date. This ensures you are studying *incident* (new) cases
rather than *prevalent* (pre-existing) cases.

Example: for a 30-day surgical site infection study, a washout of 365 days before
the surgery date excludes patients who had an SSI in the year before the index date.

---

## 8. Where to Learn More

| Resource | What it covers |
|----------|---------------|
| [Book of OHDSI](https://ohdsi.github.io/TheBookOfOhdsi/) | Comprehensive guide to OMOP study design, cohorts, characterization, prediction, estimation, and data quality |
| [OMOP CDM documentation](https://ohdsi.github.io/CommonDataModel/) | Full CDM table and field definitions |
| [ATLAS](https://atlas-demo.ohdsi.org) | Web-based OMOP cohort builder (visual, no SQL required) |
| [HADES package docs](https://ohdsi.github.io/Hades/) | R package documentation for all OHDSI analysis tools |
| [OHDSI Forums](https://forums.ohdsi.org) | Community Q&A for OMOP and OHDSI methodology questions |

The **Book of OHDSI** is the most important reference. Chapters 11–15 cover the four
study designs supported by this template:

| Chapter | Study design |
|---------|-------------|
| 11 | Cohort definition |
| 12 | Cohort characterization |
| 13 | Patient-level prediction |
| 14 | Population-level estimation (causal inference) |
| 15 | Data quality |
