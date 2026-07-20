# =============================================================================
# R/plp_validation_pipeline.R
#
# PURPOSE
# -------
# External validation pipeline for risk models with large feature sets and
# explicit beta coefficients (e.g. LASSO, Ridge, ElasticNet, logistic
# regression, or Cox-derived models stored as a linear predictor).
#
# This template helper is model-family-agnostic: it reads a coefficient vector
# from a standardised model spec file, extracts validation covariates via
# PatientLevelPrediction::getPlpData(), applies the linear predictor entirely
# in R (no Python dependency), and writes the same CSV outputs consumed by
# generate_manuscript_report().
#
# WHEN TO USE THIS PIPELINE
# -------------------------
# Use this pipeline (not risk_score_pipeline.R) when:
#   - The published model has hundreds or thousands of features.
#   - Model coefficients are explicit real-valued betas, not integer points.
#   - The predicted probability is p = logistic(intercept + sum(beta * x)).
#
# MODEL SPEC FORMAT
# -----------------
# The pipeline reads model/model_spec.rds, a named list with:
#   $intercept          — numeric scalar (log-odds intercept term)
#   $betas              — data.frame(covariateId, beta)
#                         covariateId: numeric or integer64 OMOP covariateId
#                         beta:        numeric regression coefficient
#   $covariate_settings — (optional) FeatureExtraction covariateSettings object
#                         used to extract the validation data.  If absent the
#                         caller must pass covariate_settings to the entry point.
#   $population_settings — (optional) PatientLevelPrediction populationSettings
#                          list (from createStudyPopulationSettings).  If absent
#                          a sensible default is used (see .default_pop_settings).
#
# INPUTS
#   config              — validated config list from get_validation_config()
#   connection_details  — DatabaseConnector ConnectionDetails object
#   model_dir           — path to model/ directory (default: "model")
#   covariate_settings  — FeatureExtraction covariateSettings (overrides spec)
#
# OUTPUTS (written to config$output_folder)
#   person_level_scores.csv          — one row per patient
#   covariate_summary.csv            — top-N features by |beta|
#   metrics.csv                      — AUROC, AUPRC, Brier, CalibInt, CalibSlope
#   calibration_table_lookup.csv     — decile calibration bins
#   calibration_lookup.png           — calibration plot
#
# PREREQUISITES
#   - Cohorts built in the results schema (workflow step 6)
#   - renv libraries active (source renv/activate.R before calling)
#   - Packages: PatientLevelPrediction, FeatureExtraction, DatabaseConnector,
#               SqlRender, dplyr, readr, ggplot2, Matrix, pROC, PRROC
# =============================================================================


# =============================================================================
# Helper: logistic function
# =============================================================================

.logistic <- function(x) 1 / (1 + exp(-x))


# =============================================================================
# Helper: load and validate model spec
# =============================================================================

.load_model_spec <- function(model_dir) {
  spec_path <- file.path(model_dir, "model_spec.rds")
  if (!file.exists(spec_path)) {
    stop(
      "[plp_val] Model spec not found: ", spec_path, "\n",
      "Expected model/model_spec.rds — a named list with:\n",
      "  $intercept (numeric scalar)\n",
      "  $betas     (data.frame: covariateId, beta)\n",
      "  $covariate_settings  (optional FeatureExtraction settings)\n",
      "  $population_settings (optional PLP population settings)"
    )
  }

  spec <- readRDS(spec_path)

  if (!is.list(spec) || !all(c("intercept", "betas") %in% names(spec))) {
    stop("[plp_val] model_spec.rds must be a list with $intercept and $betas.")
  }
  if (!is.numeric(spec$intercept) || length(spec$intercept) != 1) {
    stop("[plp_val] model_spec.rds$intercept must be a single numeric value.")
  }
  if (!is.data.frame(spec$betas) || !all(c("covariateId", "beta") %in% names(spec$betas))) {
    stop("[plp_val] model_spec.rds$betas must be a data.frame with columns covariateId and beta.")
  }

  # Normalise covariateId to numeric — bit64::integer64 and plain integer both
  # accepted; coerce once here so downstream merges are type-consistent.
  spec$betas$covariateId <- as.numeric(spec$betas$covariateId)
  spec$betas$beta        <- as.numeric(spec$betas$beta)

  message("[plp_val] Model spec loaded: ", nrow(spec$betas), " features, ",
          "intercept = ", round(spec$intercept, 4))
  spec
}


