#!/usr/bin/env Rscript
# =============================================================================
# workflow/08_run_analysis_and_manuscript_report.R
#
# Step 8: Run analysis and generate output.
#
# PURPOSE
# -------
# Executes the analysis blocks enabled in study_params.yaml (analyses: section)
# and writes outputs to config$output_folder.
#
# No editing of this script is needed for standard analyses.
# To enable an analysis, set its flag to true in study_params.yaml:
#
#   analyses:
#     cohort_characterization: true   # FeatureExtraction covariate summary
#     prognostic_model:         false  # PatientLevelPrediction LASSO
#     causal_inference:         false  # CohortMethod PS matching
#     integer_risk_score:       false  # custom integer score pipeline
#     word_report:              false  # Word report (run after a pipeline above)
#
# To customise a default analysis (e.g. swap the PLP model algorithm, change
# covariate settings) edit the relevant if-block in Section 7 below.
#
# PREREQUISITES
# -------------
#   - Steps 1–7 completed successfully.
#   - Step 5 (ETL) populated the CDM schema referenced in study_params.yaml.
#   - Step 7 confirmed all required packages are installed.
#
# EXECUTION
# ---------
#   Rscript workflow/08_run_analysis_and_manuscript_report.R
#   Must be run in a FRESH R session (see Java guard in Section 2).
# =============================================================================


# =============================================================================
# 1. Workflow bootstrap
# =============================================================================
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


# =============================================================================
# 2. Java / JDBC session guard
# =============================================================================
# DatabaseConnector uses rJava. The JVM can only be initialised once per R
# session. This guard stops execution immediately if Java-related namespaces
# are already loaded, prompting the analyst to open a fresh session rather
# than getting cryptic JVM errors downstream.
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector", "PatientLevelPrediction",
    "CohortMethod", "FeatureExtraction"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session. Already loaded: ",
    paste(loaded_java_ns, collapse = ", ")
  )
}


# =============================================================================
# 3. Activate renv, load config, and source helper modules
# =============================================================================
# Suppress the renv "project has not been synchronized" diagnostic that fires
# when the lockfile differs from the library — expected during analysis runs.
Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE")
if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")       # get_validation_config()
source("R/drivers.R")    # configure_java(), ensure_jdbc_bundle()
source("R/connection.R") # build_connection_details()
source("R/cohorts.R")    # ensure_results_schema(), build_cohorts()

# Read config before Java initialisation (only YAML parsing; no JDBC yet).
config <- get_validation_config()

# Source analysis-specific helper modules for the analyses that are enabled.
# Load order matters: risk_score_pipeline before plp_validation_pipeline
# (both may export helpers used by report_extended), and report_extended last
# so it can reference any function defined by the earlier pipelines.
if (config$run_integer_risk_score)   source("R/risk_score_pipeline.R")
if (config$run_plp_model_validation) source("R/plp_validation_pipeline.R")
if (config$run_word_report)          source("R/report_extended.R")
if (config$run_cohort_characterization) library(CohortDiagnostics)


# =============================================================================
# 4. Initialise Java and load packages
# =============================================================================
# configure_java() sets the JVM heap and JDBC class path; must run before any
# library() call that depends on rJava.
configure_java(config)

# Core database packages — always required.
library(DatabaseConnector)
library(SqlRender)

# Load analysis packages based on the flags in study_params.yaml.
# FeatureExtraction is a shared dependency for PLP, CohortMethod, and
# CohortDiagnostics and is loaded once when any of those are enabled.
# CohortDiagnostics is gated on run_cohort_characterization because it is
# used in the Section 5 characterization block (not the separate diagnostics block).
if (config$run_cohort_characterization) {
  library(CohortDiagnostics)
}
if (config$run_cohort_characterization ||
    config$run_prognostic_model        ||
    config$run_causal_inference) {
  library(FeatureExtraction)
}
if (config$run_prognostic_model) {
  library(PatientLevelPrediction)
  library(pROC)    # AUROC with confidence intervals
  library(PRROC)   # area under precision-recall curve
}
if (config$run_causal_inference) {
  library(CohortMethod)
  library(EmpiricalCalibration)
}
if (config$run_integer_risk_score || config$run_word_report ||
    config$run_descriptive_ed_analysis) {
  library(ggplot2)
  library(officer)
  library(flextable)
}
if (config$run_descriptive_ed_analysis) {
  library(pROC)
  library(PRROC)
  library(scales)
}
if (config$run_plp_model_validation) {
  library(PatientLevelPrediction)
  library(FeatureExtraction)
  library(Andromeda)
  library(reticulate)
  library(jsonlite)
  library(Matrix)  # sparseMatrix() for feature alignment
  library(pROC)    # AUROC computation in pipeline metrics
  library(PRROC)   # AUPRC computation in pipeline metrics
}
library(dplyr)   # data wrangling — broadly useful
library(readr)   # CSV I/O


