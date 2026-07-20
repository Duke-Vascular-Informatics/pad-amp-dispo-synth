#!/usr/bin/env Rscript
# =============================================================================
# workflow/07_setup_analysis_env.R
#
# Step 7: Verify the analysis environment before running Step 8.
#
# PURPOSE
# -------
# Confirms that every R package required by Step 8 is installed and that the
# SQL Server JDBC driver bundle is present in the project-local drivers/
# folder.  Fails fast with an actionable message so you discover any gaps
# before running the full analysis.
# No editing required — the package list covers all study designs.
#
# This step does NOT install packages. Run setup/install_packages.R first.
#
# PREREQUISITES
# -------------
#   - renv has been initialised (setup/setup_renv.R run once).
#   - Project packages have been installed (setup/install_packages.R run once).
#   - Java >= 11 is installed and JAVA_HOME is configured in config.R.
#
# EXECUTION
# ---------
#   Rscript workflow/07_setup_analysis_env.R
#   (Run from the project root, or source interactively from RStudio.)
# =============================================================================


# -----------------------------------------------------------------------------
# 1. Locate and source the workflow bootstrap
# -----------------------------------------------------------------------------
# Resolves the project root from the --file= argument when called via Rscript,
# and falls back to the conventional relative path when sourced interactively.
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


# -----------------------------------------------------------------------------
# 2. Activate renv
# -----------------------------------------------------------------------------
# Pins every package to the version recorded in renv.lock, ensuring the same
# library state as when the project was last snapshotted.  Safe to call on
# every run — renv is a no-op if already active.
if (file.exists("renv/activate.R")) source("renv/activate.R")


# -----------------------------------------------------------------------------
# 3. Package list
# -----------------------------------------------------------------------------
# All HADES analysis packages and general utilities used by this template are
# verified here. No editing required — Step 7 checks everything at once so
# you discover any installation gaps before running Step 8.
#
# Packages are grouped by role; all are checked regardless of study design.
# If a package is not yet installed, run setup/install_packages.R in a fresh
# R session first.

required <- c(
  # --- OMOP database access (always required) ---
  "DatabaseConnector",          # JDBC connectivity to SQL Server OMOP CDM
  "SqlRender",                  # SQL dialect translation and parameterisation

  # --- HADES analysis packages ---
  "FeatureExtraction",          # patient feature extraction from OMOP CDM;
                                #   required internally by PLP and CohortMethod
  "PatientLevelPrediction",     # supervised learning pipeline: data extraction,
                                #   model training, evaluation (AUROC, calibration)
  "CohortMethod",               # active comparator new-user design; PS matching/
                                #   weighting and outcome modelling
  "CohortDiagnostics",          # cohort phenotype validation: incidence, attrition,
                                #   time distributions, concept prevalence
  "EvidenceSynthesis",          # meta-analysis across databases / sites
  "EmpiricalCalibration",       # p-value and CI calibration using negative controls
  "SelfControlledCaseSeries",   # SCCS design; each patient is their own control

  # --- Discrimination and calibration metrics ---
  "pROC",                       # AUROC with confidence intervals
  "PRROC",                      # area under precision-recall curve (AUPRC)

  # --- Tidyverse data wrangling ---
  "dplyr",                      # filter, mutate, join, summarise
  "tidyr",                      # pivot_longer, pivot_wider, unnest
  "readr",                      # fast CSV reading / writing

  # --- Reporting and output ---
  "ggplot2",                    # calibration plots, ROC curves, feature importance
  "officer",                    # Word (.docx) report generation
  "flextable",                  # formatted tables for Word / HTML output
  "openxlsx",                   # Excel (.xlsx) output with formatting
  "knitr",                      # R Markdown report rendering
  NULL                          # trailing sentinel — allows every line above to
                                # end with a comma safely; filtered out below
)
required <- required[!vapply(required, is.null, logical(1L))]


# -----------------------------------------------------------------------------
# 4. Check packages
# -----------------------------------------------------------------------------
missing_pkgs <- required[
  !vapply(required, requireNamespace, logical(1L), quietly = TRUE)
]

if (length(missing_pkgs) > 0) {
  stop(
    "The following packages required by Step 8 are not installed:\n",
    paste0("  - ", missing_pkgs, collapse = "\n"),
    "\n\nRun setup/install_packages.R in a fresh R session to install them,",
    "\nthen re-run Step 7."
  )
}

message("Package check passed. All ", length(required), " required packages are installed:")
for (pkg in required) {
  ver <- tryCatch(
    as.character(utils::packageVersion(pkg)),
    error = function(e) "?"
  )
  message(sprintf("  %-35s %s", pkg, ver))
}


# -----------------------------------------------------------------------------
# 5. Verify JDBC driver bundle
# -----------------------------------------------------------------------------
# ensure_jdbc_bundle() (R/drivers.R) checks whether the mssql-jdbc runtime jar
# exists in drivers/jdbc-runtime/.  If it does not, it downloads and extracts
# the official Microsoft JDBC zip (once) — subsequent calls are instant.
# This step must succeed before Step 8 can open any database connection.
source("config.R")
source("R/drivers.R")
config <- get_validation_config()
ensure_jdbc_bundle(config)
message("JDBC driver verified: ",
        file.path(config$jdbc_runtime_dir,
                  paste0("mssql-jdbc-", config$sql_server_jdbc_version,
                         ".jre11.jar")))


# -----------------------------------------------------------------------------
# 6. Done
# -----------------------------------------------------------------------------
message("\nStep 7 complete: analysis environment is ready for Step 8.")
message("Next: Rscript workflow/08_run_analysis_and_manuscript_report.R")
