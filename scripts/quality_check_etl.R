# =============================================================================
# quality_check_etl.R
#
# Run post-load quality checks after the Synthea CSV -> OMOP ETL.
#
# Design notes:
# - This script supports both historical CSV-stage pipelines
#   (synthea_csv_stage.*_stage tables) and the current ETLSyntheaBuilder
#   staging pattern (synthea.* tables).
# - It auto-detects the active loaded CDM schema so Step 6 works even when
#   Step 5 uses the schema omop_synth_<study_name> (derived from study_params.yaml).
# - It can optionally enforce threshold gates for CI-style pass/fail checks.
# =============================================================================

# JVM + JDBC setup must happen before DatabaseConnector first touches Java.
local({
  java_home <- Sys.getenv(
    "JAVA_HOME",
    unset = "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot"
  )
  jdbc_rt_dir <- file.path(getwd(), "drivers", "jdbc-runtime")

  Sys.setenv(JAVA_HOME = java_home)
  Sys.setenv(PATH = paste(
    normalizePath(file.path(java_home, "bin"), winslash = "/", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  ))
  options(java.parameters = paste0(
    "-Djava.home=",
    normalizePath(java_home, winslash = "/", mustWork = FALSE)
  ))
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = jdbc_rt_dir)

  # Windows only: add JDBC auth DLL directory to PATH and java.library.path
  if (.Platform$OS.type == "windows") {
    jdbc_auth_dir <- file.path(getwd(), "drivers", "sqljdbc_13.2", "enu", "auth", "x64")
    Sys.setenv(PATH = paste(
      normalizePath(jdbc_auth_dir, winslash = "\\", mustWork = FALSE),
      Sys.getenv("PATH"),
      sep = .Platform$path.sep
    ))
    options(java.parameters = paste0(
      "-Djava.library.path=",
      normalizePath(jdbc_auth_dir, winslash = "/", mustWork = FALSE)
    ))
  }
})

source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")

# -----------------------------------------------------------------------------
# CLI argument parsing
# -----------------------------------------------------------------------------
# Supported flags:
#   --run_name=<name>
#   --enforce_thresholds=<true|false>
#   --min_person_rows=<n>
#   --min_open_revascularization_rows=<n>
#   --min_outcome_condition_rows=<n>
#   --min_mapped_condition_pct=<pct>
#   --run_achilles=<true|false>     Run ACHILLES CDM profiling (default: TRUE)
#   --run_dqd=<true|false>          Run OHDSI Data Quality Dashboard (default: TRUE)
#     NOTE: both default to TRUE in parse_args below. The comment previously
#     said "false", which is worth knowing because each stage costs 10-60 min
#     on a synthetic CDM — pass --run_achilles=false --run_dqd=false for a
#     fast Step 6.
#   --achilles_threads=<n>          Parallel threads for ACHILLES (default: 1)
parse_args <- function(args) {
  opts <- list(
    run_name = "",
    enforce_thresholds = FALSE,
    min_person_rows = 1,
    min_open_revascularization_rows = 1,
    min_outcome_condition_rows = 1,
    min_mapped_condition_pct = 0,
    run_achilles = TRUE,
    run_dqd = TRUE,
    achilles_threads = 1L
  )

  parse_bool <- function(x) {
    tolower(trimws(as.character(x))) %in% c("1", "true", "t", "yes", "y")
  }

  for (arg in args) {
    if (grepl("^--", arg)) {
      m <- regmatches(arg, regexec("^--([^=]+)=(.*)$", arg))[[1]]
      if (length(m) == 3) {
        key <- m[2]
        val <- m[3]
        if (identical(key, "run_name")) opts$run_name <- val
        if (identical(key, "enforce_thresholds")) opts$enforce_thresholds <- parse_bool(val)
        if (identical(key, "min_person_rows")) opts$min_person_rows <- as.numeric(val)
        if (identical(key, "min_open_revascularization_rows")) opts$min_open_revascularization_rows <- as.numeric(val)
        if (identical(key, "min_outcome_condition_rows")) opts$min_outcome_condition_rows <- as.numeric(val)
        if (identical(key, "min_mapped_condition_pct")) opts$min_mapped_condition_pct <- as.numeric(val)
        if (identical(key, "run_achilles")) opts$run_achilles <- parse_bool(val)
        if (identical(key, "run_dqd"))     opts$run_dqd     <- parse_bool(val)
        if (identical(key, "achilles_threads")) opts$achilles_threads <- as.integer(val)
      }
    } else if (!nzchar(opts$run_name)) {
      opts$run_name <- arg
    }
  }

  opts
}