# =============================================================================
# 5. Build database connection
# =============================================================================
# build_connection_details() returns a DatabaseConnector ConnectionDetails
# object (credentials only — no open connection yet) from the settings in
# config.R. All downstream HADES functions accept this object and manage their
# own connections internally.
message("[Step 8] Building connection details ...")
connection_details <- build_connection_details(config)


# =============================================================================
# 5b. Verify standard OMOP concept IDs
# =============================================================================
# Checks every concept ID used in this study against omop_vocab.concept at
# runtime, before any cohort or analysis work begins.
#
# Concept IDs are collected from two sources:
#   1. covariates/covariate_concepts.csv   — all covariate and risk score IDs
#   2. study_params.yaml                   — cohort ancestor concept IDs
#      (target index event, target washout, outcome, and comparator if enabled)
#
# For each concept the check confirms:
#   (a) concept_id exists in the connected vocabulary
#   (b) standard_concept is 'S' (Standard) or 'C' (Classification — acceptable
#       for ATC drug-class ancestors used in drug rollup queries)
#   (c) invalid_reason IS NULL (concept is not deprecated or replaced)
#
# A WARNING is emitted for any failing concept (not stop()) so that runs on
# vocabularies with minor version differences still complete; the analyst is
# alerted to review the flagged concept before publishing results.
#
# The function is silent and returns NULL when:
#   - no concept IDs are found in either source (e.g. template placeholder run)
#   - the database connection cannot be established
#   - omop_vocab.concept returns no rows (vocabulary schema unavailable)
verify_omop_concepts <- function(
    connection_details,
    study_params_path       = "study_params.yaml",
    covariate_concepts_path = "covariates/covariate_concepts.csv"
) {
  message("[Step 8] Verifying OMOP concept IDs against omop_vocab ...")

  concept_ids <- integer(0)

  # ---- Source 1: covariates/covariate_concepts.csv ---------------------------
  # comment.char = "#" strips header comment blocks written above the CSV header
  # row (e.g. study description, verification notes). concept_id values of 0
  # are placeholder rows and are excluded from the check.
  if (file.exists(covariate_concepts_path)) {
    csv_raw <- tryCatch(
      read.csv(covariate_concepts_path, comment.char = "#",
               stringsAsFactors = FALSE, na.strings = c("", "NA")),
      error = function(e) NULL
    )
    if (!is.null(csv_raw) && "concept_id" %in% names(csv_raw)) {
      ids <- suppressWarnings(as.integer(csv_raw$concept_id))
      concept_ids <- c(concept_ids, ids[!is.na(ids) & ids > 0L])
    }
  }

  # ---- Source 2: study_params.yaml cohort ancestor concept IDs ---------------
  # Pulls all ancestor_concept_ids declared for the target index event, target
  # washout, outcome cohort, and comparator (when enabled). These IDs drive the
  # cohort SQL templates and are the most critical to verify.
  if (file.exists(study_params_path)) {
    p <- tryCatch(yaml::read_yaml(study_params_path), error = function(e) NULL)
    if (!is.null(p)) {
      yaml_ids <- c(
        unlist(p$target$index_event$ancestor_concept_ids),
        unlist(p$target$washout$ancestor_concept_ids),
        unlist(p$outcome$ancestor_concept_ids),
        # Include comparator only when it is enabled (cohort_id is not null/NA).
        if (!is.null(p$comparator$cohort_id) && !is.na(p$comparator$cohort_id))
          unlist(p$comparator$index_event$ancestor_concept_ids)
      )
      yaml_ids <- suppressWarnings(as.integer(yaml_ids))
      concept_ids <- c(concept_ids, yaml_ids[!is.na(yaml_ids) & yaml_ids > 0L])
    }
  }

  concept_ids <- unique(concept_ids)

  if (length(concept_ids) == 0L) {
    message("[Step 8] No concept IDs found to verify — skipping check.")
    return(invisible(NULL))
  }

  # ---- Query omop_vocab -------------------------------------------------------
  conn <- tryCatch(DatabaseConnector::connect(connection_details),
                   error = function(e) NULL)
  if (is.null(conn)) {
    warning("[Step 8] Could not connect to verify concept IDs — skipping check.")
    return(invisible(NULL))
  }
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  id_csv <- paste(concept_ids, collapse = ", ")
  sql <- paste0(
    "SELECT concept_id, concept_name, vocabulary_id, domain_id, ",
    "       standard_concept, invalid_reason ",
    "FROM omop_vocab.concept ",
    "WHERE concept_id IN (", id_csv, ")"
  )
  vocab <- tryCatch(
    DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = TRUE),
    error = function(e) NULL
  )

  if (is.null(vocab) || nrow(vocab) == 0L) {
    warning("[Step 8] omop_vocab.concept returned no rows — concept check skipped.")
    return(invisible(NULL))
  }

  # ---- Merge and evaluate -----------------------------------------------------
  # All concept IDs from both sources are in the registry; left join so that IDs
  # absent from the vocabulary appear as MISSING rows.
  registry <- data.frame(concept_id = concept_ids, stringsAsFactors = FALSE)
  result   <- merge(registry, vocab, by.x = "concept_id", by.y = "conceptId",
                    all.x = TRUE)

  result$status <- mapply(function(std_actual, invalid) {
    if (is.na(std_actual))             return("MISSING")
    if (!is.na(invalid))               return("DEPRECATED")
    if (std_actual %in% c("S", "C"))   return("OK")
    return("NOT_STANDARD")
  }, result$standardConcept, result$invalidReason)

  # ---- Print verification table -----------------------------------------------
  message(sprintf("\n  OMOP Concept Verification (%d concepts)\n  %s",
                  nrow(result), strrep("-", 90)))
  for (i in seq_len(nrow(result))) {
    r   <- result[i, ]
    tag <- if (r$status == "OK") "  OK " else paste0(" !!! ", r$status)
    message(sprintf("  [%s] %9d  %-14s  %-8s  %s",
      tag,
      r$concept_id,
      ifelse(is.na(r$vocabularyId),    "NOT FOUND", r$vocabularyId),
      ifelse(is.na(r$standardConcept), "?",         r$standardConcept),
      ifelse(is.na(r$conceptName),     "(no match in vocab)", r$conceptName)
    ))
  }
  message("  ", strrep("-", 90))

  # ---- Warn on any failures ---------------------------------------------------
  failures <- result[result$status != "OK", ]
  if (nrow(failures) > 0L) {
    warning(
      "[Step 8] ", nrow(failures), " concept(s) failed the standard concept check:\n",
      paste0(
        sprintf("    concept_id %d (%s): %s",
          failures$concept_id, failures$status,
          ifelse(is.na(failures$conceptName), "NOT FOUND IN VOCAB", failures$conceptName)
        ),
        collapse = "\n"
      ),
      "\nReview these concept IDs before publishing results."
    )
  } else {
    message("  All ", nrow(result), " concept IDs verified as standard and active.\n")
  }

  invisible(result)
}

