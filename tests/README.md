# tests/

Unit tests for core R functions using the [testthat](https://testthat.r-lib.org) framework (edition 3).

## Running tests

From the project root:

```r
# Run all tests
source("tests/testthat.R")

# Run a single test file
testthat::test_file("tests/testthat/test-connection.R")
```

Tests also run automatically:
- **Step 01** (`workflow/01_setup_synthea_etl_qc_env.R`) — as a preflight check before the DB connection is established
- **CI** (`.github/workflows/ci.yml`) — on every push and pull request to `main`

## Files

| File | Description |
|------|-------------|
| `testthat.R` | Test runner entry point. Sets the working directory to project root and calls `testthat::test_dir()`. |

## testthat/

| Test file | Functions tested |
|-----------|-----------------|
| `test-connection.R` | `is_transient_db_error()` — all transient patterns, case insensitivity, NULL/empty inputs; `with_db_retry()` — success path, non-transient immediate failure, exhausted retries, argument validation |
| `test-risk-score-pipeline.R` | `clamp_probability()`, `get_domain_mapping()`, `compute_ece()`, `build_calibration_table()`, `compute_binary_metrics()`, `score_discrimination_metrics()` |
| `test-cohort-demographics.R` | `build_combined_feature_table()` — NULL handling, column names, lookback format, prevalence string format |
| `test-read-score-specs.R` | `read_score_specs()` — valid CSV loading, domain normalization, type coercion, lookup table, all validation error paths |

## Scope

Tests cover **pure functions only** — those that take inputs and return outputs without
a live database connection. Database-dependent functions (cohort queries, ETL steps,
ACHILLES, DQD) are not unit-tested here; they are validated by Step 06 quality checks
against the actual OMOP CDM.
