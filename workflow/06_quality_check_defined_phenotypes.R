#!/usr/bin/env Rscript
# Step 6: Data quality check against defined cohort, outcome, and covariates.

# This wrapper script intentionally stays thin and delegates all SQL-heavy
# validation logic to scripts/quality_check_etl.R. Its responsibilities are:
#  1) locate workflow bootstrap reliably across invocation contexts,
#  2) normalize working directory to project root,
#  3) initialize Java variables needed by DatabaseConnector/rJava,
#  4) forward any CLI flags to quality_check_etl.R,
#  5) propagate non-zero exit status as a hard workflow failure.
#
# Supported flags (all forwarded to quality_check_etl.R):
#   --run_name=<name>
#   --enforce_thresholds=<true|false>
#   --min_person_rows=<n>
#   --min_mapped_condition_pct=<pct>
#   --run_achilles=<true|false>   Run ACHILLES CDM profiling (default: TRUE, 10-60 min)
#   --run_dqd=<true|false>        Run OHDSI Data Quality Dashboard (default: TRUE, 10-60 min)
#   --achilles_threads=<n>        Parallel threads for ACHILLES (default: 1)
#
#   --skip_consumer_qc=<true|false>   Skip checking consuming studies' cohorts (default: false)
#   (the flags --consumers, --cdm_schema and --registry are forwarded to
#    scripts/consumer_cohort_qc.R; see that file)
#
# Examples:
#   # Fast path — skip the slow profilers (clinical signal checks + consumer QC only)
#   Rscript workflow/06_quality_check_defined_phenotypes.R --run_achilles=false --run_dqd=false
#
#   # Full profiling before manuscript submission
#   Rscript workflow/06_quality_check_defined_phenotypes.R \
#     --run_achilles=true --run_dqd=true --achilles_threads=2

# Resolve the bootstrap file relative to this script path when launched by
# Rscript, while still supporting interactive/manual execution fallback.
bootstrap_path <- local({
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

# Bootstrap sets helper functions used by all workflow steps (for example
# set_workflow_root()) and establishes consistent runtime assumptions.
source(bootstrap_path)
set_workflow_root()

# Load central configuration once and apply Java runtime settings before any
# package lazily initializes JVM bindings.
source("config.R")
cfg <- get_validation_config()
if (!is.null(cfg$java_home) && nzchar(cfg$java_home) && dir.exists(cfg$java_home)) {
  java_bin <- file.path(cfg$java_home, "bin")
  Sys.setenv(JAVA_HOME = cfg$java_home)
  Sys.setenv(PATH = paste(normalizePath(java_bin, winslash = "/", mustWork = FALSE), Sys.getenv("PATH"), sep = .Platform$path.sep))
  options(java.parameters = paste0("-Djava.home=", normalizePath(cfg$java_home, winslash = "/", mustWork = FALSE)))
}

# Forward all incoming CLI args transparently so callers can pass threshold
# gates or run-name overrides directly at Step 6 entrypoint.
args <- commandArgs(trailingOnly = TRUE)

# Default execution target is scripts/quality_check_etl.R.
cmd <- c("scripts/quality_check_etl.R")
if (length(args) > 0) {
  cmd <- c(cmd, args)
}

# Execute in a child R session to isolate script-level options and avoid
# accidental object leakage from wrapper into quality-check script scope.
rscript_bin <- if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
status <- system2(file.path(R.home("bin"), rscript_bin), args = cmd)
if (!identical(status, 0L)) {
  # Preserve fail-fast behavior for downstream workflow automation.
  stop("Quality check failed.")
}

# Consumer-study QC: check the dataset against the cohorts of every Strategus
# study listed in consumers.yaml, so a regenerated or edited dataset cannot
# silently break a downstream study. Runs only when the generic QC passed.
# Skip with --skip_consumer_qc=true. Report-only unless --enforce_thresholds=true.
skip_consumer_qc <- any(grepl("^--skip_consumer_qc=(true|1|yes)$", args, ignore.case = TRUE))
if (!skip_consumer_qc) {
  consumer_args <- grep("^--(enforce_thresholds|cdm_schema|consumers|registry)=", args, value = TRUE)
  status <- system2(file.path(R.home("bin"), rscript_bin),
                    args = c("scripts/consumer_cohort_qc.R", consumer_args))
  if (!identical(status, 0L)) {
    stop("Consumer-study QC failed: a study that uses this dataset would break.")
  }
}

cat("Step 6 complete: quality checks executed.\n")
