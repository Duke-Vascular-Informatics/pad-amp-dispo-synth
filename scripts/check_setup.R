#!/usr/bin/env Rscript
# =============================================================================
# scripts/check_setup.R
#
# Setup pre-flight check for a -synth repo — command-line equivalent of the
# /check-setup Claude Code skill.
#
# PURPOSE
# -------
# Scans study_params.yaml, consumers.yaml and the Synthea module for incomplete
# placeholders and prints a checklist showing what is done and what still needs
# attention before generating synthetic data.
#
# A -synth repo defines no cohorts, outcomes or covariates of its own. What the
# dataset must contain comes from the consuming studies listed in consumers.yaml
# (their cohort definitions are read directly), so this check verifies that list
# is filled in and usable rather than checking copies of those definitions.
#
# No database connection is required — all checks are file-based.
#
# USAGE
# -----
#   Rscript scripts/check_setup.R
#
# OUTPUT
# ------
# Prints a sectioned checklist to the console:
#   1. study_params.yaml — placeholder values and TODO items
#   2. consumers.yaml    — consuming studies present, readable, roles resolvable
#   3. Synthea module    — custom module present, REPLACE_ME placeholders
#   4. Summary           — pass / warnings / failures
#
# Exit codes:
#   0  — all checks passed (ready to generate synthetic data)
#   1  — one or more items require attention
# =============================================================================

# -----------------------------------------------------------------------------
# 0. Bootstrap
# -----------------------------------------------------------------------------
args_full <- commandArgs(trailingOnly = FALSE)
file_arg  <- grep("^--file=", args_full, value = TRUE)
if (length(file_arg) > 0) {
  script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                      winslash = "/"))
  proj_root  <- dirname(script_dir)
} else {
  proj_root <- getwd()
}
setwd(proj_root)

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
PASS <- function(msg) cat("  [OK]   ", msg, "\n", sep = "")
WARN <- function(msg) cat("  [WARN] ", msg, "\n", sep = "")
FAIL <- function(msg) cat("  [FAIL] ", msg, "\n", sep = "")

issues   <- 0L
warnings <- 0L

flag_fail <- function(msg) { FAIL(msg); issues   <<- issues   + 1L }
flag_warn <- function(msg) { WARN(msg); warnings <<- warnings + 1L }

`%||%` <- function(x, y) if (is.null(x)) y else x

source("R/consumer_qc.R")

# -----------------------------------------------------------------------------
# 1. study_params.yaml — placeholder values
# -----------------------------------------------------------------------------
cat("\n=== Check Setup Report ===\n")
cat("\n--- 1. study_params.yaml ---\n")

if (!file.exists("study_params.yaml")) {
  flag_fail("study_params.yaml not found. Run: cp study_params.yaml.example study_params.yaml")
  quit(status = 1)
}

p <- yaml::read_yaml("study_params.yaml")

if (is.null(p$study_name) || p$study_name == "my_study") {
  flag_fail("study_name is still the default 'my_study'")
} else {
  PASS(paste0("study_name = '", p$study_name, "'"))
}

# cdm_schema must be set explicitly — the CDM is typically a shared dataset
# populated by a separate ETL, so it cannot be auto-derived from study_name.
if (is.null(p$cdm_schema) || p$cdm_schema == "cdm_my_study") {
  flag_fail("cdm_schema is still the default 'cdm_my_study'")
} else {
  PASS(paste0("cdm_schema = '", p$cdm_schema, "'"))
}

# results_schema and output_folder are optional — when omitted they auto-derive
# from study_name (slugified to a SQL-safe identifier stem). Report whichever
# form is in effect so the user can confirm it.
study_slug <- gsub("_+", "_",
                   gsub("[\\s\\-\\.]+", "_", tolower(p$study_name %||% "my_study"),
                        perl = TRUE))
study_slug <- sub("^_|_$", "", study_slug)

if (is.null(p$results_schema)) {
  PASS(paste0("results_schema auto-derived = '", study_slug, "_results'"))
} else {
  PASS(paste0("results_schema = '", p$results_schema, "' (explicit)"))
}
if (is.null(p$output_folder)) {
  PASS(paste0("output_folder auto-derived = 'output/", study_slug, "'"))
} else {
  PASS(paste0("output_folder = '", p$output_folder, "' (explicit)"))
}

