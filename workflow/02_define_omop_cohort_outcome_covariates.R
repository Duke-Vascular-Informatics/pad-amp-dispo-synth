#!/usr/bin/env Rscript
# =============================================================================
# workflow/02_define_omop_cohort_outcome_covariates.R
#
# Step 2: Declare and validate the phenotype artifacts for your study.
#
# PURPOSE
# -------
# This step is the single source of truth for WHAT the study measures:
#   • Which patients are in scope (target / exposure cohort)
#   • What is being compared to or against (comparator cohort, if any)
#   • What outcome is being tracked (outcome cohort, if any)
#   • Which covariates / features are extracted (covariate definitions, if any)
#
# It does NOT connect to a database. It reads files, validates their structure,
# and prints a manifest so you can confirm the artifacts before running Step 8.
#
# This step supports any OMOP-based study design:
#   • Cohort characterization  — target cohort only
#   • Prognostic modelling     — target cohort + outcome + covariates
#   • Causal inference         — target + comparator + outcome + covariates
#   • Descriptive comparison   — target + comparator (no formal outcome)
#
# =============================================================================
# STUDY PARAMETERS — read from study_params.yaml via config.R
# =============================================================================
# All study-specific settings (study design, cohort SQL paths, concept IDs,
# analysis parameters) live in study_params.yaml. This script reads them via
# get_validation_config() below and uses them for validation only.
#
# To change any setting: edit study_params.yaml, then re-run this script.
# =============================================================================


# =============================================================================
# — INFRASTRUCTURE BELOW — no changes needed unless extending validation —
# =============================================================================


# -----------------------------------------------------------------------------
# Chunk 1 - Workflow bootstrap
# -----------------------------------------------------------------------------
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
source(bootstrap_path)
set_workflow_root()

# Read all study parameters from config.R (which reads study_params.yaml).
# Step 8 (build_cohorts) reads the same config, so the values never diverge.
source("config.R")
config <- get_validation_config()
target_cohort_sql_path     <- config$target_cohort_sql
comparator_cohort_sql_path <- config$comparator_cohort_sql
outcome_cohort_sql_path    <- config$outcome_cohort_sql
study_design               <- config$study_design
prediction_window_days     <- config$prediction_window_days
min_prior_observation_days <- config$min_prior_observation_days
covariate_lookback_days    <- config$covariate_lookback_days
covariate_definitions_path  <- config$covariate_definitions_file
covariate_concepts_path    <- config$covariate_concepts_file

# Guard: comparator is active only when comparator.cohort_id is explicitly set
# in study_params.yaml (not null/NA). Studies without a comparator skip all
# comparator artifact loading and validation silently.
comparator_enabled <- !is.na(config$comparator_cohort_id)

# Guard: points column in covariates.csv is only required when the integer
# risk score analysis is enabled. Continuous PLP studies don't use it.
require_points <- isTRUE(config$run_integer_risk_score)

# Read the raw YAML once so read_model_reference() can access the full tree.
study_params_raw <- yaml::read_yaml("study_params.yaml")


# -----------------------------------------------------------------------------
# Chunk 1b - Model reference reader
# Purpose: surface metadata about the model or score being externally validated.
# Two-tier approach:
#   Tier 1 — YAML block: reads model_reference: from study_params.yaml (works
#             for any model type: integer_risk_score, plp_*, logistic, etc.)
#   Tier 2 — PLP .rds fallback: when model_reference: is absent but a model/
#             folder contains PLP artefacts, extracts metadata from the .rds
#             files produced by PatientLevelPrediction.
# Returns a named list or NULL when no reference metadata is found.
# -----------------------------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x)) y else x   # null-coalescing helper

