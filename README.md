# pad-amp-dispo-synth — Synthetic Data Generation

**Data-generation-only repository.** This is **not** a study. It exists solely to produce a
synthetic OMOP CDM v5.4 dataset and register it for reuse by real study repositories. It has
no IRB scope, no real patient data, no analysis, and no manuscript output.

## What it produces

A synthetic OMOP CDM of patients undergoing **major lower extremity amputation** (BKA / AKA)
for dysvascular, diabetic, or wound indications, carrying:

- a modeled **90-day post-discharge emergency-department (ED) visit** outcome, and
- a **VA Frailty Index** comorbidity burden (~30 deficit states).

The dataset is authored as a single Synthea disease module
(`synthea/modules/pad_amp_dispo.json`) and materialized into SQL Server via ETL.

## Who consumes it

The resulting CDM schema (`omop_synth_pad_amp_dispo`) is consumed by:

- **`pad-amp-ed-desc`** — the Strategus analysis study (the real analysis + Word manuscript).
- **`pad-oler-aki-desc`** — via a read-only view-overlay.

Consumers point their `OMOP_CDM_SCHEMA_OVERRIDE` at a view-overlay built with
`synthetic_data/scripts/generate_overlay_schema.R`. The schema name intentionally keeps the
`_desc` suffix (not `_synth`) so those overlays don't break — see [CLAUDE.md](CLAUDE.md).

The dataset is registered in `../synthetic_data/registry.yaml` as `id: pad_amp_dispo`.

## Scope: Steps 1-6 only

This repo runs the Synthea/ETL/QC half of the pipeline and nothing else. There is **no Step
7-9** (analysis, Word report, or portable bundle) — those live in the analysis repo
`pad-amp-ed-desc`. Every flag under `analyses:` in `study_params.yaml` stays `false`.

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `workflow/01_setup_synthea_etl_qc_env.R` | Install packages, verify DB connectivity, provision JDBC driver |
| 2 | `workflow/02_define_omop_cohort_outcome_covariates.R` | Validate cohort SQL / concept IDs used for QC checks |
| 3 | `workflow/03_generate_synthea_module_artifacts.R` | Validate the Synthea module and regenerate its HTML diagram |
| 4 | `workflow/04_generate_synthea_csv.sh` / `.ps1` | Generate Synthea synthetic patient CSVs |
| 5 | `workflow/05_etl_csv_to_omop.R` | ETL Synthea CSV → OMOP CDM (`omop_synth_pad_amp_dispo`) |
| 6 | `workflow/06_quality_check_defined_phenotypes.R` | Post-ETL data-quality + phenotype sanity checks |

After a successful Step 5/6 run, update the dataset's `generation_params` and
`last_generated.qc_summary` in `../synthetic_data/registry.yaml`.

## Repository structure

```
pad-amp-dispo-synth/
  study_params.yaml           ← generation config (all analyses: false)
  config.R                    ← infrastructure settings (no edits needed)
  workflow/01–06 + bootstrap  ← Synthea generation → ETL → QC
  R/                          ← infra only: connection, drivers, db_maintenance, cohorts
  scripts/                    ← ETL, Synthea runner, QC utilities
  cohorts/                    ← SQL cohort definitions (kept for Step 6 QC checks)
  covariates/                 ← header-only (authoritative defs live in pad-amp-ed-desc)
  synthea/modules/            ← pad_amp_dispo.json disease module + diagram
  external/synthea/           ← vendored Synthea engine (submodule; git submodule update --init)
  drivers/                    ← JDBC driver archive
```

## Notes

- `external/synthea` is a git submodule; run `git submodule update --init external/synthea`
  before generating data (Step 4).
- The analysis code, report templates, and portable-bundle tooling that a normal study repo
  carries have been removed here — this repo only generates data.
- Workspace setup (Docker, SQL Server, OMOP vocabulary, dev container) is documented in the
  root `omop-dev-workspace` README and `../docs/`.

## License & Funding

Licensed under **GNU GPL v3.0** (see [LICENSE](LICENSE)).

This repo vendors [Synthea](https://github.com/synthetichealth/synthea) (Copyright
2017-2025 The MITRE Corporation) at `external/synthea/`, an independently developed,
open-source synthetic patient generator distributed under its own **Apache License
2.0** — a separate license from this repository's GPL v3.0, not a GPL dependency.
Synthea's own `LICENSE` and `NOTICE` files are preserved unmodified in
`external/synthea/`; the `NOTICE` file documents Synthea's own third-party content
(RxNorm, LOINC, SNOMED CT terminology, and the SBSCL library). Synthea is not
affiliated with Duke University; see the upstream project for its own terms,
attribution requirements, and citation.

Research reported here was supported by the National Center for Advancing Translational
Sciences of the National Institutes of Health under Award Number K12TR005435. The content is
solely the responsibility of the authors and does not necessarily represent the official views
of the National Institutes of Health.