# =============================================================================
# Helper: default population settings (risk window 0–30 days, no washout)
# =============================================================================
# Override by supplying population_settings in model_spec.rds or by passing
# pop_settings to run_plp_validation_pipeline().

.default_pop_settings <- function() {
  PatientLevelPrediction::createStudyPopulationSettings(
    washoutPeriod                  = 0L,
    firstExposureOnly              = FALSE,
    removeSubjectsWithPriorOutcome = FALSE,
    priorOutcomeLookback           = 99999L,
    riskWindowStart                = 0L,
    riskWindowEnd                  = 365L,   # RESEARCHER_ADJUSTS: match training window
    startAnchor                    = "cohort start",
    endAnchor                      = "cohort start",
    minTimeAtRisk                  = 0L,
    requireTimeAtRisk              = FALSE
  )
}


# =============================================================================
# Helper: compute performance metrics with bootstrap CIs
# =============================================================================
# Returns a data.frame with one row per metric: AUROC, AUPRC, Brier,
# CalibrationIntercept, CalibrationSlope.  All CIs are 95% bootstrap percentile
# intervals (200 resamples — sufficient for reporting, increase for publication).

.compute_metrics <- function(labels, probs, n_boot = 200L) {
  # AUROC with pROC
  roc_obj <- pROC::roc(response  = labels,
                       predictor = probs,
                       quiet     = TRUE,
                       direction = "<")
  auroc   <- as.numeric(pROC::auc(roc_obj))
  roc_ci  <- tryCatch(
    as.numeric(pROC::ci.auc(roc_obj, method = "bootstrap",
                             boot.n = n_boot, progress = "none")),
    error = function(e) c(NA_real_, auroc, NA_real_)
  )

  # AUPRC with PRROC
  pr_obj <- PRROC::pr.curve(scores.class0 = probs[labels == 1],
                             scores.class1 = probs[labels == 0],
                             curve         = FALSE)
  auprc  <- pr_obj$auc.integral

  # Brier score
  brier  <- mean((probs - labels)^2)

  # Calibration intercept and slope (Harrell / Van Calster)
  log_odds <- log(pmax(probs, 1e-6) / pmax(1 - probs, 1e-6))
  cal_fit  <- tryCatch(
    glm(labels ~ log_odds, family = binomial()),
    error = function(e) NULL
  )
  cal_int   <- if (!is.null(cal_fit)) coef(cal_fit)[1] else NA_real_
  cal_slope <- if (!is.null(cal_fit)) coef(cal_fit)[2] else NA_real_

  # Bootstrap CIs for AUPRC and Brier
  set.seed(42L)
  boot_auprc <- numeric(n_boot)
  boot_brier <- numeric(n_boot)
  n          <- length(labels)
  for (i in seq_len(n_boot)) {
    idx       <- sample.int(n, n, replace = TRUE)
    b_lab     <- labels[idx]; b_prob <- probs[idx]
    if (length(unique(b_lab)) < 2L) {
      boot_auprc[i] <- NA_real_; boot_brier[i] <- NA_real_
    } else {
      pr_b          <- PRROC::pr.curve(scores.class0 = b_prob[b_lab == 1],
                                        scores.class1 = b_prob[b_lab == 0],
                                        curve = FALSE)
      boot_auprc[i] <- pr_b$auc.integral
      boot_brier[i] <- mean((b_prob - b_lab)^2)
    }
  }

  data.frame(
    metric   = c("AUROC", "AUPRC", "Brier", "CalibrationIntercept", "CalibrationSlope"),
    value    = c(auroc, auprc, brier, cal_int, cal_slope),
    ci_lower = c(roc_ci[1],
                 quantile(boot_auprc, 0.025, na.rm = TRUE),
                 quantile(boot_brier, 0.025, na.rm = TRUE),
                 NA_real_, NA_real_),
    ci_upper = c(roc_ci[3],
                 quantile(boot_auprc, 0.975, na.rm = TRUE),
                 quantile(boot_brier, 0.975, na.rm = TRUE),
                 NA_real_, NA_real_),
    model    = "lookup",
    stringsAsFactors = FALSE
  )
}


# =============================================================================
# Main entry point
# =============================================================================