# Verify all OMOP concept IDs (covariate_concepts.csv + study_params.yaml
# cohort ancestors) before any cohort or analysis work.
verify_omop_concepts(connection_details)


# =============================================================================
# 6. Prepare results schema and instantiate cohorts
# =============================================================================
# ensure_results_schema() creates the results schema and cohort table if they
# do not already exist (idempotent — safe to re-run).
#
# build_cohorts() renders and executes the SqlRender-parameterised cohort SQL
# files declared in study_params.yaml. Each SQL deletes existing rows before
# inserting, so re-runs produce a fresh, non-duplicated cohort.
# Comparator and outcome cohorts are skipped when their IDs are NA.
message("[Step 8] Preparing results schema and instantiating cohorts ...")
cohort_conn <- DatabaseConnector::connect(connection_details)
ensure_results_schema(cohort_conn, config)
build_cohorts(cohort_conn, config)
DatabaseConnector::disconnect(cohort_conn)
message("[Step 8] Cohorts instantiated.")


# =============================================================================
# 7. ANALYSIS
# =============================================================================
# Each block below runs only when its flag is true in study_params.yaml.
# Customise default settings (e.g. model algorithm, covariate settings) by
# editing the relevant block here.

dir.create(config$output_folder, recursive = TRUE, showWarnings = FALSE)

