# workflow/ — Numbered Study Steps (01–09)

Each script is a self-contained step in the study lifecycle. Scripts auto-resolve
the project root from their own file path, so they can be run from any shell
working directory.

Use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) for the canonical run order.
This file is a step-level reference for what each workflow script does.

---

## Steps at a glance

| Step | Script | Customize? | Purpose |
|------|--------|:----------:|---------|
| 1 | `01_setup_synthea_etl_qc_env.R` | — | Install packages, verify DB connectivity, provision JDBC driver |
| **2** | **`02_define_omop_cohort_outcome_covariates.R`** | **Yes** | Declare study design, validate cohort SQL and covariate files |
| 3 | `03_generate_synthea_module_artifacts.R` | — | Validate Synthea disease module JSON and regenerate HTML diagram |
| 4 | `04_generate_synthea_csv.ps1` / `.sh` | — | Generate synthetic patients (skip if using real CDM data) |
| 5 | `05_etl_csv_to_omop.R` | — | ETL Synthea CSV → OMOP CDM tables (skip if using real CDM data) |
| 6 | `06_quality_check_defined_phenotypes.R` | — | Post-ETL data quality and phenotype validation checks |
| **7** | **`07_setup_analysis_env.R`** | **Optional** | Extend package checks only if your analysis needs additional packages |
| **8** | **`08_run_analysis_and_manuscript_report.R`** | **Optional** | Add custom analysis logic in Sections 7–9 when needed |
| 9 | `09_build_portable_analysis_bundle.ps1` / `.sh` | — | Package a self-contained bundle for deployment to external sites |

Step 2 is the primary required study customization.
Steps 7 and 8 are optional customization points when study-specific analysis code is needed.
Steps 1, 3–6, and 9 are infrastructure and do not normally need changes.

---

## Execution

Use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) for complete execution commands,
skip logic, and platform-specific instructions.

Run `workflow/01_setup_synthea_etl_qc_env.R` first after opening this study repo in the
dev container. Treat Step 1 as per-repo bootstrap (packages + DB preflight), not as shared
workspace infrastructure setup.

Minimal direct invocation example:

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

> **Step 8 must be run in a fresh R session.** The Java/JDBC session guard at the
> top of the script will stop execution if any Java-related namespace is already
> loaded. Open a new R session or run via `Rscript` from the terminal.

---

## Step 2 — Study definition (`02_define_omop_cohort_outcome_covariates.R`)

The primary customization checkpoint before running any analysis. Contains three
user-facing sections at the top of the file:

**Section A — Study design**
Set `study_design` to one of:
- `"cohort_characterization"` — single cohort, no outcome required
- `"prognostic_model"` — target cohort + outcome + covariates
- `"causal_inference"` — target + comparator + outcome + covariates
- `"descriptive"` — target + comparator, no formal outcome
- `"custom"` — any other design; minimal validation

**Section B — Phenotype artifact paths**
Set file paths to your cohort SQL files and covariate CSVs. Paths are relative to
the project root. Set any path to `NULL` to mark it as not applicable for your design.

**Section C — Study parameters**
Set `prediction_window_days`, `min_prior_observation_days`, `covariate_lookback_days`,
and any other study-specific numeric parameters.

The validation logic (Chunks 3–5) adapts to your study design: a
`cohort_characterization` run will not warn about a missing outcome cohort, a
`causal_inference` run will warn if the comparator path is NULL, etc.

Run Step 2 early and often as you fill in your phenotype files — it catches
placeholder `concept_id = 0` values and structural issues before Step 8.

---

## Step 7 — Analysis environment (`07_setup_analysis_env.R`)

Add your analysis packages to the `required` vector. `DatabaseConnector` and
`SqlRender` are included by default. Reference lists for common designs:

```r
# Cohort characterization
"FeatureExtraction", "CohortDiagnostics"

# Prognostic modelling
"PatientLevelPrediction", "FeatureExtraction", "pROC", "PRROC", "ggplot2",
"officer", "flextable"

# Causal inference
"CohortMethod", "FeatureExtraction", "EvidenceSynthesis"
```

---

## Step 8 — Analysis (`08_run_analysis_and_manuscript_report.R`)

Sections 1–6 are pre-wired infrastructure (bootstrap, Java guard, renv, config,
connection, cohort instantiation). **Do not modify these.**

Sections 7–9 are the analysis sections. For most studies, enabling the right flags in
`study_params.yaml` is all that is needed — no code changes are required in this file.

| Section | What goes here |
|---------|----------------|
| **7 — YOUR ANALYSIS** | Driven by `analyses:` flags in `study_params.yaml`. Pre-wired blocks for `cohort_characterization`, `prognostic_model`, `causal_inference`, `integer_risk_score`. Add custom code below the flag-driven blocks only if needed. |
| **8 — YOUR OUTPUT** | Calls `generate_manuscript_report()` (via `R/report_extended.R`) when `word_report: true`. Report template is selected automatically from `config$study_design` and `config$score_type`. |
| **9 — DONE** | Completion message — update to reflect study-specific outputs if customized. |

The report dispatcher (`R/report_extended.R`) routes to the correct template based on
`config$study_design`. For `"prognostic_model"` the template is fully implemented and
branches on `config$score_type` (`"integer"` or `"lasso"`). Stubs for
`"descriptive"` / `"cohort_characterization"` and `"causal_inference"` are in
`R/report_descriptive.R` and `R/report_causal.R` — uncomment their `source()` lines in
`R/report_extended.R` once implemented.

### Available objects at the start of Section 7

| Object | Type | Description |
|--------|------|-------------|
| `config` | named list | All study settings from `config.R` |
| `connection_details` | ConnectionDetails | DatabaseConnector credentials object |
| `config$cdm_schema` | character | CDM schema name |
| `config$results_schema` | character | Results schema name |
| `config$cohort_table` | character | Cohort table name |
| `config$target_cohort_id` | integer | Cohort definition ID for target population |
| `config$comparator_cohort_id` | integer or NA | Cohort definition ID for comparator (NA if not defined) |
| `config$outcome_cohort_id` | integer | Cohort definition ID for outcome |
| `config$prediction_window_days` | integer | Follow-up window in days |
| `config$output_folder` | character | Output directory path |

---

## Step parameters

**Step 5** (`05_etl_csv_to_omop.R`):
```bash
Rscript workflow/05_etl_csv_to_omop.R \
  --csv_input_dir=/path/to/synthea/output/csv \
  --run_name=my_study_run_001 \
  --reset_before_etl=true
```

**Step 6** (`06_quality_check_defined_phenotypes.R`):
```bash
Rscript workflow/06_quality_check_defined_phenotypes.R \
  --run_name=my_study_run_001 \
  --enforce_thresholds=true \
  --min_person_rows=100
```
