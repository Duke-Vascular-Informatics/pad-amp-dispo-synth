#!/usr/bin/env Rscript
# Step 1: Install packages and initialize environment for Synthea generation, ETL, and data checks.

# -----------------------------------------------------------------------------
# Chunk 1: Resolve and load shared workflow bootstrap helper.
# Purpose:
# - Ensure this step can be launched from any working directory.
# - Resolve repository root consistently before sourcing project-relative files.
# Outcome:
# - `set_workflow_root()` sets the working directory to repo root.
# -----------------------------------------------------------------------------

bootstrap_path <- local({
  # Prefer `--file=...` when script is executed via Rscript.
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    normalizePath(
      file.path(dirname(sub("^--file=", "", file_arg[1])), "workflow_bootstrap.R"),
      winslash = "/",
      mustWork = FALSE
    )
  } else {
    "workflow/workflow_bootstrap.R"
  }
})
source(bootstrap_path)
set_workflow_root()

# -----------------------------------------------------------------------------
# Chunk 1b: Dev-container guard.
# Purpose:
# - Step 1 installs Java-dependent packages (rJava, DatabaseConnector) and
#   connects to the SQL Server service defined by the workspace root compose files.
#   Both requirements are only satisfied inside the dev container.
# - Running outside the container produces cryptic Java/JDBC errors; this
#   guard surfaces the real problem immediately.
# Outcome:
# - Hard stop with actionable message if IN_DEV_CONTAINER is not "true".
# - No-op (continues) when running inside the container.
# -----------------------------------------------------------------------------
if (!identical(Sys.getenv("IN_DEV_CONTAINER"), "true")) {
  stop(
    "This script must be run inside the dev container.\n",
    "Open this repository in VS Code and select\n",
    "  'Reopen in Container'\n",
    "then re-run: Rscript workflow/01_setup_synthea_etl_qc_env.R"
  )
}

# -----------------------------------------------------------------------------
# Chunk 2: Run environment setup and load runtime helpers.
# Purpose:
# - Initialize renv and install required packages (CRAN-first, GitHub fallback)
#   via the canonical setup scripts.
# - Load config + DB/JDBC helper functions needed for the DB preflight.
# Outcome:
# - Package environment and helper APIs are ready for validation checks below.
# -----------------------------------------------------------------------------

source("setup/setup_renv.R")
source("setup/install_packages.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")

# -----------------------------------------------------------------------------
# Chunk 2a: Ensure the synthea-pad remote branch and submodule registration
# exist before initializing the checkout.
#
# For a brand-new study the remote branch and .gitmodules entry will not yet
# exist. This chunk:
#   1. Reads study_name from study_params.yaml and derives the kebab-case
#      branch name (e.g. pad_oler_nhd_val → pad-oler-nhd-val).
#   2. Creates the remote branch on synthea-pad if it does not exist, forking
#      from synthea-pad/main — the canonical trunk that incorporates validated
#      improvements from all analysis branches.
#   3. Registers external/synthea as a git submodule pinned to that branch.
#
# Idempotent: if .gitmodules already contains external/synthea the entire
# chunk is skipped. Safe to re-run on every Step 1 execution.
#
# Prerequisite: gh CLI must be authenticated (GH_TOKEN in environment or
# gh auth login). Inside the dev container this is satisfied by the
# GH_TOKEN variable forwarded from the host .env file.
# -----------------------------------------------------------------------------

synthea_pad_url  <- "https://github.com/adam-mdmph/synthea-pad.git"
gitmodules_path  <- ".gitmodules"

submodule_configured <- file.exists(gitmodules_path) &&
  any(grepl("external/synthea", readLines(gitmodules_path, warn = FALSE),
            fixed = TRUE))

