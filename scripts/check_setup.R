#!/usr/bin/env Rscript
# =============================================================================
# scripts/check_setup.R
#
# Study setup pre-flight check — command-line equivalent of the /check-setup
# Claude Code skill.
#
# PURPOSE
# -------
# Scans study_params.yaml, cohort SQL files, and covariate CSVs for incomplete
# placeholders and prints a checklist report showing what is done and what
# still needs attention before running Step 8.
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
#   2. Cohort SQL files  — concept_id = 0 guards still active
#   3. covariates.csv    — placeholder covariate rows
#   4. covariate_concepts.csv — concept_id = 0 rows
#   5. analyses flags    — which analyses are enabled
#   6. Summary           — pass / warnings / failures
#
# Exit codes:
#   0  — all checks passed (ready for Step 8)
#   1  — one or more items require attention
#
# PREREQUISITES
# -------------
#   - yaml package installed (used by config.R; installed by setup/install_packages.R)
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

# Study identity placeholders
if (is.null(p$study_name) || p$study_name == "my_study") {
  flag_fail("study_name is still the default 'my_study'")
} else {
  PASS(paste0("study_name = '", p$study_name, "'"))
}

if (is.null(p$study_design) || p$study_design == "prognostic_model") {
  flag_warn("study_design is still the default 'prognostic_model' — update if different")
} else {
  PASS(paste0("study_design = '", p$study_design, "'"))
}

# cdm_schema must be set explicitly — the CDM is typically a shared dataset
# populated by a separate ETL, so it cannot be auto-derived from study_name.
if (is.null(p$cdm_schema) || p$cdm_schema == "cdm_my_study") {
  flag_fail("cdm_schema is still the default 'cdm_my_study'")
} else {
  PASS(paste0("cdm_schema = '", p$cdm_schema, "'"))
}

# results_schema, cohort_table, and output_folder are optional — when omitted
# they auto-derive from study_name (slugified to a SQL-safe identifier stem).
# Report whichever form is in effect so the user can confirm it.
study_slug <- gsub("_+", "_",
                   gsub("[\\s\\-\\.]+", "_", tolower(p$study_name %||% "my_study"),
                        perl = TRUE))
study_slug <- sub("^_|_$", "", study_slug)

derive_or_use <- function(field, default_fmt) {
  val <- p[[field]]
  if (is.null(val)) {
    PASS(paste0(field, " auto-derived = '", sprintf(default_fmt, study_slug), "'"))
  } else {
    PASS(paste0(field, " = '", val, "' (explicit)"))
  }
}
derive_or_use("results_schema", "%s_results")
derive_or_use("cohort_table",   "%s_cohort")

if (is.null(p$output_folder)) {
  PASS(paste0("output_folder auto-derived = 'output/", study_slug, "'"))
} else {
  PASS(paste0("output_folder = '", p$output_folder, "' (explicit)"))
}

# Database metadata
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

# Index event concept IDs
index_ids <- unlist(p$target$index_event$ancestor_concept_ids)
if (is.null(index_ids) || any(index_ids == 0)) {
  flag_fail("target.index_event.ancestor_concept_ids contains 0 — replace with verified concept IDs (/concept-lookup)")
} else {
  PASS(paste0("target.index_event.ancestor_concept_ids = [",
              paste(index_ids, collapse = ", "), "]"))
}

# Washout concept IDs
washout_ids <- unlist(p$target$washout$ancestor_concept_ids)
if (!is.null(washout_ids) && any(washout_ids == 0)) {
  flag_fail("target.washout.ancestor_concept_ids contains 0 — replace or set to [] to disable (/concept-lookup)")
} else if (is.null(washout_ids) || length(washout_ids) == 0) {
  PASS("target.washout disabled (ancestor_concept_ids = [])")
} else {
  PASS(paste0("target.washout.ancestor_concept_ids = [",
              paste(washout_ids, collapse = ", "), "]"))
}

# Outcome concept IDs
outcome_ids <- unlist(p$outcome$ancestor_concept_ids)
if (is.null(outcome_ids) || any(outcome_ids == 0)) {
  flag_fail("outcome.ancestor_concept_ids contains 0 — replace with verified concept IDs (/concept-lookup)")
} else {
  PASS(paste0("outcome.ancestor_concept_ids = [",
              paste(outcome_ids, collapse = ", "), "]"))
}