args <- commandArgs(trailingOnly = TRUE)
opts <- parse_args(args)

# -----------------------------------------------------------------------------
# Connection helpers and metadata probes
# -----------------------------------------------------------------------------
config <- get_validation_config()

# Derive default run_name now that config is available.
if (!nzchar(opts$run_name)) {
  opts$run_name <- paste0(config$study_name, "-qc-", format(Sys.Date(), "%Y%m%d"))
}
run_name <- opts$run_name
conn <- DatabaseConnector::connect(build_connection_details(config))
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

# Centralized query wrapper keeps all SQL calls in one place.
run_query <- function(sql) {
  DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = TRUE)
}

# Helper: test if a physical table exists in SQL Server.
table_exists <- function(schema_name, table_name) {
  sql <- SqlRender::translate(SqlRender::render(
    "SELECT CASE WHEN OBJECT_ID('@schema_name.@table_name', 'U') IS NULL THEN 0 ELSE 1 END AS exists_flag;",
    schema_name = schema_name,
    table_name = table_name
  ), targetDialect = config$dbms)
  res <- run_query(sql)
  as.integer(res$existsFlag[[1]]) == 1L
}

# Helper: test if a given column exists in a table.
# Used for backward compatibility where run_name may not exist in staging.
column_exists <- function(schema_name, table_name, column_name) {
  sql <- SqlRender::translate(SqlRender::render(
    "SELECT COUNT(*) AS n
     FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = '@schema_name'
       AND TABLE_NAME = '@table_name'
       AND COLUMN_NAME = '@column_name';",
    schema_name = schema_name,
    table_name = table_name,
    column_name = column_name
  ), targetDialect = config$dbms)
  res <- run_query(sql)
  as.numeric(res$n[[1]]) > 0
}

# Resolve active CDM schema:
# 1) Use config$cdm_schema if it exists and has data.
# 2) Otherwise scan omop_synth_<study_name>* schemas and pick the most recent
#    suffix containing person rows (fallback for misconfigured study_params.yaml).
resolve_cdm_schema <- function(default_schema) {
  has_default_person <- FALSE
  if (table_exists(default_schema, "person")) {
    cnt_sql <- SqlRender::translate(SqlRender::render(
      "SELECT COUNT(*) AS n FROM @cdm_schema.person;",
      cdm_schema = default_schema
    ), targetDialect = config$dbms)
    cnt <- run_query(cnt_sql)
    has_default_person <- as.numeric(cnt$n[[1]]) > 0
  }
  if (has_default_person) {
    return(default_schema)
  }

  # Derive fallback base from study name (matches Step 5 schema naming convention).
  etl_base <- paste0("omop_synth_", config$study_name)
  safe_base <- gsub("'", "''", etl_base, fixed = TRUE)
  schema_sql <- paste0(
    "SELECT name FROM sys.schemas\n",
    "WHERE name = '", safe_base, "'\n",
    "   OR name LIKE '", safe_base, "[_]%';"
  )
  schema_rows <- run_query(schema_sql)
  if (nrow(schema_rows) == 0) {
    return(default_schema)
  }

  schema_names <- as.character(schema_rows$name)
  pat <- paste0("^", gsub("([][{}()+*^$|\\?.])", "\\\\\\1", etl_base), "_(\\d+)$")
  suffix <- suppressWarnings(as.integer(sub(pat, "\\1", schema_names, perl = TRUE)))

  order_index <- order(ifelse(is.na(suffix), -1L, suffix), decreasing = TRUE)
  ordered_candidates <- schema_names[order_index]

  for (candidate in ordered_candidates) {
    if (!table_exists(candidate, "person")) {
      next
    }
    cnt_sql <- SqlRender::translate(SqlRender::render(
      "SELECT COUNT(*) AS n FROM @cdm_schema.person;",
      cdm_schema = candidate
    ), targetDialect = config$dbms)
    cnt <- run_query(cnt_sql)
    if (as.numeric(cnt$n[[1]]) > 0) {
      return(candidate)
    }
  }

  default_schema
}

