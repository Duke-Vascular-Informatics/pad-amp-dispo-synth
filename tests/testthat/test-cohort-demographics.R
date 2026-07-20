source(file.path(.PROJ_ROOT, "R/cohort_demographics.R"))

# ---------------------------------------------------------------------------
# build_combined_feature_table()
# ---------------------------------------------------------------------------

make_covariates <- function() {
  data.frame(
    covariate_name    = c("female", "obese", "abi_35"),
    points            = c(1L, 2L, 3L),
    lookback_start_day = c(-365L, -365L, -90L),
    lookback_end_day  = c(0L, 0L, 0L),
    stringsAsFactors  = FALSE
  )
}

make_summary <- function() {
  data.frame(
    covariate_name = c("female", "obese", "abi_35"),
    n_positive     = c(40L, 20L, 10L),
    n_total        = c(100L, 100L, 100L),
    stringsAsFactors = FALSE
  )
}

test_that("build_combined_feature_table returns NULL when covariate_summary is NULL", {
  result <- build_combined_feature_table(make_covariates(), NULL)
  expect_null(result)
})

test_that("build_combined_feature_table returns a data frame", {
  result <- build_combined_feature_table(make_covariates(), make_summary())
  expect_s3_class(result, "data.frame")
})

test_that("build_combined_feature_table has the expected output column names", {
  result <- build_combined_feature_table(make_covariates(), make_summary())
  expect_equal(names(result), c("Covariate", "Points", "Lookback Window", "Prevalence (n / N, %)"))
})

test_that("build_combined_feature_table has one row per covariate", {
  result <- build_combined_feature_table(make_covariates(), make_summary())
  expect_equal(nrow(result), 3)
})

test_that("build_combined_feature_table formats lookback window correctly", {
  result <- build_combined_feature_table(make_covariates(), make_summary())
  expect_equal(result[result$Covariate == "abi_35", "Lookback Window"], "-90 to 0 days")
})

test_that("build_combined_feature_table formats prevalence string correctly", {
  result <- build_combined_feature_table(make_covariates(), make_summary())
  female_row <- result[result$Covariate == "female", "Prevalence (n / N, %)"]
  expect_match(female_row, "40 / 100 \\(40%\\)")
})

test_that("build_combined_feature_table preserves point values", {
  result <- build_combined_feature_table(make_covariates(), make_summary())
  expect_equal(result[result$Covariate == "obese", "Points"], 2L)
})