if (is.null(p$cdm_database_id) || p$cdm_database_id == "my_cdm_v5.4") {
  flag_warn("cdm_database_id is still the default 'my_cdm_v5.4'")
} else {
  PASS(paste0("cdm_database_id = '", p$cdm_database_id, "'"))
}
if (is.null(p$cdm_database_name) || p$cdm_database_name == "My Study Database") {
  flag_warn("cdm_database_name is still the default 'My Study Database'")
} else {
  PASS(paste0("cdm_database_name = '", p$cdm_database_name, "'"))
}

# -----------------------------------------------------------------------------
# 2. consumers.yaml — the studies this dataset must support
# -----------------------------------------------------------------------------
cat("\n--- 2. consumers.yaml (studies this dataset must support) ---\n")

if (!file.exists("consumers.yaml")) {
  flag_fail("consumers.yaml not found. Restore it from the template and list the Strategus studies that will use this dataset.")
} else {
  cfg <- read_consumers("consumers.yaml")

  if (is.na(cfg$dataset_id) || cfg$dataset_id == "my_study_synth_dataset") {
    flag_warn("dataset_id is still the default 'my_study_synth_dataset' — set it to this dataset's id in synthetic_data/registry.yaml")
  } else {
    PASS(paste0("dataset_id = '", cfg$dataset_id, "'"))
  }

  if (length(cfg$consumers) == 0) {
    flag_fail("no consuming studies listed. The Synthea module and the final data are checked against the cohorts of these studies; add each Strategus study that will use this dataset.")
  } else {
    seen <- inspect_consumers(cfg$consumers, proj_root)
    for (nm in unique(seen$manifest$consumer)) {
      m <- seen$manifest[seen$manifest$consumer == nm, , drop = FALSE]
      PASS(paste0(nm, ": ", sum(m$role == "target"), " target, ", sum(m$role == "outcome"),
                  " outcome, ", sum(m$role == "covariate"), " covariate cohort(s) found"))
    }
    for (prob in seen$problems) flag_fail(prob)
    for (h in seen$hints) flag_warn(h)
  }
}

# -----------------------------------------------------------------------------
# 3. Synthea module
# -----------------------------------------------------------------------------
cat("\n--- 3. Synthea module (synthea/modules/) ---\n")

mods <- list.files("synthea/modules", pattern = "\\.json$", full.names = TRUE)
mods <- mods[basename(mods) != "study_template.json"]
if (length(mods) == 0) {
  flag_warn("no custom module yet — copy synthea/modules/study_template.json to <name>.json and edit it (Step 6)")
} else {
  for (m in mods) {
    n_placeholder <- sum(grepl("REPLACE_ME", readLines(m, warn = FALSE), fixed = TRUE))
    if (n_placeholder > 0) {
      flag_warn(paste0(basename(m), " still has ", n_placeholder,
                       " REPLACE_ME placeholder line(s) — resolve them with a vocabulary lookup before generating data"))
    } else {
      PASS(paste0(basename(m), " — no REPLACE_ME placeholders"))
    }
  }
}

# -----------------------------------------------------------------------------
# 4. Summary
# -----------------------------------------------------------------------------
cat("\n--- Summary ---\n")
total_checks <- issues + warnings
if (issues == 0 && warnings == 0) {
  cat("  ALL CHECKS PASSED — ready to generate synthetic data.\n")
  cat("  Next: Rscript workflow/03_generate_synthea_module_artifacts.R\n")
  cat("        bash workflow/04_generate_synthea_csv.sh\n\n")
  quit(status = 0)
} else {
  if (issues > 0) {
    cat("  FAIL:    ", issues, " item(s) must be resolved before generating synthetic data.\n", sep = "")
  }
  if (warnings > 0) {
    cat("  WARNING: ", warnings, " item(s) to review (non-blocking).\n", sep = "")
  }
  cat("\nResolve [FAIL] items, then re-run: Rscript scripts/check_setup.R\n\n")
  quit(status = 1)
}
