# workflow/ — Numbered Data-Generation Steps (01–06)

**Data-generation-only repo.** This repo runs the Synthea → ETL → QC half of the pipeline to
produce a synthetic OMOP CDM. There are **no analysis / report / bundle steps (07–09)** — those
live in the analysis repo `pad-amp-ed-desc`.

Each script is self-contained and auto-resolves the project root from its own file path, so it
can be run from any shell working directory.

---

## Steps at a glance

| Step | Script | Customize? | Purpose |
|------|--------|:----------:|---------|
| 1 | `01_setup_synthea_etl_qc_env.R` | — | Install packages, verify DB connectivity, provision JDBC driver |
| 2 | `02_define_omop_cohort_outcome_covariates.R` | — | Validate the cohort SQL / concept IDs used only for Step 6 QC checks |
| 3 | `03_generate_synthea_module_artifacts.R` | — | Validate the Synthea disease module JSON and regenerate its HTML diagram |
| 4 | `04_generate_synthea_csv.ps1` / `.sh` | — | Generate synthetic patients with Synthea |
| 5 | `05_etl_csv_to_omop.R` | — | ETL Synthea CSV → OMOP CDM (`omop_synth_pad_amp_dispo`) |
| 6 | `06_quality_check_defined_phenotypes.R` | — | Post-ETL data quality and phenotype sanity checks |

Run `workflow/01_setup_synthea_etl_qc_env.R` first after opening this repo in the dev container
(per-repo bootstrap: packages + DB preflight). Before Step 4, fetch the Synthea engine submodule:
`git submodule update --init external/synthea`.

After a successful Step 5/6 run, update this dataset's entry (`id: pad_amp_dispo`) in
`../synthetic_data/registry.yaml` — fill in `generation_params` and `last_generated.qc_summary`.

---

## The Synthea module

The single authored module is `synthea/modules/pad_amp_dispo.json` (PAD → major amputation →
90-day post-discharge ED-visit pathway, ~30 VA-FI comorbidity states, and a fixed ED-visit
probability gate). Steps 3/4 auto-detect it (any `.json` under `synthea/modules/` other than
`study_template.json`). The authoritative cohort / outcome / covariate **definitions** live in
the analysis repo `pad-amp-ed-desc`; the `cohorts/*.sql` here are kept only for Step 6 QC.

---

## Step parameters

**Step 5** (`05_etl_csv_to_omop.R`):
```bash
Rscript workflow/05_etl_csv_to_omop.R \
  --csv_input_dir=/path/to/synthea/output/csv \
  --run_name=pad_amp_dispo_run_001 \
  --reset_before_etl=true
```

**Step 6** (`06_quality_check_defined_phenotypes.R`):
```bash
Rscript workflow/06_quality_check_defined_phenotypes.R \
  --run_name=pad_amp_dispo_run_001 \
  --enforce_thresholds=true \
  --min_person_rows=100
```
