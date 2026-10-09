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
| **2** | **`02_define_omop_cohort_outcome_covariates.R`** | **Edit `consumers.yaml`** | List the cohorts of every consuming study that the module and the data must support |
| 3 | `03_generate_synthea_module_artifacts.R` | — | Validate Synthea disease module JSON, regenerate HTML diagram, and check the module can produce the cohorts of every study in `consumers.yaml` (`scripts/module_coverage_check.R`) |
| 4 | `04_generate_synthea_csv.ps1` / `.sh` | — | Generate synthetic patients |
| 5 | `05_etl_csv_to_omop.R` | — | ETL Synthea CSV → OMOP CDM (`omop_synth_pad_amp_dispo`) |
| 6 | `06_quality_check_defined_phenotypes.R` | — | Post-ETL data quality checks, then consumer-study QC of every study in `consumers.yaml` (`scripts/consumer_cohort_qc.R`) — the last step this repo documents |

Step 2 is the primary required customization. Steps 1, 3–6 are infrastructure and do
not normally need changes. After Step 6, register the dataset in
`synthetic_data/registry.yaml` at the workspace root.

---

## Execution

Run `workflow/01_setup_synthea_etl_qc_env.R` first after opening this repo in the dev container
(per-repo bootstrap: packages + DB preflight). Before Step 4, fetch the Synthea engine submodule:
`git submodule update --init external/synthea`.

After a successful Step 5/6 run, update this dataset's entry (`id: pad_amp_dispo`) in
the workspace's `synthetic_data/registry.yaml` (format: [charon's synthetic_data README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)) — fill in `generation_params` and `last_generated.qc_summary`.

---

## Step 2 — What the dataset must support (`02_define_omop_cohort_outcome_covariates.R`)

A `-synth` repo defines no cohorts, outcomes or covariates of its own. What the dataset must
contain is defined by the studies that will use it, listed in `consumers.yaml`; their cohort
definitions (`inst/Cohorts.csv` and `inst/cohorts/*.json` in each Strategus repo) are read
directly, so nothing is copied here and nothing can drift.

Step 2 does not connect to a database. It prints, for every consuming study, the cohorts the
Synthea module must be able to produce and the final data must contain, by role (target, outcome,
covariate), and reports anything that would stop the later checks from running (a study repo not
cloned, a missing manifest or cohort JSON, an unresolvable target or outcome id). It also registers
this repo in the workspace `studies.yaml` on first run. The same list drives Step 3 (does the module
cover these cohorts?) and Step 6 (does the final data contain them?).

Edit `consumers.yaml`, then run Step 2 early and often.

## The Synthea module

The single authored module is `synthea/modules/pad_amp_dispo.json` (PAD → major amputation →
90-day post-discharge ED-visit pathway, ~30 VA-FI comorbidity states, and a fixed ED-visit
probability gate). Steps 3/4 auto-detect it (any `.json` under `synthea/modules/` other than
`study_template.json`). The authoritative cohort / outcome / covariate **definitions** live in the
consuming study repos listed in `consumers.yaml`; this repo holds none of its own.

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

**Consumer-study QC** (part of Step 6; flags are forwarded to `scripts/consumer_cohort_qc.R`):
```bash
Rscript workflow/06_quality_check_defined_phenotypes.R --enforce_thresholds=true
Rscript workflow/06_quality_check_defined_phenotypes.R --skip_consumer_qc=true   # generic QC only
Rscript scripts/consumer_cohort_qc.R --enforce_thresholds=true                   # consumer check only
```
For a consumer with `discharge_disposition_check: true` (analyses that depend on discharge
disposition) it also verifies the dataset has discharge dispositions loaded, mapped, and both home
and non-home (`output/qc/discharge_disposition_qc.csv`). It reads `consumers.yaml`, renders each consuming Strategus study's cohorts from their
circe JSON, instantiates them against the active CDM schema, and fails any cohort below its
per-role minimum (target, outcome-in-target, covariate). With no consumers listed it only warns.

**Module coverage check** (part of Step 3; flags are forwarded to `scripts/module_coverage_check.R`):
```bash
Rscript workflow/03_generate_synthea_module_artifacts.R --enforce_coverage=true
Rscript workflow/03_generate_synthea_module_artifacts.R --skip_coverage_check=true
Rscript scripts/module_coverage_check.R --enforce_coverage=true     # coverage check only
```
Before data generation it checks that the custom module **and** Synthea's built-in modules (all of
which workflow 04 runs) can emit the concepts in each consuming study's cohorts. Step 2 prints
the requirements (`consumers.yaml`), Step 3 checks the module, Step 6 checks the final data.
