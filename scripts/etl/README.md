# scripts/etl/

ETL pipeline for transforming Synthea CSV exports into the OMOP CDM.

For full run order and prerequisites, use [docs/GETTING_STARTED.md](../../docs/GETTING_STARTED.md).

## Files

| File | Description |
|------|-------------|
| `run_synthea_full_csv_builder_etl.R` | Main ETL engine. Reads Synthea CSV output and loads all OMOP CDM domains (person, visit, condition, drug, procedure, measurement, observation, death, era tables). Uses ETLSyntheaBuilder v2.1.0 pattern with SQL Server-specific patches for `insert_drug_era` and `insert_person`. Supports incremental loads, shared vocabulary schema via SQL Server synonyms, and pre-flight DB maintenance. |

## Usage

Called by `workflow/05_etl_csv_to_omop.R`. Do not run directly.

```r
# workflow/05 sources this and calls run_etl() with a config list:
source("scripts/etl/run_synthea_full_csv_builder_etl.R")
run_etl(config, connection_details, csv_input_dir, run_name)
```

## Prerequisites

- OMOP vocabulary must be loaded into the shared `omop_vocab` schema before running.
  Run `infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template` once per SQL Server instance.
- Transaction log and tempdb should be pre-grown for bulk loads.
  `R/db_maintenance.R` handles this automatically when called by the ETL.