#' Run the PLP beta-coefficient validation pipeline.
#'
#' Extracts validation plpData, applies the pre-built linear predictor (beta
#' vector), and writes CSV outputs consumed by generate_manuscript_report().
#'
#' @param config              Named list from get_validation_config().
#' @param connection_details  DatabaseConnector ConnectionDetails object.
#' @param model_dir           Path to the model/ directory.  Defaults to
#'                            file.path(getwd(), "model").
#' @param covariate_settings  Optional FeatureExtraction covariateSettings.
#'                            Overrides model_spec.rds$covariate_settings when
#'                            supplied.  Required if the spec does not embed
#'                            covariate settings.
#' @param pop_settings        Optional PatientLevelPrediction populationSettings.
#'                            Overrides model_spec.rds$population_settings.
#' @param n_top_covariates    Number of top features (by |beta|) to include in
#'                            covariate_summary.csv.  Default 50.
#'
#' @return Invisibly returns the per-person prediction data frame.
run_plp_validation_pipeline <- function(
    config,
    connection_details,
    model_dir          = file.path(getwd(), "model"),
    covariate_settings = NULL,
    pop_settings       = NULL,
    n_top_covariates   = 50L
) {

  output_dir <- config$output_folder
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)


  # ---------------------------------------------------------------------------
  # 1. Load and validate model spec
  # ---------------------------------------------------------------------------
  spec <- .load_model_spec(model_dir)

  # Resolve covariate settings: argument > spec > error
  if (is.null(covariate_settings)) {
    if (!is.null(spec$covariate_settings)) {
      covariate_settings <- spec$covariate_settings
      message("[plp_val] Using covariate settings from model_spec.rds.")
    } else {
      stop(
        "[plp_val] No covariate_settings provided.\n",
        "Either embed FeatureExtraction covariateSettings in model_spec.rds",
        " or pass covariate_settings to run_plp_validation_pipeline()."
      )
    }
  }

  # Resolve population settings: argument > spec > default
  if (is.null(pop_settings)) {
    pop_settings <- if (!is.null(spec$population_settings)) {
      message("[plp_val] Using population settings from model_spec.rds.")
      spec$population_settings
    } else {
      message("[plp_val] Using default population settings (riskWindowEnd = 365 days).")
      .default_pop_settings()
    }
  }


  # ---------------------------------------------------------------------------
  # 2. Extract plpData from the validation CDM
  # ---------------------------------------------------------------------------
  message("[plp_val] Extracting plpData from CDM (this may take several minutes) ...")

  db_details <- PatientLevelPrediction::createDatabaseDetails(
    connectionDetails    = connection_details,
    cdmDatabaseSchema    = config$cdm_schema,
    cohortDatabaseSchema = config$results_schema,
    cohortTable          = config$cohort_table,
    outcomeTable         = config$cohort_table,
    targetId             = config$target_cohort_id,
    outcomeIds           = config$outcome_cohort_id
  )

  plp_data <- PatientLevelPrediction::getPlpData(
    databaseDetails         = db_details,
    covariateSettings       = covariate_settings,
    restrictPlpDataSettings = PatientLevelPrediction::createRestrictPlpDataSettings()
  )

  plp_data_path <- file.path(output_dir, "plp_data_validation")
  PatientLevelPrediction::savePlpData(plp_data, plp_data_path)
  message("[plp_val] plpData saved to: ", plp_data_path)


  # ---------------------------------------------------------------------------
  # 3. Create study population aligned with training settings
  # ---------------------------------------------------------------------------
  message("[plp_val] Creating study population ...")

  population <- PatientLevelPrediction::createStudyPopulation(
    plpData            = plp_data,
    outcomeId          = config$outcome_cohort_id,
    populationSettings = pop_settings
  )

  message("[plp_val] Study population: ", nrow(population), " patients, ",
          sum(population$outcomeCount > 0, na.rm = TRUE), " with outcome.")


  # ---------------------------------------------------------------------------
  # 4. Collect covariates for the validation population
  # ---------------------------------------------------------------------------
  # Restrict to rows in the study population (inner join on rowId).
  message("[plp_val] Collecting covariates for study population ...")

  cov_raw <- dplyr::collect(
    plp_data$covariateData$covariates |>
      dplyr::filter(rowId %in% !!population$rowId)
  )
  # Normalise covariateId type to numeric for consistent merging.
  cov_raw$covariateId <- as.numeric(cov_raw$covariateId)

  message("[plp_val] Collected ", nrow(cov_raw), " covariate records across ",
          length(unique(cov_raw$rowId)), " patients.")


  # ---------------------------------------------------------------------------
  # 5. Apply the linear predictor (beta vector)
  # ---------------------------------------------------------------------------
  # For each patient, compute:
  #   linear_predictor = intercept + sum_{j in betas} beta_j * x_j
  # where x_j = 0 for unobserved covariates (sparse representation).
  # Missing features contribute 0 to the linear predictor by construction.
  #
  # This covers LASSO / Ridge / ElasticNet / plain logistic regression.
  # For Cox-derived models stored as log-hazard ratios, interpret the resulting
  # predicted value as a relative risk on the log-odds scale (not a probability)
  # unless the intercept has been calibrated to the validation baseline hazard.

  message("[plp_val] Applying linear predictor (", nrow(spec$betas), " features) ...")

  # Restrict covariate records to features present in the beta vector.
  cov_model <- merge(cov_raw, spec$betas, by = "covariateId")

  # Sum beta * x per patient.
  patient_lp <- tapply(
    cov_model$covariateValue * cov_model$beta,
    cov_model$rowId,
    sum,
    default = 0
  )

  # Build result frame aligned to population (all rowIds, even those with no
  # matching features — their linear predictor equals the intercept alone).
  lp_df <- data.frame(
    rowId           = population$rowId,
    linear_predictor = spec$intercept + as.numeric(
      patient_lp[as.character(population$rowId)]
    ),
    stringsAsFactors = FALSE
  )
  # rowIds absent from cov_model contribute NA from tapply lookup → replace with 0
  # (no features observed, so LP = intercept).
  lp_df$linear_predictor[is.na(lp_df$linear_predictor)] <- spec$intercept

  lp_df$predicted_risk <- .logistic(lp_df$linear_predictor)

  message("[plp_val] Predicted risk range: [",
          round(min(lp_df$predicted_risk), 4), ", ",
          round(max(lp_df$predicted_risk), 4), "]")


  # ---------------------------------------------------------------------------
  # 6. Assemble per-person prediction data frame
  # ---------------------------------------------------------------------------
  pred_df <- data.frame(
    rowId           = population$rowId,
    subjectId       = population$subjectId,
    cohortStartDate = population$cohortStartDate,
    outcomeCount    = population$outcomeCount,
    stringsAsFactors = FALSE
  )
  pred_df <- merge(pred_df, lp_df[, c("rowId", "predicted_risk")], by = "rowId")


  # ---------------------------------------------------------------------------
  # 7. Write person_level_scores.csv
  # ---------------------------------------------------------------------------
  # Column names match the contract expected by generate_manuscript_report():
  #   subject_id, index_date, outcome, predicted_risk_lookup
  person_level <- data.frame(
    subject_id            = pred_df$subjectId,
    index_date            = as.character(pred_df$cohortStartDate),
    outcome               = as.integer(pred_df$outcomeCount > 0),
    predicted_risk_lookup = pred_df$predicted_risk,
    stringsAsFactors      = FALSE
  )

  readr::write_csv(person_level, file.path(output_dir, "person_level_scores.csv"))
  message("[plp_val] person_level_scores.csv written (",
          nrow(person_level), " rows, ", sum(person_level$outcome), " events).")


  # ---------------------------------------------------------------------------
  # 8. Write covariate_summary.csv
  # ---------------------------------------------------------------------------
  # Lists the top-N features by |beta|, enriched with validation prevalence.
  # The report's .build_combined_covariate_table() reads feature_importance to
  # trigger PLP display mode.
  message("[plp_val] Summarising covariates ...")

  cov_data <- plp_data$covariateData
  cov_agg  <- dplyr::collect(
    cov_data$covariates |>
      dplyr::group_by(covariateId) |>
      dplyr::summarise(
        n_positive = dplyr::n(),
        mean_value = mean(covariateValue, na.rm = TRUE)
      )
  )
  cov_agg$covariateId <- as.numeric(cov_agg$covariateId)

  cov_ref <- dplyr::collect(cov_data$covariateRef)
  cov_ref$covariateId <- as.numeric(cov_ref$covariateId)

  cov_summary_df <- dplyr::left_join(cov_agg, cov_ref, by = "covariateId") |>
    dplyr::rename(covariate_id   = covariateId,
                  covariate_name = covariateName) |>
    as.data.frame()

  cov_summary_df$n_total <- nrow(population)

  # Join beta values; use |beta| as feature_importance for report display.
  beta_sel <- spec$betas
  names(beta_sel) <- c("covariate_id", "feature_importance")
  beta_sel$feature_importance <- abs(beta_sel$feature_importance)

  cov_summary_df <- merge(cov_summary_df, beta_sel, by = "covariate_id", all.x = TRUE)
  cov_summary_df <- cov_summary_df[!is.na(cov_summary_df$feature_importance), ]
  cov_summary_df <- cov_summary_df[order(-cov_summary_df$feature_importance), ]
  cov_summary_df <- head(cov_summary_df, n_top_covariates)

  readr::write_csv(cov_summary_df, file.path(output_dir, "covariate_summary.csv"))
  message("[plp_val] covariate_summary.csv written (",
          nrow(cov_summary_df), " features, top ", n_top_covariates, " by |beta|).")


  # ---------------------------------------------------------------------------
  # 9. Compute and write metrics.csv
  # ---------------------------------------------------------------------------
  message("[plp_val] Computing performance metrics ...")

  labels <- person_level$outcome
  probs  <- person_level$predicted_risk_lookup
  n_events <- sum(labels, na.rm = TRUE)

  message("[plp_val] Outcome summary: ", n_events, " events / ", length(labels),
          " patients (", round(100 * n_events / max(length(labels), 1), 1), "%)")

  na_metrics_df <- data.frame(
    metric   = c("AUROC", "AUPRC", "Brier", "CalibrationIntercept", "CalibrationSlope"),
    value    = NA_real_, ci_lower = NA_real_, ci_upper = NA_real_,
    model    = "lookup",
    stringsAsFactors = FALSE
  )

  if (length(unique(labels)) < 2L) {
    warning("[plp_val] Only one outcome class present — metrics will be NA.")
    metrics_df <- na_metrics_df
  } else {
    metrics_df <- tryCatch(
      .compute_metrics(labels, probs),
      error = function(e) {
        warning("[plp_val] .compute_metrics() failed: ", conditionMessage(e),
                " — writing NA metrics.")
        na_metrics_df
      }
    )
  }

  readr::write_csv(metrics_df, file.path(output_dir, "metrics.csv"))
  message("[plp_val] metrics.csv written.")
  message("[plp_val] AUROC: ",
          round(metrics_df$value[metrics_df$metric == "AUROC"], 3))


  # ---------------------------------------------------------------------------
  # 10. Calibration table and plot (10 decile bins)
  # ---------------------------------------------------------------------------
  if (length(unique(labels)) >= 2L) {
    message("[plp_val] Computing calibration table (10 decile bins) ...")

    n_bins <- 10L
    cuts   <- quantile(probs, probs = seq(0, 1, length.out = n_bins + 1L))
    bin    <- findInterval(probs, cuts, rightmost.closed = TRUE)
    bin[bin < 1L]     <- 1L
    bin[bin > n_bins] <- n_bins

    events_by_bin <- tapply(as.integer(labels), bin, sum)
    n_by_bin      <- tabulate(bin, nbins = n_bins)
    mean_pred     <- tapply(probs, bin, mean)

    bin_keys <- as.character(seq_len(n_bins))
    cal_tbl  <- data.frame(
      bin       = seq_len(n_bins),
      n         = as.integer(n_by_bin),
      events    = as.integer(
        ifelse(bin_keys %in% names(events_by_bin), events_by_bin[bin_keys], 0L)
      ),
      predicted = as.numeric(
        ifelse(bin_keys %in% names(mean_pred), mean_pred[bin_keys], 0)
      ),
      stringsAsFactors = FALSE
    )
    cal_tbl$observed <- cal_tbl$events / pmax(cal_tbl$n, 1L)

    readr::write_csv(cal_tbl,
                     file.path(output_dir, "calibration_table_lookup.csv"))
    message("[plp_val] calibration_table_lookup.csv written.")

    cal_plot <- ggplot2::ggplot(cal_tbl,
                                ggplot2::aes(x = predicted, y = observed)) +
      ggplot2::geom_abline(intercept = 0, slope = 1,
                           linetype = "dashed", colour = "grey50") +
      ggplot2::geom_point(size = 3) +
      ggplot2::geom_line() +
      ggplot2::scale_x_continuous(name = "Mean predicted probability",
                                  limits = c(0, 1)) +
      ggplot2::scale_y_continuous(name = "Observed event rate",
                                  limits = c(0, 1)) +
      ggplot2::labs(title = "PLP Model Calibration (10 decile bins)") +
      ggplot2::theme_bw()

    ggplot2::ggsave(file.path(output_dir, "calibration_lookup.png"),
                    cal_plot, width = 6, height = 5, dpi = 150)
    message("[plp_val] calibration_lookup.png written.")
  }

  message("[plp_val] Pipeline complete. Outputs written to: ", output_dir)
  invisible(pred_df)
}
