# R/cohort_demographics.R
# Extract cohort demographic and procedural characteristics from OMOP CDM
# Used by the extended report generation

#' Calculate cohort summary statistics
#'
#' @param person_level Data frame with person-level scores (from risk_score_pipeline)
#' @param connection DatabaseConnector connection object
#' @param config Configuration list with CDM/cohort details
#' @return Data frame with cohort summary statistics
calculate_cohort_summary <- function(person_level, connection, config) {
  
  if (is.null(person_level) || nrow(person_level) == 0) {
    return(NULL)
  }
  
  # Extract basic counts
  n_total_procedures <- nrow(person_level)
  n_unique_patients <- length(unique(person_level$subject_id))
  n_ssi_events <- sum(person_level$outcome, na.rm = TRUE)
  ssi_rate <- round(100 * n_ssi_events / n_total_procedures, 2)
  
  # Age statistics
  sql_age <- SqlRender::render(
    "SELECT YEAR(p.birth_datetime) AS birth_year,
            YEAR(c.cohort_start_date) - YEAR(p.birth_datetime) AS age_at_index
     FROM @results_schema.@cohort_table c
     INNER JOIN @cdm_schema.person p ON c.subject_id = p.person_id
     WHERE c.cohort_definition_id = @target_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    cdm_schema = config$cdm_schema,
    target_id = config$target_cohort_id
  )
  
  age_data <- tryCatch({
    DatabaseConnector::querySql(connection, SqlRender::translate(sql_age, targetDialect = "sql server"))
  }, error = function(e) NULL)
  
  age_stats <- NULL
  if (!is.null(age_data) && nrow(age_data) > 0) {
    age_data$AGE_AT_INDEX <- as.numeric(age_data$AGE_AT_INDEX)
    age_stats <- list(
      mean_age = round(mean(age_data$AGE_AT_INDEX, na.rm = TRUE), 1),
      sd_age = round(sd(age_data$AGE_AT_INDEX, na.rm = TRUE), 1),
      median_age = as.numeric(median(age_data$AGE_AT_INDEX, na.rm = TRUE)),
      min_age = as.numeric(min(age_data$AGE_AT_INDEX, na.rm = TRUE)),
      max_age = as.numeric(max(age_data$AGE_AT_INDEX, na.rm = TRUE))
    )
  }
  
  # Gender distribution
  sql_gender <- SqlRender::render(
    "SELECT gc.concept_name AS gender,
            COUNT(DISTINCT p.person_id) AS count
     FROM @cdm_schema.person p
     INNER JOIN @results_schema.@cohort_table c ON p.person_id = c.subject_id
     INNER JOIN @cdm_schema.concept gc ON p.gender_concept_id = gc.concept_id
     WHERE c.cohort_definition_id = @target_id
     GROUP BY gc.concept_name
     ORDER BY count DESC",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    cdm_schema = config$cdm_schema,
    target_id = config$target_cohort_id
  )
  
  gender_data <- tryCatch({
    DatabaseConnector::querySql(connection, SqlRender::translate(sql_gender, targetDialect = "sql server"))
  }, error = function(e) NULL)
  
  # Return summary as data frame
  summary_df <- data.frame(
    characteristic = c(
      "Total procedures", "Unique patients", "SSI events", "SSI rate (%)",
      "Mean age (SD)", "Median age [min, max]"
    ),
    value = c(
      as.character(n_total_procedures),
      as.character(n_unique_patients),
      as.character(n_ssi_events),
      as.character(ssi_rate),
      if (!is.null(age_stats)) 
        paste0(age_stats$mean_age, " (", age_stats$sd_age, ")")
      else "N/A",
      if (!is.null(age_stats))
        paste0(age_stats$median_age, " [", age_stats$min_age, ", ", age_stats$max_age, "]")
      else "N/A"
    ),
    stringsAsFactors = FALSE
  )
  
  # Add gender distribution if available
  if (!is.null(gender_data) && nrow(gender_data) > 0) {
    for (i in seq_len(nrow(gender_data))) {
      pct <- round(100 * gender_data$COUNT[i] / n_unique_patients, 1)
      summary_df <- rbind(summary_df, data.frame(
        characteristic = paste0(gender_data$GENDER[i], " (%)"),
        value = paste0(gender_data$COUNT[i], " (", pct, "%)"),
        stringsAsFactors = FALSE
      ))
    }
  }
  
  summary_df
}