if (submodule_configured) {
  message("Chunk 2a: external/synthea already registered in .gitmodules — skipping.")
} else {
  message("Chunk 2a: Configuring synthea-pad submodule for this study ...")

  # Derive kebab-case branch name from study_name in study_params.yaml.
  if (!requireNamespace("yaml", quietly = TRUE)) renv::install("yaml")
  params      <- yaml::read_yaml("study_params.yaml")
  study_name  <- params$study_name
  if (is.null(study_name) || study_name == "my_study")
    stop("Set study_name in study_params.yaml before running Step 1.")
  branch_name <- gsub("_", "-", study_name)  # my_study → my-study
  message("  Synthea-pad branch: ", branch_name)

  # Check whether the remote branch already exists.
  branch_exists_raw <- system2(
    "gh",
    c("api", paste0("repos/adam-mdmph/synthea-pad/branches/", branch_name),
      "--jq", ".name"),
    stdout = TRUE, stderr = TRUE
  )
  branch_exists <- !is.null(attr(branch_exists_raw, "status")) &&
    attr(branch_exists_raw, "status") == 0 &&
    any(grepl(branch_name, branch_exists_raw, fixed = TRUE))

  if (branch_exists) {
    message("  Remote branch already exists: ", branch_name)
  } else {
    # Fork from synthea-pad/main — the canonical trunk that incorporates validated
    # improvements from all analysis branches.
    message("  Creating remote branch '", branch_name, "' from synthea-pad/main ...")
    base_sha_raw <- system2(
      "gh",
      c("api", "repos/adam-mdmph/synthea-pad/git/ref/heads/main",
        "--jq", ".object.sha"),
      stdout = TRUE, stderr = TRUE
    )
    if (!is.null(attr(base_sha_raw, "status")) && attr(base_sha_raw, "status") != 0)
      stop("Could not resolve synthea-pad/main SHA:\n",
           paste(base_sha_raw, collapse = "\n"))
    base_sha <- trimws(paste(base_sha_raw, collapse = ""))

    create_raw <- system2(
      "gh",
      c("api", "repos/adam-mdmph/synthea-pad/git/refs",
        "--method", "POST",
        "--field", paste0("ref=refs/heads/", branch_name),
        "--field", paste0("sha=", base_sha)),
      stdout = TRUE, stderr = TRUE
    )
    if (!is.null(attr(create_raw, "status")) && attr(create_raw, "status") != 0)
      stop("Branch creation failed:\n", paste(create_raw, collapse = "\n"))
    message("  Remote branch created: refs/heads/", branch_name)
  }

  # Register external/synthea as a submodule pinned to the study branch.
  message("  Registering external/synthea submodule ...")
  ret <- system2(
    "git",
    c("submodule", "add", "-b", branch_name, synthea_pad_url, "external/synthea"),
    stdout = TRUE, stderr = TRUE
  )
  if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0)
    stop("git submodule add failed:\n", paste(ret, collapse = "\n"))
  message("  Submodule registered: external/synthea → branch ", branch_name)
}

# -----------------------------------------------------------------------------
# Chunk 2b: Initialize the synthea-pad submodule (external/synthea).
#
# The submodule branch is set to the study name (kebab-case) by Chunk 2a above
# (or by new_study.R during study initialization), and the pinned commit is
# recorded in the repo's index. After a fresh clone, run:
#   git submodule update --init external/synthea
# Safe to run repeatedly: no-op when already at the recorded commit.
# Outcome:
# - external/synthea contains the synthea-pad checkout at the pinned commit.
# -----------------------------------------------------------------------------

message("Initializing synthea submodule (external/synthea) ...")
ret <- system2(
  "git",
  c("submodule", "update", "--init", "--recursive", "external/synthea"),
  stdout = TRUE, stderr = TRUE
)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git submodule update failed:\n", paste(ret, collapse = "\n"))
}
message("Synthea submodule ready at: ", file.path(getwd(), "external", "synthea"))

# -----------------------------------------------------------------------------
# Chunk 3: Ensure DatabaseConnector is available.
# Purpose:
# - Guard against edge cases where setup scripts complete but
#   DatabaseConnector is still unavailable in the active library.
# - Keep installation path reproducible by using renv and approved CRAN mirror.
# Outcome:
# - DatabaseConnector is installed or script exits with a clear error.
# -----------------------------------------------------------------------------

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  if (!requireNamespace("renv", quietly = TRUE)) {
    stop("DatabaseConnector is missing and renv is unavailable to install it.")
  }
  options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))
  message("DatabaseConnector not found after setup; installing via renv::install('DatabaseConnector') ...")
  renv::install("DatabaseConnector")
}

# -----------------------------------------------------------------------------
# Chunk 4: Validate required package set for downstream workflow steps.
# Purpose:
# - Confirm core packages needed for ETL and quality checks are installed
#   before expensive work begins.
# Outcome:
# - Hard stop listing any missing packages.
# -----------------------------------------------------------------------------

required <- c("DatabaseConnector", "SqlRender", "jsonlite", "data.table")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  stop("Missing required packages after setup: ", paste(missing, collapse = ", "))
}

# -----------------------------------------------------------------------------
# Chunk 5: Run unit tests.
# Purpose:
# - Verify pure pipeline logic (scoring maths, domain mappings, spec parsing,
#   retry classification) before any database work is attempted.
# - Catch regressions in helper functions introduced since the last run.
# Outcome:
# - Hard stop if any test fails; all 43 tests must pass to proceed.
# -----------------------------------------------------------------------------