read_model_reference <- function(study_params_raw, model_dir = "model") {

  # Tier 1: YAML-declared reference (type-agnostic — integer score, PLP, or any other)
  if (!is.null(study_params_raw$model_reference)) {
    ref <- study_params_raw$model_reference
    ref[["source"]] <- "study_params.yaml"
    return(ref)
  }

  # Tier 2: PLP .rds artefacts (legacy / supplemental fallback)
  if (!dir.exists(model_dir)) return(NULL)

  read_rds_safe <- function(path) tryCatch(readRDS(path), error = function(e) NULL)

  pop_settings <- read_rds_safe(file.path(model_dir, "populationSettings.rds"))
  meta_data    <- read_rds_safe(file.path(model_dir, "metaData.rds"))
  var_imp      <- read_rds_safe(file.path(model_dir, "varImp.rds"))
  cohort_id    <- read_rds_safe(file.path(model_dir, "cohortId.rds"))
  outcome_id   <- read_rds_safe(file.path(model_dir, "outcomeId.rds"))

  if (is.null(pop_settings) && is.null(meta_data) && is.null(var_imp)) return(NULL)

  outcome_ids <- NULL
  if (!is.null(meta_data) && !is.null(meta_data$call$outcomeIds)) {
    outcome_ids <- as.integer(meta_data$call$outcomeIds)
  } else if (!is.null(outcome_id)) {
    outcome_ids <- as.integer(outcome_id)
  }

  total_covariates <- included_covariates <- NA_integer_
  if (is.data.frame(var_imp)) {
    total_covariates    <- nrow(var_imp)
    included_covariates <- sum(var_imp$included == 1, na.rm = TRUE)
  }

  covariate_flags <- character(0)
  if (!is.null(meta_data) && !is.null(meta_data$call$covariateSettings)) {
    cs <- meta_data$call$covariateSettings
    if (length(cs) >= 1)
      covariate_flags <- names(cs[[1]])[vapply(cs[[1]], isTRUE, logical(1))]
  }

  list(
    source                             = "plp_rds",
    model_type                         = "plp",
    source_folder                      = model_dir,
    target_cohort_id                   = as.integer(cohort_id %||% pop_settings$cohortId),
    outcome_ids                        = outcome_ids,
    risk_window_start_day              = as.integer(pop_settings$riskWindowStart %||% NA_integer_),
    risk_window_end_day                = as.integer(pop_settings$riskWindowEnd   %||% NA_integer_),
    washout_period_days                = as.integer(pop_settings$washoutPeriod   %||% NA_integer_),
    first_exposure_only                = isTRUE(pop_settings$firstExposureOnly),
    remove_subjects_with_prior_outcome = isTRUE(pop_settings$removeSubjectsWithPriorOutcome),
    total_covariates                   = total_covariates,
    included_covariates                = included_covariates,
    covariate_flags                    = covariate_flags
  )
}

model_reference <- read_model_reference(study_params_raw)


# -----------------------------------------------------------------------------
# Chunk 2 - Resolve required vs. optional artifact list for this design
# -----------------------------------------------------------------------------
required_artifacts  <- list()
optional_artifacts  <- list()

# Target cohort is always required.
required_artifacts[["target_cohort"]] <- target_cohort_sql_path

# Comparator, outcome, and covariate files depend on study design.
if (study_design %in% c("causal_inference", "descriptive") && comparator_enabled) {
  if (!is.null(comparator_cohort_sql_path)) {
    required_artifacts[["comparator_cohort"]] <- comparator_cohort_sql_path
  } else {
    warning(
      "[Step 2] study_design = '", study_design, "' with comparator enabled requires a comparator SQL file.\n",
      "  Set comparator.sql_file in study_params.yaml or change study_design."
    )
  }
} else if (study_design %in% c("causal_inference", "descriptive") && !comparator_enabled) {
  warning(
    "[Step 2] study_design = '", study_design, "' typically requires a comparator cohort.\n",
    "  Set comparator.cohort_id in study_params.yaml or change study_design."
  )
}

if (study_design %in% c("prognostic_model", "causal_inference")) {
  if (!is.null(outcome_cohort_sql_path)) {
    required_artifacts[["outcome_cohort"]] <- outcome_cohort_sql_path
  } else {
    warning(
      "[Step 2] study_design = '", study_design, "' requires an outcome cohort.\n",
      "  TODO [PHENOTYPE PATHS]: Set outcome_cohort_sql_path or change study_design."
    )
  }
}

if (!is.null(covariate_definitions_path))
  optional_artifacts[["covariate_definitions"]] <- covariate_definitions_path
if (!is.null(covariate_concepts_path))
  optional_artifacts[["covariate_concepts"]] <- covariate_concepts_path