#' Build combined feature table (covariates + prevalence)
#'
#' @param covariates Data frame from specs$covariates
#' @param covariate_summary Data frame from risk_score_pipeline output
#' @return Data frame suitable for flextable display
build_combined_feature_table <- function(covariates, covariate_summary) {

  if (is.null(covariate_summary)) {
    return(NULL)
  }

  # Merge covariates with prevalence data
  combined <- merge(
    covariates[, c("covariate_name", "points", "lookback_start_day", "lookback_end_day")],
    covariate_summary[, c("covariate_name", "n_positive", "n_total")],
    by = "covariate_name",
    all.x = TRUE
  )

  combined$lookback <- paste0(
    combined$lookback_start_day, " to ",
    combined$lookback_end_day, " days"
  )
  combined$prevalence <- paste0(
    combined$n_positive, " / ", combined$n_total, " (",
    round(100 * combined$n_positive / combined$n_total, 1), "%)"
  )

  # Select and reorder columns
  combined <- combined[, c("covariate_name", "points", "lookback", "prevalence")]
  names(combined) <- c("Covariate", "Points", "Lookback Window", "Prevalence (n / N, %)")
  
  combined
}

# -----------------------------------------------------------------------------
# fetch_subgroup_labels()
#
# Queries the OMOP CDM person table to assign demographic subgroup labels to
# each subject in the target cohort.  Returns a data frame with one row per
# subject_id and five label columns used by compute_subgroup_bias():
#
#   sex        — "Female" / "Male"  (OMOP gender_concept_id: 8532 = Female)
#   race       — "White" / "Black" / "Other"
#                (OMOP race_concept_id: 8527 = White, 8516 = Black)
#   ethnicity  — "Hispanic" / "Non-Hispanic"
#                (OMOP ethnicity_concept_id: 38003563 = Hispanic or Latino)
#   age_group  — "<65" / "65-74" / ">=75"  (age at index date in years)
#
# Note: surgical indication subgroup is derived from the score component
# column score_indicationClaudication in person_level (already computed by
# the risk score pipeline), so it is NOT included here.
#
# Returns NULL (with a warning) if the SQL query fails or returns no rows.
# -----------------------------------------------------------------------------
fetch_subgroup_labels <- function(connection, config) {

  # ---------------------------------------------------------------------------
  # Query person demographics + age at index date for all target cohort members.
  # FLOOR(DATEDIFF / 365.25) replicates the age calculation used elsewhere in
  # the pipeline (consistent with SQL FLOOR(days/365.25) convention).
  # ---------------------------------------------------------------------------
  sql <- SqlRender::render(
    "SELECT
       c.subject_id,
       FLOOR(DATEDIFF(day, p.birth_datetime, c.cohort_start_date) / 365.25)
         AS age_at_index,
       p.gender_concept_id,
       p.race_concept_id,
       p.ethnicity_concept_id
     FROM @results_schema.@cohort_table c
     INNER JOIN @cdm_schema.person p
       ON c.subject_id = p.person_id
     WHERE c.cohort_definition_id = @target_id",
    results_schema = config$results_schema,
    cohort_table   = config$cohort_table,
    cdm_schema     = config$cdm_schema,
    target_id      = config$target_cohort_id
  )

  demog <- tryCatch(
    DatabaseConnector::querySql(
      connection,
      SqlRender::translate(sql, targetDialect = "sql server")
    ),
    error = function(e) {
      warning("[fetch_subgroup_labels] Demographics query failed: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(demog) || nrow(demog) == 0) {
    warning("[fetch_subgroup_labels] No rows returned — subgroup labels unavailable.")
    return(NULL)
  }

  # Normalise column names: DatabaseConnector may return UPPER or mixed case.
  names(demog) <- tolower(names(demog))

  # ---------------------------------------------------------------------------
  # Map concept IDs to human-readable subgroup labels.
  # ---------------------------------------------------------------------------

  # Sex: 8532 = FEMALE; all others treated as Male.
  demog$sex <- ifelse(
    as.integer(demog$gender_concept_id) == 8532L,
    "Female",
    "Male"
  )

  # Race: 8527 = White, 8516 = Black; all others → "Other".
  demog$race <- dplyr::case_when(
    as.integer(demog$race_concept_id) == 8527L ~ "White",
    as.integer(demog$race_concept_id) == 8516L ~ "Black",
    TRUE                                        ~ "Other"
  )

  # Ethnicity: 38003563 = Hispanic or Latino; all others → "Non-Hispanic".
  demog$ethnicity <- ifelse(
    as.integer(demog$ethnicity_concept_id) == 38003563L,
    "Hispanic",
    "Non-Hispanic"
  )

  # Age group: three clinically meaningful bands.
  age <- as.numeric(demog$age_at_index)
  demog$age_group <- dplyr::case_when(
    age <  65 ~ "<65",
    age <  75 ~ "65-74",
    !is.na(age) ~ ">=75",
    TRUE        ~ NA_character_
  )

  # Return only the columns needed downstream.
  demog[, c("subject_id", "sex", "race", "ethnicity", "age_group")]
}

# -----------------------------------------------------------------------------
# fetch_proc_type_labels()
#
# Queries the OMOP CDM to assign a single procedure type label to each subject
# in the target cohort based on the qualifying procedure at the index visit.
# Priority order (highest to lowest): Extra-anatomic bypass, Aortobifemoral,
# Femoral-popliteal, Femorotibial, Femoral endarterectomy, Other.
#
# Returns a data frame with columns: subject_id, proc_type
# Returns NULL (with a warning) if the query fails.
# -----------------------------------------------------------------------------
fetch_proc_type_labels <- function(connection, config) {

  sql <- SqlRender::render(
    "WITH target AS (
       SELECT subject_id,
              cohort_start_date,
              ISNULL(cohort_end_date, cohort_start_date) AS cohort_end_date
       FROM @results_schema.@cohort_table
       WHERE cohort_definition_id = @target_id
     ),
     proc_hits AS (
       SELECT t.subject_id,
         MAX(CASE WHEN ca.ancestor_concept_id = 4050281 THEN 1 ELSE 0 END) AS is_extraanat,
         MAX(CASE WHEN ca.ancestor_concept_id = 4231680 THEN 1 ELSE 0 END) AS is_aortobif,
         MAX(CASE WHEN ca.ancestor_concept_id = 4012936 THEN 1 ELSE 0 END) AS is_fempop,
         MAX(CASE WHEN ca.ancestor_concept_id = 4166196 THEN 1 ELSE 0 END) AS is_femtib,
         MAX(CASE WHEN ca.ancestor_concept_id = 4040974 THEN 1 ELSE 0 END) AS is_endar
       FROM target t
       INNER JOIN @cdm_schema.procedure_occurrence po
         ON po.person_id = t.subject_id
        AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
       INNER JOIN @cdm_schema.concept_ancestor ca
         ON ca.descendant_concept_id = po.procedure_concept_id
        AND ca.ancestor_concept_id IN (4050281, 4231680, 4012936, 4166196, 4040974)
       GROUP BY t.subject_id
     )
     SELECT subject_id,
       CASE
         WHEN is_extraanat = 1 THEN 'Extra-anatomic bypass'
         WHEN is_aortobif  = 1 THEN 'Aortobifemoral bypass'
         WHEN is_fempop    = 1 THEN 'Femoral-popliteal bypass'
         WHEN is_femtib    = 1 THEN 'Femorotibial bypass'
         WHEN is_endar     = 1 THEN 'Femoral endarterectomy'
         ELSE 'Other'
       END AS proc_type
     FROM proc_hits",
    results_schema = config$results_schema,
    cohort_table   = config$cohort_table,
    cdm_schema     = config$cdm_schema,
    target_id      = config$target_cohort_id
  )

  result <- tryCatch(
    DatabaseConnector::querySql(
      connection,
      SqlRender::translate(sql, targetDialect = "sql server")
    ),
    error = function(e) {
      warning("[fetch_proc_type_labels] Query failed: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(result) || nrow(result) == 0) {
    warning("[fetch_proc_type_labels] No rows returned.")
    return(NULL)
  }

  names(result) <- tolower(names(result))
  result[, c("subject_id", "proc_type")]
}