if (requireNamespace("testthat", quietly = TRUE) && requireNamespace("withr", quietly = TRUE)) {
  message("Running unit tests ...")
  withr::with_dir(getwd(), {
    results <- testthat::test_dir("tests/testthat", reporter = "progress", stop_on_failure = TRUE)
  })
  message("All unit tests passed.")
} else {
  message("Skipping unit tests: 'testthat' or 'withr' not installed.")
}

# -----------------------------------------------------------------------------
# Chunk 7: Execute database connectivity preflight.
# Purpose:
# - Verify JDBC provisioning, Java runtime settings, credentials, and SQL Server
#   reachability before subsequent workflow steps are attempted.
# - Require multiple consecutive successes to avoid transient false positives.
# Outcome:
# - Fails fast if DB cannot be reached reliably.
# -----------------------------------------------------------------------------

config <- get_validation_config()
connection_details <- build_connection_details(config)
run_db_preflight(
  connection_details = connection_details,
  required_successes = 3L,
  max_attempts = 10L,
  delay_seconds = 2
)

# -----------------------------------------------------------------------------
# Chunk 7b: Shared vocabulary reachability check.
# Purpose:
# - Confirm the connection can see the shared OMOP vocabulary schema (omop_vocab)
#   and that it is populated. The vocabulary is the one hard prerequisite that
#   must exist before any cohort or covariate work; downstream steps query it.
# - Crucially, this does NOT require the study CDM (cdm_schema) to contain any
#   synthetic data yet. Step 1 runs on a freshly created study before the
#   Synthea ETL (Steps 4-5) has populated the CDM, so we report CDM status as
#   informational only and never fail on an empty CDM.
# Outcome:
# - Clear [OK]/[WARN] status for both the vocabulary and the study CDM.
# - A populated vocabulary is required: a clear, actionable error (pointing at
#   the vocabulary loader) if it is missing, instead of a cryptic SQL failure
#   three steps later.
# -----------------------------------------------------------------------------

conn <- DatabaseConnector::connect(connection_details)
on.exit(try(DatabaseConnector::disconnect(conn), silent = TRUE), add = TRUE)

# Vocabulary: must exist AND be populated.
vocab_rows <- tryCatch(
  {
    sql <- SqlRender::render(
      "SELECT COUNT_BIG(*) AS n FROM @vocab_schema.concept;",
      vocab_schema = config$vocab_schema
    )
    sql <- SqlRender::translate(sql, targetDialect = config$dbms)
    r <- DatabaseConnector::querySql(conn, sql)
    as.numeric(r[[1]][[1]])
  },
  error = function(e) NA_real_
)

if (is.na(vocab_rows) || vocab_rows <= 0) {
  stop(
    "Shared OMOP vocabulary not found or empty in schema '", config$vocab_schema, "'.\n",
    "The vocabulary is a one-time, workspace-wide prerequisite. Load it from the\n",
    "workspace root with:\n",
    "  Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template\n",
    "See docs/GETTING_STARTED.md (Step 9) for details."
  )
}
cat(sprintf("[OK]   Shared vocabulary reachable: %s.concept has %s concepts.\n",
            config$vocab_schema, format(vocab_rows, big.mark = ",", scientific = FALSE)))

# Study CDM: informational only — empty is expected before the Synthea ETL runs.
cdm_status <- tryCatch(
  {
    sql <- SqlRender::render(
      "SELECT COUNT_BIG(*) AS n FROM @cdm_schema.person;",
      cdm_schema = config$cdm_schema
    )
    sql <- SqlRender::translate(sql, targetDialect = config$dbms)
    r <- DatabaseConnector::querySql(conn, sql)
    as.numeric(r[[1]][[1]])
  },
  error = function(e) NA_real_
)
if (is.na(cdm_status)) {
  cat(sprintf("[WARN] Study CDM schema '%s' not populated yet (no person table). This is\n",
              config$cdm_schema))
  cat("       expected before the Synthea ETL — run Steps 4-5 to generate and load data.\n")
} else {
  cat(sprintf("[OK]   Study CDM '%s' has %s persons.\n",
              config$cdm_schema, format(cdm_status, big.mark = ",", scientific = FALSE)))
}

DatabaseConnector::disconnect(conn)

# -----------------------------------------------------------------------------
# Chunk 8: Final completion message.
# Purpose:
# - Provide an explicit success signal for automation logs and interactive users.
# -----------------------------------------------------------------------------

cat("Step 1 complete: environment and packages are ready, database connectivity preflight passed, and the shared vocabulary is reachable.\n")
