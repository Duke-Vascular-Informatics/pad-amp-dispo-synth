---
description: "Pre-flight check for study setup — scans study_params.yaml, cohort SQL files, and covariate CSVs for incomplete placeholders and prints a checklist report. Run before Step 8 to confirm everything is ready."
name: "Check Study Setup"
agent: "agent"
tools: ["read_file", "grep_search", "file_search"]
---

You are performing a pre-flight setup check for this OMOP study template.

## Non-interactive alternative

For terminal or CI use, run the standalone R script instead of this skill:

```bash
Rscript scripts/check_setup.R
```

The script performs the same file-based checks below and exits with code 0 (all pass)
or 1 (failures present). No database connection is required. Use it in a shell hook
or before kicking off a long analysis run.

## What to check

Work through the following sections in order. Read each file directly — no database
connection is needed for any of these checks.

---

### 1. study_params.yaml

Read `study_params.yaml`. For each field below, report [OK], [WARN], or [FAIL]:

| Field | FAIL condition | WARN condition |
|-------|---------------|----------------|
| `study_name` | equals `"my_study"` or missing | — |
| `study_design` | — | equals `"prognostic_model"` (default, may be correct) |
| `cdm_schema` | equals `"cdm_my_study"` or missing | — |
| `results_schema` | equals `"my_study_results"` or missing | — |
| `cohort_table` | equals `"my_study_cohort"` or missing | — |
| `output_folder` | equals `"output/my_study"` or missing | — |
| `cdm_database_id` | — | equals `"my_cdm_v5.4"` (default) |
| `cdm_database_name` | — | equals `"My Study Database"` (default) |
| `target.index_event.ancestor_concept_ids` | contains `0` or is missing | — |
| `target.washout.ancestor_concept_ids` | contains `0` | — (empty list is OK) |
| `outcome.ancestor_concept_ids` | contains `0` or is missing | — |
| `comparator.index_event.ancestor_concept_ids` | contains `0` when `comparator.cohort_id` is set | — |

---

### 2. Cohort SQL files

Read each SQL file path listed under `target.sql_file`, `outcome.sql_file`, and
(when `comparator.cohort_id` is set) `comparator.sql_file` in `study_params.yaml`.

For each file:
- [FAIL] if the file does not exist at the declared path.
- [FAIL] if the file contains the pattern `concept_id = 0` (case-insensitive) — this
  indicates a hardcoded placeholder ID that was not replaced.
- [OK] otherwise.

---

### 3. covariates/covariates.csv

Read `covariates/covariates.csv` if it exists.

- [WARN] if the file does not exist (skip if using FeatureExtraction directly).
- [FAIL] if any row has a `covariate_id` matching the pattern `covariate_[0-9]+`
  (these are placeholder rows from the template).
- [OK] otherwise — report the row count.

---

### 4. covariates/covariate_concepts.csv

Read `covariates/covariate_concepts.csv` if it exists.

- [WARN] if the file does not exist (skip if using FeatureExtraction directly).
- [FAIL] if any row has `concept_id` equal to `0` or `"0"` — these are placeholders
  that must be replaced with verified IDs from `/concept-lookup` or
  `Rscript scripts/concept_lookup.R`.
- [OK] otherwise — report the row count.

---

### 5. analyses flags

Read the `analyses:` section of `study_params.yaml`. For each flag
(`cohort_characterization`, `prognostic_model`, `causal_inference`,
`integer_risk_score`, `word_report`):

- Print [OK] + flag name when `true`.
- Print [----] + flag name when `false` (not an error — just informational).
- [WARN] if all five flags are `false` (nothing will run in Step 8).
- [FAIL] if `causal_inference: true` but `comparator.cohort_id` is not set.
- [FAIL] if `integer_risk_score: true` but `covariates/covariates.csv` has no
  `points` column.

---

## Output format

Print a sectioned checklist report exactly like this structure:

```
=== Check Setup Report ===

--- 1. study_params.yaml ---
  [OK]   study_name = 'hip_fracture_study'
  [WARN] study_design is still the default 'prognostic_model' — update if different
  [FAIL] cdm_schema is still the default 'cdm_my_study'
  ...

--- 2. Cohort SQL files ---
  [OK]   target SQL (cohorts/target_surgery.sql) — no hardcoded concept_id = 0
  ...

--- 3. covariates/covariates.csv ---
  [OK]   covariates.csv — 8 covariate(s), no placeholders

--- 4. covariates/covariate_concepts.csv ---
  [FAIL] covariate_concepts.csv has 3 row(s) with concept_id = 0: cov_diabetes, ...

--- 5. analyses flags (study_params.yaml) ---
  [OK]   cohort_characterization: true
  [----] prognostic_model: false
  ...

--- Summary ---
  FAIL:    2 item(s) must be resolved before running Step 8.
  WARNING: 1 item(s) to review (non-blocking).

Resolve [FAIL] items, then re-run: Rscript scripts/check_setup.R
```

If everything passes:

```
--- Summary ---
  ALL CHECKS PASSED — ready to run Step 8.
  Next: Rscript workflow/07_setup_analysis_env.R
        Rscript workflow/08_run_analysis_and_manuscript_report.R
```

---

## After the report

For each [FAIL] item, provide a one-line remediation hint:

- Concept ID `0` in `study_params.yaml` → Run `/concept-lookup <term>` or
  `Rscript scripts/concept_lookup.R "<term>" [domain]`
- Placeholder rows in CSVs → Replace with study-specific values
- Missing SQL file → Verify the path in `study_params.yaml` matches the actual file
- Schema still at default → Edit `study_params.yaml` and set the correct schema name

Do not suggest database queries or code changes for [WARN] items — those are
informational only and do not block Step 8.