# -----------------------------------------------------------------------------
# Cohort diagnostics — CohortDiagnostics phenotype QA
#
# Run this before any primary analysis to validate cohort phenotypes.
# Produces incidence rates, concept set breakdowns, orphan concepts, and
# cohort overlap — the same outputs Strategus requires before running HADES
# analyses in a network study.
#
# Output: a SQLite results file written to config$output_folder/cohort_diagnostics/
# View results with: CohortDiagnostics::launchDiagnosticsExplorer(
#   sqliteDbPath = file.path(config$output_folder, "cohort_diagnostics",
#                            "MergedCohortDiagnosticsData.sqlite"))
#
# NOTE: CohortDiagnostics expects cohorts to be already instantiated in the
# cohort table (Step 6 above). runInclusionStatistics requires the cohort
# attrition table populated by CohortGenerator; set to FALSE when using the
# custom SQL instantiation path (build_cohorts).
# -----------------------------------------------------------------------------
if (config$run_cohort_diagnostics) {
  message("[Step 8] Running cohort diagnostics (CohortDiagnostics) ...")

  diag_output_folder <- file.path(config$output_folder, "cohort_diagnostics")
  dir.create(diag_output_folder, recursive = TRUE, showWarnings = FALSE)

  # Build the cohort reference table that CohortDiagnostics expects:
  # one row per cohort, with cohortId and cohortName columns.
  cohort_ids <- c(config$target_cohort_id)
  cohort_names <- c("Target")
  if (!is.na(config$comparator_cohort_id)) {
    cohort_ids   <- c(cohort_ids,   config$comparator_cohort_id)
    cohort_names <- c(cohort_names, "Comparator")
  }
  if (!is.na(config$outcome_cohort_id)) {
    cohort_ids   <- c(cohort_ids,   config$outcome_cohort_id)
    cohort_names <- c(cohort_names, "Outcome")
  }
  cohort_ref <- data.frame(
    cohortId   = cohort_ids,
    cohortName = cohort_names,
    stringsAsFactors = FALSE
  )

  # executeDiagnostics() connects, extracts diagnostics, and writes an
  # exportFolder of CSV files.  exportToCsv = TRUE, then merge into SQLite
  # for the Shiny explorer.  runInclusionStatistics is FALSE here because we
  # instantiate cohorts via custom SQL (no CohortGenerator attrition table).
  CohortDiagnostics::executeDiagnostics(
    cohortDefinitionSet    = cohort_ref,
    connectionDetails      = connection_details,
    cdmDatabaseSchema      = config$cdm_schema,
    cohortDatabaseSchema   = config$results_schema,
    cohortTable            = config$cohort_table,
    exportFolder           = diag_output_folder,
    databaseId             = config$cdm_database_id,
    databaseName           = config$cdm_database_name,
    databaseDescription    = config$cdm_database_description,
    runInclusionStatistics = FALSE,  # requires CohortGenerator attrition table
    runIncludedSourceConcepts  = TRUE,
    runOrphanConcepts          = TRUE,
    runTimeSeries              = FALSE,  # slow on large CDMs; enable when needed
    runVisitContext            = TRUE,
    runBreakdownIndexEvents    = TRUE,
    runIncidenceRate           = TRUE,
    runCohortRelationship      = TRUE,
    runTemporalCohortCharacterization = FALSE,  # very slow; enable selectively
    minCellCount               = 5L
  )

  # Merge CSV exports into a single SQLite file for the Shiny explorer.
  CohortDiagnostics::createMergedResultsFile(
    dataFolder   = diag_output_folder,
    sqliteDbPath = file.path(diag_output_folder, "MergedCohortDiagnosticsData.sqlite")
  )

  message(
    "[Step 8] Cohort diagnostics complete.\n",
    "  Launch explorer: CohortDiagnostics::launchDiagnosticsExplorer(\n",
    "    sqliteDbPath = '",
    file.path(diag_output_folder, "MergedCohortDiagnosticsData.sqlite"),
    "')"
  )
}