cdm_schema_active <- resolve_cdm_schema(config$cdm_schema)

# Detect staging mode:
# - csv_stage mode: legacy workflow with synthea_csv_stage.*_stage tables
# - synthea mode: current ETLSyntheaBuilder staging in synthea.* tables
staging_mode <- if (table_exists("synthea_csv_stage", "patients_stage")) {
  "csv_stage"
} else if (table_exists("synthea", "patients")) {
  "synthea"
} else {
  "none"
}

if (identical(staging_mode, "csv_stage")) {
  staging_schema <- "synthea_csv_stage"
  patients_table <- "patients_stage"
  encounters_table <- "encounters_stage"
  procedures_table <- "procedures_stage"
  conditions_table <- "conditions_stage"
} else if (identical(staging_mode, "synthea")) {
  staging_schema <- "synthea"
  patients_table <- "patients"
  encounters_table <- "encounters"
  procedures_table <- "procedures"
  conditions_table <- "conditions"
} else {
  stop("Could not find expected staging tables in either synthea_csv_stage or synthea schema.")
}

# Enable run_name filter only when staging tables physically contain a run_name
# column; older/newer load paths may not track run lineage at row level.
has_run_name <- column_exists(staging_schema, patients_table, "run_name")
run_name_filter <- if (isTRUE(has_run_name)) {
  " WHERE run_name = '@run_name'"
} else {
  ""
}

# Some ETL paths prefix person_source_value with synthea_csv:, others do not.
# Probe once and choose the safest person filter for downstream metrics.
use_synthea_csv_source_filter <- FALSE
if (table_exists(cdm_schema_active, "person")) {
  src_filter_probe_sql <- SqlRender::translate(SqlRender::render(
    "SELECT COUNT(*) AS n
     FROM @cdm_schema.person
     WHERE person_source_value LIKE 'synthea_csv:%';",
    cdm_schema = cdm_schema_active
  ), targetDialect = config$dbms)
  src_filter_probe <- run_query(src_filter_probe_sql)
  use_synthea_csv_source_filter <- as.numeric(src_filter_probe$n[[1]]) > 0
}

person_filter <- if (use_synthea_csv_source_filter) {
  "p.person_source_value LIKE 'synthea_csv:%'"
} else {
  "1=1"
}

# -----------------------------------------------------------------------------
# Human-readable run header
# -----------------------------------------------------------------------------
cat("=== ETL QUALITY CHECK ===\n")
cat("Run name:", run_name, "\n\n")
cat("Active CDM schema:", cdm_schema_active, "\n")
cat("Staging schema:", staging_schema, "\n")
cat("Staging mode:", staging_mode, "\n")
cat("Run-name filter:", ifelse(has_run_name, "enabled", "disabled"), "\n\n")

# -----------------------------------------------------------------------------
# Staging counts: show evidence that each expected source table is populated.
# -----------------------------------------------------------------------------
resource_sql <- SqlRender::translate(SqlRender::render(
  paste0(
    "SELECT source_schema, COUNT(*) AS row_count\n",
    "FROM (\n",
    "  SELECT '", patients_table, "'   AS source_schema FROM @staging_schema.", patients_table, run_name_filter, "\n",
    "  UNION ALL\n",
    "  SELECT '", encounters_table, "' AS source_schema FROM @staging_schema.", encounters_table, run_name_filter, "\n",
    "  UNION ALL\n",
    "  SELECT '", procedures_table, "' AS source_schema FROM @staging_schema.", procedures_table, run_name_filter, "\n",
    "  UNION ALL\n",
    "  SELECT '", conditions_table, "' AS source_schema FROM @staging_schema.", conditions_table, run_name_filter, "\n",
    ") t\n",
    "GROUP BY source_schema\n",
    "ORDER BY source_schema;"
  ),
  staging_schema = staging_schema,
  run_name = run_name
), targetDialect = config$dbms)

