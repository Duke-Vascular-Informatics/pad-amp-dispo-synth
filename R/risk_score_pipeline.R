# =============================================================================
# R/risk_score_pipeline.R
#
# Integer risk score evaluation pipeline for the PAD / OLER SSI external
# validation study.
#
# This module provides all functions needed to:
#   1. Read and validate the score specification files (covariates.csv,
#      covariate_concepts.csv, risk_lookup.csv).
#   2. Query the OMOP CDM for each of the 10 covariate domains, applying
#      per-covariate lookback windows and concept-ancestor descendant expansion.
#   3. Assign integer points to each patient based on covariate presence flags.
#   4. Map integer scores to predicted probabilities via the published lookup
#      table and via a refitted logistic recalibration model.
#   5. Compute discrimination (AUROC, AUPRC), calibration (Brier, ECE,
#      intercept, slope), and 95% bootstrap percentile CIs for all metrics.
#   6. Save all per-person and aggregate outputs to the configured output folder.
#
# Entry point: run_integer_risk_score_pipeline(config, connection_details)
#
# Inputs:
#   risk_score/covariates.csv        — covariate_id, domain, lookback window,
#                                      min_count, and point value for each of
#                                      the 10 score covariates
#   risk_score/covariate_concepts.csv — OMOP concept_id(s) and descendant-
#                                      expansion flag per covariate; some
#                                      covariates carry additional concept_role
#                                      (weight/height for BMI, sub-covariate
#                                      roles for mFI) and value_concept_ids
#                                      (for observation value filtering)
#   risk_lookup.csv (optional)        — integer score → published risk mapping;
#                                       pass path as lookup_file= argument to
#                                       run_integer_risk_score_pipeline()
#
# Outputs (written to the output_folder argument of run_integer_risk_score_pipeline):
#   person_level_scores.csv       — one row per patient; covariate point columns
#                                   (score_<covariate_id>), total_score, outcome,
#                                   predicted_risk_lookup, predicted_risk_recalibrated
#   covariate_summary.csv         — per-covariate n_positive, mean_points
#   metrics.csv                   — AUROC, AUPRC, Brier, ECE, CalibrationIntercept,
#                                   CalibrationSlope for score_only / lookup /
#                                   recalibrated models, with ci_lower / ci_upper
#   calibration_table_<model>.csv — decile calibration tables (predicted, observed)
#   calibration_<model>.png       — calibration plots
# =============================================================================

# -----------------------------------------------------------------------------
# read_score_specs()
#
# Reads and validates the covariate specification CSV files that define the
# integer risk score.  Returns a named list with elements $covariates,
# $concepts, and $lookup (NULL when no lookup file is supplied or found).
#
# Arguments:
#   config      — list from get_validation_config() in config.R.
#                 Reads config$covariate_definitions_file and
#                 config$covariate_concepts_file — the same standard keys used
#                 by all other analyses in this template.
#   lookup_file — optional path to a score → probability lookup CSV
#                 (columns: score, risk).  Pass NULL to skip.  When supplied,
#                 the file is read and validated; if the path does not exist
#                 the lookup is silently omitted (fallback: logistic recalibration).
#
# Validation performed:
#   - All required column names are present in each CSV.
#   - domain values are restricted to the supported OMOP CDM domains.
#   - Integer/numeric columns are coerced and checked for NA.
#   - concept_role and value_concept_ids are normalised to lowercase / NA.
#   - Every covariate_id in covariates.csv has at least one concept mapping.
#   - The points column is optional (used by the integer scoring path only).
# -----------------------------------------------------------------------------
read_score_specs <- function(config, lookup_file = NULL) {
  covariates <- read.csv(config$covariate_definitions_file, stringsAsFactors = FALSE, comment.char = "#")
  concepts   <- read.csv(config$covariate_concepts_file,    stringsAsFactors = FALSE, comment.char = "#")

  required_covariate_cols <- c(
    "covariate_id", "covariate_name", "domain",
    "lookback_start_day", "lookback_end_day", "min_count"
  )
  missing_covariate_cols <- setdiff(required_covariate_cols, names(covariates))
  if (length(missing_covariate_cols) > 0) {
    stop("Missing required columns in covariates.csv: ", paste(missing_covariate_cols, collapse = ", "))
  }

  required_concept_cols <- c("covariate_id", "concept_id", "include_descendants")
  missing_concept_cols <- setdiff(required_concept_cols, names(concepts))
  if (length(missing_concept_cols) > 0) {
    stop("Missing required columns in covariate_concepts.csv: ", paste(missing_concept_cols, collapse = ", "))
  }

  covariates$domain <- tolower(trimws(covariates$domain))
  valid_domains <- c("condition", "drug", "procedure", "measurement", "observation", "visit")
  invalid_domains <- unique(covariates$domain[!covariates$domain %in% valid_domains])
  if (length(invalid_domains) > 0) {
    stop("Unsupported domains in covariates.csv: ", paste(invalid_domains, collapse = ", "))
  }

  covariates$lookback_start_day <- as.integer(covariates$lookback_start_day)
  covariates$lookback_end_day   <- as.integer(covariates$lookback_end_day)
  covariates$min_count          <- as.integer(covariates$min_count)

  # points: optional — only required for the integer risk score scoring path.
  # Default to 1 (binary presence/absence) when the column is absent.
  if ("points" %in% names(covariates)) {
    covariates$points <- as.numeric(covariates$points)
  } else {
    covariates$points <- 1L
  }

  # missing_is_negative: optional column added in covariates.csv.
  # TRUE  = absence of CDM records for this covariate is a true negative
  #         (e.g. sex, indication, prior procedures) — n_missing should be 0.
  # FALSE = absence may reflect unmeasured data (e.g. BMI, ABI, op time).
  # Defaults to FALSE when the column is absent (backward-compatible).
  if (!"missing_is_negative" %in% names(covariates)) {
    covariates$missing_is_negative <- FALSE
  }
  covariates$missing_is_negative <- tolower(trimws(as.character(covariates$missing_is_negative))) %in%
    c("true", "1", "t", "yes", "y")

  concepts$concept_id <- as.integer(concepts$concept_id)
  concepts$include_descendants <- tolower(trimws(as.character(concepts$include_descendants))) %in% c("true", "1", "t", "yes", "y")
  if (!"concept_role" %in% names(concepts)) {
    concepts$concept_role <- NA_character_
  }
  concepts$concept_role <- tolower(trimws(as.character(concepts$concept_role)))
  concepts$concept_role[concepts$concept_role == ""] <- NA_character_

  # value_concept_ids: optional semicolon-separated list of value_as_concept_id values
  # that qualify as a positive hit (used by mFI observation sub-components).
  # Empty / NA means any occurrence of the concept counts as positive.
  if (!"value_concept_ids" %in% names(concepts)) {
    concepts$value_concept_ids <- NA_character_
  }
  concepts$value_concept_ids <- trimws(as.character(concepts$value_concept_ids))
  concepts$value_concept_ids[concepts$value_concept_ids %in% c("", "NA")] <- NA_character_

  if (any(is.na(concepts$concept_id))) {
    stop("covariate_concepts.csv contains non-integer concept_id values.")
  }

  missing_covariates <- setdiff(covariates$covariate_id, concepts$covariate_id)
  if (length(missing_covariates) > 0) {
    stop("No concept mappings found for covariate_id(s): ", paste(missing_covariates, collapse = ", "))
  }

  # Load optional score → probability lookup table.
  # When lookup_file is NULL or the file does not exist the pipeline falls back
  # to logistic recalibration on the validation data.
  lookup <- NULL
  if (!is.null(lookup_file) && file.exists(lookup_file)) {
    lookup <- read.csv(lookup_file, stringsAsFactors = FALSE)
    if (!all(c("score", "risk") %in% names(lookup))) {
      stop("lookup_file must contain columns: score, risk")
    }
    lookup$score <- as.integer(lookup$score)
    lookup$risk  <- as.numeric(lookup$risk)
  }

  list(covariates = covariates, concepts = concepts, lookup = lookup)
}

# -----------------------------------------------------------------------------
# get_domain_mapping()
#
# Maps a lowercase OMOP domain string to the three SQL identifiers needed to
# query that domain:
#   $table        — CDM table name (e.g. "condition_occurrence")
#   $concept_col  — concept_id column name within that table
#   $date_col     — start-date column name within that table
#
# Used by the generic query_component_counts() path for standard domains.
# Domain-specific components (female, BMI, ABI, prolong_abx, optime4h, mFI)
# bypass this mapping and use their own dedicated query functions.
# -----------------------------------------------------------------------------
get_domain_mapping <- function(domain) {
  switch(
    domain,
    condition = list(table = "condition_occurrence", concept_col = "condition_concept_id", date_col = "condition_start_date"),
    drug = list(table = "drug_exposure", concept_col = "drug_concept_id", date_col = "drug_exposure_start_date"),
    procedure = list(table = "procedure_occurrence", concept_col = "procedure_concept_id", date_col = "procedure_date"),
    measurement = list(table = "measurement", concept_col = "measurement_concept_id", date_col = "measurement_date"),
    observation = list(table = "observation", concept_col = "observation_concept_id", date_col = "observation_date"),
    visit = list(table = "visit_occurrence", concept_col = "visit_concept_id", date_col = "visit_start_date"),
    stop("Unsupported domain: ", domain)
  )
}

# -----------------------------------------------------------------------------
# get_target_population()
#
# Returns a two-column data frame (SUBJECT_ID, INDEX_DATE) for all patients
# in the target cohort (cohort_definition_id = config$target_cohort_id).
# INDEX_DATE is cast to SQL DATE to strip any time-of-day component.
# This result set is used as the denominator/spine in every component query.
# -----------------------------------------------------------------------------
get_target_population <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "SELECT c.subject_id,
                  CAST(c.cohort_start_date AS DATE) AS index_date
           FROM @results_schema.@cohort_table c
           WHERE c.cohort_definition_id = @target_id",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id
  )
  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# get_outcomes()