# -----------------------------------------------------------------------------
# Cohort characterization — FeatureExtraction default covariate summary
# -----------------------------------------------------------------------------
if (config$run_cohort_characterization) {
  message("[Step 8] Running cohort characterization ...")

  # createDefaultCovariateSettings() extracts demographics, conditions, drugs,
  # and procedures across standard OHDSI lookback windows. Swap for
  # createCovariateSettings() to specify individual domains and windows.
  covariate_settings <- FeatureExtraction::createDefaultCovariateSettings()

  covariate_data <- FeatureExtraction::getDbCovariateData(
    connectionDetails    = connection_details,
    cdmDatabaseSchema    = config$cdm_schema,
    cohortDatabaseSchema = config$results_schema,
    cohortTable          = config$cohort_table,
    cohortId             = config$target_cohort_id,
    rowIdField           = "subject_id",
    covariateSettings    = covariate_settings
  )

  FeatureExtraction::saveCovariateData(
    covariateData = covariate_data,
    file          = file.path(config$output_folder, "covariate_data")
  )
  message("[Step 8] Cohort characterization complete. ",
          "Saved to: ", file.path(config$output_folder, "covariate_data"))
}


# -----------------------------------------------------------------------------
# Prognostic model — PatientLevelPrediction (LASSO logistic regression default)
# To change the model algorithm replace setLassoLogisticRegression() with
# setRandomForest(), setGradientBoostingMachine(), etc.
# -----------------------------------------------------------------------------
if (config$run_prognostic_model) {
  message("[Step 8] Running prognostic model (PatientLevelPrediction) ...")

  covariate_settings <- FeatureExtraction::createDefaultCovariateSettings()

  # Study population settings — use study_params.yaml values for the key
  # time windows so this block requires no editing for most studies.
  population_settings <- PatientLevelPrediction::createStudyPopulationSettings(
    washoutPeriod                  = config$min_prior_observation_days,
    firstExposureOnly              = TRUE,
    removeSubjectsWithPriorOutcome = TRUE,
    priorOutcomeLookback           = config$min_prior_observation_days,
    riskWindowStart                = 1L,
    riskWindowEnd                  = config$prediction_window_days,
    startAnchor                    = "cohort start",
    endAnchor                      = "cohort start",
    minTimeAtRisk                  = 1L,
    requireTimeAtRisk              = TRUE
  )

  plp_data <- PatientLevelPrediction::getPlpData(
    databaseDetails = PatientLevelPrediction::createDatabaseDetails(
      connectionDetails    = connection_details,
      cdmDatabaseSchema    = config$cdm_schema,
      cohortDatabaseSchema = config$results_schema,
      cohortTable          = config$cohort_table,
      targetId             = config$target_cohort_id,
      outcomeIds           = config$outcome_cohort_id
    ),
    covariateSettings        = covariate_settings,
    restrictPlpDataToIPeriod = FALSE
  )

  results <- PatientLevelPrediction::runPlp(
    plpData            = plp_data,
    outcomeId          = config$outcome_cohort_id,
    analysisId         = config$study_name,
    analysisName       = config$cdm_database_name,
    populationSettings = population_settings,
    splitSettings      = PatientLevelPrediction::createDefaultSplitSetting(
                           testFraction = 0.25, nfold = 3L),
    sampleSettings            = PatientLevelPrediction::createSampleSettings(),
    featureEngineeringSettings = PatientLevelPrediction::createFeatureEngineeringSettings(),
    preprocessSettings        = PatientLevelPrediction::createPreprocessSettings(),
    modelSettings             = PatientLevelPrediction::setLassoLogisticRegression(),
    logSettings               = PatientLevelPrediction::createLogSettings(),
    executeSettings           = PatientLevelPrediction::createExecuteSettings(
                                  runSplitData          = TRUE,
                                  runSampleData         = TRUE,
                                  runfeatureEngineering = TRUE,
                                  runPreprocessData     = TRUE,
                                  runModelDevelopment   = TRUE,
                                  runCovariateSummary   = TRUE),
    saveDirectory      = config$output_folder
  )

  message("[Step 8] Prognostic model complete. ",
          "Results saved to: ", config$output_folder)
}