resource_counts <- run_query(resource_sql)
cat("Staging table counts\n")
print(resource_counts)
cat("\n")

# -----------------------------------------------------------------------------
# OMOP summary: aggregate ETL output shape and key condition/procedure signals.
# -----------------------------------------------------------------------------
summary_sql <- SqlRender::translate(SqlRender::render(
  paste0(
    "SELECT\n",
    "  ((SELECT COUNT(*) FROM @staging_schema.", patients_table, run_name_filter, ") +\n",
    "   (SELECT COUNT(*) FROM @staging_schema.", encounters_table, run_name_filter, ") +\n",
    "   (SELECT COUNT(*) FROM @staging_schema.", procedures_table, run_name_filter, ") +\n",
    "   (SELECT COUNT(*) FROM @staging_schema.", conditions_table, run_name_filter, ")) AS staged_rows,\n",
    "  (SELECT SUM(CASE WHEN row_count > 0 THEN 1 ELSE 0 END) FROM (\n",
    "     SELECT COUNT(*) AS row_count FROM @staging_schema.", patients_table, run_name_filter, "\n",
    "     UNION ALL SELECT COUNT(*) AS row_count FROM @staging_schema.", encounters_table, run_name_filter, "\n",
    "     UNION ALL SELECT COUNT(*) AS row_count FROM @staging_schema.", procedures_table, run_name_filter, "\n",
    "     UNION ALL SELECT COUNT(*) AS row_count FROM @staging_schema.", conditions_table, run_name_filter, "\n",
    "   ) stage_counts) AS staged_tables_with_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.person p WHERE ", person_filter, ") AS person_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.visit_occurrence) AS visit_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.procedure_occurrence po WHERE po.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   )) AS procedure_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.procedure_occurrence po WHERE po.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   ) AND EXISTS (\n",
    "     SELECT 1 FROM @cdm_schema.concept_ancestor ca\n",
    "     WHERE ca.descendant_concept_id = po.procedure_concept_id\n",
    "       AND ca.ancestor_concept_id IN (4236706, 4225375)\n",
    "   )) AS open_revascularization_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   )) AS condition_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   ) AND co.condition_concept_id > 0) AS mapped_condition_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   ) AND co.condition_concept_id = 317309) AS pad_condition_rows,\n",
    # Include outcome condition count only when outcome concept IDs are configured.
  if (length(config$outcome_concept_ids) > 0) paste0(
    "  (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   ) AND EXISTS (\n",
    "     SELECT 1 FROM @cdm_schema.concept_ancestor ca\n",
    "     WHERE ca.descendant_concept_id = co.condition_concept_id\n",
    "       AND ca.ancestor_concept_id IN (", paste(config$outcome_concept_ids, collapse = ", "), ")\n",
    "   )) AS outcome_condition_rows,\n"
  ) else NULL,
    "  (SELECT COUNT(*) FROM @cdm_schema.condition_era ce WHERE ce.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   )) AS condition_era_rows,\n",
    "  (SELECT COUNT(*) FROM @cdm_schema.drug_era de WHERE de.person_id IN (\n",
    "     SELECT p.person_id FROM @cdm_schema.person p WHERE ", person_filter, "\n",
    "   )) AS drug_era_rows;"
  ),
  staging_schema = staging_schema,
  cdm_schema = cdm_schema_active,
  run_name = run_name
), targetDialect = config$dbms)

summary_df <- run_query(summary_sql)
cat("OMOP summary\n")
print(summary_df)
cat("\n")

# Helper to tolerate snake_case/camelCase name differences returned by
# DatabaseConnector across versions/options.
value_from_summary <- function(df, candidates) {
  nm <- names(df)
  hit <- candidates[candidates %in% nm]
  if (length(hit) == 0) return(NA_real_)
  as.numeric(df[[hit[1]]][1])
}