#
# Returns one row per target-cohort patient with a binary OUTCOME flag.
# OUTCOME = 1 when the patient has a row in the outcome cohort whose
# cohort_start_date falls within [index_date, index_date + prediction_window_days].
#
# prediction_window_days comes from config$prediction_window_days (currently
# 90 days for the 90-day SSI endpoint).
#
# The query is written as a correlated EXISTS subquery so SQL Server can short-
# circuit as soon as the first qualifying outcome row is found per patient.
# -----------------------------------------------------------------------------
get_outcomes <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "SELECT t.subject_id,
                  t.index_date,
                  CASE WHEN EXISTS (
                    SELECT 1
                    FROM @results_schema.@cohort_table o
                    WHERE o.cohort_definition_id = @outcome_id
                      AND o.subject_id = t.subject_id
                      AND o.cohort_start_date >= t.index_date
                      AND o.cohort_start_date <= DATEADD(DAY, @prediction_window_days, t.index_date)
                  ) THEN 1 ELSE 0 END AS outcome
           FROM (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ) t",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    outcome_id = config$outcome_cohort_id,
    prediction_window_days = config$prediction_window_days
  )
  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# get_ssi_type()
#
# For each patient who developed a 90-day SSI, identifies the CDC/NHSN sub-type
# by looking for the first condition_occurrence (within the prediction window)
# whose source or standard concept maps to one of the three specific SSI codes:
#   Superficial incisional : SNOMED 609339001
#   Deep incisional        : SNOMED 609340004
#   Organ-space            : SNOMED 609341000
#
# Returns one row per patient with a non-NULL SSI outcome, with a column
# ssi_type containing "Superficial", "Deep", or "Organ-space".
# Patients without any of the three typed codes (i.e. only the parent SSI code)
# are returned with ssi_type = NA and can be treated as unclassified.
#
# The result is left-joined onto person_level in calculate_scores() so all
# patients (SSI and non-SSI) remain in the dataset; non-SSI patients get NA.
# -----------------------------------------------------------------------------
get_ssi_type <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "SELECT t.subject_id,
                  co.condition_start_date,
                  CASE co.condition_source_value
                    WHEN '609339001' THEN 'Superficial'
                    WHEN '609340004' THEN 'Deep'
                    WHEN '609341000' THEN 'Organ-space'
                    ELSE NULL
                  END AS ssi_type
           FROM (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ) t
           JOIN @cdm_schema.condition_occurrence co
             ON  co.person_id = t.subject_id
             AND co.condition_source_value IN ('609339001','609340004','609341000')
             AND co.condition_start_date >= t.index_date
             AND co.condition_start_date <= DATEADD(DAY, @prediction_window_days, t.index_date)
           WHERE CASE co.condition_source_value
                   WHEN '609339001' THEN 'Superficial'
                   WHEN '609340004' THEN 'Deep'
                   WHEN '609341000' THEN 'Organ-space'
                   ELSE NULL
                 END IS NOT NULL",
    results_schema = results_schema_prefix(config),
    cohort_table   = config$cohort_table,
    cdm_schema     = config$cdm_schema,
    target_id      = config$target_cohort_id,
    prediction_window_days = config$prediction_window_days
  )
  df <- DatabaseConnector::querySql(
    connection, SqlRender::translate(sql, targetDialect = "sql server")
  )
  names(df) <- tolower(names(df))
  names(df)[names(df) == "subjectid"]             <- "subject_id"
  names(df)[names(df) == "conditionstartdate"]    <- "condition_start_date"
  # Keep the latest typed SSI event per patient within the window
  df <- df[order(df$subject_id, df$condition_start_date, decreasing = c(FALSE, TRUE)), ]
  df <- df[!duplicated(df$subject_id), c("subject_id", "ssi_type")]
  df
}

# -----------------------------------------------------------------------------
# ensure_concept_ancestor_indexes()
#
# Creates two non-clustered covering indexes on concept_ancestor if they do not
# already exist:
#   IX_concept_ancestor_ancestor   — on ancestor_concept_id (supports the
#                                    descendant expansion JOINs in component
#                                    queries that start from a known ancestor)
#   IX_concept_ancestor_descendant — on descendant_concept_id (supports reverse
#                                    lookups, e.g. finding the ancestor of a
#                                    code found in a CDM table)
#
# Both indexes INCLUDE the complementary concept_id column and the level columns
# so they are fully covering for the typical query pattern.
#
# Called once at pipeline startup.  Errors are demoted to warnings so a missing
# CREATE INDEX permission does not abort the entire pipeline — it just means
# ancestor expansion queries will be slower.
# -----------------------------------------------------------------------------
ensure_concept_ancestor_indexes <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "IF OBJECT_ID('@cdm_schema.concept_ancestor', 'U') IS NOT NULL
           BEGIN
             IF NOT EXISTS (
               SELECT 1
               FROM sys.indexes
               WHERE object_id = OBJECT_ID('@cdm_schema.concept_ancestor')
                 AND name = 'IX_concept_ancestor_ancestor'
             )
             BEGIN
               CREATE INDEX IX_concept_ancestor_ancestor
                 ON @cdm_schema.concept_ancestor (ancestor_concept_id)
                 INCLUDE (descendant_concept_id, min_levels_of_separation, max_levels_of_separation);
             END;

             IF NOT EXISTS (
               SELECT 1
               FROM sys.indexes
               WHERE object_id = OBJECT_ID('@cdm_schema.concept_ancestor')
                 AND name = 'IX_concept_ancestor_descendant'
             )
             BEGIN
               CREATE INDEX IX_concept_ancestor_descendant
                 ON @cdm_schema.concept_ancestor (descendant_concept_id)
                 INCLUDE (ancestor_concept_id);
             END;
           END;",
    cdm_schema = config$cdm_schema
  )

  sql <- SqlRender::translate(sql, targetDialect = "sql server")

  tryCatch({
    DatabaseConnector::executeSql(connection, sql)
    message("concept_ancestor indexes verified/created.")
  }, error = function(e) {
    warning(
      "Unable to verify/create concept_ancestor indexes. Descendant-expansion queries may be slow. Details: ",
      conditionMessage(e)
    )
  })

  invisible(NULL)
}

