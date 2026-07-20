# R/

Core R helper functions for this data-generation repo. These files are sourced by the numbered
workflow steps (01–06) — they are not a package and should not be run directly.

This repo is **data-generation-only**: the analysis, report-template, and risk-score R code that
a full study repo carries has been removed (it lives in the analysis repo `pad-amp-ed-desc`). Only
the infrastructure helpers used by Steps 1-6 remain.

## Files

| File | Purpose | Sourced by |
|------|---------|------------|
| `connection.R` | Builds DatabaseConnector connection details for SQL Server with JDBC/Windows auth; retry helpers for transient DB errors | Steps 01, 05, 06 |
| `drivers.R` | Downloads and stages the Microsoft JDBC 13.2.1 driver bundle into `drivers/` on first run | Step 01 via `connection.R` |
| `db_maintenance.R` | SQL Server maintenance utilities: pre-grows transaction log and tempdb before bulk ETL to prevent auto-growth stalls | Step 05 |
| `cohorts.R` | Creates OMOP results schema and cohort table; instantiates cohorts from SQL files (used for Step 6 QC phenotype checks) | Step 06 |

## Key functions available for testing

Pure functions (no database required) are covered by unit tests in `tests/testthat/`:

- `is_transient_db_error()`, `with_db_retry()` — connection retry logic
