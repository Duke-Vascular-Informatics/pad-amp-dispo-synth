source(file.path(.PROJ_ROOT, "R/risk_score_pipeline.R"))

# Helpers to write minimal valid CSV files into a temp directory.
make_valid_covariates_csv <- function(path) {
  # points column is optional — omit here to test the default-to-1 path
  writeLines(c(
    "covariate_id,covariate_name,domain,lookback_start_day,lookback_end_day,min_count",
    "female,Female sex,condition,-365,0,1",
    "obese,Obesity,condition,-365,0,1"
  ), path)
}

make_valid_concepts_csv <- function(path) {
  writeLines(c(
    "covariate_id,concept_id,include_descendants",
    "female,8532,false",
    "obese,433736,true"
  ), path)
}

make_config <- function(comp_path, conc_path) {
  # Uses the same key names as config.R so read_score_specs() works with the
  # standard template config without requiring pipeline-specific keys.
  list(
    covariate_definitions_file = comp_path,
    covariate_concepts_file    = conc_path
  )
}

# ---------------------------------------------------------------------------
# read_score_specs() — happy path
# ---------------------------------------------------------------------------

test_that("read_score_specs returns a list with covariates, concepts, and lookup", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  make_valid_covariates_csv(comp)
  make_valid_concepts_csv(conc)

  result <- read_score_specs(make_config(comp, conc))

  expect_type(result, "list")
  expect_named(result, c("covariates", "concepts", "lookup"))
})

test_that("read_score_specs returns NULL lookup when file does not exist", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  make_valid_covariates_csv(comp)
  make_valid_concepts_csv(conc)

  result <- read_score_specs(make_config(comp, conc))
  expect_null(result$lookup)
})

test_that("read_score_specs normalizes domain to lowercase", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  writeLines(c(
    "covariate_id,covariate_name,domain,lookback_start_day,lookback_end_day,min_count",
    "female,Female sex,CONDITION,-365,0,1"
  ), comp)
  writeLines(c(
    "covariate_id,concept_id,include_descendants",
    "female,8532,false"
  ), conc)

  result <- read_score_specs(make_config(comp, conc))
  expect_equal(result$covariates$domain, "condition")
})

test_that("read_score_specs coerces include_descendants to logical", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  make_valid_covariates_csv(comp)
  writeLines(c(
    "covariate_id,concept_id,include_descendants",
    "female,8532,true",
    "obese,433736,false"
  ), conc)

  result <- read_score_specs(make_config(comp, conc))
  expect_type(result$concepts$include_descendants, "logical")
  expect_equal(result$concepts$include_descendants, c(TRUE, FALSE))
})

test_that("read_score_specs loads an optional lookup table when present", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  lkup <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc); unlink(lkup) })
  make_valid_covariates_csv(comp)
  make_valid_concepts_csv(conc)
  writeLines(c("score,risk", "0,0.05", "1,0.10", "2,0.20"), lkup)

  # lookup_file is a separate argument, not a config key
  result <- read_score_specs(make_config(comp, conc), lookup_file = lkup)
  expect_false(is.null(result$lookup))
  expect_equal(nrow(result$lookup), 3)
})

# ---------------------------------------------------------------------------
# read_score_specs() — validation errors
# ---------------------------------------------------------------------------

test_that("read_score_specs stops when covariates.csv is missing required columns", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  writeLines(c(
    "covariate_id,covariate_name",
    "female,Female sex"
  ), comp)
  make_valid_concepts_csv(conc)

  expect_error(read_score_specs(make_config(comp, conc)), "Missing required columns in covariates.csv")
})

test_that("read_score_specs stops when covariate_concepts.csv is missing required columns", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  make_valid_covariates_csv(comp)
  writeLines(c(
    "covariate_id,concept_id",
    "female,8532"
  ), conc)

  expect_error(read_score_specs(make_config(comp, conc)), "Missing required columns in covariate_concepts.csv")
})

test_that("read_score_specs stops on unsupported domain", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  writeLines(c(
    "covariate_id,covariate_name,domain,lookback_start_day,lookback_end_day,min_count",
    "female,Female sex,device,-365,0,1"
  ), comp)
  make_valid_concepts_csv(conc)

  expect_error(read_score_specs(make_config(comp, conc)), "Unsupported domains")
})

test_that("read_score_specs stops when a covariate has no concept mappings", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  make_valid_covariates_csv(comp)
  # Only map female, leave obese unmapped
  writeLines(c(
    "covariate_id,concept_id,include_descendants",
    "female,8532,false"
  ), conc)

  expect_error(read_score_specs(make_config(comp, conc)), "No concept mappings found for covariate_id")
})

test_that("read_score_specs stops on non-integer concept_id", {
  comp <- tempfile(fileext = ".csv")
  conc <- tempfile(fileext = ".csv")
  on.exit({ unlink(comp); unlink(conc) })
  make_valid_covariates_csv(comp)
  writeLines(c(
    "covariate_id,concept_id,include_descendants",
    "female,not_a_number,false",
    "obese,433736,true"
  ), conc)

  expect_error(read_score_specs(make_config(comp, conc)), "non-integer concept_id")
})
