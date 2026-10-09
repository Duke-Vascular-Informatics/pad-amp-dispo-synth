#!/usr/bin/env Rscript
# =============================================================================
# scripts/module_coverage_check.R
#
# Module-build coverage check: confirms, BEFORE data generation, that the Synthea
# modules that will run can emit the clinical concepts every consuming Strategus
# study's cohorts need. The final data is then judged by consumer-study QC
# (scripts/consumer_cohort_qc.R) in workflow/06.
#
# It covers the custom module in synthea/modules/ AND the built-in Synthea
# modules, because workflow/04 runs Synthea with all of them. See
# R/module_coverage.R for the method and what a pass does and does not mean.
#
# Called by workflow/03_generate_synthea_module_artifacts.R; can be run alone.
#
# USAGE
#   Rscript scripts/module_coverage_check.R
#   Rscript scripts/module_coverage_check.R --enforce_coverage=true
#
# FLAGS
#   --consumers=<path>              consumers file (default consumers.yaml)
#   --enforce_coverage=<true|false> exit non-zero when a consuming cohort cannot
#                                   be produced, or a consumer cannot be checked
#                                   (default false: report only)
#   --synthea_home=<dir>            Synthea checkout (default $SYNTHEA_HOME or
#                                   external/synthea)
#
# OUTPUT   console table + output/qc/module_coverage.csv (no patient data)
# EXIT     0 ok / report-only / nothing to check; 1 enforced failure
# NEEDS    the OMOP vocabulary (omop_vocab) on the SQL Server; read-only queries.
#          If the database is unreachable the check is skipped with a warning
#          (and fails under --enforce_coverage=true).
# =============================================================================

source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/consumer_qc.R")
source("R/module_coverage.R")

args <- commandArgs(trailingOnly = TRUE)
flag <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit) == 0) default else sub(paste0("^--", name, "="), "", hit[1])
}
as_bool <- function(x) tolower(trimws(as.character(x))) %in% c("1", "true", "t", "yes", "y")

consumers_path <- flag("consumers", "consumers.yaml")
enforce        <- as_bool(flag("enforce_coverage", "false"))
synthea_home   <- flag("synthea_home", Sys.getenv("SYNTHEA_HOME", unset = file.path(getwd(), "external", "synthea")))

cfg <- read_consumers(consumers_path)
if (length(cfg$consumers) == 0) {
  cat("Module coverage: no consuming studies listed in ", consumers_path, ".\n",
      "  [WARN] Nothing to check the module against. Add each Strategus study that\n",
      "         will use this dataset to ", consumers_path, ".\n", sep = "")
  quit(status = 0)
}

# The custom module(s): same detection as workflow/03 and 04.
custom <- list.files("synthea/modules", pattern = "\\.json$", full.names = TRUE)
custom <- custom[basename(custom) != "study_template.json"]
if (length(custom) == 0) {
  cat("Module coverage: no custom module in synthea/modules/ yet.\n")
  quit(status = if (enforce) 1 else 0)
}

inv <- collect_all_module_codes(custom, synthea_home)
placeholders <- sum(inv$codes$code == "REPLACE_ME")
cat("Module coverage for dataset '", cfg$dataset_id, "': ",
    paste(vapply(cfg$consumers, function(co) co$study, character(1)), collapse = ", "), "\n", sep = "")
cat("  custom module(s): ", paste(basename(custom), collapse = ", "), "\n", sep = "")
if (inv$builtin_found) {
  cat("  built-in Synthea modules: ", inv$n_builtin, " (", synthea_home, ")\n", sep = "")
} else {
  cat("  [WARN] built-in Synthea modules not found at ", synthea_home, ".\n",
      "         Only the custom module is considered, so concepts that Synthea's built-in\n",
      "         modules generate (e.g. common comorbidities) may be reported as not covered.\n", sep = "")
}
if (placeholders > 0) {
  cat("  [WARN] ", placeholders, " REPLACE_ME code(s) in the module are ignored.\n", sep = "")
}

config <- get_validation_config()
conn <- tryCatch(DatabaseConnector::connect(build_connection_details(config)),
                 error = function(e) { cat("  [WARN] cannot connect to the database: ", conditionMessage(e), "\n", sep = ""); NULL })
if (is.null(conn)) {
  cat("Module coverage check skipped: it needs the OMOP vocabulary.\n")
  quit(status = if (enforce) 1 else 0)
}
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

out <- check_module_coverage(conn, config$vocab_schema, cfg$consumers, inv$codes, repo_root = getwd())

if (length(out$unmapped_systems)) {
  cat("  note: code systems with no OMOP vocabulary mapping were skipped: ",
      paste(out$unmapped_systems, collapse = ", "), "\n", sep = "")
}
if (!is.null(out$results)) {
  print(out$results[, c("consumer", "cohort_id", "cohort_name", "role", "status", "provided_by")], row.names = FALSE)
  qc_dir <- file.path(getwd(), "output", "qc"); dir.create(qc_dir, recursive = TRUE, showWarnings = FALSE)
  write.csv(out$results, file.path(qc_dir, "module_coverage.csv"), row.names = FALSE)
  cat("\nWrote output/qc/module_coverage.csv\n")
  bad <- out$results[out$results$status %in% c("NOT_COVERED", "NOT_EVALUABLE") | nzchar(out$results$detail), , drop = FALSE]
  for (i in seq_len(nrow(bad))) {
    cat("  ", bad$status[i], ": ", bad$consumer[i], " cohort ", bad$cohort_id[i], " (", bad$role[i], ") ",
        bad$detail[i], "\n", sep = "")
  }
}
for (p in out$problems) cat("  [FAIL] ", p, "\n", sep = "")

n_uncovered <- if (is.null(out$results)) 0L else sum(out$results$status == "NOT_COVERED")
n_unknown   <- if (is.null(out$results)) 0L else sum(out$results$status == "NOT_EVALUABLE")
cat("\nModule coverage: ", n_uncovered, " cohort(s) the module cannot produce, ", n_unknown,
    " not evaluable, ", length(out$problems), " consumer(s) could not be checked.\n",
    "Covered means the module CAN emit the concept; counts come from consumer-study QC after generation.\n", sep = "")
if ((n_uncovered > 0 || length(out$problems) > 0) && enforce) {
  cat("Failing because --enforce_coverage=true: extend the module before generating data.\n")
  quit(status = 1)
}
