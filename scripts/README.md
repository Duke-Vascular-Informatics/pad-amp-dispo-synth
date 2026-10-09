# scripts/

Helper and utility scripts that support the numbered workflow steps.
Scripts here are called by workflow steps or run manually as one-time setup tasks —
they are not workflow entry points themselves.

## Top-level files

| File | Description | Called by |
|------|-------------|-----------|
| `check_setup.R` | Pre-flight setup check. Scans `study_params.yaml`, `consumers.yaml` (consuming studies present and readable) and the Synthea module for incomplete placeholders; prints a `[OK]`/`[WARN]`/`[FAIL]` checklist. No database connection required. Exit code 0 = ready to generate synthetic data. Equivalent to the `/check-setup` Claude skill. | Manual: `Rscript scripts/check_setup.R` |
| `concept_lookup.R` | OMOP vocabulary lookup. Queries `omop_vocab` for standard concept IDs matching a clinical term, with synonym fallback and descendant expansion. Labels results `[vocab query]`. Equivalent to the `/concept-lookup` Claude skill. | Manual: `Rscript scripts/concept_lookup.R "<term>" [domain]` |
| `create_support_bundle.R` | Creates a redacted troubleshooting bundle in `output/support/` including setup report, git diagnostics, and recent logs. | Manual: `Rscript scripts/create_support_bundle.R` |
| `module_coverage_check.R` | Pre-generation coverage check. Confirms the custom Synthea module and Synthea's built-in modules can emit the concepts needed by every cohort of every study in `consumers.yaml`. Writes `output/qc/module_coverage.csv`. See `R/module_coverage.R`. | `workflow/03_generate_synthea_module_artifacts.R`; manual: `Rscript scripts/module_coverage_check.R` |
| `consumer_cohort_qc.R` | Consumer-study QC. For each Strategus study in `consumers.yaml`, instantiates its cohorts (target, outcomes, covariate cohorts) against the synthetic CDM and fails any below its minimum subject count. Writes `output/qc/consumer_cohort_qc.csv`; for consumers with `discharge_disposition_check: true`, also verifies discharge dispositions in `visit_occurrence` and writes `output/qc/discharge_disposition_qc.csv`. See `R/consumer_qc.R`. | `workflow/06_quality_check_defined_phenotypes.R`; manual: `Rscript scripts/consumer_cohort_qc.R` |
| `find_todos.R` | Scans the project for `# TODO` tags and prints a summary of remaining placeholders. | Manual |
| `new_study.R` | Scaffolds a new `study_params.yaml` from the example template. | Manual: `Rscript scripts/new_study.R <study_name>` |
| `quality_check_etl.R` | Post-ETL quality check implementation: validates cohort row counts, concept mapping rates, and optionally runs ACHILLES CDM profiling and OHDSI Data Quality Dashboard. Accepts CLI flags for threshold gates. | `workflow/06_quality_check_defined_phenotypes.R` |
| `../infrastructure/scripts/setup_omop_vocab_schema.R` | One-time setup: loads the full OMOP vocabulary from Athena CSVs into the shared `omop_vocab` schema (~30–60 min). Run once per SQL Server instance. See `docs/SETUP.md` for prerequisites. | Manual: `Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template` |
| `validate_docs_commands.R` | Validates command/path references across documentation files and fails on known-bad patterns or missing script paths. | CI + manual: `Rscript scripts/validate_docs_commands.R` |

## Emergency / Repair Tools

| File | Description |
|------|-------------|
| `load_missing_vocab_tables.R` | Recovers from incomplete vocabulary setup: loads any missing tables into `omop_vocab` without re-downloading the full vocabulary. Use only if `infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template` failed partway through. | Manual: `Rscript scripts/load_missing_vocab_tables.R` |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `etl/` | Main Synthea CSV → OMOP ETL engine (`run_synthea_full_csv_builder_etl.R`) |
| `hooks/` | Local git-hook installer and hook documentation for analyst guardrails |
| `synthea/` | Synthea synthetic data generation and module visualization utilities |
| `archive/` | Inactive scripts preserved for reference; not part of the active workflow |

## CLI flags for quality_check_etl.R

Pass these through `workflow/06_quality_check_defined_phenotypes.R`:

| Flag | Default | Description |
|------|---------|-------------|
| `--run_name=<name>` | latest schema | Target CDM schema override |
| `--enforce_thresholds=<true\|false>` | `false` | Fail if row counts fall below minimums |
| `--min_person_rows=<n>` | 1 | Minimum rows in person table |
| `--min_mapped_condition_pct=<pct>` | 0 | Minimum % conditions with standard concept |
| `--run_achilles=<true\|false>` | `true` | Run ACHILLES CDM profiling |
| `--run_dqd=<true\|false>` | `true` | Run OHDSI Data Quality Dashboard |
| `--achilles_threads=<n>` | 1 | Parallel threads for ACHILLES |
