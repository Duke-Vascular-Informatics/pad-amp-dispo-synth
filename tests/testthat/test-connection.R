source(file.path(.PROJ_ROOT, "R/connection.R"))

# ---------------------------------------------------------------------------
# is_transient_db_error()
# ---------------------------------------------------------------------------

test_that("is_transient_db_error returns FALSE for NULL and empty input", {
  expect_false(is_transient_db_error(NULL))
  expect_false(is_transient_db_error(""))
})

test_that("is_transient_db_error returns FALSE for non-transient errors", {
  expect_false(is_transient_db_error("syntax error near SELECT"))
  expect_false(is_transient_db_error("object not found"))
  expect_false(is_transient_db_error("permission denied"))
})

test_that("is_transient_db_error returns TRUE for each transient pattern", {
  transient_messages <- c(
    "Error: connection reset by peer",
    "Error reading prelogin response from server",
    "Prelogin error occurred",
    "Query timed out after 30s",
    "Connection timeout exceeded",
    "Connection refused on port 1433",
    "Transport-level error when receiving results",
    "Communications link failure",
    "Broken pipe",
    "Connection closed unexpectedly",
    "Socket exception thrown",
    "IO exception during read",
    "Cannot open database 'omop_synth'",
    "Login failed, requested by the login"
  )
  for (msg in transient_messages) {
    expect_true(is_transient_db_error(msg), info = paste("Expected TRUE for:", msg))
  }
})

test_that("is_transient_db_error is case-insensitive", {
  expect_true(is_transient_db_error("CONNECTION RESET"))
  expect_true(is_transient_db_error("Timed Out"))
  expect_true(is_transient_db_error("BROKEN PIPE"))
})

# ---------------------------------------------------------------------------
# with_db_retry()
# ---------------------------------------------------------------------------

test_that("with_db_retry returns result on first success", {
  result <- with_db_retry(1 + 1, max_attempts = 3L)
  expect_equal(result, 2)
})

test_that("with_db_retry returns a value from an expression", {
  result <- with_db_retry({
    x <- 10
    x * 2
  }, max_attempts = 2L)
  expect_equal(result, 20)
})

test_that("with_db_retry stops immediately on non-transient error", {
  expect_error(
    with_db_retry(stop("syntax error near SELECT"), max_attempts = 3L),
    "syntax error near SELECT"
  )
})

test_that("with_db_retry stops after max_attempts on transient error", {
  # max_attempts = 1 avoids Sys.sleep; first failure exhausts attempts immediately
  expect_error(
    with_db_retry(
      stop("connection reset"),
      operation_name = "test op",
      max_attempts = 1L,
      initial_delay_seconds = 0
    ),
    "test op failed after 1 attempt"
  )
})

test_that("with_db_retry rejects max_attempts < 1", {
  expect_error(
    with_db_retry(1 + 1, max_attempts = 0L),
    "max_attempts must be >= 1"
  )
})