# -----------------------------------------------------------------------------
# Causal inference — CohortMethod (propensity score matching, Cox outcome model)
# Requires comparator.cohort_id set in study_params.yaml.
# -----------------------------------------------------------------------------
if (config$run_causal_inference) {
  if (is.na(config$comparator_cohort_id)) {
    warning("[Step 8] run_causal_inference = TRUE but comparator_cohort_id is NA. ",
            "Set comparator.cohort_id in study_params.yaml and re-run.")
  } else {
    message("[Step 8] Running causal inference (CohortMethod) ...")

    # Exclude the exposure concept IDs from the propensity score covariate set
    # to avoid conditioning on the treatment itself.
    covariate_settings <- FeatureExtraction::createDefaultCovariateSettings(
      excludedCovariateConceptIds = config$target_index_concept_ids,
      addDescendantsToExclude     = TRUE
    )

    cm_data <- CohortMethod::getDbCohortMethodData(
      connectionDetails      = connection_details,
      cdmDatabaseSchema      = config$cdm_schema,
      targetId               = config$target_cohort_id,
      comparatorId           = config$comparator_cohort_id,
      outcomeIds             = config$outcome_cohort_id,
      exposureDatabaseSchema = config$results_schema,
      exposureTable          = config$cohort_table,
      outcomeDatabaseSchema  = config$results_schema,
      outcomeTable           = config$cohort_table,
      covariateSettings      = covariate_settings
    )

    study_pop <- CohortMethod::createStudyPopulation(
      cohortMethodData = cm_data,
      outcomeId        = config$outcome_cohort_id,
      riskWindowStart  = 1L,
      startAnchor      = "cohort start",
      riskWindowEnd    = config$prediction_window_days,
      endAnchor        = "cohort start"
    )

    ps_model    <- CohortMethod::createPs(cm_data, study_pop)
    matched_pop <- CohortMethod::matchOnPs(
      ps_model,
      caliper      = 0.2,
      caliperScale = "standardized logit"
    )

    outcome_model <- CohortMethod::fitOutcomeModel(
      population = matched_pop,
      modelType  = "cox"
    )
    print(outcome_model)

    # Persist the data and model for downstream review / meta-analysis.
    CohortMethod::saveCohortMethodData(
      cm_data,
      file.path(config$output_folder, "cm_data")
    )
    saveRDS(outcome_model,
            file.path(config$output_folder, "outcome_model.rds"))

    # ---- Empirical calibration via negative control outcomes -----------------
    # Follows the Strategus pattern: estimate the log(HR) for each negative
    # control outcome, fit a systematic error model from those null estimates,
    # then apply it to the primary outcome HR to produce a calibrated p-value
    # and calibrated confidence interval.
    #
    # Requires negative_controls.ancestor_concept_ids in study_params.yaml.
    # Skips silently when no negative control concept IDs are defined (the
    # template default) so the causal inference block runs without modification
    # for studies that have not yet specified controls.
    nco_ids <- config$negative_control_concept_ids
    if (length(nco_ids) > 0L) {
      message("[Step 8] Running empirical calibration (",
              length(nco_ids), " negative controls) ...")

      # Fit one outcome model per negative control using the same matched
      # population, study window, and Cox model as the primary analysis.
      nco_estimates <- lapply(nco_ids, function(nco_id) {
        tryCatch({
          nco_pop   <- CohortMethod::createStudyPopulation(
            cohortMethodData = cm_data,
            outcomeId        = nco_id,
            riskWindowStart  = 1L,
            startAnchor      = "cohort start",
            riskWindowEnd    = config$prediction_window_days,
            endAnchor        = "cohort start"
          )
          nco_ps_pop <- CohortMethod::matchOnPs(
            CohortMethod::createPs(cm_data, nco_pop),
            caliper      = 0.2,
            caliperScale = "standardized logit"
          )
          nco_model <- CohortMethod::fitOutcomeModel(
            population = nco_ps_pop,
            modelType  = "cox"
          )
          coef_row <- coef(summary(nco_model$outcomeModelTreatmentEstimate))
          data.frame(
            nco_concept_id  = nco_id,
            log_rr          = coef_row[1, "coef"],
            se_log_rr       = coef_row[1, "se(coef)"],
            stringsAsFactors = FALSE
          )
        }, error = function(e) {
          warning("[Step 8] NCO ", nco_id, " failed: ", conditionMessage(e))
          NULL
        })
      })

      nco_estimates <- do.call(rbind, Filter(Negate(is.null), nco_estimates))

      if (!is.null(nco_estimates) && nrow(nco_estimates) >= 5L) {
        # Fit a null distribution from the NCO log(HR) estimates.
        null_dist <- EmpiricalCalibration::fitNull(
          logRr   = nco_estimates$log_rr,
          seLogRr = nco_estimates$se_log_rr
        )

        # Calibrated p-value for the primary outcome.
        primary_coef <- coef(summary(outcome_model$outcomeModelTreatmentEstimate))
        primary_log_rr  <- primary_coef[1, "coef"]
        primary_se      <- primary_coef[1, "se(coef)"]

        cal_p <- EmpiricalCalibration::calibrateP(
          null    = null_dist,
          logRr   = primary_log_rr,
          seLogRr = primary_se
        )

        # Calibrated 95 % CI using the systematic-error model.
        error_model <- EmpiricalCalibration::convertNullToErrorModel(null_dist)
        cal_ci <- EmpiricalCalibration::calibrateConfidenceInterval(
          logRr      = primary_log_rr,
          seLogRr    = primary_se,
          errorModel = error_model
        )

        calibration_results <- list(
          null_distribution    = null_dist,
          error_model          = error_model,
          nco_estimates        = nco_estimates,
          calibrated_p_value   = cal_p,
          calibrated_ci_lower  = exp(cal_ci$logLb95Rr),
          calibrated_ci_upper  = exp(cal_ci$logUb95Rr),
          uncalibrated_hr      = exp(primary_log_rr),
          uncalibrated_ci_lower = exp(primary_log_rr - 1.96 * primary_se),
          uncalibrated_ci_upper = exp(primary_log_rr + 1.96 * primary_se)
        )

        saveRDS(calibration_results,
                file.path(config$output_folder, "calibration_results.rds"))

        message(sprintf(
          "[Step 8] Empirical calibration complete.\n",
          "  Uncalibrated HR: %.2f (%.2f–%.2f)\n",
          "  Calibrated   HR: %.2f (%.2f–%.2f)  p = %.3f",
          calibration_results$uncalibrated_hr,
          calibration_results$uncalibrated_ci_lower,
          calibration_results$uncalibrated_ci_upper,
          exp((cal_ci$logLb95Rr + cal_ci$logUb95Rr) / 2),
          calibration_results$calibrated_ci_lower,
          calibration_results$calibrated_ci_upper,
          cal_p
        ))
      } else {
        warning(
          "[Step 8] Empirical calibration skipped: fewer than 5 NCO estimates ",
          "converged (", if (is.null(nco_estimates)) 0L else nrow(nco_estimates),
          " of ", length(nco_ids), " controls produced estimates). ",
          "Add more negative controls in study_params.yaml."
        )
      }
    }

    message("[Step 8] Causal inference complete. ",
            "Results saved to: ", config$output_folder)
  }
}