# Causal inference: comparator concept IDs when cohort_id is set
if (!is.null(p$comparator$cohort_id) && !is.na(p$comparator$cohort_id)) {
  comp_ids <- unlist(p$comparator$index_event$ancestor_concept_ids)
  if (is.null(comp_ids) || any(comp_ids == 0)) {
    flag_fail("comparator.index_event.ancestor_concept_ids contains 0 — required when comparator cohort is enabled")
  } else {
    PASS(paste0("comparator.index_event.ancestor_concept_ids = [",
                paste(comp_ids, collapse = ", "), "]"))
  }
}


# -----------------------------------------------------------------------------
# 2. Cohort SQL files — concept_id = 0 guard blocks
# -----------------------------------------------------------------------------
cat("\n--- 2. Cohort SQL files ---\n")

# The cohort SQL templates use IF @index_concept_ids = '0' guard blocks to
# prevent accidental execution with unset concept IDs.  When concept IDs are
# properly set via study_params.yaml those guard blocks do not fire.
# This check scans for '= 0' patterns that indicate placeholder IDs are still
# present in any custom SQL written directly into cohort files.
cohort_files <- c(
  target     = p$target$sql_file,
  outcome    = p$outcome$sql_file,
  comparator = if (!is.null(p$comparator$cohort_id) &&
                   !is.na(p$comparator$cohort_id)) p$comparator$sql_file
)
cohort_files <- cohort_files[!is.null(cohort_files) & !is.na(cohort_files)]

for (role in names(cohort_files)) {
  fpath <- cohort_files[[role]]
  if (is.null(fpath) || is.na(fpath)) next
  if (!file.exists(fpath)) {
    flag_warn(paste0(role, " SQL file not found: ", fpath))
    next
  }
  sql_text <- paste(readLines(fpath, warn = FALSE), collapse = "\n")
  # Look for hardcoded concept_id = 0 in non-guard, non-comment lines.
  # The parameterised templates don't hardcode IDs, so any literal 0 in a
  # concept_id context in a *non-template* file is a red flag.
  has_zero <- grepl("concept_id\\s*=\\s*0(?!x)", sql_text,
                    perl = TRUE, ignore.case = TRUE)
  if (has_zero) {
    flag_fail(paste0(role, " SQL (", fpath,
                     "): contains 'concept_id = 0' — check for hardcoded placeholder IDs"))
  } else {
    PASS(paste0(role, " SQL (", fpath, ") — no hardcoded concept_id = 0"))
  }
}


# -----------------------------------------------------------------------------
# 3. covariates/covariates.csv — placeholder rows
# -----------------------------------------------------------------------------
cat("\n--- 3. covariates/covariates.csv ---\n")

cov_def_path <- "covariates/covariates.csv"
if (!file.exists(cov_def_path)) {
  flag_warn(paste0(cov_def_path, " not found — skip if using FeatureExtraction directly"))
} else {
  cov_defs <- read.csv(cov_def_path, stringsAsFactors = FALSE, comment.char = "#")
  placeholder_rows <- grep("^covariate_[0-9]+$", cov_defs$covariate_id, value = TRUE)
  if (length(placeholder_rows) > 0) {
    flag_fail(paste0(
      "covariates.csv still has ", length(placeholder_rows),
      " placeholder row(s): ", paste(placeholder_rows, collapse = ", ")
    ))
  } else {
    PASS(paste0("covariates.csv — ", nrow(cov_defs), " covariate(s), no placeholders"))
  }
}


# -----------------------------------------------------------------------------
# 4. covariates/covariate_concepts.csv — concept_id = 0 rows
# -----------------------------------------------------------------------------
cat("\n--- 4. covariates/covariate_concepts.csv ---\n")