# -----------------------------------------------------------------------------
# Chunk 3 - File existence validation
# -----------------------------------------------------------------------------
missing_required <- Filter(function(p) !file.exists(p), required_artifacts)
if (length(missing_required) > 0) {
  stop(
    "Missing required phenotype artifact(s):\n",
    paste0("  [", names(missing_required), "] ", unlist(missing_required), collapse = "\n"),
    "\nCreate the file(s) or update the sql_file paths in study_params.yaml."
  )
}

missing_optional <- Filter(function(p) !file.exists(p), optional_artifacts)
if (length(missing_optional) > 0) {
  warning(
    "[Step 2] Optional covariate file(s) not found (set path to NULL to suppress):\n",
    paste0("  [", names(missing_optional), "] ", unlist(missing_optional), collapse = "\n")
  )
}


# -----------------------------------------------------------------------------
# Chunk 4 - Load and validate SQL artifacts
# -----------------------------------------------------------------------------
load_sql <- function(path, label) {
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  if (nchar(trimws(sql)) == 0)
    stop(label, " SQL file is empty: ", path)
  # Warn if placeholder concept_id = 0 values are still present.
  # For parameterized templates this is the YAML-level check; for custom SQL
  # files this catches any hardcoded 0 values that bypass YAML.
  if (grepl("concept_id\\s*=\\s*0\\b|IN\\s*\\(\\s*0\\s*\\)", sql)) {
    warning(
      "[Step 2] ", label, " (", path, ") may contain placeholder concept_id = 0 values.\n",
      "  For standard templates: set concept IDs in study_params.yaml.\n",
      "  For custom SQL files: replace hardcoded 0 values with verified OMOP concept IDs."
    )
  }
  sql
}

target_cohort_sql   <- load_sql(target_cohort_sql_path, "Target cohort")
comparator_cohort_sql <- if (comparator_enabled && !is.null(comparator_cohort_sql_path) && file.exists(comparator_cohort_sql_path))
  load_sql(comparator_cohort_sql_path, "Comparator cohort") else NULL
outcome_cohort_sql  <- if (!is.null(outcome_cohort_sql_path) && file.exists(outcome_cohort_sql_path))
  load_sql(outcome_cohort_sql_path, "Outcome cohort") else NULL


# -----------------------------------------------------------------------------
# Chunk 5 - Load and validate covariate definition files (if provided)
# -----------------------------------------------------------------------------
covariate_definitions <- NULL
covariate_concepts    <- NULL

if (!is.null(covariate_definitions_path) && file.exists(covariate_definitions_path)) {
  covariate_definitions <- read.csv(covariate_definitions_path,
                                    stringsAsFactors = FALSE, comment.char = "#")

  required_cols <- c("covariate_id", "covariate_name", "domain",
                     "lookback_start_day", "lookback_end_day", "min_count")
  if (require_points) required_cols <- c(required_cols, "points")
  missing_cols  <- setdiff(required_cols, names(covariate_definitions))
  if (length(missing_cols) > 0)
    stop("Covariates file is missing required columns: ",
         paste(missing_cols, collapse = ", "))
  if (!require_points && !("points" %in% names(covariate_definitions)))
    message("[Step 2] No 'points' column in covariates — fine unless analyses.integer_risk_score = true.")

  # Warn on placeholder rows (covariate_id still matching template defaults).
  placeholder_ids <- grep("^covariate_[0-9]+$", covariate_definitions$covariate_id, value = TRUE)
  if (length(placeholder_ids) > 0)
    warning(
      "[Step 2] Covariates file still contains ", length(placeholder_ids),
      " placeholder row(s): ", paste(placeholder_ids, collapse = ", "), ".\n",
      "  TODO [COVARIATES]: Replace template example rows with your study covariates."
    )
}