# -----------------------------------------------------------------------------
# Integer risk score validation — custom pipeline
# Reads covariates/covariates.csv and covariates/covariate_concepts.csv.
# Those files must have a points column and verified concept IDs.
# Pass lookup_file= to supply a score → probability table from the derivation
# cohort; omit to use logistic recalibration only.
# -----------------------------------------------------------------------------
if (config$run_integer_risk_score) {
  message("[Step 8] Running integer risk score pipeline ...")
  lookup_path <- file.path("covariates", "risk_lookup.csv")
  # Route pipeline outputs to a named subfolder to keep the top-level output
  # directory clean; absent on a fresh checkout (before Step 6), falls back
  # to logistic recalibration rather than crash.
  run_integer_risk_score_pipeline(
    config,
    connection_details,
    lookup_file    = if (file.exists(lookup_path)) lookup_path else NULL,
    output_folder  = file.path(config$output_folder, "risk_score")
  )
  message("[Step 8] Integer risk score pipeline complete.")
}


# -----------------------------------------------------------------------------
# Word report — requires a pipeline above to have written its outputs first.
# Reads person_level_scores.csv, covariate_summary.csv, and metrics.csv from
# config$output_folder.  All pipeline outputs and the report are written to
# config$output_folder; previous reports are moved to output/archive/ automatically.
# -----------------------------------------------------------------------------
if (config$run_word_report) {
  message("[Step 8] Generating Word report ...")
  # Pipeline output subfolder name varies by study design: the integer risk
  # score / prognostic pipeline writes to output/risk_score, the descriptive
  # ED analysis writes to output/descriptive. .report_descriptive() reads
  # from output_dir/descriptive directly and ignores score_output_dir, but
  # pass the matching subfolder for consistency.
  pipeline_subfolder <- if (config$study_design %in% c("descriptive", "cohort_characterization")) {
    "descriptive"
  } else {
    "risk_score"
  }
  generate_manuscript_report(
    output_dir         = config$output_folder,
    score_output_dir   = file.path(config$output_folder, pipeline_subfolder),
    connection_details = connection_details,
    config             = config
  )
  message("[Step 8] Word report complete.")
}