# -----------------------------------------------------------------------------
# query_bmi_covariate_counts()
#
# Resolves BMI for each patient using a three-tier priority strategy:
#
#   1. Direct BMI measurement (concept_role = "bmi_direct")
#      — most recent value_as_number from the measurement table whose
#        measurement_concept_id is in the bmi_direct concept set.
#        Unit assumed to be kg/m² (OMOP 9531); no conversion applied.
#        Use this when the EHR or ETL stores a pre-computed BMI value.
#
#   2. Computed BMI from weight + height (concept_role = "weight" / "height")
#      — most-recent weight and most-recent height are paired and BMI is
#        calculated as weight_kg / height_m².  Used as fallback when no
#        direct BMI reading is available.
#
#   3. Neither — patient is not flagged for this covariate.
#
# Priority is implemented via a UNION ALL + ROW_NUMBER with an explicit
# priority column (1 = direct, 2 = computed); the lowest priority value
# per patient wins.
#
# BMI thresholds:
#   overweight: 25 ≤ BMI < 30
#   obese:      BMI ≥ 30
#
# Unit handling:
#   Weight — kg (9529) as-is; lb (8739) × 0.45359237.
#   Height — m  (9546) as-is; cm (8582) ÷ 100; in (9326, 9327, 9330) × 0.0254.
#   BMI    — kg/m² (9531 or no unit) used directly from value_as_number.
#
# concept_role column in covariate_concepts.csv is required.  At least one of
# (bmi_direct) or (weight + height) must be present; stop() if neither is.
# -----------------------------------------------------------------------------
query_bmi_covariate_counts <- function(connection, config, covariate, covariate_concepts) {
  if (!"concept_role" %in% names(covariate_concepts)) {
    stop("BMI-derived covariates require concept_role values in covariate_concepts.csv.")
  }

  roles          <- tolower(trimws(as.character(covariate_concepts$concept_role)))
  weight_ids     <- unique(covariate_concepts$concept_id[roles == "weight"])
  height_ids     <- unique(covariate_concepts$concept_id[roles == "height"])
  bmi_direct_ids <- unique(covariate_concepts$concept_id[roles == "bmi_direct"])

  weight_ids     <- weight_ids[!is.na(weight_ids) & weight_ids > 0]
  height_ids     <- height_ids[!is.na(height_ids) & height_ids > 0]
  bmi_direct_ids <- bmi_direct_ids[!is.na(bmi_direct_ids) & bmi_direct_ids > 0]

  has_direct   <- length(bmi_direct_ids) > 0
  has_computed <- length(weight_ids) > 0 && length(height_ids) > 0

  if (!has_direct && !has_computed) {
    stop(
      "Covariate ", covariate$covariate_id,
      ": covariate_concepts.csv must supply either bmi_direct concept(s) or ",
      "both weight and height concept(s)."
    )
  }

  bmi_where_clause <- switch(
    covariate$covariate_id,
    overweight = "b.bmi >= 25 AND b.bmi < 30",
    obese      = "b.bmi >= 30",
    stop("Unsupported BMI-derived covariate_id: ", covariate$covariate_id)
  )

  # OMOP standard UCUM unit concept IDs.
  kilogram_unit_id  <- 9529L
  pound_unit_ids    <- c(8739L)
  meter_unit_id     <- 9546L
  centimeter_unit_id <- 8582L
  inch_unit_ids     <- c(9326L, 9327L, 9330L)

  # ---------------------------------------------------------------------------
  # Build the BMI source UNION. Each branch produces:
  #   subject_id, bmi, priority (1 = direct, 2 = computed)
  # A final ROW_NUMBER() picks the best (lowest priority) reading per patient.
  # ---------------------------------------------------------------------------

  # Branch 1 — direct BMI measurement (only if bmi_direct concepts exist)
  direct_cte <- if (has_direct) {
    paste0(
      "           bmi_direct_concepts AS (\n",
      "             SELECT CAST(id AS BIGINT) AS concept_id\n",
      "             FROM (SELECT value AS id FROM string_split('", paste(bmi_direct_ids, collapse = ","), "', ',')) s\n",
      "           ),\n",
      "           direct_bmi_raw AS (\n",
      "             SELECT t.subject_id,\n",
      "                    m.value_as_number AS bmi,\n",
      "                    m.measurement_date,\n",
      "                    m.measurement_id\n",
      "             FROM target_population t\n",
      "             JOIN @cdm_schema.measurement m\n",
      "               ON m.person_id = t.subject_id\n",
      "             JOIN bmi_direct_concepts bc\n",
      "               ON m.measurement_concept_id = bc.concept_id\n",
      "             WHERE m.value_as_number IS NOT NULL\n",
      "               AND m.value_as_number > 0\n",
      "               AND m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)\n",
      "               AND m.measurement_date <= DATEADD(DAY, @lookback_end,   t.index_date)\n",
      "           ),\n"
    )
  } else ""

  # Branch 2 — computed BMI from weight + height (only if both concept sets exist)
  computed_cte <- if (has_computed) {
    paste0(
      "           weight_concepts AS (\n",
      "             SELECT CAST(id AS BIGINT) AS concept_id\n",
      "             FROM (SELECT value AS id FROM string_split('", paste(weight_ids, collapse = ","), "', ',')) s\n",
      "           ),\n",
      "           height_concepts AS (\n",
      "             SELECT CAST(id AS BIGINT) AS concept_id\n",
      "             FROM (SELECT value AS id FROM string_split('", paste(height_ids, collapse = ","), "', ',')) s\n",
      "           ),\n",
      "           latest_weight AS (\n",
      "             SELECT t.subject_id,\n",
      "                    CASE\n",
      "                      WHEN m.unit_concept_id = @kilogram_unit_id    THEN m.value_as_number\n",
      "                      WHEN m.unit_concept_id IN (@pound_unit_ids)   THEN m.value_as_number * 0.45359237\n",
      "                      ELSE NULL\n",
      "                    END AS weight_kg,\n",
      "                    m.measurement_date,\n",
      "                    m.measurement_id,\n",
      "                    ROW_NUMBER() OVER (\n",
      "                      PARTITION BY t.subject_id\n",
      "                      ORDER BY m.measurement_date DESC, m.measurement_id DESC\n",
      "                    ) AS rn\n",
      "             FROM target_population t\n",
      "             JOIN @cdm_schema.measurement m ON m.person_id = t.subject_id\n",
      "             JOIN weight_concepts wc ON m.measurement_concept_id = wc.concept_id\n",
      "             WHERE m.value_as_number IS NOT NULL\n",
      "               AND m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)\n",
      "               AND m.measurement_date <= DATEADD(DAY, @lookback_end,   t.index_date)\n",
      "           ),\n",
      "           latest_height AS (\n",
      "             SELECT t.subject_id,\n",
      "                    CASE\n",
      "                      WHEN m.unit_concept_id = @meter_unit_id        THEN m.value_as_number\n",
      "                      WHEN m.unit_concept_id = @centimeter_unit_id   THEN m.value_as_number / 100.0\n",
      "                      WHEN m.unit_concept_id IN (@inch_unit_ids)     THEN m.value_as_number * 0.0254\n",
      "                      ELSE NULL\n",
      "                    END AS height_m,\n",
      "                    m.measurement_date,\n",
      "                    m.measurement_id,\n",
      "                    ROW_NUMBER() OVER (\n",
      "                      PARTITION BY t.subject_id\n",
      "                      ORDER BY m.measurement_date DESC, m.measurement_id DESC\n",
      "                    ) AS rn\n",
      "             FROM target_population t\n",
      "             JOIN @cdm_schema.measurement m ON m.person_id = t.subject_id\n",
      "             JOIN height_concepts hc ON m.measurement_concept_id = hc.concept_id\n",
      "             WHERE m.value_as_number IS NOT NULL\n",
      "               AND m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)\n",
      "               AND m.measurement_date <= DATEADD(DAY, @lookback_end,   t.index_date)\n",
      "           ),\n"
    )
  } else ""

  # Build UNION branches
  union_branches <- c()
  if (has_direct) {
    union_branches <- c(union_branches,
      paste0(
        "             SELECT subject_id, bmi, 1 AS priority, measurement_date AS bmi_date\n",
        "             FROM direct_bmi_raw"
      )
    )
  }
  if (has_computed) {
    union_branches <- c(union_branches,
      paste0(
        "             SELECT w.subject_id,\n",
        "                    w.weight_kg / POWER(h.height_m, 2) AS bmi,\n",
        "                    2 AS priority,\n",
        "                    w.measurement_date AS bmi_date\n",
        "             FROM latest_weight w\n",
        "             JOIN latest_height h ON w.subject_id = h.subject_id\n",
        "             WHERE w.rn = 1 AND h.rn = 1\n",
        "               AND w.weight_kg IS NOT NULL AND h.height_m IS NOT NULL\n",
        "               AND w.weight_kg > 0 AND h.height_m > 0"
      )
    )
  }

  sql <- paste0(
    "WITH target_population AS (\n",
    "             SELECT c.subject_id,\n",
    "                    CAST(c.cohort_start_date AS DATE) AS index_date\n",
    "             FROM @results_schema.@cohort_table c\n",
    "             WHERE c.cohort_definition_id = @target_id\n",
    "           ),\n",
    direct_cte,
    computed_cte,
    "           bmi_ranked AS (\n",
    "             SELECT subject_id, bmi, priority,\n",
    "                    ROW_NUMBER() OVER (\n",
    "                      PARTITION BY subject_id\n",
    "                      ORDER BY priority ASC, bmi_date DESC\n",
    "                    ) AS final_rn\n",
    "             FROM (\n",
    paste(union_branches, collapse = "\n             UNION ALL\n"),
    "\n             ) all_bmi\n",
    "             WHERE bmi IS NOT NULL AND bmi > 0\n",
    "           ),\n",
    "           bmi_values AS (\n",
    "             SELECT subject_id, bmi\n",
    "             FROM bmi_ranked\n",
    "             WHERE final_rn = 1\n",
    "           )\n",
    "           SELECT b.subject_id,\n",
    "                  1 AS event_count\n",
    "           FROM bmi_values b\n",
    "           WHERE ", bmi_where_clause
  )

  sql <- SqlRender::render(
    sql             = sql,
    results_schema  = results_schema_prefix(config),
    cohort_table    = config$cohort_table,
    target_id       = config$target_cohort_id,
    cdm_schema      = config$cdm_schema,
    kilogram_unit_id  = kilogram_unit_id,
    pound_unit_ids    = paste(pound_unit_ids,    collapse = ","),
    meter_unit_id     = meter_unit_id,
    centimeter_unit_id = centimeter_unit_id,
    inch_unit_ids     = paste(inch_unit_ids,     collapse = ","),
    lookback_start  = as.integer(covariate$lookback_start_day),
    lookback_end    = as.integer(covariate$lookback_end_day)
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# query_abi_covariate_counts()
#
# Counts qualifying ankle-brachial index (ABI) measurements per patient.
# A measurement qualifies when:
#   - Its measurement_concept_id is in the configured ABI concept set (optionally
#     expanded to include all descendants via concept_ancestor).
#   - value_as_number IS NOT NULL.
#   - value_as_number < 0.35 (the ABI threshold for this risk covariate).
#   - The measurement_date is within the covariate lookback window.
#
# Returns one row per patient with event_count > 0, which calculate_scores()
# will convert to the covariate point value when event_count ≥ min_count.
# -----------------------------------------------------------------------------
query_abi_covariate_counts <- function(connection, config, covariate, covariate_concepts) {
  concept_ids <- unique(covariate_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]
  include_desc <- any(covariate_concepts$include_descendants)

  if (length(concept_ids) == 0) {
    stop(
      "Covariate ", covariate$covariate_id,
      " requires at least one ABI measurement concept_id in covariate_concepts.csv"
    )
  }

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           )
           SELECT t.subject_id,
                  COUNT(*) AS event_count
           FROM target_population t
           JOIN @cdm_schema.measurement m
             ON m.person_id = t.subject_id
           JOIN expanded_concepts ec
             ON m.measurement_concept_id = ec.concept_id
           WHERE m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)
             AND m.measurement_date <= DATEADD(DAY, @lookback_end, t.index_date)
             AND m.value_as_number IS NOT NULL
             AND m.value_as_number < @abi_threshold
           GROUP BY t.subject_id",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ","),
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(covariate$lookback_start_day),
    lookback_end = as.integer(covariate$lookback_end_day),
    abi_threshold = 0.35
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# query_prolonged_antibiotic_counts()
#
# Counts non-prophylactic systemic antibiotic exposures per patient.
# Operationally defined as a drug_exposure record where:
#   - drug_concept_id is in the configured antibiotic concept set (with optional
#     descendant expansion — typically ATC ancestor 21603553).
#   - drug_exposure_start_date is within the component lookback window AND
#     is on or before index_date − 1 day (excludes perioperative prophylaxis
#     started on the day of or the day before surgery).
#   - Exposure duration > 2 days (treatment-like, not prophylactic):
#     DATEDIFF(DAY, start_date, end_date) > 2  OR  days_supply > 2.
#
# The non_prophylaxis_buffer_days parameter (currently 0, meaning start_date
# must be <= index − 1) and min_treatment_days (2) are explicit constants so
# they can be adjusted without changing SQL logic.
# -----------------------------------------------------------------------------
query_prolonged_antibiotic_counts <- function(connection, config, covariate, covariate_concepts) {
  concept_ids <- unique(covariate_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]
  include_desc <- any(covariate_concepts$include_descendants)

  if (length(concept_ids) == 0) {
    stop(
      "Covariate ", covariate$covariate_id,
      " requires at least one antibiotic drug concept_id in covariate_concepts.csv"
    )
  }

  # Operational definition for non-prophylactic prior antibiotic exposure:
  # - Exposure must start before the day immediately prior to index (<= index - 2 days)
  # - Exposure must represent a treatment-like duration (>= 2 days from end date or days_supply)
  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           )
           SELECT t.subject_id,
                  COUNT(*) AS event_count
           FROM target_population t
           JOIN @cdm_schema.drug_exposure d
             ON d.person_id = t.subject_id
           JOIN expanded_concepts ec
             ON d.drug_concept_id = ec.concept_id
           WHERE d.drug_exposure_start_date >= DATEADD(DAY, @lookback_start, t.index_date)
             AND d.drug_exposure_start_date <= DATEADD(DAY, @lookback_end, t.index_date)
             AND d.drug_exposure_start_date <= DATEADD(DAY, -@non_prophylaxis_buffer_days, t.index_date)
             AND (
               (d.drug_exposure_end_date IS NOT NULL
                AND DATEDIFF(DAY, d.drug_exposure_start_date, d.drug_exposure_end_date) > @min_treatment_days)
               OR (d.days_supply IS NOT NULL AND d.days_supply > @min_treatment_days)
             )
           GROUP BY t.subject_id",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ","),
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(covariate$lookback_start_day),
    lookback_end = as.integer(covariate$lookback_end_day),
    non_prophylaxis_buffer_days = 0,
    min_treatment_days = 2
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# query_operative_time_covariate_counts()
#
# Identifies patients with operative time ≥ 4 hours (240 minutes) using two
# complementary sources, combined with UNION (de-duplicated):
#
#   Source 1 — procedure_occurrence datetime columns:
#     DATEDIFF(MINUTE, procedure_datetime, procedure_end_datetime) > 240
#     on procedures dated to the index date.  Requires Synthea to have generated
#     sub-day timestamps (via the module duration field) and ETL to have mapped
#     them to procedure_datetime / procedure_end_datetime.
#
#   Source 2 — measurement table operative-time concepts:
#     Matching measurement_concept_id values (from covariate_concepts.csv) with
#     value_as_number > 240 within the lookback window.
#
# If neither source has data the function returns an empty data frame; the
# patient is then scored 0 for this covariate.
# -----------------------------------------------------------------------------
query_operative_time_covariate_counts <- function(connection, config, covariate, covariate_concepts) {
  # Captures operative time >= 4 hours (240 minutes) using two complementary
  # sources, combined with UNION (de-duplicated):
  #
  #   Source 1 — procedure_occurrence datetime columns:
  #     DATEDIFF(MINUTE, procedure_datetime, procedure_end_datetime) > 240
  #     for the qualifying index procedure (concept_ancestor descendants of
  #     the target procedure anchors 4236706 / 4225375) occurring at any
  #     point during the inpatient admission (cohort_start_date to
  #     cohort_end_date).  This window is used instead of a single-date match
  #     because in many OMOP ETLs the index date is the admission start date
  #     and the surgery occurs on a subsequent day of the same admission.
  #
  #   Source 2 — measurement table operative-time concepts:
  #     Matching measurement_concept_id values (from covariate_concepts.csv)
  #     with value_as_number > 240 within the covariate lookback window.

  concept_ids <- unique(covariate_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]
  include_desc <- any(covariate_concepts$include_descendants)

  operative_time_threshold_minutes <- 240  # 4 hours

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date,
                    CAST(c.cohort_end_date   AS DATE) AS admission_end_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           ),
           -- Source 1: duration computed from procedure_datetime / procedure_end_datetime.
           -- Searches the full inpatient admission window (index_date to admission_end_date)
           -- rather than only the exact index date, because surgery typically occurs on
           -- a day after the admission start date.
           -- Restricted to the qualifying target procedure concepts so that unrelated
           -- same-admission procedures do not falsely trigger the component.
           procedure_duration_mins AS (
             SELECT DISTINCT t.subject_id
             FROM target_population t
             JOIN @cdm_schema.procedure_occurrence po
               ON po.person_id = t.subject_id
             JOIN @cdm_schema.concept_ancestor ca_proc
               ON ca_proc.descendant_concept_id = po.procedure_concept_id
              AND ca_proc.ancestor_concept_id IN (4236706, 4225375)
             WHERE CAST(po.procedure_date AS DATE) >= t.index_date
               AND CAST(po.procedure_date AS DATE) <= DATEADD(DAY, 30, t.index_date)
               AND po.procedure_datetime     IS NOT NULL
               AND po.procedure_end_datetime IS NOT NULL
               AND DATEDIFF(MINUTE, po.procedure_datetime, po.procedure_end_datetime) > @operative_time_threshold
           ),
           -- Source 2: measured operative time stored as a measurement value.
           measurement_operative_time AS (
             SELECT DISTINCT t.subject_id
             FROM target_population t
             JOIN @cdm_schema.measurement m
               ON m.person_id = t.subject_id
             JOIN expanded_concepts ec
               ON m.measurement_concept_id = ec.concept_id
             WHERE CAST(m.measurement_date AS DATE) >= DATEADD(DAY, @lookback_start, t.index_date)
               AND CAST(m.measurement_date AS DATE) <= DATEADD(DAY, @lookback_end, t.index_date)
               AND m.value_as_number > @operative_time_threshold
           ),
           combined_operative_time AS (
             SELECT subject_id FROM procedure_duration_mins
             UNION
             SELECT subject_id FROM measurement_operative_time
           )
           SELECT subject_id,
                  COUNT(*) AS event_count
           FROM combined_operative_time
           GROUP BY subject_id",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ","),
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(covariate$lookback_start_day),
    lookback_end = as.integer(covariate$lookback_end_day),
    operative_time_threshold = operative_time_threshold_minutes
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# query_mfi_covariate_counts()
#
# Computes the modified Frailty Index (mFI) composite flag.  A patient is
# flagged (event_count = 1) when more than mfi_threshold (0.25) of the
# configured sub-covariates are present.  With 5 sub-covariates the effective
# threshold is > 1 out of 5 (i.e., ≥ 2 conditions present).
#
# Sub-covariates are identified by concept_role in covariate_concepts.csv:
#   diabetes, copd, chf, hypertension, functional_status
# (or any non-empty role values defined there).
#
# Query strategy:
#   - A separate CTE is built dynamically for each sub-covariate role, joining
#     target_population to either condition_occurrence (default) or observation
#     (when value_concept_ids is set) to detect qualifying records within the
#     lookback window.
#   - A final mfi_counts CTE sums the sub-covariate flags (0/1) per patient
#     using a dynamic CASE WHEN IS NOT NULL expression.
#   - Patients with sub_count / n_sub > mfi_threshold (0.25) are returned.
#
# All CTEs are assembled as plain-SQL strings (no SqlRender::render) because
# the number of sub-covariates is variable.  DatabaseConnector::querySql() +
# SqlRender::translate() is still called for dialect normalisation.
# -----------------------------------------------------------------------------
query_mfi_covariate_counts <- function(connection, config, covariate, covariate_concepts) {
  # Modified Frailty Index: binary flag if (# sub-covariates present / total sub-covariates) > 0.25
  # Each sub-covariate is identified by concept_role in covariate_concepts.
  # Sub-covariates are queried from condition_occurrence.
  mfi_threshold <- 0.25

  valid_rows <- covariate_concepts[
    !is.na(covariate_concepts$concept_role) &
    trimws(covariate_concepts$concept_role) != "" &
    !is.na(covariate_concepts$concept_id) &
    covariate_concepts$concept_id > 0, ]

  roles <- unique(trimws(valid_rows$concept_role))
  n_sub <- length(roles)

  if (n_sub == 0) {
    stop("mFI_high requires concept_role entries with valid concept_ids in covariate_concepts.csv")
  }

  # Build CTE for target population
  tp_cte <- sprintf(
    paste0("target_population AS (\n",
           "  SELECT c.subject_id, CAST(c.cohort_start_date AS DATE) AS index_date\n",
           "  FROM %s.%s c\n",
           "  WHERE c.cohort_definition_id = %d\n",
           ")"),
    results_schema_prefix(config), config$cohort_table, as.integer(config$target_cohort_id)
  )

  # Build one CTE per sub-component, joined to target_population
  sub_cte_names <- paste0("sub_comp_", seq_along(roles))

  sub_ctes <- mapply(function(role, cte_name) {
    sc   <- valid_rows[trimws(valid_rows$concept_role) == role, ]
    ids  <- paste(unique(sc$concept_id), collapse = ", ")
    desc <- if (any(sc$include_descendants)) 1L else 0L

    # Rows with value_concept_ids use the observation table with value filtering;
    # rows without use condition_occurrence (standard diagnosis lookup).
    value_ids_raw <- sc$value_concept_ids[!is.na(sc$value_concept_ids)]
    value_ids <- unique(unlist(strsplit(value_ids_raw, ";")))
    value_ids <- trimws(value_ids[nzchar(trimws(value_ids))])
    use_observation <- length(value_ids) > 0

    if (use_observation) {
      concept_filter <- sprintf(
        paste0("(o.observation_concept_id IN (%s)\n",
               "         OR (%d = 1 AND o.observation_concept_id IN (\n",
               "               SELECT ca.descendant_concept_id\n",
               "               FROM %s.concept_ancestor ca\n",
               "               WHERE ca.ancestor_concept_id IN (%s)\n",
               "             )))\n",
               "    AND o.value_as_concept_id IN (%s)"),
        ids, desc, config$cdm_schema, ids,
        paste(value_ids, collapse = ", ")
      )
      sprintf(
        paste0("%s AS (\n",
               "  SELECT DISTINCT t.subject_id\n",
               "  FROM target_population t\n",
               "  JOIN %s.observation o ON o.person_id = t.subject_id\n",
               "  WHERE %s\n",
               "    AND CAST(o.observation_date AS DATE) >= DATEADD(DAY, %d, t.index_date)\n",
               "    AND CAST(o.observation_date AS DATE) <= DATEADD(DAY, %d, t.index_date)\n",
               ")"),
        cte_name, config$cdm_schema, concept_filter,
        as.integer(covariate$lookback_start_day),
        as.integer(covariate$lookback_end_day)
      )
    } else {
      concept_filter <- sprintf(
        paste0("(co.condition_concept_id IN (%s)\n",
               "         OR (%d = 1 AND co.condition_concept_id IN (\n",
               "               SELECT ca.descendant_concept_id\n",
               "               FROM %s.concept_ancestor ca\n",
               "               WHERE ca.ancestor_concept_id IN (%s)\n",
               "             )))"),
        ids, desc, config$cdm_schema, ids
      )
      sprintf(
        paste0("%s AS (\n",
               "  SELECT DISTINCT t.subject_id\n",
               "  FROM target_population t\n",
               "  JOIN %s.condition_occurrence co ON co.person_id = t.subject_id\n",
               "  WHERE %s\n",
               "    AND CAST(co.condition_start_date AS DATE) >= DATEADD(DAY, %d, t.index_date)\n",
               "    AND CAST(co.condition_start_date AS DATE) <= DATEADD(DAY, %d, t.index_date)\n",
               ")"),
        cte_name, config$cdm_schema, concept_filter,
        as.integer(covariate$lookback_start_day),
        as.integer(covariate$lookback_end_day)
      )
    }
  }, roles, sub_cte_names, SIMPLIFY = TRUE)

  # CTE that sums sub-covariate flags per patient
  flag_expr <- paste(
    sprintf("CASE WHEN %s.subject_id IS NOT NULL THEN 1 ELSE 0 END", sub_cte_names),
    collapse = " +\n               "
  )
  join_clauses <- paste(
    sprintf("LEFT JOIN %s ON %s.subject_id = tp.subject_id",
            sub_cte_names, sub_cte_names),
    collapse = "\n  "
  )
  mfi_counts_cte <- sprintf(
    paste0("mfi_counts AS (\n",
           "  SELECT tp.subject_id,\n",
           "         (%s) AS sub_count\n",
           "  FROM target_population tp\n",
           "  %s\n",
           ")"),
    flag_expr, join_clauses
  )

  all_ctes <- paste(c(tp_cte, sub_ctes, mfi_counts_cte), collapse = ",\n")

  sql <- sprintf(
    paste0("WITH %s\n",
           "SELECT subject_id,\n",
           "       1 AS event_count\n",
           "FROM mfi_counts\n",
           "WHERE CAST(sub_count AS FLOAT) / %d > %s"),
    all_ctes, n_sub, mfi_threshold
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# query_female_covariate_counts()
#
# Flags patients whose person.gender_concept_id matches one of the configured
# female-sex concept IDs (typically concept 8532 — Female).
#
# Unlike clinical event covariates this query has no lookback window: sex is
# a demographic attribute stored directly in the person table, not as a dated
# clinical event.  Returns subject_id with event_count = 1 for female patients.
# -----------------------------------------------------------------------------
query_female_covariate_counts <- function(connection, config, covariate, covariate_concepts) {
  concept_ids <- unique(covariate_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]

  if (length(concept_ids) == 0) {
    stop("Covariate female requires at least one concept_id mapping in covariate_concepts.csv")
  }

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           )
           SELECT t.subject_id,
                  1 AS event_count
           FROM target_population t
           JOIN @cdm_schema.person p
             ON p.person_id = t.subject_id
           JOIN concept_ids ci
             ON p.gender_concept_id = ci.concept_id",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ",")
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# query_covariate_counts()
#
# Dispatcher function — routes each score covariate to its specialised query
# function or falls back to the generic OMOP domain query.
#
# Routing logic:
#   "female"           → query_female_covariate_counts()
#   "overweight","obese" → query_bmi_covariate_counts()
#   "abi_35"           → query_abi_covariate_counts()
#   "prolong_abx"      → query_prolonged_antibiotic_counts()
#   "optime4h"         → query_operative_time_covariate_counts()
#   "mFI_high"         → query_mfi_covariate_counts()
#   all others         → generic concept-ancestor SQL via get_domain_mapping()
#
# The generic path builds a WITH ... expanded_concepts AS (...) query that
# optionally joins concept_ancestor for descendant expansion, then counts
# qualifying domain table rows within the covariate lookback window.
#
# Returns a data frame with columns SUBJECT_ID and EVENT_COUNT.
# -----------------------------------------------------------------------------
query_covariate_counts <- function(connection, config, covariate, covariate_concepts) {
  if (covariate$covariate_id == "female") {
    return(query_female_covariate_counts(connection, config, covariate, covariate_concepts))
  }

  if (covariate$covariate_id %in% c("overweight", "obese")) {
    return(query_bmi_covariate_counts(connection, config, covariate, covariate_concepts))
  }

  if (covariate$covariate_id == "abi_35") {
    return(query_abi_covariate_counts(connection, config, covariate, covariate_concepts))
  }

  if (covariate$covariate_id == "prolong_abx") {
    return(query_prolonged_antibiotic_counts(connection, config, covariate, covariate_concepts))
  }

  if (covariate$covariate_id == "optime4h") {
    return(query_operative_time_covariate_counts(connection, config, covariate, covariate_concepts))
  }

  if (covariate$covariate_id == "mFI_high") {
    return(query_mfi_covariate_counts(connection, config, covariate, covariate_concepts))
  }

  map <- get_domain_mapping(covariate$domain)

  concept_ids <- unique(covariate_concepts$concept_id)
  concept_id_string <- paste(concept_ids, collapse = ",")
  include_desc <- any(covariate_concepts$include_descendants)

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           )
           SELECT t.subject_id,
                  COUNT(*) AS event_count
           FROM target_population t
           JOIN @cdm_schema.@domain_table d
             ON d.person_id = t.subject_id
           JOIN expanded_concepts ec
             ON d.@domain_concept_col = ec.concept_id
           WHERE d.@domain_date_col >= DATEADD(DAY, @lookback_start, t.index_date)
             AND d.@domain_date_col <= DATEADD(DAY, @lookback_end, t.index_date)
           GROUP BY t.subject_id",
    results_schema = results_schema_prefix(config),
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    domain_table = map$table,
    domain_concept_col = map$concept_col,
    domain_date_col = map$date_col,
    concept_ids = concept_id_string,
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(covariate$lookback_start_day),
    lookback_end = as.integer(covariate$lookback_end_day)
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

# -----------------------------------------------------------------------------
# calculate_scores()
#
# Iterates over all covariates defined in specs$covariates, calls
# query_covariate_counts() for each, and assembles a person-level wide matrix
# of score contributions.
#
# For each covariate:
#   1. Counts per patient are fetched from the CDM.
#   2. Counts are de-duplicated by subject_id (max aggregation) to guard against
#      Cartesian-product inflation from multi-row query results.
#   3. Missing patients (no CDM records) receive event_count = 0.
#   4. score_<covariate_id> = comp$points when event_count ≥ comp$min_count;
#      0 otherwise.  (min_count allows requiring ≥ N qualifying events.)
#
# The running covariate_matrix is de-duplicated after each merge to prevent
# row inflation from multi-covariate merges.
#
# final total_score = row sum of all score_<covariate_id> columns.
#
# Returns a named list:
#   $person_level       — per-patient data frame with all score columns + outcome
#   $covariate_summary  — aggregate summary (n_positive, mean_points per covariate)
# -----------------------------------------------------------------------------
calculate_scores <- function(connection, config, specs) {
  outcomes <- get_outcomes(connection, config)
  outcome_names <- tolower(names(outcomes))
  outcome_names[outcome_names == "subjectid"] <- "subject_id"
  outcome_names[outcome_names == "indexdate"] <- "index_date"
  names(outcomes) <- outcome_names

  covariates <- specs$covariates
  concepts <- specs$concepts

  covariate_matrix <- outcomes[, c("subject_id"), drop = FALSE]
  covariate_summary <- data.frame(
    covariate_id = character(),
    covariate_name = character(),
    domain = character(),
    n_positive = integer(),
    n_missing = integer(),
    mean_points = numeric(),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(covariates))) {
    comp <- covariates[i, ]
    comp_concepts <- concepts[concepts$covariate_id == comp$covariate_id, ]

    counts <- query_covariate_counts(connection, config, comp, comp_concepts)
    if (nrow(counts) > 0) {
      count_names <- tolower(names(counts))
      count_names[count_names == "subjectid"] <- "subject_id"
      count_names[count_names == "eventcount"] <- "event_count"
      names(counts) <- count_names
      # Deduplicate counts by subject_id (keep max event_count) to prevent
      # Cartesian-product inflation when a query returns multiple rows per person
      if (any(duplicated(counts$subject_id))) {
        counts <- aggregate(event_count ~ subject_id, data = counts, FUN = max)
      }
    } else {
      counts <- data.frame(subject_id = numeric(), event_count = numeric())
    }

    df <- merge(
      outcomes[, c("subject_id"), drop = FALSE],
      counts[, c("subject_id", "event_count"), drop = FALSE],
      by = "subject_id",
      all.x = TRUE
    )
    # Count patients with no CDM records for this covariate BEFORE 0-imputation.
    # When missing_is_negative = TRUE the covariate query only returns positive
    # cases; all un-returned patients are true negatives, not missing data
    # (e.g. male patients for the sex covariate, CLI patients for claudication).
    # When FALSE, absent records may genuinely reflect unmeasured data
    # (e.g. no BMI or ABI measurement in the lookback window).
    missing_is_neg <- isTRUE(comp$missing_is_negative)
    n_missing_comp <- if (missing_is_neg) 0L else sum(is.na(df$event_count))

    df$event_count[is.na(df$event_count)] <- 0L

    score_col <- paste0("score_", comp$covariate_id)
    df[[score_col]] <- ifelse(df$event_count >= comp$min_count, comp$points, 0)

    covariate_matrix <- merge(covariate_matrix, df[, c("subject_id", score_col)], by = "subject_id", all.x = TRUE)
    # Prevent cascading duplication: keep first row per subject after each merge
    covariate_matrix <- covariate_matrix[!duplicated(covariate_matrix$subject_id), ]

    is_activated <- df$event_count >= comp$min_count

    covariate_summary <- rbind(
      covariate_summary,
      data.frame(
        covariate_id = comp$covariate_id,
        covariate_name = comp$covariate_name,
        domain = comp$domain,
        n_positive = sum(is_activated, na.rm = TRUE),
        n_missing = n_missing_comp,
        mean_points = mean(df[[score_col]], na.rm = TRUE),
        stringsAsFactors = FALSE
      )
    )
  }

  score_cols <- grep("^score_", names(covariate_matrix), value = TRUE)
  covariate_matrix$total_score <- rowSums(covariate_matrix[, score_cols, drop = FALSE], na.rm = TRUE)

  person_level <- merge(outcomes, covariate_matrix, by = "subject_id", all.x = TRUE)

  # Join SSI sub-type (Superficial / Deep / Organ-space) — NA for non-SSI patients
  ssi_types <- tryCatch(
    get_ssi_type(connection, config),
    error = function(e) {
      message("[pipeline] ssi_type lookup failed (non-fatal): ", conditionMessage(e))
      data.frame(subject_id = integer(0), ssi_type = character(0),
                 stringsAsFactors = FALSE)
    }
  )
  if (nrow(ssi_types) > 0) {
    person_level <- merge(person_level, ssi_types, by = "subject_id", all.x = TRUE)
  } else {
    person_level$ssi_type <- NA_character_
  }

  list(person_level = person_level, covariate_summary = covariate_summary)
}

# -----------------------------------------------------------------------------
# clamp_probability()
#
# Clips a numeric probability vector to the open interval (eps, 1−eps) to
# avoid log(0) in logit transforms and degenerate likelihood calculations.
# Default eps = 1e-6 is small enough not to materially affect metric values
# while preventing NaN/Inf in downstream glm() and qlogis() calls.
# -----------------------------------------------------------------------------
clamp_probability <- function(p, eps = 1e-6) {
  p <- as.numeric(p)
  p[p < eps] <- eps
  p[p > (1 - eps)] <- 1 - eps
  p
}

# -----------------------------------------------------------------------------
# compute_bootstrap_cis()
#
# Computes 95% bootstrap percentile confidence intervals for all six performance
# metrics in a single pass to avoid redundant resampling.
#
# Algorithm:
#   1. Draw B = 500 bootstrap samples (with replacement) from the paired (y, p)
#      vectors.  Seed is fixed (default 42) for reproducibility.
#   2. For each resample compute: AUROC (pROC), AUPRC (PRROC integral), Brier
#      score, ECE (10 equal-frequency bins), calibration intercept (logistic
#      regression with offset), and calibration slope (logistic regression).
#      Resamples with only one outcome class are silently skipped (return NULL).
#   3. Collect valid resamples into a matrix; extract the 2.5th and 97.5th
#      percentiles of each column as the CI bounds.
#
# Returns a named list; each element is a length-2 numeric vector [lower, upper]:
#   $auroc, $auprc, $brier, $ece, $cal_int, $cal_slope
#
# B = 500 gives stable CI estimates for cohort sizes in the range 200–2000.
# Increase B for smaller cohorts or publication-quality precision.
# -----------------------------------------------------------------------------
# Bootstrap 95% percentile confidence intervals for all six performance metrics.
# Uses B = 500 resamples (enough for stable percentile CIs at n ~ 200-500).
# Each resample fits AUROC, AUPRC, Brier, ECE, calibration intercept, and
# calibration slope in a single pass to avoid redundant computation.
# Returns a named list with elements auroc, auprc, brier, ece, cal_int,
# cal_slope; each a length-2 numeric vector (lower, upper).
compute_bootstrap_cis <- function(y, p, B = 500, seed = 42) {
  set.seed(seed)
  n    <- length(y)
  y    <- as.numeric(y)
  p    <- clamp_probability(p)

  boot_vals <- lapply(seq_len(B), function(i) {
    idx <- sample.int(n, replace = TRUE)
    yi  <- y[idx]
    pi  <- clamp_probability(p[idx])
    lpi <- qlogis(pi)

    if (length(unique(yi)) < 2) return(NULL)

    auroc_i <- tryCatch(
      as.numeric(pROC::auc(pROC::roc(yi, pi, quiet = TRUE, direction = "<"))),
      error = function(e) NA_real_
    )
    auprc_i <- tryCatch(
      PRROC::pr.curve(
        scores.class0 = pi[yi == 1],
        scores.class1 = pi[yi == 0],
        curve = FALSE
      )$auc.integral,
      error = function(e) NA_real_
    )
    brier_i  <- mean((pi - yi)^2)
    ece_i    <- tryCatch(compute_ece(yi, pi), error = function(e) NA_real_)
    cal_int_i <- tryCatch(
      unname(coef(glm(yi ~ 1 + offset(lpi), family = binomial()))[1]),
      error = function(e) NA_real_
    )
    cal_slope_i <- tryCatch(
      unname(coef(glm(yi ~ lpi, family = binomial()))[2]),
      error = function(e) NA_real_
    )

    data.frame(
      auroc = auroc_i, auprc = auprc_i, brier = brier_i,
      ece = ece_i, cal_int = cal_int_i, cal_slope = cal_slope_i,
      stringsAsFactors = FALSE
    )
  })

  mat <- do.call(rbind, Filter(Negate(is.null), boot_vals))

  pct_ci <- function(col) {
    v <- mat[[col]]
    as.numeric(quantile(v[!is.na(v)], probs = c(0.025, 0.975), names = FALSE))
  }

  list(
    auroc     = pct_ci("auroc"),
    auprc     = pct_ci("auprc"),
    brier     = pct_ci("brier"),
    ece       = pct_ci("ece"),
    cal_int   = pct_ci("cal_int"),
    cal_slope = pct_ci("cal_slope")
  )
}

# -----------------------------------------------------------------------------
# compute_ece()
#
# Expected Calibration Error using equal-frequency (quantile) bins.
#
# ECE = Σ_b (n_b / N) × | mean_predicted_b − mean_observed_b |
#
# where b indexes bins, n_b is the bin count, and N is the total sample size.
# Equal-frequency binning is used (vs. equal-width) so that each bin contains
# approximately the same number of patients; this avoids inflated ECE from
# near-empty tails.  Degenerate binning (< 3 unique quantile values) falls back
# to a single [0, 1] bin.
#
# Probabilities are clamped to [eps, 1−eps] before binning to prevent boundary
# artefacts.
# -----------------------------------------------------------------------------
compute_ece <- function(y, p, n_bins = 10) {
  p <- clamp_probability(p)
  d <- data.frame(y = as.numeric(y), p = as.numeric(p))

  probs <- unique(stats::quantile(d$p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
  if (length(probs) < 3) {
    probs <- c(0, 1)
  }
  d$bin <- cut(d$p, breaks = probs, include.lowest = TRUE)

  predicted_mean <- tapply(d$p, d$bin, mean, na.rm = TRUE)
  observed_mean  <- tapply(d$y, d$bin, mean, na.rm = TRUE)
  bin_size       <- tapply(d$y, d$bin, length)

  abs_diff <- abs(predicted_mean - observed_mean)
  ece <- sum(abs_diff * bin_size, na.rm = TRUE) / sum(bin_size, na.rm = TRUE)
  as.numeric(ece)
}

# -----------------------------------------------------------------------------
# compute_binary_metrics()
#
# Computes three discrimination / scoring metrics for a binary outcome y and
# a continuous predictor estimate:
#   auroc  — area under the ROC curve (pROC::auc with direction = "<")
#   auprc  — area under the precision-recall curve (PRROC integral)
#   brier  — mean squared error between estimate and binary y
#
# When y is constant (all 0 or all 1) AUROC and AUPRC cannot be computed;
# both are returned as NA while Brier is still computed.
#
# PRROC::pr.curve() convention: scores.class0 receives predicted scores for
# positive events (y = 1) and scores.class1 receives them for negatives (y = 0).
# -----------------------------------------------------------------------------
compute_binary_metrics <- function(y, estimate) {
  if (!requireNamespace("pROC", quietly = TRUE)) {
    stop("Package 'pROC' is required for AUROC metrics.")
  }
  if (!requireNamespace("PRROC", quietly = TRUE)) {
    stop("Package 'PRROC' is required for AUPRC metrics.")
  }

  y_num <- as.numeric(y)
  score <- as.numeric(estimate)

  if (length(unique(y_num)) < 2) {
    return(list(
      auroc = NA_real_,
      auprc = NA_real_,
      brier = mean((score - y_num)^2)
    ))
  }

  roc_obj <- pROC::roc(
    response = y_num,
    predictor = score,
    quiet = TRUE,
    direction = "<"
  )

  pr <- PRROC::pr.curve(
    scores.class0 = score[y_num == 1],
    scores.class1 = score[y_num == 0],
    curve = FALSE
  )

  list(
    auroc = as.numeric(pROC::auc(roc_obj)),
    auprc = as.numeric(pr$auc.integral),
    brier = mean((score - y_num)^2)
  )
}

# -----------------------------------------------------------------------------
# score_discrimination_metrics()
#
# Computes AUROC and AUPRC for the raw integer score (before probability
# mapping), optionally with 95% bootstrap CIs.
#
# Arguments:
#   y        — binary outcome vector (0/1 integer or logical)
#   score    — continuous risk score (higher = higher predicted risk)
#   boot_ci  — if TRUE (default), adds ci_lower and ci_upper via
#              compute_bootstrap_cis()
#   B        — bootstrap resamples (default 500)
#
# Returns a data frame with columns: metric, value, ci_lower, ci_upper, model.
# model is always "score_only" to distinguish from lookup / recalibrated models.
# -----------------------------------------------------------------------------
score_discrimination_metrics <- function(y, score, boot_ci = TRUE, B = 500) {
  if (length(unique(y)) < 2) {
    return(data.frame(
      metric   = c("AUROC", "AUPRC"),
      value    = NA_real_,
      ci_lower = NA_real_,
      ci_upper = NA_real_,
      model    = "score_only",
      stringsAsFactors = FALSE
    ))
  }

  discrim  <- compute_binary_metrics(y, score)
  ci_lower <- rep(NA_real_, 2)
  ci_upper <- rep(NA_real_, 2)

  if (boot_ci) {
    cis      <- compute_bootstrap_cis(y, score, B = B)
    ci_lower <- c(cis$auroc[1], cis$auprc[1])
    ci_upper <- c(cis$auroc[2], cis$auprc[2])
  }

  data.frame(
    metric   = c("AUROC", "AUPRC"),
    value    = c(discrim$auroc, discrim$auprc),
    ci_lower = ci_lower,
    ci_upper = ci_upper,
    model    = "score_only",
    stringsAsFactors = FALSE
  )
}

# -----------------------------------------------------------------------------
# probability_metrics()
#
# Computes all six calibration and discrimination metrics for a model that
# outputs predicted probabilities p for binary outcome y.
#
# Metrics:
#   AUROC                — area under the ROC curve
#   AUPRC                — area under the precision-recall curve
#   Brier                — mean squared prediction error (lower = better)
#   ECE                  — expected calibration error (10 equal-frequency bins)
#   CalibrationIntercept — logistic regression intercept when the published
#                          log-odds is used as a fixed offset; ideal value = 0
#   CalibrationSlope     — logistic regression slope on the log-odds predictor;
#                          ideal value = 1
#
# Arguments:
#   y          — binary outcome vector
#   p          — predicted probability vector (will be clamped to (eps, 1-eps))
#   model_name — string label stored in the model column of the output
#   boot_ci    — if TRUE, computes 95% bootstrap percentile CIs (B resamples)
#   B          — number of bootstrap resamples (default 500)
#
# Returns a data frame with columns: metric, value, ci_lower, ci_upper, model.
# -----------------------------------------------------------------------------
probability_metrics <- function(y, p, model_name, boot_ci = TRUE, B = 500) {
  p  <- clamp_probability(p)
  lp <- qlogis(p)

  metrics_names <- c("AUROC", "AUPRC", "Brier", "ECE", "CalibrationIntercept", "CalibrationSlope")

  if (length(unique(y)) < 2) {
    return(data.frame(
      metric   = metrics_names,
      value    = NA_real_,
      ci_lower = NA_real_,
      ci_upper = NA_real_,
      model    = model_name,
      stringsAsFactors = FALSE
    ))
  }

  prob_metrics    <- compute_binary_metrics(y, p)
  ece             <- compute_ece(y, p)
  intercept_fit   <- glm(y ~ 1 + offset(lp), family = binomial())
  calib_intercept <- unname(coef(intercept_fit)[1])
  slope_fit       <- glm(y ~ lp, family = binomial())
  calib_slope     <- unname(coef(slope_fit)[2])

  values   <- c(prob_metrics$auroc, prob_metrics$auprc, prob_metrics$brier,
                ece, calib_intercept, calib_slope)
  ci_lower <- rep(NA_real_, 6)
  ci_upper <- rep(NA_real_, 6)

  if (boot_ci) {
    cis      <- compute_bootstrap_cis(y, p, B = B)
    ci_lower <- c(cis$auroc[1], cis$auprc[1], cis$brier[1],
                  cis$ece[1],   cis$cal_int[1], cis$cal_slope[1])
    ci_upper <- c(cis$auroc[2], cis$auprc[2], cis$brier[2],
                  cis$ece[2],   cis$cal_int[2], cis$cal_slope[2])
  }

  data.frame(
    metric   = metrics_names,
    value    = values,
    ci_lower = ci_lower,
    ci_upper = ci_upper,
    model    = model_name,
    stringsAsFactors = FALSE
  )
}

# -----------------------------------------------------------------------------
# build_calibration_table()
#
# Bins predicted probabilities p into n_bins equal-frequency groups and
# computes the mean predicted probability and mean observed event rate per bin.
#
# Returns a data frame with columns: bin (factor label), predicted, observed.
# This table is used both for calibration plots and for the calibration CSV
# outputs (calibration_table_lookup.csv, calibration_table_recalibrated.csv).
# -----------------------------------------------------------------------------
build_calibration_table <- function(y, p, n_bins = 10) {
  p <- clamp_probability(p)
  d <- data.frame(y = y, p = p)

  probs <- unique(stats::quantile(d$p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
  if (length(probs) < 3) {
    probs <- c(0, 1)
  }
  d$bin <- cut(d$p, breaks = probs, include.lowest = TRUE)

  aggregate(
    cbind(predicted = d$p, observed = d$y) ~ bin,
    data = d,
    FUN = mean
  )
}

# -----------------------------------------------------------------------------
# evaluate_integer_risk_score()
#
# Orchestrates the full evaluation of the integer risk score against the binary
# SSI outcome, producing metrics and calibration tables for up to three model
# specifications:
#
#   score_only   — discrimination metrics (AUROC, AUPRC) on the raw integer
#                  score without probability mapping.
#   lookup       — all six metrics on published score-to-risk probabilities from
#                  risk_lookup.csv.  Skipped when lookup is NULL or when no
#                  patients have a matching row in the lookup table.
#   recalibrated — all six metrics on probabilities from a logistic regression
#                  of total_score → outcome fitted in the validation cohort.
#
# The recalibrated model is always fitted (it requires no external lookup table)
# and its predicted probabilities are stored in person_level as
# predicted_risk_recalibrated for downstream report functions.
#
# Returns a named list:
#   $person_level        — input data frame augmented with predicted probability
#                          columns and outcome
#   $metrics             — data frame of all metrics (rbind of up to 3 model blocks)
#   $calibration_tables  — named list of calibration data frames (lookup, recalibrated)
# -----------------------------------------------------------------------------
evaluate_integer_risk_score <- function(person_level, lookup) {
  y <- as.integer(person_level$outcome)
  score <- as.numeric(person_level$total_score)

  metrics <- score_discrimination_metrics(y, score)
  calibration_tables <- list()

  if (!is.null(lookup)) {
    person_level <- merge(person_level, lookup, by.x = "total_score", by.y = "score", all.x = TRUE)
    names(person_level)[names(person_level) == "risk"] <- "predicted_risk_lookup"

    valid_lookup <- !is.na(person_level$predicted_risk_lookup)
    if (any(valid_lookup)) {
      metrics <- rbind(
        metrics,
        probability_metrics(
          y = y[valid_lookup],
          p = person_level$predicted_risk_lookup[valid_lookup],
          model_name = "lookup"
        )
      )
      calibration_tables$lookup <- build_calibration_table(
        y = y[valid_lookup],
        p = person_level$predicted_risk_lookup[valid_lookup]
      )
    }
  }

  recal_fit <- glm(y ~ score, family = binomial())
  person_level$predicted_risk_recalibrated <- stats::predict(recal_fit, type = "response")

  metrics <- rbind(
    metrics,
    probability_metrics(
      y = y,
      p = person_level$predicted_risk_recalibrated,
      model_name = "recalibrated"
    )
  )
  calibration_tables$recalibrated <- build_calibration_table(
    y = y,
    p = person_level$predicted_risk_recalibrated
  )

  list(person_level = person_level, metrics = metrics, calibration_tables = calibration_tables)
}

# -----------------------------------------------------------------------------
# calc_ece()
#
# Computes the Expected Calibration Error (ECE) between a vector of predicted
# probabilities and a binary outcome vector.
#
# Method: predictions are sorted into n_bins equal-width probability bins
# spanning [0, 1].  For each non-empty bin the absolute difference between
# the mean predicted probability and the observed event rate is computed and
# weighted by the fraction of observations in that bin.  ECE is the weighted
# sum across all bins.
#
# Arguments:
#   pred   — numeric vector of predicted probabilities in [0, 1]
#   truth  — numeric vector of binary outcomes (0/1)
#   n_bins — number of equal-width bins (default 10)
#
# Returns a single numeric value, or NA if no valid observations remain after
# removing NAs.
# -----------------------------------------------------------------------------
calc_ece <- function(pred, truth, n_bins = 10L) {

  # Remove missing values from both vectors jointly.
  valid <- !is.na(pred) & !is.na(truth)
  pred  <- pred[valid]
  truth <- truth[valid]
  if (length(pred) == 0L) return(NA_real_)

  # Assign each prediction to one of n_bins equal-width bins over [0, 1].
  breaks <- seq(0, 1, length.out = n_bins + 1L)
  bins   <- cut(pred, breaks = breaks, include.lowest = TRUE, labels = FALSE)

  n   <- length(pred)
  ece <- 0.0

  for (b in seq_len(n_bins)) {
    idx <- which(bins == b)
    if (length(idx) == 0L) next
    # Weighted absolute calibration error for this bin.
    ece <- ece + (length(idx) / n) * abs(mean(pred[idx]) - mean(truth[idx]))
  }

  ece
}

# -----------------------------------------------------------------------------
# compute_subgroup_bias()
#
# Evaluates ECE (Expected Calibration Error) for the lookup model within each
# demographic and clinical subgroup.  Groups with fewer than min_events observed
# SSI events are suppressed to avoid unreliable estimates.
#
# Subgroups evaluated:
#   sex        — Female / Male  (from OMOP person table via fetch_subgroup_labels)
#   race       — White / Black / Other
#   ethnicity  — Hispanic / Non-Hispanic
#   age_group  — <65 / 65-74 / >=75
#   indication — Claudication / Critical limb ischemia
#                (derived from score_indicationClaudication in person_level;
#                 score > 0 → Claudication, score == 0 → Critical limb ischemia)
#
# Bootstrap CIs use B = 200 resamples (percentile method, 2.5th–97.5th).
# The random seed is fixed at 42 for reproducibility.
#
# Arguments:
#   person_level — data frame returned by evaluate_integer_risk_score()
#   connection   — open DatabaseConnector connection object
#   config       — list from get_validation_config()
#   B            — number of bootstrap resamples (default 200)
#   min_events   — minimum observed events required per subgroup (default 10)
#
# Returns a data frame with columns:
#   subgroup_var, subgroup_level, n, n_events, ece, ci_lower, ci_upper
# Returns NULL if demographics cannot be fetched or no subgroups qualify.
# -----------------------------------------------------------------------------
compute_subgroup_bias <- function(person_level,
                                  connection,
                                  config,
                                  B          = 200L,
                                  min_events = 10L) {

  # ---------------------------------------------------------------------------
  # Step 1 — fetch demographic subgroup labels from OMOP person table.
  # ---------------------------------------------------------------------------
  subgroup_labels <- fetch_subgroup_labels(connection, config)

  if (is.null(subgroup_labels)) {
    warning("[subgroup_bias] Could not fetch demographic labels — skipping.")
    return(NULL)
  }

  # ---------------------------------------------------------------------------
  # Step 2 — merge demographics with person-level scores.
  # ---------------------------------------------------------------------------
  df <- merge(person_level, subgroup_labels, by = "subject_id", all.x = TRUE)

  # ---------------------------------------------------------------------------
  # Step 3 — derive surgical indication from score_indicationClaudication.
  # The column name follows the pattern score_<covariate_id>; covariate_id is
  # "indicationClaudication" as defined in covariates.csv.
  # score > 0 means the Claudication component was positive at the index date.
  # ---------------------------------------------------------------------------
  ind_col <- names(df)[tolower(names(df)) == "score_indicationclaudication"][1]
  if (is.na(ind_col)) {
    # Exact-case fallback for case-sensitive environments.
    ind_col <- if ("score_indicationClaudication" %in% names(df))
                 "score_indicationClaudication"
               else
                 NA_character_
  }

  if (!is.na(ind_col)) {
    df$indication <- ifelse(
      !is.na(df[[ind_col]]) & as.numeric(df[[ind_col]]) > 0,
      "Claudication",
      "Critical limb ischemia"
    )
  } else {
    message("[subgroup_bias] score_indicationClaudication column not found ",
            "— indication subgroup will be skipped.")
    df$indication <- NA_character_
  }

  # ---------------------------------------------------------------------------
  # Step 4 — require the lookup model predictions.
  # ---------------------------------------------------------------------------
  if (!"predicted_risk_lookup" %in% names(df)) {
    warning("[subgroup_bias] predicted_risk_lookup column not found — skipping.")
    return(NULL)
  }

  # ---------------------------------------------------------------------------
  # Step 4b — derive calendar year from index_date for temporal subgroup.
  # ---------------------------------------------------------------------------
  if ("index_date" %in% names(df)) {
    year_val <- tryCatch(
      as.integer(format(as.Date(df$index_date), "%Y")),
      error = function(e) NA_integer_
    )
    if (!all(is.na(year_val))) {
      df$year <- as.character(year_val)
    }
  }

  # ---------------------------------------------------------------------------
  # Step 4c — derive procedure type subgroup from OMOP CDM.
  # ---------------------------------------------------------------------------
  proc_type_labels <- tryCatch(
    fetch_proc_type_labels(connection, config),
    error = function(e) {
      message("[subgroup_bias] fetch_proc_type_labels failed: ", conditionMessage(e))
      NULL
    }
  )
  if (!is.null(proc_type_labels)) {
    df <- merge(df, proc_type_labels, by = "subject_id", all.x = TRUE)
  }

  # ---------------------------------------------------------------------------
  # Step 5 — bootstrap ECE for each non-empty, qualifying subgroup level.
  # ---------------------------------------------------------------------------
  subgroup_vars <- c("sex", "race", "ethnicity", "age_group", "indication", "year", "proc_type")
  # Keep only vars that were successfully added to df.
  subgroup_vars <- subgroup_vars[subgroup_vars %in% names(df)]

  set.seed(42L)
  results <- list()

  for (var in subgroup_vars) {

    levels_present <- sort(unique(na.omit(as.character(df[[var]]))))

    for (lvl in levels_present) {

      # Filter to this subgroup; drop rows with missing predictions or outcomes.
      grp <- df[!is.na(df[[var]]) & as.character(df[[var]]) == lvl, ]
      grp <- grp[!is.na(grp$predicted_risk_lookup) & !is.na(grp$outcome), ]

      n_total  <- nrow(grp)
      n_events <- sum(as.integer(grp$outcome), na.rm = TRUE)

      # Suppress if below minimum event threshold.
      if (n_events < min_events) {
        message(sprintf(
          "[subgroup_bias] Suppressing %s = '%s': %d events < min %d",
          var, lvl, n_events, min_events
        ))
        next
      }

      # Observed ECE for this subgroup.
      ece_obs <- calc_ece(grp$predicted_risk_lookup, as.numeric(grp$outcome))

      # Bootstrap to obtain 95% percentile CI.
      boot_eces <- vapply(seq_len(B), function(i) {
        idx <- sample(n_total, n_total, replace = TRUE)
        calc_ece(grp$predicted_risk_lookup[idx], as.numeric(grp$outcome[idx]))
      }, numeric(1L))
      boot_eces <- boot_eces[!is.na(boot_eces)]

      ci_lo <- stats::quantile(boot_eces, 0.025, na.rm = TRUE)
      ci_hi <- stats::quantile(boot_eces, 0.975, na.rm = TRUE)

      results[[length(results) + 1L]] <- data.frame(
        subgroup_var   = var,
        subgroup_level = lvl,
        n              = n_total,
        n_events       = n_events,
        ece            = round(ece_obs, 4),
        ci_lower       = round(as.numeric(ci_lo), 4),
        ci_upper       = round(as.numeric(ci_hi), 4),
        stringsAsFactors = FALSE
      )
    }
  }

  if (length(results) == 0L) {
    warning("[subgroup_bias] No subgroups met the minimum event threshold ",
            "(min_events = ", min_events, ").")
    return(NULL)
  }

  dplyr::bind_rows(results)
}

# -----------------------------------------------------------------------------
# save_calibration_plot()
#
# Saves a calibration plot (mean predicted vs. mean observed per decile) to
# a PNG file named calibration_<model_name>.png in output_folder.
# Calls ggplot2::ggsave() at 150 dpi, 7×5 inches.
# -----------------------------------------------------------------------------
save_calibration_plot <- function(calibration_table, model_name, output_folder) {
  p <- ggplot2::ggplot(calibration_table, ggplot2::aes(x = predicted, y = observed)) +
    ggplot2::geom_point(size = 2) +
    ggplot2::geom_line() +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed", color = "gray") +
    ggplot2::labs(
      title = paste("Calibration Plot:", model_name),
      x = "Mean predicted risk",
      y = "Observed event rate"
    ) +
    ggplot2::scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::coord_equal() +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, paste0("calibration_", model_name, ".png"))
  ggplot2::ggsave(out_file, p, width = 5, height = 5, dpi = 150)
}

# =============================================================================
# run_integer_risk_score_pipeline()
#
# Top-level entry point for the integer risk score evaluation.
# Called from workflow/08_run_analysis_and_manuscript_report.R.
#
# Execution sequence:
#   1. Create the output folder if it does not exist.
#   2. read_score_specs()        — load and validate CSV spec files
#   3. connect()                 — open a JDBC connection using connection_details
#   4. ensure_concept_ancestor_indexes() — create covering indexes if missing
#   5. calculate_scores()        — query CDM and assign covariate points per patient
#   6. evaluate_integer_risk_score() — compute metrics + calibration tables
#   7. write_csv()               — save person_level_scores.csv,
#                                  covariate_summary.csv, metrics.csv,
#                                  calibration_table_*.csv
#   8. save_calibration_plot()   — save calibration_*.png for each model
#
# Arguments:
#   config             — list from get_validation_config() in config.R.
#                        Uses config$covariate_definitions_file,
#                        config$covariate_concepts_file, and
#                        config$output_folder as the output root.
#   connection_details — DatabaseConnector ConnectionDetails object
#   output_folder      — directory for pipeline outputs (person_level_scores.csv,
#                        covariate_summary.csv, metrics.csv, calibration_*.png).
#                        Defaults to config$output_folder.
#   lookup_file        — optional path to a score → probability lookup CSV
#                        (columns: score, risk). Pass NULL to use logistic
#                        recalibration only.
#
# Returns the eval_results list (invisibly); primary side effect is writing
# output files to output_folder.
# =============================================================================
run_integer_risk_score_pipeline <- function(config, connection_details,
                                            output_folder = config$output_folder,
                                            lookup_file   = NULL) {
  dir.create(output_folder, recursive = TRUE, showWarnings = TRUE)
  if (!dir.exists(output_folder)) {
    stop(
      "Could not create output directory: ", output_folder, "\n",
      "Check that you have write access to: ",
      dirname(output_folder)
    )
  }

  message("\n=== Integer risk score pipeline ===")
  message("Reading score specification files ...")
  specs <- read_score_specs(config, lookup_file = lookup_file)

  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  message("Checking concept_ancestor indexes ...")
  ensure_concept_ancestor_indexes(conn, config)

  message("Calculating person-level score covariates ...")
  score_data <- calculate_scores(conn, config, specs)
  person_level <- score_data$person_level

  message("Evaluating discrimination and calibration ...")
  eval_results <- evaluate_integer_risk_score(person_level, specs$lookup)

  out <- output_folder

  readr::write_csv(eval_results$person_level, file.path(out, "person_level_scores.csv"))
  readr::write_csv(score_data$covariate_summary, file.path(out, "covariate_summary.csv"))
  readr::write_csv(eval_results$metrics, file.path(out, "metrics.csv"))

  # ---------------------------------------------------------------------------
  # Subgroup bias analysis — ECE per demographic and clinical subgroup.
  # Suppressed for subgroups with fewer than 10 observed SSI events.
  # Uses 200 bootstrap resamples per subgroup for speed.
  # ---------------------------------------------------------------------------
  message("Computing subgroup bias analysis (B = 200 per subgroup) ...")
  subgroup_bias <- tryCatch(
    compute_subgroup_bias(eval_results$person_level, conn, config,
                          B = 200L, min_events = 10L),
    error = function(e) {
      message("[subgroup_bias] Skipped due to error: ", conditionMessage(e))
      NULL
    }
  )
  if (!is.null(subgroup_bias) && nrow(subgroup_bias) > 0) {
    readr::write_csv(subgroup_bias, file.path(out, "subgroup_bias.csv"))
    message("Wrote: subgroup_bias.csv (", nrow(subgroup_bias), " subgroup rows)")
  }

  for (nm in names(eval_results$calibration_tables)) {
    tbl <- eval_results$calibration_tables[[nm]]
    readr::write_csv(tbl, file.path(out, paste0("calibration_table_", nm, ".csv")))
    save_calibration_plot(tbl, nm, out)
  }

  message("Output folder: ", normalizePath(out, winslash = "/", mustWork = FALSE))
  message("Wrote: person_level_scores.csv, covariate_summary.csv, metrics.csv, calibration tables, calibration plots")

  invisible(eval_results)
}
