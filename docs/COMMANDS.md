# Commands Index (Canonical)

Use this file as the single source of truth for executable commands used across setup,
validation, analysis, and packaging.

When a command changes:
1. Update this file first.
2. Update `docs/GETTING_STARTED.md` step text if needed.
3. Keep other docs linked here instead of duplicating command blocks.

---

## Core Commands

| Task | Command | Canonical Step |
|------|---------|----------------|
| Verify VS Code install | `code --version` | [Step 1](GETTING_STARTED.md#step-1-install-vs-code-5-minutes) |
| Verify Git setup | `git --version` | [Step 2](GETTING_STARTED.md#step-2-set-up-git-and-version-control-10-minutes) |
| Clone study repo (HTTPS) | `git clone https://github.com/<your-org>/<your-study>.git` | [Step 5](GETTING_STARTED.md#step-5-create-your-study-repository-from-template-5-minutes) |
| Clone study repo (SSH) | `git clone git@github.com:<your-org>/<your-study>.git` | [Step 5](GETTING_STARTED.md#step-5-create-your-study-repository-from-template-5-minutes) |
| Check shared setup artifacts | `ls -la .env docker-compose.yml omop_vocab` | [Step 6](GETTING_STARTED.md#step-6-check-whether-shared-local-setup-already-exists-2-minutes) |
| Run Docker + vocab setup (macOS/Linux) | `bash ../infrastructure/setup/setup_docker_and_vocab.sh` | [Step 7](GETTING_STARTED.md#step-7-complete-machine-setup-if-needed-20-60-minutes) |
| Run Docker + vocab setup (PowerShell) | `powershell -ExecutionPolicy Bypass -File ..\infrastructure\setup\setup_docker_and_vocab.ps1` | [Step 7](GETTING_STARTED.md#step-7-complete-machine-setup-if-needed-20-60-minutes) |
| Check vocabulary table presence | `Rscript -e "...SELECT COUNT(*) AS n FROM omop_vocab.concept..."` | [Step 9](GETTING_STARTED.md#step-9-check-whether-omop-vocabulary-is-already-loaded-2-minutes) |
| Load OMOP vocabulary schema | `Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template` | [Step 10](GETTING_STARTED.md#step-10-load-omop-vocabulary-into-sql-server-3060-minutes) |
| Validate customization status | `Rscript scripts/check_setup.R` | [Step 11](GETTING_STARTED.md#step-11-define-your-cohort-outcome-and-covariates-3060-minutes) |
| Look up OMOP concepts | `Rscript scripts/concept_lookup.R "<clinical term>" <Domain>` | [Step 11](GETTING_STARTED.md#step-11-define-your-cohort-outcome-and-covariates-3060-minutes) |
| Generate Synthea CSV (bash) | `bash workflow/04_generate_synthea_csv.sh` | [Step 13](GETTING_STARTED.md#step-13-generate-synthetic-data-and-run-etl-60-minutes) |
| Generate Synthea CSV (PowerShell) | `powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1` | [Step 13](GETTING_STARTED.md#step-13-generate-synthetic-data-and-run-etl-60-minutes) |
| Run ETL | `Rscript workflow/05_etl_csv_to_omop.R` | [Step 13](GETTING_STARTED.md#step-13-generate-synthetic-data-and-run-etl-60-minutes) |
| Run QC checks | `Rscript workflow/06_quality_check_defined_phenotypes.R` | [Step 13](GETTING_STARTED.md#step-13-generate-synthetic-data-and-run-etl-60-minutes) |
| Build cohorts | `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` | [Step 14](GETTING_STARTED.md#step-14-create-and-test-analysis-code-3060-minutes) |
| Setup analysis environment | `Rscript workflow/07_setup_analysis_env.R` | [Step 14](GETTING_STARTED.md#step-14-create-and-test-analysis-code-3060-minutes) |
| Run analyses | `Rscript workflow/08_run_analysis_and_manuscript_report.R` | [Step 14](GETTING_STARTED.md#step-14-create-and-test-analysis-code-3060-minutes) |
| Build portable bundle (bash) | `bash workflow/09_build_portable_analysis_bundle.sh` | [Step 15](GETTING_STARTED.md#step-15-create-transportable-code-packet-5-minutes) |
| Build portable bundle (PowerShell) | `powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1` | [Step 15](GETTING_STARTED.md#step-15-create-transportable-code-packet-5-minutes) |
| Create support bundle | `Rscript scripts/create_support_bundle.R` | [Playbooks](PLAYBOOKS.md) |

---

## Guardrails

- Do not use `Rscript` to run `.sh` or `.ps1` files.
- Keep command examples consistent with this file and `docs/GETTING_STARTED.md`.
- If a command appears in more than one doc, link here instead of duplicating the snippet.