person_rows <- value_from_summary(summary_df, c("personRows", "person_rows"))
open_revasc_rows <- value_from_summary(summary_df, c("openRevascularizationRows", "open_revascularization_rows"))
outcome_rows <- value_from_summary(summary_df, c("outcomeConditionRows", "outcome_condition_rows"))
condition_rows <- value_from_summary(summary_df, c("conditionRows", "condition_rows"))
mapped_condition_rows <- value_from_summary(summary_df, c("mappedConditionRows", "mapped_condition_rows"))
condition_era_rows <- value_from_summary(summary_df, c("conditionEraRows", "condition_era_rows"))
drug_era_rows <- value_from_summary(summary_df, c("drugEraRows", "drug_era_rows"))

mapped_pct <- if (!is.na(condition_rows) && condition_rows > 0) {
  100 * mapped_condition_rows / condition_rows
} else {
  NA_real_
}

# Mapping completeness sanity check.
cat("Mapping quality\n")
cat("Mapped condition percentage: ", round(mapped_pct, 2), "%\n\n", sep = "")

# Era table coverage checks ensure condition/drug episodes were materialized.
cat("Era table checks\n")
cat("condition_era rows: ", format(condition_era_rows, big.mark = ","), "\n", sep = "")
cat("drug_era rows: ", format(drug_era_rows, big.mark = ","), "\n\n", sep = "")

# -----------------------------------------------------------------------------
# Age-profile check: confirms plausible population bounds after ETL.
# -----------------------------------------------------------------------------
age_sql <- SqlRender::translate(SqlRender::render(
  paste0(
    "SELECT\n",
    "  COUNT(*) AS n_people,\n",
    "  SUM(CASE WHEN year_of_birth >= YEAR(GETDATE()) - 18 THEN 1 ELSE 0 END) AS age_under_18_count,\n",
    "  MIN(year_of_birth) AS min_year_of_birth,\n",
    "  MAX(year_of_birth) AS max_year_of_birth\n",
    "FROM @cdm_schema.person p\n",
    "WHERE ", person_filter, ";"
  ),
  cdm_schema = cdm_schema_active
), targetDialect = config$dbms)

age_df <- run_query(age_sql)
cat("Age distribution check\n")
print(age_df)
cat("\n")

# -----------------------------------------------------------------------------
# Clinical signal check: rough face-validity counts for study-relevant markers.
# -----------------------------------------------------------------------------
# Build the outcome signal subquery dynamically from config$outcome_concept_ids.
# When no outcome concept IDs are configured, the outcome column is omitted.
outcome_signal_col <- if (length(config$outcome_concept_ids) > 0) {
  paste0(
    "  -- Outcome: concept_ancestor rollup under config$outcome_concept_ids\n",
    "  (SELECT COUNT(DISTINCT co.person_id)\n",
    "   FROM @cdm_schema.condition_occurrence co\n",
    "   INNER JOIN @cdm_schema.concept_ancestor ca\n",
    "     ON ca.descendant_concept_id = co.condition_concept_id\n",
    "   WHERE ca.ancestor_concept_id IN (", paste(config$outcome_concept_ids, collapse = ", "), ")\n",
    "     AND co.person_id IN (SELECT p2.person_id FROM @cdm_schema.person p2 WHERE ", person_filter, ")\n",
    "  ) AS people_with_outcome"
  )
} else {
  # No outcome concept IDs configured — emit a placeholder column.
  "  NULL AS people_with_outcome"
}

signal_sql <- SqlRender::translate(SqlRender::render(
  paste0(
    "SELECT\n",
    "  -- Index procedure: concept_ancestor rollup under target ancestor concept IDs\n",
    "  (SELECT COUNT(DISTINCT po.person_id)\n",
    "   FROM @cdm_schema.procedure_occurrence po\n",
    "   INNER JOIN @cdm_schema.concept_ancestor ca\n",
    "     ON ca.descendant_concept_id = po.procedure_concept_id\n",
    "   WHERE ca.ancestor_concept_id IN (",
         paste(
           if (length(config$target_index_concept_ids) > 0) config$target_index_concept_ids else "NULL",
           collapse = ", "
         ), ")\n",
    "     AND po.person_id IN (SELECT p2.person_id FROM @cdm_schema.person p2 WHERE ", person_filter, ")\n",
    "  ) AS people_with_index_procedure,\n",
    outcome_signal_col, ";"
  ),
  cdm_schema = cdm_schema_active
), targetDialect = config$dbms)

