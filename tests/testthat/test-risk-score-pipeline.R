source(file.path(.PROJ_ROOT, "R/risk_score_pipeline.R"))

# ---------------------------------------------------------------------------
# clamp_probability()
# ---------------------------------------------------------------------------

test_that("clamp_probability leaves in-range values unchanged", {
  p <- c(0.1, 0.5, 0.9)
  expect_equal(clamp_probability(p), p)
})

test_that("clamp_probability clamps 0 and 1 to eps boundaries", {
  eps <- 1e-6
  result <- clamp_probability(c(0, 1), eps = eps)
  expect_equal(result[1], eps)
  expect_equal(result[2], 1 - eps)
})

test_that("clamp_probability clamps values below eps up to eps", {
  expect_equal(clamp_probability(1e-10, eps = 1e-6), 1e-6)
})

test_that("clamp_probability clamps values above 1-eps down to 1-eps", {
  expect_equal(clamp_probability(1 - 1e-10, eps = 1e-6), 1 - 1e-6)
})

test_that("clamp_probability handles vectors with mixed values", {
  eps <- 1e-6
  p <- c(0, 0.3, 0.7, 1)
  result <- clamp_probability(p, eps = eps)
  expect_equal(result, c(eps, 0.3, 0.7, 1 - eps))
})

test_that("clamp_probability coerces character to numeric", {
  result <- clamp_probability(c("0.2", "0.8"))
  expect_equal(result, c(0.2, 0.8))
})

# ---------------------------------------------------------------------------
# get_domain_mapping()
# ---------------------------------------------------------------------------

test_that("get_domain_mapping returns correct mapping for condition", {
  m <- get_domain_mapping("condition")
  expect_equal(m$table, "condition_occurrence")
  expect_equal(m$concept_col, "condition_concept_id")
  expect_equal(m$date_col, "condition_start_date")
})

test_that("get_domain_mapping returns correct mapping for drug", {
  m <- get_domain_mapping("drug")
  expect_equal(m$table, "drug_exposure")
  expect_equal(m$concept_col, "drug_concept_id")
  expect_equal(m$date_col, "drug_exposure_start_date")
})

test_that("get_domain_mapping returns correct mapping for procedure", {
  m <- get_domain_mapping("procedure")
  expect_equal(m$table, "procedure_occurrence")
  expect_equal(m$concept_col, "procedure_concept_id")
  expect_equal(m$date_col, "procedure_date")
})

test_that("get_domain_mapping returns correct mapping for measurement", {
  m <- get_domain_mapping("measurement")
  expect_equal(m$table, "measurement")
  expect_equal(m$concept_col, "measurement_concept_id")
  expect_equal(m$date_col, "measurement_date")
})

test_that("get_domain_mapping returns correct mapping for observation", {
  m <- get_domain_mapping("observation")
  expect_equal(m$table, "observation")
  expect_equal(m$concept_col, "observation_concept_id")
  expect_equal(m$date_col, "observation_date")
})

test_that("get_domain_mapping returns correct mapping for visit", {
  m <- get_domain_mapping("visit")
  expect_equal(m$table, "visit_occurrence")
  expect_equal(m$concept_col, "visit_concept_id")
  expect_equal(m$date_col, "visit_start_date")
})

test_that("get_domain_mapping stops on unsupported domain", {
  expect_error(get_domain_mapping("device"), "Unsupported domain")
  expect_error(get_domain_mapping("note"), "Unsupported domain")
  expect_error(get_domain_mapping(""), "Unsupported domain")
})

# ---------------------------------------------------------------------------
# compute_ece()
# ---------------------------------------------------------------------------

test_that("compute_ece returns a single numeric value", {
  set.seed(1)
  y <- rbinom(100, 1, 0.3)
  p <- runif(100, 0, 1)
  result <- compute_ece(y, p)
  expect_true(is.numeric(result))
  expect_length(result, 1)
})

test_that("compute_ece is near zero for perfectly calibrated predictions", {
  # When predicted probability equals observed rate within each bin, ECE ~ 0
  y <- c(rep(0, 70), rep(1, 30))
  p <- c(rep(0.05, 70), rep(0.95, 30))
  ece <- compute_ece(y, p, n_bins = 2)
  expect_lt(ece, 0.15)
})

