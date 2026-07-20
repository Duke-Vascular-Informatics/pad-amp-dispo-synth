# cohorts/

OMOP cohort SQL definitions for the current study.
Each file is rendered by SqlRender and executed against the SQL Server CDM to populate the results cohort table.

For complete setup and execution flow, use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).

## Files

| File | Cohort | Description |
|------|--------|-------------|
| `target_surgery.sql` | Target cohort | Target/index event cohort SQL template for exposure or index procedure definition. |
| `outcome_ssi.sql` | Outcome cohort | Outcome cohort SQL template for events observed during follow-up. |
| `comparator_cohort.sql` | Comparator cohort | Optional comparator cohort SQL template used for causal inference studies. |

## Usage

Cohort SQL files are not run directly.

- Step 02 validates the files and checks for placeholders.
- Step 08 loads and executes the cohort SQL via `R/cohorts.R`.

SqlRender template parameters used in both files:

| Parameter | Source |
|-----------|--------|
| `@results_schema` | `config$results_schema` |
| `@cohort_table` | `config$cohort_table` |
| `@cdm_schema` | `config$cdm_schema` |
| `@target_cohort_id` / `@outcome_cohort_id` | `config$target_cohort_id` / `config$outcome_cohort_id` |