signal_df <- run_query(signal_sql)
cat("Clinical signal check\n")
print(signal_df)
cat("\n")

# -----------------------------------------------------------------------------
# Optional threshold gate for automated pipeline enforcement.
# -----------------------------------------------------------------------------
if (isTRUE(opts$enforce_thresholds)) {
  failures <- character()

  if (is.na(person_rows) || person_rows < opts$min_person_rows) {
    failures <- c(failures, paste0("person_rows < min_person_rows (", person_rows, " < ", opts$min_person_rows, ")"))
  }
  if (is.na(open_revasc_rows) || open_revasc_rows < opts$min_open_revascularization_rows) {
    failures <- c(failures, paste0("open_revascularization_rows < min_open_revascularization_rows (", open_revasc_rows, " < ", opts$min_open_revascularization_rows, ")"))
  }
  if (length(config$outcome_concept_ids) > 0 &&
      (is.na(outcome_rows) || outcome_rows < opts$min_outcome_condition_rows)) {
    failures <- c(failures, paste0("outcome_condition_rows < min_outcome_condition_rows (", outcome_rows, " < ", opts$min_outcome_condition_rows, ")"))
  }
  if (is.na(mapped_pct) || mapped_pct < opts$min_mapped_condition_pct) {
    failures <- c(failures, paste0("mapped_condition_pct < min_mapped_condition_pct (", round(mapped_pct, 2), " < ", opts$min_mapped_condition_pct, ")"))
  }

  if (length(failures) > 0) {
    stop("Quality check threshold failures: ", paste(failures, collapse = "; "))
  }

  cat("Threshold gate\n")
  cat("All enforced thresholds passed.\n\n")
}

# -----------------------------------------------------------------------------
# Stage failure tracking
# -----------------------------------------------------------------------------
# 6b and 6c each wrap their work in tryCatch so that one failing profiler does
# not abort the other. That is right, but on its own it made a failed stage
# invisible: the script printed "QUALITY CHECK COMPLETE" and exited 0 even when
# both stages had produced nothing. Record failures here and exit non-zero at
# the end, so a workflow driver (or CI) actually notices.
stage_failures <- character(0)

record_stage_failure <- function(stage, message_text) {
  stage_failures <<- c(stage_failures, paste0(stage, ": ", message_text))
}

# -----------------------------------------------------------------------------
# ensure_results_schema
#
# Purpose:
#   Create config$results_schema if it does not exist. ACHILLES and DQD both
#   write tables there and both hard-fail on a missing schema — the error is
#   "The specified schema name ... either does not exist or you do not have
#   permission to use it", which reads like a permissions problem but is
#   usually just an un-created schema on a fresh instance.
#
#   Unlike the CDM schema, nothing upstream creates this one: workflow/05 only
#   creates the CDM and staging schemas, so a repo that has never run ACHILLES
#   or DQD will not have it.
#
# Returns: invisibly TRUE if the schema exists (or was created), FALSE if it
#          could not be created — in which case the caller should skip the
#          stage and record a failure rather than let the profiler die deep
#          inside its own SQL.
# -----------------------------------------------------------------------------
ensure_results_schema <- function() {
  schema <- config$results_schema
  exists_sql <- paste0(
    "SELECT COUNT(*) AS n FROM sys.schemas WHERE name = '",
    gsub("'", "''", schema), "';"
  )
  present <- tryCatch(
    as.integer(run_query(exists_sql)$n[[1]]) > 0L,
    error = function(e) NA
  )
  if (isTRUE(present)) {
    return(invisible(TRUE))
  }
  if (is.na(present)) {
    warning("[Step 6] Could not check for results schema '", schema, "'.")
    return(invisible(FALSE))
  }

  message("[Step 6] Results schema '", schema, "' does not exist — creating it.")
  created <- tryCatch({
    conn_rs <- DatabaseConnector::connect(build_connection_details(config))
    on.exit(DatabaseConnector::disconnect(conn_rs), add = TRUE)
    DatabaseConnector::executeSql(
      conn_rs,
      paste0("IF SCHEMA_ID('", gsub("'", "''", schema), "') IS NULL ",
             "EXEC('CREATE SCHEMA [", schema, "]');"),
      progressBar = FALSE, reportOverallTime = FALSE
    )
    TRUE
  }, error = function(e) {
    warning("[Step 6] Could not create results schema '", schema, "': ",
            conditionMessage(e))
    FALSE
  })
  invisible(isTRUE(created))
}

