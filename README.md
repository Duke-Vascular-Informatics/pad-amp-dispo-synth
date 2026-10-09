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

The resulting CDM schema (`omop_synth_pad_amp_dispo`; v2 in `omop_synth_pad_amp_v2`) is consumed by
the Strategus studies listed in **`consumers.yaml`** (it must agree with `used_by` in the workspace's
`synthetic_data/registry.yaml`): `pad-amp-ed-desc`, `pad-amp-nhd-prog`, `pad-amp-nhd-val` and
`pad-bka-aka-prog` (the registry's `used_by` for dataset `pad_amp`). Consumers reach the data through a
read-only view-overlay.

This repo defines **no cohorts, outcomes or covariates of its own**. Those are defined by the consuming
studies, and their own cohort definitions are read directly: `workflow/02` lists them, `workflow/03`
checks the Synthea module can produce them before any data is generated, and `workflow/06` checks the
final data contains them.

Consumers point their `OMOP_CDM_SCHEMA_OVERRIDE` at a view-overlay built with
`synthetic_data/scripts/generate_overlay_schema.R`. The schema name intentionally keeps the
`_desc` suffix (not `_synth`) so those overlays don't break — see [CLAUDE.md](CLAUDE.md).

The dataset is registered in the workspace's `synthetic_data/registry.yaml` (format: [charon's synthetic_data README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)) as `id: pad_amp_dispo`.

## Scope: Steps 1-6 only

This repo runs the Synthea/ETL/QC half of the pipeline and nothing else. There is **no Step
7-9** (analysis, Word report, or portable bundle) — those live in the consuming analysis repos
(see `consumers.yaml`).

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `workflow/01_setup_synthea_etl_qc_env.R` | Install packages, verify DB connectivity, provision JDBC driver |
| 2 | `workflow/02_define_omop_cohort_outcome_covariates.R` | List the cohorts of every study in `consumers.yaml` that the module and data must support |
| 3 | `workflow/03_generate_synthea_module_artifacts.R` | Validate the Synthea module, regenerate its HTML diagram, and check it can produce the consuming studies' cohorts |
| 4 | `workflow/04_generate_synthea_csv.sh` / `.ps1` | Generate Synthea synthetic patient CSVs |
| 5 | `workflow/05_etl_csv_to_omop.R` | ETL Synthea CSV → OMOP CDM (`omop_synth_pad_amp_dispo`) |
| 6 | `workflow/06_quality_check_defined_phenotypes.R` | Post-ETL data-quality checks, then consumer-study QC of every study in `consumers.yaml` |

After a successful Step 5/6 run, update the dataset's `generation_params` and
`last_generated.qc_summary` in the workspace's `synthetic_data/registry.yaml` (format: [charon's synthetic_data README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)).

## Repository structure

```
pad-amp-dispo-synth/
  consumers.yaml              ← the Strategus studies that use this dataset (defines what it must contain)
  study_params.yaml           ← identity, schemas and database description
  config.R                    ← infrastructure settings (no edits needed)
  workflow/01–06 + bootstrap  ← Synthea generation → ETL → QC
  R/                          ← infra only: connection, drivers, db_maintenance, consumer_qc, module_coverage
  scripts/                    ← ETL, Synthea runner, QC utilities (incl. consumer and module-coverage checks)
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
  root `charon` README and `../docs/`.

## License & Funding

Copyright 2026 Duke University. All Rights Reserved. The software is hereby licensed under the GNU GPL License v2 (see [LICENSE](LICENSE)).

This repo vendors [Synthea](https://github.com/synthetichealth/synthea) (Copyright
2017-2025 The MITRE Corporation) at `external/synthea/`, an independently developed,
open-source synthetic patient generator distributed under its own **Apache License
2.0** — a separate license from this repository's GPL v2, not a GPL dependency.
Synthea's own `LICENSE` and `NOTICE` files are preserved unmodified in
`external/synthea/`; the `NOTICE` file documents Synthea's own third-party content
(RxNorm, LOINC, SNOMED CT terminology, and the SBSCL library). Synthea is not
affiliated with Duke University; see the upstream project for its own terms,
attribution requirements, and citation.

Research reported here was supported by the National Center for Advancing Translational
Sciences of the National Institutes of Health under Award Number K12TR005435. The content is
solely the responsibility of the authors and does not necessarily represent the official views
of the National Institutes of Health.