if (!is.null(covariate_concepts_path) && file.exists(covariate_concepts_path)) {
  covariate_concepts <- read.csv(covariate_concepts_path,
                                 stringsAsFactors = FALSE, comment.char = "#")

  required_cols <- c("covariate_id", "concept_id", "include_descendants")
  missing_cols  <- setdiff(required_cols, names(covariate_concepts))
  if (length(missing_cols) > 0)
    stop("Covariate concepts file is missing required columns: ",
         paste(missing_cols, collapse = ", "))

  # Cross-check: every concept row must reference a known covariate.
  if (!is.null(covariate_definitions)) {
    unknown_ids <- setdiff(unique(covariate_concepts$covariate_id),
                           unique(covariate_definitions$covariate_id))
    if (length(unknown_ids) > 0) {
      # Detect whether template placeholder rows (covariate_1, covariate_2, …) are
      # still present.  When they are, a mismatch between the two CSVs is expected
      # and should not halt execution — emit a warning so the analyst can proceed
      # with setup before Step 8.
      placeholder_mode <- any(grepl("^covariate_[0-9]+$", covariate_definitions$covariate_id))
      if (placeholder_mode) {
        warning(
          "[Step 2] Covariate concepts file references unknown covariate_id values: ",
          paste(unknown_ids, collapse = ", "), ".\n",
          "  Template placeholder rows are still present, so this is reported as a warning.\n",
          "  Replace template rows in both covariate files before Step 8."
        )
      } else {
        stop("Covariate concepts file references unknown covariate_id values: ",
             paste(unknown_ids, collapse = ", "))
      }
    }
  }

  placeholder_concepts <- sum(covariate_concepts$concept_id %in% c(0, "0"), na.rm = TRUE)
  if (placeholder_concepts > 0)
    warning(
      "[Step 2] Covariate concepts file contains ", placeholder_concepts,
      " placeholder concept_id = 0 value(s).\n",
      "  TODO [COVARIATES]: Replace with verified standard OMOP concept IDs before Step 8."
    )
}


# -----------------------------------------------------------------------------
# Chunk 6 - Manifest output
# -----------------------------------------------------------------------------
cat("=================================================================\n")
cat("Step 2 complete: phenotype artifacts loaded and validated.\n")
cat("=================================================================\n")
cat("Study design     : ", study_design, "\n", sep = "")
cat("\nCohort artifacts:\n")
cat("  [target]     ", target_cohort_sql_path,
    "  (", nchar(target_cohort_sql), " chars)\n", sep = "")
if (!is.null(comparator_cohort_sql))
  cat("  [comparator] ", comparator_cohort_sql_path,
      "  (", nchar(comparator_cohort_sql), " chars)\n", sep = "")
if (!is.null(outcome_cohort_sql))
  cat("  [outcome]    ", outcome_cohort_sql_path,
      "  (", nchar(outcome_cohort_sql), " chars)\n", sep = "")
cat("\nCovariate definitions:\n")
if (!is.null(covariate_definitions)) {
  cat("  covariates   : ", covariate_definitions_path,
      "  (", nrow(covariate_definitions), " rows)\n", sep = "")
} else {
  cat("  covariates   : not provided",
      if (study_design %in% c("prognostic_model", "causal_inference"))
        " — define covariates in Step 8 using FeatureExtraction" else "", "\n")
}
if (!is.null(covariate_concepts)) {
  cat("  concepts     : ", covariate_concepts_path,
      "  (", nrow(covariate_concepts), " rows)\n", sep = "")
}
cat("\nStudy parameters:\n")
cat("  Prediction window  : ",
    if (!is.null(prediction_window_days)) paste0(prediction_window_days, " days") else "not set",
    "\n", sep = "")
cat("  Min prior obs days : ",
    if (!is.null(min_prior_observation_days)) paste0(min_prior_observation_days, " days") else "not set",
    "\n", sep = "")
cat("  Covariate lookback : ",
    if (!is.null(covariate_lookback_days)) paste0(covariate_lookback_days, " days") else "not set",
    "\n", sep = "")