# Create it once up front if either profiler is going to run.
results_schema_ready <- TRUE
if (isTRUE(opts$run_achilles) || isTRUE(opts$run_dqd)) {
  results_schema_ready <- ensure_results_schema()
  if (!results_schema_ready) {
    record_stage_failure(
      "Step 6",
      paste0("results schema '", config$results_schema,
             "' is missing and could not be created; ACHILLES/DQD skipped")
    )
  }
}

# -----------------------------------------------------------------------------
# 6b. ACHILLES CDM profiling (optional — enable with --run_achilles=true)
# -----------------------------------------------------------------------------
# ACHILLES computes 170+ standardised analyses across every CDM domain and
# writes results to achilles_analysis, achilles_results, and achilles_heel
# tables in the results schema.  These tables are consumed by the OHDSI Atlas
# Data Sources viewer and by the DQD layer below.
#
# Output folder: output/achilles/   (excluded from git via .gitignore)
# Runtime: typically 10-30 min on a synthetic CDM of ~5,000 persons.
if (isTRUE(opts$run_achilles) && isTRUE(results_schema_ready)) {
  if (!requireNamespace("Achilles", quietly = TRUE)) {
    warning(
      "[Step 6b] Package 'Achilles' is not installed.\n",
      "Install it with: renv::install('OHDSI/Achilles')\n",
      "Skipping ACHILLES profiling."
    )
  } else {
    message("[Step 6b] Running ACHILLES CDM profiling ...")
    achilles_output <- config$achilles_output_folder
    dir.create(achilles_output, recursive = TRUE, showWarnings = FALSE)

    achilles_result <- tryCatch(
      Achilles::achilles(
        connectionDetails     = build_connection_details(config),
        cdmDatabaseSchema     = cdm_schema_active,
        resultsDatabaseSchema = config$results_schema,
        # SQL Server requires a writable scratch schema for intermediate
        # aggregation tables — reuse the results schema.
        scratchDatabaseSchema = config$results_schema,
        sourceName            = config$cdm_database_name,
        outputFolder          = achilles_output,
        cdmVersion            = "5.4",
        numThreads            = opts$achilles_threads,
        defaultAnalysesOnly   = TRUE,
        createTable           = TRUE
      ),
      error = function(e) {
        warning("[Step 6b] ACHILLES failed: ", conditionMessage(e))
        record_stage_failure("Step 6b (ACHILLES)", conditionMessage(e))
        NULL
      }
    )

    if (!is.null(achilles_result)) {
      message("[Step 6b] ACHILLES complete. Results in: ", achilles_output)

      # Print Heel warning summary to console so issues are visible in the log.
      heel_sql <- SqlRender::translate(SqlRender::render(
        "SELECT TOP 50 analysis_id, achilles_heel_warning
         FROM @results_schema.achilles_heel_results
         ORDER BY analysis_id;",
        results_schema = config$results_schema
      ), targetDialect = config$dbms)

      heel_df <- tryCatch(run_query(heel_sql), error = function(e) NULL)
      if (!is.null(heel_df) && nrow(heel_df) > 0) {
        cat("\n[Step 6b] ACHILLES Heel warnings (top 50)\n")
        print(heel_df)
      } else {
        cat("[Step 6b] No ACHILLES Heel warnings found.\n")
      }
      cat("\n")
    }
  }
}