# -----------------------------------------------------------------------------
# PLP prebuilt model external validation
# Runs an external validation pass for a prebuilt PatientLevelPrediction model
# (linear / LASSO / Ridge) whose coefficients are stored in a standardised spec
# file.  No Python dependency.  See R/plp_validation_pipeline.R for the model
# spec format and required files (model_spec.yaml, covariates/covariates.csv).
# Outputs are written to config$output_folder/plp_validation/.
# -----------------------------------------------------------------------------
if (config$run_plp_model_validation) {
  message("[Step 8] Running PLP model external validation ...")
  run_plp_validation_pipeline(
    config             = config,
    connection_details = connection_details
  )
  message("[Step 8] PLP model external validation complete.")
}


# -----------------------------------------------------------------------------
# Descriptive ED analysis — Table 1, outcomes, KM curve, VA-FI ORs,
# VA-FI discrimination and calibration.
#
# Output: config$output_folder/descriptive/
#   table1.csv / table1.docx            — cohort characteristics
#   outcomes_summary.csv               — LOS, discharge disposition, ED timing
#   discharge_disposition.csv          — breakdown of discharge destination
#   km_ed_cumulative_incidence.png     — 90-day cumulative incidence plot
#   vafi_component_associations.csv    — OR (95% CI) per VA-FI deficit
#   vafi_forest_plot.png               — forest plot of component ORs
#   vafi_discrimination.csv            — C-statistic, HL test
#   vafi_calibration_plot.png          — observed vs expected by decile
# -----------------------------------------------------------------------------
if (config$run_descriptive_ed_analysis) {
  message("[Step 8] Running descriptive ED analysis ...")
  source("scripts/analysis/descriptive_ed_analysis.R")
  run_descriptive_ed_analysis(connection_details, config)
  message("[Step 8] Descriptive ED analysis complete.")
}


# =============================================================================
# 8. DONE
# =============================================================================
enabled <- Filter(isTRUE, list(
  cohort_diagnostics        = config$run_cohort_diagnostics,
  cohort_characterization   = config$run_cohort_characterization,
  prognostic_model          = config$run_prognostic_model,
  causal_inference          = config$run_causal_inference,
  integer_risk_score        = config$run_integer_risk_score,
  word_report               = config$run_word_report,
  plp_model_validation      = config$run_plp_model_validation,
  descriptive_ed_analysis   = config$run_descriptive_ed_analysis
))
message("\n[Step 8] Complete. Analyses run: ",
        if (length(enabled) > 0) paste(names(enabled), collapse = ", ") else "none")
message("[Step 8] Output folder: ", config$output_folder)
