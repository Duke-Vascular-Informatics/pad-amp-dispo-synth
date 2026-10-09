# Commands Index (Canonical)

Use this file as the single source of truth for executable commands in this
synthetic-data-generation repo. Workspace-level commands (Docker, vocabulary
load, git setup) are owned by the charon workspace; see
[charon `docs/COMMANDS.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/COMMANDS.md).

When a command changes:
1. Update this file first.
2. Update `GETTING_STARTED.md` step text if needed.
3. Keep other docs linked here instead of duplicating command blocks.

---

## Core Commands

| Task | Command | Canonical Step |
|------|---------|----------------|
| Check whether a dataset already exists (run from workspace root) | `Rscript synthetic_data/scripts/lookup_dataset.R --disease "<clinical term>"` | [Step 2](GETTING_STARTED.md#step-2-check-whether-a-dataset-already-exists-5-minutes) |
| Clone your synth repo | `git clone https://github.com/<your-org>/<your-study>-synth.git` | [Step 3](GETTING_STARTED.md#step-3-create-your-synth-repository-from-template-5-minutes) |
| Create your working branch | `BRANCH=$(gh api user --jq .login) && git checkout -b "$BRANCH" && git push -u origin "$BRANCH"` | [Step 3](GETTING_STARTED.md#step-3-create-your-synth-repository-from-template-5-minutes) |
| Per-repo bootstrap (packages, JDBC, DB test) | `Rscript workflow/01_setup_synthea_etl_qc_env.R` | [Step 4](GETTING_STARTED.md#step-4-open-in-the-dev-container-and-bootstrap-10-minutes) |
| Validate customization status (study_params, consumers, module) | `Rscript scripts/check_setup.R` | [Step 5](GETTING_STARTED.md#step-5-declare-the-studies-your-data-must-support-15-minutes) |
| Look up OMOP concepts (for the Synthea module's source codes, or a consuming study's cohorts) | `Rscript scripts/concept_lookup.R "<clinical term>" <Domain>` | [Step 5](GETTING_STARTED.md#step-5-declare-the-studies-your-data-must-support-15-minutes) |
| List the cohorts the dataset must support (from consumers.yaml) | `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` | [Step 5](GETTING_STARTED.md#step-5-declare-the-studies-your-data-must-support-15-minutes) |
| Validate Synthea module (+ coverage of consuming studies' cohorts) | `Rscript workflow/03_generate_synthea_module_artifacts.R` | [Step 6](GETTING_STARTED.md#step-6-design-the-analysis-specific-synthea-module-30-minutes) |
| Fail if the module cannot produce a consuming study's cohort | `Rscript workflow/03_generate_synthea_module_artifacts.R --enforce_coverage=true` | [Step 6](GETTING_STARTED.md#step-6-design-the-analysis-specific-synthea-module-30-minutes) |
| Generate Synthea CSV (bash) | `bash workflow/04_generate_synthea_csv.sh` | [Step 7](GETTING_STARTED.md#step-7-generate-synthetic-data-run-etl-and-check-quality-60-minutes) |
| Generate Synthea CSV (PowerShell) | `powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1` | [Step 7](GETTING_STARTED.md#step-7-generate-synthetic-data-run-etl-and-check-quality-60-minutes) |
| Run ETL | `Rscript workflow/05_etl_csv_to_omop.R` | [Step 7](GETTING_STARTED.md#step-7-generate-synthetic-data-run-etl-and-check-quality-60-minutes) |
| Run QC checks (generic + consumer-study QC) | `Rscript workflow/06_quality_check_defined_phenotypes.R` | [Step 7](GETTING_STARTED.md#step-7-generate-synthetic-data-run-etl-and-check-quality-60-minutes) |
| Consumer-study QC only (fail if a using study would break) | `Rscript scripts/consumer_cohort_qc.R --enforce_thresholds=true` | [Step 7](GETTING_STARTED.md#step-7-generate-synthetic-data-run-etl-and-check-quality-60-minutes) |
| Create support bundle | `Rscript scripts/create_support_bundle.R` | [Playbooks](PLAYBOOKS.md) |

Workspace-level commands (not in this repo): load the OMOP vocabulary with
`Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template`
from the workspace root (charon Step 9).

---

## Guardrails

- Do not use `Rscript` to run `.sh` or `.ps1` files.
- Keep command examples consistent with this file and `docs/GETTING_STARTED.md`.
- If a command appears in more than one doc, link here instead of duplicating the snippet.
