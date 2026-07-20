# R/

Core R helper functions for the OMOP study template. These files are sourced
by the numbered workflow steps — they are not a package and should not be run directly.

## Files

| File | Purpose | Sourced by |
|------|---------|------------|
| `connection.R` | Builds DatabaseConnector connection details for SQL Server with JDBC/Windows auth; retry helpers for transient DB errors | Steps 01, 05, 06, 07, 08 |
| `drivers.R` | Downloads and stages the Microsoft JDBC 13.2.1 driver bundle into `drivers/` on first run | Step 01 via `connection.R` |
| `db_maintenance.R` | SQL Server maintenance utilities: pre-grows transaction log and tempdb before bulk ETL to prevent auto-growth stalls | Step 05 |
| `cohorts.R` | Creates OMOP results schema and cohort table; instantiates target and outcome cohorts from SQL files | Step 08 |
| `cohort_demographics.R` | Queries OMOP CDM for cohort summary statistics and demographic/procedural characteristics for Table 1 | Step 08 via `report_helpers.R` |
| `risk_score_pipeline.R` | Integer risk score pipeline: reads covariate specs, queries OMOP for each covariate, computes person-level scores, AUROC/AUPRC, and calibration metrics | Step 08 |
| `report_extended.R` | Dispatcher: routes `generate_manuscript_report()` to the correct template based on `config$study_design`; sources `report_helpers.R` and active templates | Step 08 |
| `report_helpers.R` | Shared helper functions for all report templates: calibration, ROC plot, Table 1 builder, cohort summary, Vancouver reference formatter | Sourced by `report_extended.R` |
| `report_prognostic.R` | Word report template for prognostic model studies; parameterized on `config$score_type` (`"integer"` or `"lasso"`) | Sourced by `report_extended.R` |
| `report_descriptive.R` | Stub for descriptive / cohort characterization report template (`study_design = "descriptive"` or `"cohort_characterization"`) | Not yet active — uncomment in `report_extended.R` when implemented |
| `report_causal.R` | Stub for causal inference (CohortMethod) report template (`study_design = "causal_inference"`) | Not yet active — uncomment in `report_extended.R` when implemented |

## Key functions available for testing

Pure functions (no database required) are covered by unit tests in `tests/testthat/`:

- `is_transient_db_error()`, `with_db_retry()` — connection retry logic
- `clamp_probability()`, `compute_ece()`, `compute_binary_metrics()` — statistical helpers (in `report_helpers.R`)
- `get_domain_mapping()`, `build_calibration_table()` — pipeline utilities
- `build_combined_feature_table()` — cohort demographics
- `read_score_specs()` — spec file validation

## Report architecture

`report_extended.R` is a thin dispatcher. It sources `report_helpers.R` (shared utilities)
and whichever template files are active, then routes `generate_manuscript_report()` to the
correct template based on `config$study_design`:

- `"prognostic_model"` → `report_prognostic.R` (implemented; routes further on `config$score_type`)
- `"descriptive"` / `"cohort_characterization"` → `report_descriptive.R` (stub; uncomment to activate)
- `"causal_inference"` → `report_causal.R` (stub; uncomment to activate)

To add a new template: create `R/report_<design>.R`, uncomment its `source()` line in
`report_extended.R`, and add the routing branch in `generate_manuscript_report()`.
