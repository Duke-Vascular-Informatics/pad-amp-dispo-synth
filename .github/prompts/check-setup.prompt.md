---
description: "Pre-flight check for synthetic dataset setup — scans study_params.yaml, consumers.yaml and the Synthea module for incomplete placeholders and prints a checklist report. Run before generating synthetic data to confirm everything is ready."
name: "Check Study Setup"
agent: "agent"
tools: ["read_file", "grep_search", "file_search"]
---

You are performing a pre-flight setup check for this synthetic-dataset (`-synth`) repo.

A `-synth` repo defines no cohorts, outcomes or covariates of its own. What the dataset
must contain comes from the consuming studies listed in `consumers.yaml`; their cohort
definitions (`inst/Cohorts.csv` and `inst/cohorts/*.json` in each Strategus repo) are read
directly. So this check verifies that list is filled in and usable.

## Non-interactive alternative

For terminal or CI use, run the standalone R script instead of this skill:

```bash
Rscript scripts/check_setup.R
```

The script performs the same file-based checks below and exits with code 0 (all pass)
or 1 (failures present). No database connection is required.

## What to check

Work through the following sections in order. Read each file directly — no database
connection is needed for any of these checks.

---

### 1. study_params.yaml

Read `study_params.yaml`. For each field below, report [OK], [WARN], or [FAIL]:

| Field | FAIL condition | WARN condition |
|-------|---------------|----------------|
| `study_name` | equals `"my_study"` or missing | — |
| `cdm_schema` | equals `"cdm_my_study"` or missing | — |
| `results_schema` | — | (optional; defaults to `<study_name>_results`) |
| `output_folder` | — | (optional; defaults to `output/<study_name>`) |
| `cdm_database_id` | — | equals `"my_cdm_v5.4"` |
| `cdm_database_name` | — | equals `"My Study Database"` |

---

### 2. consumers.yaml

Read `consumers.yaml`.

- [FAIL] if the file is missing, or if `consumers:` is empty (nothing defines what the
  dataset must contain).
- [WARN] if `dataset_id` is still `"my_study_synth_dataset"`.
- For each consumer, resolve its repo (`repo_dir`, or `../<study>`). [FAIL] if the repo is
  not found, its `inst/Cohorts.csv` is missing, a cohort in it has no `inst/cohorts/<id>.json`,
  or the target and outcome ids cannot be determined (from `targetId` / `outcomeIds` in
  `CreateStrategusAnalysisSpecification.R`, or `target_id` / `outcome_ids` in `consumers.yaml`).
- [OK] otherwise — report how many target, outcome and covariate cohorts were found.

---

### 3. Synthea module

List `synthea/modules/*.json` other than `study_template.json`.

- [WARN] if there is no custom module yet.
- [WARN] for each module that still contains `REPLACE_ME`.
- [OK] otherwise.

---

## Output format

Print a sectioned checklist report exactly like this structure:

```
=== Check Setup Report ===

--- 1. study_params.yaml ---
  [OK]   study_name = 'hip_fracture_study'
  [FAIL] cdm_schema is still the default 'cdm_my_study'
  ...

--- 2. consumers.yaml (studies this dataset must support) ---
  [OK]   dataset_id = 'hip_fracture_dataset'
  [OK]   my-study: 1 target, 3 outcome, 8 covariate cohort(s) found

--- 3. Synthea module (synthea/modules/) ---
  [WARN] hip_module.json still has 4 REPLACE_ME placeholder line(s)

--- Summary ---
  FAIL:    1 item(s) must be resolved before generating synthetic data.
  WARNING: 1 item(s) to review (non-blocking).
```