cov_conc_path <- "covariates/covariate_concepts.csv"
if (!file.exists(cov_conc_path)) {
  flag_warn(paste0(cov_conc_path, " not found — skip if using FeatureExtraction directly"))
} else {
  cov_concs <- read.csv(cov_conc_path, stringsAsFactors = FALSE, comment.char = "#")
  zero_rows  <- cov_concs[!is.na(cov_concs$concept_id) &
                            cov_concs$concept_id %in% c(0, "0"), ]
  if (nrow(zero_rows) > 0) {
    flag_fail(paste0(
      "covariate_concepts.csv has ", nrow(zero_rows),
      " row(s) with concept_id = 0: ",
      paste(zero_rows$covariate_id, collapse = ", "),
      "\nRun: Rscript scripts/concept_lookup.R \"<term>\" [domain]"
    ))
  } else {
    PASS(paste0("covariate_concepts.csv — ",
                nrow(cov_concs), " concept mapping(s), no zeros"))
  }
}


# -----------------------------------------------------------------------------
# 5. analyses flags — which analyses are enabled
# -----------------------------------------------------------------------------
cat("\n--- 5. analyses flags (study_params.yaml) ---\n")

analyses <- p$analyses
if (is.null(analyses)) {
  flag_warn("analyses: section missing from study_params.yaml — no analyses will run in Step 8")
} else {
  any_enabled <- FALSE
  flag_names <- c(
    cohort_characterization = "cohort_characterization",
    prognostic_model        = "prognostic_model",
    causal_inference        = "causal_inference",
    integer_risk_score      = "integer_risk_score",
    plp_model_validation    = "plp_model_validation",
    word_report             = "word_report"
  )
  for (flag in names(flag_names)) {
    val <- isTRUE(analyses[[flag]])
    if (val) {
      PASS(paste0(flag, ": true"))
      any_enabled <- TRUE
    } else {
      cat("  [----] ", flag, ": false\n", sep = "")
    }
  }
  if (!any_enabled) {
    flag_warn("All analyses flags are false — set at least one to true before running Step 8")
  }

  # Causal inference requires a comparator cohort
  if (isTRUE(analyses$causal_inference)) {
    if (is.null(p$comparator$cohort_id) || is.na(p$comparator$cohort_id)) {
      flag_fail("causal_inference = true but comparator.cohort_id is not set in study_params.yaml")
    }
    # Negative controls are not required but strongly recommended for calibration
    nco_ids <- unlist(p$negative_controls$ancestor_concept_ids)
    nco_ids <- nco_ids[!is.na(nco_ids) & nco_ids != 0]
    if (is.null(nco_ids) || length(nco_ids) == 0) {
      flag_warn(paste0(
        "causal_inference = true but negative_controls.ancestor_concept_ids is empty. ",
        "Add >= 5 negative control concept IDs for empirical calibration."
      ))
    } else if (length(nco_ids) < 5L) {
      flag_warn(paste0(
        "Only ", length(nco_ids), " negative control(s) defined. ",
        "EmpiricalCalibration requires >= 5 for a reliable null distribution."
      ))
    } else {
      PASS(paste0("negative_controls: ", length(nco_ids), " concept ID(s) defined"))
    }
  }

  # Integer risk score requires points column in covariates.csv
  if (isTRUE(analyses$integer_risk_score) && file.exists(cov_def_path)) {
    cov_check <- read.csv(cov_def_path, stringsAsFactors = FALSE, comment.char = "#")
    if (!"points" %in% names(cov_check)) {
      flag_fail("integer_risk_score = true but covariates.csv has no 'points' column")
    }
  }
}


# -----------------------------------------------------------------------------
# 6. Summary
# -----------------------------------------------------------------------------
cat("\n--- Summary ---\n")
total_checks <- issues + warnings
if (issues == 0 && warnings == 0) {
  cat("  ALL CHECKS PASSED — ready to generate data.\n")
  cat("  Next (data-generation-only repo — no Steps 7-9):\n")
  cat("        Rscript workflow/03_generate_synthea_module_artifacts.R\n")
  cat("        (then Steps 4-6: generate CSVs, ETL, QC)\n\n")
  quit(status = 0)
} else {
  if (issues > 0) {
    cat("  FAIL:    ", issues, " item(s) must be resolved before generating data.\n", sep = "")
  }
  if (warnings > 0) {
    cat("  WARNING: ", warnings, " item(s) to review (non-blocking).\n", sep = "")
  }
  cat("\nResolve [FAIL] items, then re-run: Rscript scripts/check_setup.R\n\n")
  quit(status = 1)
}