if (!is.null(model_reference)) {
  cat("\nModel reference (", model_reference$source, "):\n", sep = "")
  if (!is.null(model_reference$model_type))
    cat("  Type             : ", model_reference$model_type, "\n", sep = "")
  if (!is.null(model_reference$score_name) && nzchar(model_reference$score_name %||% ""))
    cat("  Score / model    : ", model_reference$score_name, "\n", sep = "")
  if (!is.null(model_reference$source_paper) && nzchar(model_reference$source_paper %||% ""))
    cat("  Source paper     : ", model_reference$source_paper, "\n", sep = "")
  if (!is.null(model_reference$time_at_risk_days) && !is.na(model_reference$time_at_risk_days))
    cat("  Time at risk     : ", model_reference$time_at_risk_days, " days\n", sep = "")
  if (!is.null(model_reference$original_n) && !is.na(model_reference$original_n))
    cat("  Original N       : ", model_reference$original_n, "\n", sep = "")
  if (!is.null(model_reference$original_event_rate) && !is.na(model_reference$original_event_rate))
    cat("  Original evt rate: ", model_reference$original_event_rate, "\n", sep = "")
  if (!is.null(model_reference$original_c_statistic) && !is.na(model_reference$original_c_statistic))
    cat("  C-statistic      : ", model_reference$original_c_statistic, "\n", sep = "")
  # PLP .rds supplement fields
  if (!is.null(model_reference$risk_window_end_day))
    cat("  Risk window      : day ", model_reference$risk_window_start_day %||% 0,
        " – ", model_reference$risk_window_end_day, "\n", sep = "")
  if (!is.null(model_reference$total_covariates) && !is.na(model_reference$total_covariates))
    cat("  Covariates       : ", model_reference$included_covariates, " of ",
        model_reference$total_covariates, " in model\n", sep = "")
}
cat("\nNext step: Rscript workflow/03_generate_synthea_module_artifacts.R\n")
cat("           (or skip to Step 7 if not using Synthea)\n")


# -----------------------------------------------------------------------------
# Chunk 7 - Study registry
# Purpose:
# - Register this study in the workspace-level studies.yaml index on first run.
# - Subsequent runs are idempotent: already-registered studies are skipped.
# - Fails gracefully when studies.yaml is absent (e.g., standalone repo outside
#   the standard workspace layout).
# Output:
# - Appends one YAML entry to <workspace_root>/studies.yaml.
# -----------------------------------------------------------------------------

# Workspace root is one level above the study repo root (standard layout).
workspace_root <- normalizePath(file.path(getwd(), ".."), mustWork = FALSE)
registry_path  <- file.path(workspace_root, "studies.yaml")

if (!file.exists(registry_path)) {
  message(
    "[Step 2] Study registry not found at: ", registry_path, "\n",
    "         Skipping auto-registration. To enable, create studies.yaml at\n",
    "         the workspace root using the template in synthea-omop-template."
  )
} else {
  study_dir <- basename(getwd())

  # Check for an existing entry by scanning raw text — avoids a hard yaml dep.
  # NOTE: entries are list items ("  - dir: <name>"), so the match must allow
  # for the "- " list marker between the leading whitespace and "dir:", and
  # must anchor on the line end so a prefix (e.g. "foo") can't match "foo-bar".
  registry_text <- paste(readLines(registry_path, warn = FALSE), collapse = "\n")
  already_registered <- grepl(
    paste0("(^|\\n)\\s*-\\s*dir:\\s+['\"]?", study_dir, "['\"]?\\s*(\\n|$)"),
    registry_text,
    perl = TRUE
  )

  if (already_registered) {
    message("[Step 2] Study already registered in studies.yaml: ", study_dir)
  } else {
    # Resolve GitHub remote slug (https://github.com/org/repo or git@github.com:org/repo).
    github_slug <- tryCatch({
      raw <- trimws(system("git remote get-url origin 2>/dev/null", intern = TRUE))
      raw <- sub("\\.git$", "", raw)
      raw <- sub("^https?://github\\.com/", "", raw)
      raw <- sub("^git@github\\.com:", "", raw)
      raw
    }, error = function(e) "")

    new_entry <- paste0(
      "\n  - dir: ", study_dir, "\n",
      "    github: ", github_slug, "\n",
      "    study_name: ", config$study_name, "\n",
      "    study_design: ", config$study_design, "\n",
      "    description: \"\"  # TODO [CONFIG]: add a one-line study description\n",
      "    registered: ", format(Sys.Date(), "%Y-%m-%d"), "\n"
    )

    cat(new_entry, file = registry_path, append = TRUE)
    message("[Step 2] Registered study in studies.yaml: ", study_dir,
            " (", registry_path, ")")
  }
}