# -----------------------------------------------------------------------------
# 6c. OHDSI Data Quality Dashboard (optional — enable with --run_dqd=true)
# -----------------------------------------------------------------------------
# DQD runs ~3,000 standardised data quality checks across TABLE, FIELD, and
# CONCEPT levels and writes a JSON report + results table.  It is designed to
# run after ACHILLES but does not strictly require it.
#
# Output folder: output/dqd/   (excluded from git via .gitignore)
# Output file:   output/dqd/dqd_results.json
# Results table: <results_schema>.dqdashboard_results
# Runtime: typically 20-60 min on a synthetic CDM of ~5,000 persons.
if (isTRUE(opts$run_dqd) && isTRUE(results_schema_ready)) {
  if (!requireNamespace("DataQualityDashboard", quietly = TRUE)) {
    warning(
      "[Step 6c] Package 'DataQualityDashboard' is not installed.\n",
      "Install it with: renv::install('OHDSI/DataQualityDashboard')\n",
      "Skipping DQD checks."
    )
  } else {
    message("[Step 6c] Running OHDSI Data Quality Dashboard checks ...")
    dqd_output <- config$dqd_output_folder
    dir.create(dqd_output, recursive = TRUE, showWarnings = FALSE)

    tryCatch(
      DataQualityDashboard::executeDqChecks(
        connectionDetails     = build_connection_details(config),
        cdmDatabaseSchema     = cdm_schema_active,
        resultsDatabaseSchema = config$results_schema,
        cdmSourceName         = config$cdm_database_name,
        numThreads            = 1L,
        sqlOnly               = FALSE,
        outputFolder          = dqd_output,
        outputFile            = "dqd_results.json",
        verboseMode           = TRUE,
        writeToTable          = TRUE,
        writeTableName        = "dqdashboard_results",
        writeToCsv            = FALSE,
        checkLevels           = c("TABLE", "FIELD", "CONCEPT"),
        cdmVersion            = "5.4"
      ),
      error = function(e) {
        warning("[Step 6c] DQD failed: ", conditionMessage(e))
        record_stage_failure("Step 6c (DQD)", conditionMessage(e))
      }
    )

    # Print a pass/fail summary from the results table if it was written.
    dqd_summary_sql <- SqlRender::translate(SqlRender::render(
      "SELECT
         failed       AS failed_checks,
         passed       AS passed_checks,
         is_error     AS error_checks,
         not_applicable AS not_applicable_checks,
         total_checks
       FROM (
         SELECT
           SUM(CASE WHEN numFailedChecks  > 0 THEN 1 ELSE 0 END)  AS failed,
           SUM(CASE WHEN numFailedChecks  = 0 THEN 1 ELSE 0 END)  AS passed,
           SUM(CASE WHEN isError          = 1 THEN 1 ELSE 0 END)  AS is_error,
           SUM(CASE WHEN notApplicable    = 1 THEN 1 ELSE 0 END)  AS not_applicable,
           COUNT(*)                                                 AS total_checks
         FROM @results_schema.dqdashboard_results
       ) s;",
      results_schema = config$results_schema
    ), targetDialect = config$dbms)

    dqd_summary <- tryCatch(run_query(dqd_summary_sql), error = function(e) NULL)
    if (!is.null(dqd_summary) && nrow(dqd_summary) > 0) {
      cat("\n[Step 6c] DQD summary\n")
      print(dqd_summary)
    }
    message("[Step 6c] DQD complete. Report: ", file.path(dqd_output, "dqd_results.json"))
    cat("\n")
  }
}

# -----------------------------------------------------------------------------
# Exit status
# -----------------------------------------------------------------------------
# A stage that was requested and then failed is a hard failure, regardless of
# --enforce_thresholds (which governs DATA thresholds, not stage execution).
# Previously both were reported only via warning(), so Rscript still exited 0
# and workflow/06 propagated success — a run where ACHILLES and DQD both died
# on a missing results schema looked identical to a clean one.
if (length(stage_failures) > 0) {
  cat("\n=== QUALITY CHECK FAILED ===\n")
  cat("The following stage(s) did not complete:\n")
  for (f in stage_failures) cat("  - ", f, "\n", sep = "")
  cat("\nCore checks above (Step 6a) may still be valid; the stages listed\n",
      "here produced no output.\n", sep = "")
  quit(status = 1L)
}

cat("=== QUALITY CHECK COMPLETE ===\n")
