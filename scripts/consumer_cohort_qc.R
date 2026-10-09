#!/usr/bin/env Rscript
# =============================================================================
# scripts/consumer_cohort_qc.R
#
# Consumer-study QC: checks that the synthetic dataset in the active CDM schema
# still contains the patients that every consuming Strategus study needs.
#
# For each study in consumers.yaml it instantiates the study's own cohorts
# (target, outcomes and covariate cohorts, rendered from circe JSON exactly as
# Strategus does) against the synthetic CDM and compares subject counts with
# per-role minimums. See R/consumer_qc.R for the method and its limits.
#
# Called by workflow/06_quality_check_defined_phenotypes.R after the generic QC;
# can also be run on its own.
#
# USAGE
#   Rscript scripts/consumer_cohort_qc.R
#   Rscript scripts/consumer_cohort_qc.R --enforce_thresholds=true
#
# FLAGS
#   --consumers=<path>                  consumers file (default consumers.yaml)
#   --enforce_thresholds=<true|false>   exit non-zero on any FAIL or on a
#                                       consumer that could not be checked
#                                       (default false: report only)
#   --cdm_schema=<schema>               CDM schema to test (default: the active
#                                       schema, resolved like workflow/06)
#   --registry=<path>                   registry to compare used_by against
#                                       (default ../synthetic_data/registry.yaml)
#
# OUTPUT
#   Console table plus output/qc/consumer_cohort_qc.csv (aggregate counts only;
#   no patient-level data). For consumers with discharge_disposition_check: true,
#   also output/qc/discharge_disposition_qc.csv.
#
# EXIT CODES
#   0  all consumers pass (or none registered, or report-only mode)
#   1  --enforce_thresholds=true and at least one FAIL / unchecked consumer
# =============================================================================

source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/consumer_qc.R")

# -----------------------------------------------------------------------------
# CLI flags
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
flag <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit) == 0) default else sub(paste0("^--", name, "="), "", hit[1])
}
as_bool <- function(x) tolower(trimws(as.character(x))) %in% c("1", "true", "t", "yes", "y")

consumers_path <- flag("consumers", "consumers.yaml")
enforce        <- as_bool(flag("enforce_thresholds", "false"))
registry_path  <- flag("registry", file.path("..", "synthetic_data", "registry.yaml"))

# -----------------------------------------------------------------------------
# Read the consumer list. An empty list is not an error, but it is a warning:
# nothing is protecting this dataset's downstream links.
# -----------------------------------------------------------------------------
cfg <- read_consumers(consumers_path)
if (length(cfg$consumers) == 0) {
  cat("Consumer-study QC: no consuming studies listed in ", consumers_path, ".\n",
      "  [WARN] No downstream study is checked against this dataset. Add each\n",
      "         Strategus study that uses it to ", consumers_path, ".\n", sep = "")
  quit(status = 0)
}

studies <- vapply(cfg$consumers, function(co) co$study, character(1))
cat("Consumer-study QC for dataset '", cfg$dataset_id, "': ",
    paste(studies, collapse = ", "), "\n", sep = "")

# Advisory: a consumer that reads discharge disposition but has not opted in.
for (h in inspect_consumers(cfg$consumers, getwd())$hints) cat("  [WARN] ", h, "\n", sep = "")

# consumers.yaml and the workspace registry must tell the same story.
agree <- check_registry_agreement(cfg$dataset_id, studies, registry_path, cfg$not_checked)
for (p in agree) cat("  [WARN] ", p, "\n", sep = "")

# -----------------------------------------------------------------------------
# Connect, resolve the schema under test, make sure the scratch schema exists
# -----------------------------------------------------------------------------
config <- get_validation_config()
connection_details <- build_connection_details(config)

probe <- DatabaseConnector::connect(connection_details)
cdm_schema <- flag("cdm_schema", NULL)
if (is.null(cdm_schema)) {
  cdm_schema <- resolve_active_cdm_schema(probe, config$cdm_schema, config$study_name)
}
# Scratch cohort tables go in the results schema, never the CDM schema.
DatabaseConnector::executeSql(
  probe,
  paste0("IF SCHEMA_ID('", gsub("'", "''", config$results_schema), "') IS NULL ",
         "EXEC('CREATE SCHEMA [", config$results_schema, "]');"),
  progressBar = FALSE, reportOverallTime = FALSE)
DatabaseConnector::disconnect(probe)
cat("CDM schema under test: ", cdm_schema, "\n\n", sep = "")

# -----------------------------------------------------------------------------
# Run and report
# -----------------------------------------------------------------------------
out <- run_consumer_cohort_qc(
  connection_details = connection_details,
  cdm_schema         = cdm_schema,
  results_schema     = config$results_schema,
  consumers          = cfg$consumers,
  repo_root          = getwd(),
  database           = config$database)  # SQL Server needs <database>.<schema>

if (!is.null(out$results)) {
  show <- out$results[, c("consumer", "cohort_id", "cohort_name", "role",
                          "subjects", "subjects_in_target", "threshold", "status")]
  print(show, row.names = FALSE)

  qc_dir <- file.path(getwd(), "output", "qc")
  dir.create(qc_dir, recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path(qc_dir, "consumer_cohort_qc.csv")
  write.csv(out$results, out_path, row.names = FALSE)
  cat("\nWrote ", out_path, "\n", sep = "")
  notes <- out$results[nzchar(out$results$note), c("consumer", "cohort_id", "note")]
  for (i in seq_len(nrow(notes))) {
    cat("  note: ", notes$consumer[i], " cohort ", notes$cohort_id[i], ": ", notes$note[i], "\n", sep = "")
  }
}
if (!is.null(out$discharge)) {
  cat("\nDischarge-disposition check (opt-in per consumer; the cohort check above cannot see this):\n")
  print(out$discharge[, c("consumer", "check", "value", "threshold", "status")], row.names = FALSE)
  dir.create(file.path(getwd(), "output", "qc"), recursive = TRUE, showWarnings = FALSE)
  write.csv(out$discharge, file.path(getwd(), "output", "qc", "discharge_disposition_qc.csv"), row.names = FALSE)
  cat("Wrote output/qc/discharge_disposition_qc.csv\n")
}
for (p in out$problems) cat("  [FAIL] ", p, "\n", sep = "")

n_fail <- if (is.null(out$results)) 0L else sum(out$results$status == "FAIL")
if (!is.null(out$discharge)) n_fail <- n_fail + sum(out$discharge$status == "FAIL")
n_problem <- length(out$problems)
cat("\nConsumer-study QC: ", n_fail, " cohort FAIL, ", n_problem,
    " consumer(s) could not be checked.\n", sep = "")

if ((n_fail > 0 || n_problem > 0) && enforce) {
  cat("Failing because --enforce_thresholds=true. Regenerating or changing this ",
      "dataset would break the study(ies) above.\n", sep = "")
  quit(status = 1)
}
if (n_fail > 0 || n_problem > 0) {
  cat("Report-only mode: pass --enforce_thresholds=true to fail on these.\n")
}