test_that("compute_ece is bounded between 0 and 1", {
  set.seed(42)
  y <- rbinom(200, 1, 0.2)
  p <- runif(200)
  ece <- compute_ece(y, p)
  expect_gte(ece, 0)
  expect_lte(ece, 1)
})

test_that("compute_ece handles degenerate case with all same predicted probability", {
  y <- c(0, 1, 0, 1)
  p <- c(0.5, 0.5, 0.5, 0.5)
  result <- compute_ece(y, p, n_bins = 10)
  expect_true(is.numeric(result))
  expect_false(is.na(result))
})

# ---------------------------------------------------------------------------
# build_calibration_table()
# ---------------------------------------------------------------------------

test_that("build_calibration_table returns a data frame with expected columns", {
  set.seed(7)
  y <- rbinom(100, 1, 0.4)
  p <- runif(100)
  result <- build_calibration_table(y, p)
  expect_s3_class(result, "data.frame")
  expect_true("predicted" %in% names(result))
  expect_true("observed" %in% names(result))
})

test_that("build_calibration_table predicted values are in [0, 1]", {
  set.seed(7)
  y <- rbinom(100, 1, 0.4)
  p <- runif(100)
  result <- build_calibration_table(y, p)
  expect_true(all(result$predicted >= 0 & result$predicted <= 1))
})

test_that("build_calibration_table observed values are in [0, 1]", {
  set.seed(7)
  y <- rbinom(100, 1, 0.4)
  p <- runif(100)
  result <- build_calibration_table(y, p)
  expect_true(all(result$observed >= 0 & result$observed <= 1))
})

test_that("build_calibration_table produces at most n_bins rows", {
  y <- rbinom(50, 1, 0.5)
  p <- runif(50)
  result <- build_calibration_table(y, p, n_bins = 5)
  expect_lte(nrow(result), 5)
})

# ---------------------------------------------------------------------------
# compute_binary_metrics()
# ---------------------------------------------------------------------------

test_that("compute_binary_metrics returns NA metrics when only one outcome class", {
  skip_if_not_installed("pROC")
  skip_if_not_installed("PRROC")
  y <- rep(0L, 20)
  score <- runif(20)
  result <- compute_binary_metrics(y, score)
  expect_true(is.na(result$auroc))
  expect_true(is.na(result$auprc))
  expect_false(is.na(result$brier))
})

test_that("compute_binary_metrics AUROC is near 1 for a perfect classifier", {
  skip_if_not_installed("pROC")
  skip_if_not_installed("PRROC")
  y <- c(rep(0L, 50), rep(1L, 50))
  score <- c(rep(0.01, 50), rep(0.99, 50))
  result <- compute_binary_metrics(y, score)
  expect_gt(result$auroc, 0.99)
})

test_that("compute_binary_metrics AUROC is near 0.5 for a random classifier", {
  skip_if_not_installed("pROC")
  skip_if_not_installed("PRROC")
  set.seed(99)
  y <- rbinom(200, 1, 0.5)
  score <- runif(200)
  result <- compute_binary_metrics(y, score)
  expect_gt(result$auroc, 0.3)
  expect_lt(result$auroc, 0.7)
})

test_that("compute_binary_metrics Brier score is 0 for perfect predictions", {
  skip_if_not_installed("pROC")
  skip_if_not_installed("PRROC")
  y <- c(0L, 0L, 1L, 1L)
  score <- c(0, 0, 1, 1)
  result <- compute_binary_metrics(y, score)
  expect_equal(result$brier, 0)
})

# ---------------------------------------------------------------------------
# score_discrimination_metrics()
# ---------------------------------------------------------------------------

test_that("score_discrimination_metrics returns NA for single-class outcome", {
  skip_if_not_installed("pROC")
  skip_if_not_installed("PRROC")
  y <- rep(0L, 10)
  score <- 1:10
  result <- score_discrimination_metrics(y, score)
  expect_s3_class(result, "data.frame")
  expect_true(all(is.na(result$value)))
  expect_equal(nrow(result), 2)
})

test_that("score_discrimination_metrics returns AUROC and AUPRC rows", {
  skip_if_not_installed("pROC")
  skip_if_not_installed("PRROC")
  y <- c(rep(0L, 20), rep(1L, 20))
  score <- c(1:20, 11:30)
  result <- score_discrimination_metrics(y, score)
  expect_setequal(result$metric, c("AUROC", "AUPRC"))
  expect_true(all(!is.na(result$value)))
})
