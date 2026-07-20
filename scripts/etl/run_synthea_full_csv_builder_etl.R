# =============================================================================
# scripts/etl/run_synthea_full_csv_builder_etl.R
# Full-domain Synthea CSV -> OMOP ETL using ETLSyntheaBuilder.
#
# Overview of what this script does end-to-end:
#  1. Validates prerequisites (directories, packages, DB connectivity).
#  2. Ensures CDM tables exist in the target schema, creating them via
#     ETLSyntheaBuilder::CreateCDMTables if any are missing.
#  3. Loads the full OMOP vocabulary into the CDM schema, either from
#     CSV files (LoadVocabFromCsv) or by bootstrapping from a reference
#     schema via INSERT ... SELECT.
#  4. Optionally resets/drops existing Synthea staging and OMOP event
#     tables so each run starts from a clean slate.
#  5. Creates fresh Synthea staging tables using the versioned DDL
#     bundled inside ETLSyntheaBuilder.
#  6. Runs a proactive pre-flight alignment scan that reads every CSV,
#     compares column widths and types against the staging schema, and
#     issues ALTER TABLE statements to prevent loader type-clash and
#     truncation errors before any row is inserted.
#  7. Loads all Synthea CSV files into the staging schema (bulk or
#     row-by-row), with an automatic reactive fallback for any residual
#     type/truncation errors not caught by the pre-flight pass.
#  8. Generates OMOP visit rollup tables (ALL_VISITS, ASSIGN_ALL_VISIT_IDS,
#     FINAL_VISIT_IDS) using ETLSyntheaBuilder rollup SQL.
#  9. Builds concept_ancestor indexes in the CDM schema to accelerate the
#     drug_era INSERT (which joins across 75M concept_ancestor rows).
# 10. Executes the three vocabulary map SQL files (source-to-standard,
#     source-to-source, states map) followed by the 19 OMOP domain INSERT
#     SQL files produced by ETLSyntheaBuilder::LoadEventTables.
# 11. Creates extra CDM indexes via ETLSyntheaBuilder::CreateExtraIndices.
#
# Called by: workflow/05_etl_csv_to_omop.R
# =============================================================================

source("config.R")
source("R/drivers.R")
source("R/connection.R")

# run_synthea_full_csv_builder_etl()
# ---------------------------------------------------------------------------
# Main entry point.  All ETL logic lives inside this function so that its
# closures can share config, connection details, and helper functions without
# passing them through every call.
#
# Parameters:
#   csv_input_dir          Path to the folder produced by Synthea (Step 4).
#                          Must contain *.csv files such as patients.csv,
#                          encounters.csv, conditions.csv, etc.
#   run_name               Audit label stamped on log output.  Auto-generated
#                          from the current timestamp if not supplied.
#   synthea_schema         SQL Server schema to use for Synthea staging tables.
#                          Default: "synthea".
#   synthea_version        Synthea release version passed to ETLSyntheaBuilder
#                          to select the correct DDL/SQL bundle. Default: "3.3.0".
#   cdm_version            OMOP CDM version for DDL and insert SQL generation.
#                          Default: "5.4".
#   cdm_schema             Override the CDM schema from config.R.  Useful for
#                          isolated study schemas (e.g. omop_synth_pad_oler_ssi).
#   vocabulary_source_schema Schema to bootstrap vocabulary from when
#                          reload_vocab_from_csv is FALSE and the target schema
#                          has no vocab loaded.  Defaults to cdm_schema.
#   reload_vocab_from_csv  When TRUE, load vocabulary tables from CSV files in
#                          vocab_file_loc using ETLSyntheaBuilder::LoadVocabFromCsv.
#                          When FALSE, use bootstrap-from-schema instead.
#   vocab_file_loc         Directory containing OMOP vocabulary CSV files
#                          (CONCEPT.csv, CONCEPT_ANCESTOR.csv, …).
#                          Required when reload_vocab_from_csv = TRUE.
#   vocab_delimiter        Column delimiter used in the vocabulary CSVs.
#                          OHDSI distributions are tab-delimited ("\t").
#   reset_before_etl       Drop and recreate all Synthea staging tables and OMOP
#                          event tables before loading.  Set FALSE only for
#                          incremental / resumption runs.
#   synthea_bulk_load      Attempt high-speed JDBC bulk insert first.  Falls
#                          back automatically to row-by-row mode on failure.
#   verbose                Emit [INFO]/[WARN] log messages during execution.
run_synthea_full_csv_builder_etl <- function(
    csv_input_dir,
    run_name = paste0("padssi-csv-full-", format(Sys.time(), "%Y%m%d-%H%M%S")),
    synthea_schema = "synthea",
    synthea_version = "3.3.0",
    cdm_version = "5.4",
    cdm_schema = NULL,
    vocabulary_source_schema = NULL,
  reload_vocab_from_csv = FALSE,
  vocab_file_loc = NULL,
  vocab_delimiter = "\t",
    reset_before_etl = TRUE,
    synthea_bulk_load = TRUE,
    use_shared_vocab_schema = FALSE,
    shared_vocab_schema = "omop_vocab",
    verbose = TRUE) {

  # ---------------------------------------------------------------------------
  # 1. Resolve runtime configuration
  # ---------------------------------------------------------------------------
  # Load central config and apply any schema override supplied by the caller.
  # active_vocab_source_schema is the fallback for bootstrapping vocabulary
  # when reload_vocab_from_csv is FALSE.
  config <- get_validation_config()
  if (!is.null(cdm_schema) && nzchar(cdm_schema)) {
    config$cdm_schema <- cdm_schema
  }

  active_vocab_source_schema <- if (
    !is.null(vocabulary_source_schema) && nzchar(vocabulary_source_schema)
  ) vocabulary_source_schema else config$cdm_schema

  active_vocab_file_loc <- if (!is.null(vocab_file_loc) && nzchar(vocab_file_loc)) {
    vocab_file_loc
  } else {
    NULL
  }

  # ---------------------------------------------------------------------------
  # 2. Logging and progress-bar helpers
  # ---------------------------------------------------------------------------
  # log_msg() respects the verbose flag and prefixes every message with a
  # severity level so callers can grep for [WARN] lines in captured logs.
  log_msg <- function(..., level = "INFO") {
    if (isTRUE(verbose)) {
      message("[", level, "] ", paste0(..., collapse = ""))
    }
  }

  # create_progress_tracker() returns a two-element list with tick(label) and
  # close().  tick() advances the text progress bar and emits a log line with
  # the step number so the operator can see exactly which phase is running.
  create_progress_tracker <- function(total_steps) {
    pb <- utils::txtProgressBar(min = 0, max = total_steps, style = 3)
    current <- 0L
    list(
      tick = function(label) {
        current <<- current + 1L
        utils::setTxtProgressBar(pb, current)
        log_msg("[", current, "/", total_steps, "] ", label)
      },
      close = function() {
        close(pb)
      }
    )
  }

  # ---------------------------------------------------------------------------
  # 3. Pre-conditions: JDBC driver, Java, CSV directory, required packages
  # ---------------------------------------------------------------------------
  # ensure_jdbc_bundle downloads the SQL Server JDBC driver jar if absent.
  # configure_java sets JAVA_HOME and java.library.path for rJava.
  ensure_jdbc_bundle(config)
  configure_java(config)

  if (!dir.exists(csv_input_dir)) {
    stop("CSV input directory does not exist: ", csv_input_dir)
  }

  csv_files <- list.files(csv_input_dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(csv_files) == 0) {
    stop("No CSV files found in: ", csv_input_dir)
  }

  if (!requireNamespace("ETLSyntheaBuilder", quietly = TRUE)) {
    stop(
      "Package 'ETLSyntheaBuilder' is required for full-domain CSV ETL. ",
      "Install it in this renv before running Step 5 in csv_builder mode."
    )
  }

  if (!requireNamespace("SqlRender", quietly = TRUE)) {
    stop("Package 'SqlRender' is required. Install with renv::install('SqlRender').")
  }

  # ---------------------------------------------------------------------------
  # 4. Database connection and preflight check
  # ---------------------------------------------------------------------------
  # build_connection_details() assembles a DatabaseConnector connectionDetails
  # object from config.R (server, port, database, JDBC driver path, integrated
  # security settings).  run_db_preflight() then makes 3 consecutive successful
  # connections before proceeding, guarding against transient SQL Server startup
  # delays in local/dev environments.
  connection_details <- build_connection_details(config)

  run_db_preflight(
    connection_details,
    required_successes = 3L,
    max_attempts = 10L,
    delay_seconds = 2
  )

  # run_step_with_retry() wraps a single ETLSyntheaBuilder call in the project's
  # standard retry decorator (with_db_retry) so transient JDBC errors are
  # retried up to max_attempts times with an exponential back-off.
  run_step_with_retry <- function(step_name, expr, max_attempts = 3L) {
    with_db_retry(
      expr,
      operation_name = step_name,
      max_attempts = max_attempts,
      initial_delay_seconds = 2
    )
  }

  # ---------------------------------------------------------------------------
  # 5. SQL helper utilities
  # ---------------------------------------------------------------------------
  # render_sql() renders SqlRender @parameters then translates the resulting
  # SQL to the target DBMS dialect (sql server for this project).  All dynamic
  # SQL throughout this script must go through this helper to prevent injection
  # and ensure portability.
  render_sql <- function(sql, ...) {
    SqlRender::translate(
      SqlRender::render(sql, ...),
      targetDialect = config$dbms
    )
  }

  # table_exists() returns TRUE if a real table OR a synonym with the given
  # name exists in the given schema.  Checks both INFORMATION_SCHEMA.TABLES
  # (real tables/views) and sys.synonyms so that vocabulary synonym objects
  # created by create_vocab_synonyms() are treated as present by all
  # downstream guards (ensure_cdm_tables_exist, vocab_is_loaded, etc.).
  table_exists <- function(connection, schema_name, table_name) {
    sql <- paste0(
      "SELECT COUNT(*) AS n FROM (",
      "  SELECT TABLE_NAME AS obj_name FROM INFORMATION_SCHEMA.TABLES ",
      "  WHERE TABLE_SCHEMA = '", gsub("'", "''", schema_name), "'",
      "    AND TABLE_NAME   = '", gsub("'", "''", table_name),  "'",
      "  UNION ALL",
      "  SELECT s.name AS obj_name FROM sys.synonyms s",
      "  JOIN sys.schemas sc ON s.schema_id = sc.schema_id",
      "  WHERE sc.name = '", gsub("'", "''", schema_name), "'",
      "    AND s.name  = '", gsub("'", "''", table_name),  "'",
      ") AS obj;"
    )
    res <- query_sql_with_retry(connection, sql)
    as.numeric(res$n[1]) > 0
  }

  # table_has_rows() returns TRUE if the table exists AND contains at least one
  # row.  Used for vocabulary precheck: an empty concept table is treated as
  # "not loaded" and triggers the bootstrap or CSV reload path.
  table_has_rows <- function(connection, schema_name, table_name) {
    if (!table_exists(connection, schema_name, table_name)) {
      return(FALSE)
    }

    sql <- render_sql(
      "SELECT CASE
          WHEN EXISTS (SELECT 1 FROM @schema_name.@table_name)
          THEN 1 ELSE 0
        END AS has_rows;",
      schema_name = schema_name,
      table_name = table_name
    )
    res <- query_sql_with_retry(connection, sql)
    identical(as.integer(res$has_rows[1]), 1L)
  }

  # vocab_is_loaded() confirms all three minimum vocabulary tables
  # (concept, concept_ancestor, concept_relationship) are populated.
  # These are necessary for the ETL source-to-standard mapping queries.
  vocab_is_loaded <- function(connection, cdm_schema) {
    required_vocab_tables <- c("concept", "concept_ancestor", "concept_relationship")
    all(vapply(
      required_vocab_tables,
      function(table_name) table_has_rows(connection, cdm_schema, table_name),
      logical(1)
    ))
  }

  # assert_vocab_loaded_for_etl() is a hard guard called after all vocabulary
  # load paths have been attempted.  If vocabulary is still absent it stops
  # with a clear message pointing to the correct remediation step.
  assert_vocab_loaded_for_etl <- function(connection, cdm_schema) {
    if (isTRUE(vocab_is_loaded(connection, cdm_schema))) {
      return(invisible(TRUE))
    }

    stop(
      paste0(
        "Vocabulary precheck failed in ", cdm_schema, ". Required populated tables are: ",
        "concept, concept_relationship, and concept_ancestor. ",
        "This analysis repository no longer loads vocabularies during Step 5 ETL. ",
        "Please run the separate 'vocab_omop_etl' process to load vocabularies, then rerun workflow/05_etl_csv_to_omop.R."
      ),
      call. = FALSE
    )
  }

  # bootstrap_vocabulary_from_schema() is the fallback when reload_vocab_from_csv
  # is FALSE.  It copies all vocabulary tables row-by-row from a reference
  # schema (usually cdm_synthea) into the target schema via INSERT ... SELECT.
  # Only tables that exist in BOTH schemas are copied; missing tables are skipped.
  bootstrap_vocabulary_from_schema <- function(connection, target_schema, source_schema) {
    if (identical(target_schema, source_schema)) {
      return(invisible(FALSE))
    }

    if (!isTRUE(vocab_is_loaded(connection, source_schema))) {
      stop(
        "Cannot bootstrap vocabulary: source schema '", source_schema,
        "' does not contain populated concept/concept_relationship/concept_ancestor tables.",
        call. = FALSE
      )
    }

    vocab_tables <- c(
      "vocabulary", "concept_class", "domain", "relationship",
      "concept", "concept_relationship", "concept_synonym",
      "concept_ancestor", "drug_strength", "source_to_concept_map"
    )

    copied_any <- FALSE
    for (table_name in vocab_tables) {
      if (!isTRUE(table_exists(connection, source_schema, table_name))) {
        next
      }
      if (!isTRUE(table_exists(connection, target_schema, table_name))) {
        next
      }

      log_msg(
        "Bootstrapping vocabulary table ", target_schema, ".", table_name,
        " from ", source_schema, ".", table_name, " ..."
      )

      clear_sql <- render_sql(
        "DELETE FROM @target_schema.@table_name;",
        target_schema = target_schema,
        table_name = table_name
      )
      execute_sql_with_retry(connection, clear_sql)

      copy_sql <- render_sql(
        "INSERT INTO @target_schema.@table_name
         SELECT *
         FROM @source_schema.@table_name;",
        target_schema = target_schema,
        source_schema = source_schema,
        table_name = table_name
      )
      execute_sql_with_retry(connection, copy_sql)
      copied_any <- TRUE
    }

    copied_any
  }

  # clear_schema_tables() drops every user table in the named schema.  Called
  # during reset to surgically clear the synthea staging schema when the
  # ETLSyntheaBuilder::DropSyntheaTables call fails due to version mismatches.
  clear_schema_tables <- function(connection, schema_name) {
    sql <- render_sql(
      "SELECT t.name AS table_name
       FROM sys.tables t
       JOIN sys.schemas s ON t.schema_id = s.schema_id
       WHERE s.name = '@schema_name';",
      schema_name = schema_name
    )
    tbl <- query_sql_with_retry(connection, sql)
    if (nrow(tbl) == 0) {
      return(invisible(NULL))
    }

    for (nm in tbl$table_name) {
      execute_sql_with_retry(connection, paste0("DROP TABLE [", schema_name, "].[", nm, "];"))
    }
    invisible(NULL)
  }

  # ensure_cdm_tables_exist() checks all 19 required OMOP CDM v5.4 tables.
  # Two recovery paths are taken when tables are missing:
  #   a) If vocabulary tables are also absent → call CreateCDMTables (full DDL).
  #   b) If vocabulary is already present → generate DDL with sqlOnly=TRUE,
  #      then execute only the missing non-vocabulary table stanzas so existing
  #      vocabulary data is not disturbed.
  ensure_cdm_tables_exist <- function() {
    conn_cdm <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_cdm), add = TRUE)

    required_cdm_tables <- c(
      "person", "location", "care_site", "provider",
      "observation_period", "visit_occurrence",
      "visit_detail", "condition_occurrence", "observation",
      "measurement", "procedure_occurrence", "drug_exposure",
      "condition_era", "drug_era", "cdm_source",
      "device_exposure", "death", "payer_plan_period", "cost"
    )
    missing_tables <- required_cdm_tables[!vapply(
      required_cdm_tables,
      function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
      logical(1)
    )]

    if (length(missing_tables) > 0) {
      vocab_tables <- c(
        "concept", "concept_ancestor", "concept_class", "concept_relationship",
        "concept_synonym", "domain", "drug_strength", "relationship",
        "vocabulary", "source_to_concept_map"
      )
      vocab_present <- all(vapply(
        vocab_tables,
        function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
        logical(1)
      ))

      if (!vocab_present) {
        # Ensure CDM schema exists before calling CreateCDMTables
        execute_sql_with_retry(
          conn_cdm,
          paste0("IF SCHEMA_ID('", config$cdm_schema, "') IS NULL EXEC('CREATE SCHEMA ", config$cdm_schema, "');")
        )

        message(
          "Missing CDM tables detected in ", config$cdm_schema,
          " (", paste(missing_tables, collapse = ", "), "); recreating CDM tables."
        )
        run_step_with_retry("ETLSyntheaBuilder::CreateCDMTables", ETLSyntheaBuilder::CreateCDMTables(
          connectionDetails = connection_details,
          cdmSchema = config$cdm_schema,
          cdmVersion = cdm_version
        ))
        return(invisible(NULL))
      }

      # Vocabulary-only reset path: create only missing non-vocabulary tables from DDL.
      message(
        "Missing non-vocabulary CDM tables detected in ", config$cdm_schema,
        " (", paste(missing_tables, collapse = ", "), "); creating missing tables from DDL."
      )

      ddl_dir <- file.path("output", "cdm_sql")
      full_ddl_path <- file.path(ddl_dir, paste0("OMOPCDM_sql_server_", cdm_version, "_ddl.sql"))
      if (!file.exists(full_ddl_path)) {
        run_step_with_retry("ETLSyntheaBuilder::CreateCDMTables(sqlOnly)", ETLSyntheaBuilder::CreateCDMTables(
          connectionDetails = connection_details,
          cdmSchema = config$cdm_schema,
          cdmVersion = cdm_version,
          outputFolder = file.path(getwd(), ddl_dir),
          sqlOnly = TRUE
        ))
      }

      if (!file.exists(full_ddl_path)) {
        stop("Missing full CDM DDL file not found: ", full_ddl_path)
      }

      ddl_lines <- readLines(full_ddl_path, warn = FALSE)
      create_line_idx <- grep("^\\s*CREATE\\s+TABLE\\s+", ddl_lines, ignore.case = TRUE)
      if (length(create_line_idx) == 0L) {
        stop("No CREATE TABLE statements found in: ", full_ddl_path)
      }

      for (k in seq_along(create_line_idx)) {
        start_idx <- create_line_idx[[k]]
        end_idx <- if (k < length(create_line_idx)) create_line_idx[[k + 1L]] - 1L else length(ddl_lines)
        create_line <- ddl_lines[[start_idx]]

        m <- regexec(
          "(?i)^\\s*CREATE\\s+TABLE\\s+([A-Za-z0-9_]+)\\.([A-Za-z0-9_]+)",
          create_line,
          perl = TRUE
        )
        parts <- regmatches(create_line, m)[[1]]
        if (length(parts) < 3L) {
          next
        }

        table_name <- tolower(parts[[3]])
        if (!(table_name %in% missing_tables) || (table_name %in% vocab_tables)) {
          next
        }

        stmt <- paste(ddl_lines[start_idx:end_idx], collapse = "\n")
        stmt <- sub(
          "(?i)^\\s*CREATE\\s+TABLE\\s+[A-Za-z0-9_]+\\.",
          paste0("CREATE TABLE ", config$cdm_schema, "."),
          stmt,
          perl = TRUE
        )

        create_sql <- paste0(
          "IF OBJECT_ID('", config$cdm_schema, ".", table_name, "','U') IS NULL\n",
          "BEGIN\n",
          stmt,
          "\nEND;"
        )
        execute_sql_with_retry(conn_cdm, create_sql)
      }

      still_missing <- required_cdm_tables[!vapply(
        required_cdm_tables,
        function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
        logical(1)
      )]
      if (length(still_missing) > 0) {
        stop(
          "Failed to create required CDM tables: ",
          paste(still_missing, collapse = ", ")
        )
      }
    }
  }

  # drop_rollup_helper_tables() removes the three intermediate visit rollup
  # tables (ALL_VISITS, ASSIGN_ALL_VISIT_IDS, FINAL_VISIT_IDS) that are
  # created during the visit assignment step.  Called during reset so they are
  # regenerated cleanly on the next run even if the previous run partially
  # completed the visit rollup phase.
  drop_rollup_helper_tables <- function(connection, cdm_schema) {
    helper_tables <- c("all_visits", "assign_all_visit_ids", "final_visit_ids")
    for (table_name in helper_tables) {
      sql <- render_sql(
        "IF OBJECT_ID('@cdm_schema.@table_name', 'U') IS NOT NULL
           DROP TABLE @cdm_schema.@table_name;",
        cdm_schema = cdm_schema,
        table_name = table_name
      )
      execute_sql_with_retry(connection, sql)
    }
    invisible(NULL)
  }

  # execute_sql_file() reads a SQL file, applies two SQL Server-specific patches
  # for known ETLSyntheaBuilder syntax issues, then executes via
  # execute_sql_with_retry().  Two files receive special treatment:
  #
  #   insert_person.sql  — ETLSyntheaBuilder emits the non-standard
  #     "INSERT ... WITH CTE ... SELECT" form which SQL Server rejects.
  #     The regex below reorders it to the valid "WITH CTE ... INSERT ... SELECT".
  #
  #   insert_drug_era.sql — The generated query joins drug_exposure directly
  #     against concept_ancestor (75M rows), causing CXSYNC_PORT parallelism
  #     stalls that never complete on this instance.  This patch pre-materialises
  #     the drug→ingredient mapping into a temp table (#drug_ingredient_map)
  #     so the join operates on ~300 rows instead of 75M, and adds MAXDOP 1
  #     to suppress the parallel query plan.
  execute_sql_file <- function(connection, file_path) {
    sql <- paste(readLines(file_path, warn = FALSE), collapse = "\n")

    # ETLSyntheaBuilder can emit INSERT ... WITH CTE ... SELECT for person load,
    # which is invalid in SQL Server. Rewrite to WITH CTE ... INSERT ... SELECT.
    if (tolower(basename(file_path)) == "insert_person.sql") {
      schema_esc <- gsub("\\.", "\\\\.", config$cdm_schema)
      pat <- paste0(
        "(?is)^\\s*(insert\\s+into\\s+", schema_esc, "\\.person\\s*\\([^)]*\\)\\s*)",
        "with\\s+mapped_states\\s+as\\s*\\((.*?)\\)\\s*select(.*)$"
      )
      m <- regexec(pat, sql, perl = TRUE)
      parts <- regmatches(sql, m)[[1]]
      if (length(parts) == 4) {
        insert_stmt <- parts[2]
        cte_body <- parts[3]
        select_tail <- parts[4]
        sql <- paste0(
          "with mapped_states as (", cte_body, ")\n",
          insert_stmt,
          "select",
          select_tail
        )
      }
    }

    # insert_drug_era.sql: the standard ETLSyntheaBuilder CTE chain references
    # ctePreDrugTarget FOUR times in a single WITH statement, and cteSubExposureEndDates
    # is used in cteDrugExposureEnds via a non-equi join (end_date >= start_date).
    # SQL Server cannot hash-join on the inequality predicate and falls back to
    # nested loops that re-evaluate the entire CTE tree for every row, causing
    # O(n^2) to O(n^3) complexity that stalls for 8+ hours on 800K drug exposures.
    #
    # Fix: bypass the generated SQL entirely and execute a fully materialized
    # step-by-step version that:
    #   1. Builds #drug_ingredient_map (~400 rows, concept_ancestor join once)
    #   2. Materializes #pre_drug_target (drug_exposure × dim_map) with index
    #   3. Materializes #sub_exposure_end_dates (gap-and-island first pass) with index
    #   4. Materializes #final_target (sub-exposure grouping) with index
    #   5. Computes final era into #tmp_de and inserts into drug_era
    # Each step reads its input exactly once; total runtime ~1-2 minutes.
    if (tolower(basename(file_path)) == "insert_drug_era.sql") {
      s <- config$cdm_schema
      sql <- paste0(
        # Step 1: drug->ingredient map
        "IF OBJECT_ID('tempdb..#drug_ingredient_map','U') IS NOT NULL DROP TABLE #drug_ingredient_map;\n",
        "SELECT DISTINCT d.drug_concept_id, c.concept_id AS ingredient_concept_id\n",
        "INTO #drug_ingredient_map\n",
        "FROM ", s, ".drug_exposure d\n",
        "  JOIN ", s, ".concept_ancestor ca ON ca.descendant_concept_id = d.drug_concept_id\n",
        "  JOIN ", s, ".concept c ON ca.ancestor_concept_id = c.concept_id\n",
        "WHERE c.vocabulary_id = 'RxNorm' AND c.concept_class_id = 'Ingredient'\n",
        "  AND d.drug_concept_id != 0;\n",
        "CREATE INDEX IX_dim_dc ON #drug_ingredient_map (drug_concept_id);\n\n",

        # Step 2: pre_drug_target (drug_exposure x dim_map)
        "IF OBJECT_ID('tempdb..#pre_drug_target','U') IS NOT NULL DROP TABLE #pre_drug_target;\n",
        "SELECT d.drug_exposure_id, d.person_id, dim.ingredient_concept_id,\n",
        "  d.drug_exposure_start_date, d.days_supply,\n",
        "  COALESCE(NULLIF(d.drug_exposure_end_date,NULL),\n",
        "           NULLIF(DATEADD(day,d.days_supply,d.drug_exposure_start_date),d.drug_exposure_start_date),\n",
        "           DATEADD(day,1,d.drug_exposure_start_date)) AS drug_exposure_end_date\n",
        "INTO #pre_drug_target\n",
        "FROM ", s, ".drug_exposure d\n",
        "  JOIN #drug_ingredient_map dim ON dim.drug_concept_id = d.drug_concept_id\n",
        "WHERE d.drug_concept_id != 0 AND COALESCE(d.days_supply,0) >= 0;\n",
        "CREATE INDEX IX_pdt ON #pre_drug_target\n",
        "  (person_id, ingredient_concept_id, drug_exposure_start_date)\n",
        "  INCLUDE (drug_exposure_end_date, drug_exposure_id, days_supply);\n\n",

        # Step 3: sub_exposure_end_dates (gap-and-island, avoids non-equi CTE re-scan)
        "IF OBJECT_ID('tempdb..#sub_exposure_end_dates','U') IS NOT NULL DROP TABLE #sub_exposure_end_dates;\n",
        "SELECT person_id, ingredient_concept_id, event_date AS end_date\n",
        "INTO #sub_exposure_end_dates\n",
        "FROM (\n",
        "  SELECT person_id, ingredient_concept_id, event_date, event_type,\n",
        "    MAX(start_ordinal) OVER (PARTITION BY person_id, ingredient_concept_id\n",
        "      ORDER BY event_date, event_type ROWS UNBOUNDED PRECEDING) AS start_ordinal,\n",
        "    ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id\n",
        "      ORDER BY event_date, event_type) AS overall_ord\n",
        "  FROM (\n",
        "    SELECT person_id, ingredient_concept_id, drug_exposure_start_date AS event_date,\n",
        "      -1 AS event_type,\n",
        "      ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id\n",
        "        ORDER BY drug_exposure_start_date) AS start_ordinal\n",
        "    FROM #pre_drug_target\n",
        "    UNION ALL\n",
        "    SELECT person_id, ingredient_concept_id, drug_exposure_end_date, 1 AS event_type, NULL\n",
        "    FROM #pre_drug_target\n",
        "  ) RAWDATA\n",
        ") e WHERE (2 * e.start_ordinal) - e.overall_ord = 0;\n",
        "CREATE INDEX IX_sed ON #sub_exposure_end_dates (person_id, ingredient_concept_id, end_date);\n\n",

        # Step 4: final_target (sub-exposure grouping)
        "IF OBJECT_ID('tempdb..#final_target','U') IS NOT NULL DROP TABLE #final_target;\n",
        "WITH cteDrugExposureEnds AS (\n",
        "  SELECT dt.person_id, dt.ingredient_concept_id AS drug_concept_id, dt.drug_exposure_start_date,\n",
        "    MIN(e.end_date) AS drug_sub_exposure_end_date\n",
        "  FROM #pre_drug_target dt\n",
        "  JOIN #sub_exposure_end_dates e ON dt.person_id = e.person_id\n",
        "    AND dt.ingredient_concept_id = e.ingredient_concept_id\n",
        "    AND e.end_date >= dt.drug_exposure_start_date\n",
        "  GROUP BY dt.drug_exposure_id, dt.person_id, dt.ingredient_concept_id, dt.drug_exposure_start_date\n",
        "),\n",
        "cteSubExposures AS (\n",
        "  SELECT ROW_NUMBER() OVER (PARTITION BY person_id, drug_concept_id, drug_sub_exposure_end_date ORDER BY person_id) AS row_number,\n",
        "    person_id, drug_concept_id, MIN(drug_exposure_start_date) AS drug_sub_exposure_start_date,\n",
        "    drug_sub_exposure_end_date, COUNT(*) AS drug_exposure_count\n",
        "  FROM cteDrugExposureEnds\n",
        "  GROUP BY person_id, drug_concept_id, drug_sub_exposure_end_date\n",
        ")\n",
        "SELECT row_number, person_id, drug_concept_id,\n",
        "  drug_sub_exposure_start_date, drug_sub_exposure_end_date, drug_exposure_count,\n",
        "  DATEDIFF(day,drug_sub_exposure_start_date,drug_sub_exposure_end_date) AS days_exposed\n",
        "INTO #final_target FROM cteSubExposures;\n",
        "CREATE INDEX IX_ft ON #final_target\n",
        "  (person_id, drug_concept_id, drug_sub_exposure_start_date)\n",
        "  INCLUDE (drug_sub_exposure_end_date, drug_exposure_count, days_exposed);\n\n",

        # Step 5: final era into #tmp_de
        "IF OBJECT_ID('tempdb..#tmp_de','U') IS NOT NULL DROP TABLE #tmp_de;\n",
        "WITH cteEndDates AS (\n",
        "  SELECT person_id, ingredient_concept_id, DATEADD(day,-30,event_date) AS end_date\n",
        "  FROM (\n",
        "    SELECT person_id, ingredient_concept_id, event_date, event_type,\n",
        "      MAX(start_ordinal) OVER (PARTITION BY person_id, ingredient_concept_id\n",
        "        ORDER BY event_date, event_type ROWS UNBOUNDED PRECEDING) AS start_ordinal,\n",
        "      ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id\n",
        "        ORDER BY event_date, event_type) AS overall_ord\n",
        "    FROM (\n",
        "      SELECT person_id, drug_concept_id AS ingredient_concept_id, drug_sub_exposure_start_date AS event_date,\n",
        "        -1 AS event_type,\n",
        "        ROW_NUMBER() OVER (PARTITION BY person_id, drug_concept_id\n",
        "          ORDER BY drug_sub_exposure_start_date) AS start_ordinal\n",
        "      FROM #final_target\n",
        "      UNION ALL\n",
        "      SELECT person_id, drug_concept_id AS ingredient_concept_id, DATEADD(day,30,drug_sub_exposure_end_date), 1 AS event_type, NULL\n",
        "      FROM #final_target\n",
        "    ) RAWDATA\n",
        "  ) e WHERE (2 * e.start_ordinal) - e.overall_ord = 0\n",
        "),\n",
        "cteDrugEraEnds AS (\n",
        "  SELECT ft.person_id, ft.drug_concept_id, ft.drug_sub_exposure_start_date,\n",
        "    MIN(e.end_date) AS era_end_date, ft.drug_exposure_count, ft.days_exposed\n",
        "  FROM #final_target ft\n",
        "  JOIN cteEndDates e ON ft.person_id = e.person_id\n",
        "    AND ft.drug_concept_id = e.ingredient_concept_id\n",
        "    AND e.end_date >= ft.drug_sub_exposure_start_date\n",
        "  GROUP BY ft.person_id, ft.drug_concept_id, ft.drug_sub_exposure_start_date,\n",
        "    ft.drug_exposure_count, ft.days_exposed\n",
        ")\n",
        "SELECT ROW_NUMBER() OVER (ORDER BY person_id) AS drug_era_id,\n",
        "  person_id, drug_concept_id,\n",
        "  MIN(drug_sub_exposure_start_date) AS drug_era_start_date,\n",
        "  era_end_date,\n",
        "  SUM(drug_exposure_count) AS drug_exposure_count,\n",
        "  DATEDIFF(day,MIN(drug_sub_exposure_start_date),era_end_date) - SUM(days_exposed) AS gap_days\n",
        "INTO #tmp_de FROM cteDrugEraEnds dee GROUP BY person_id, drug_concept_id, era_end_date;\n\n",

        # Step 6: insert into drug_era table
        "INSERT INTO ", s, ".drug_era\n",
        "  (drug_era_id,person_id,drug_concept_id,drug_era_start_date,drug_era_end_date,drug_exposure_count,gap_days)\n",
        "SELECT * FROM #tmp_de;\n"
      )
    }

    # insert_payer_plan_period.sql wraps a 4-table join
    # (payers → payer_transitions → patients → person) in an outer SELECT that
    # uses ROW_NUMBER() OVER (ORDER BY ...) for ID generation.
    #
    # Two problems require patching:
    #   1. CXSYNC_PORT stall: SQL Server picks a parallel window-function plan
    #      that deadlocks on thread synchronisation.  MAXDOP 1 forces serial.
    #   2. Nested-loop pathology: with ~91 K payer_transition rows and no index
    #      on payer_transitions.payer, a serial nested-loop plan must scan the
    #      91 K staging table once per payer (~10 × 91 K = 917 K comparisons) and
    #      then scan patients once per matched transition row
    #      (~91 K × 1 914 = 174 M comparisons).  HASH JOIN forces hash-join
    #      operators throughout, reducing the work to O(91 K) regardless of
    #      missing indexes.
    if (tolower(basename(file_path)) == "insert_payer_plan_period.sql") {
      sql <- sub(
        "\\)\\s*person_payer_windows\\s*;",
        ") person_payer_windows\nOPTION (HASH JOIN, MAXDOP 1);",
        sql, perl = TRUE, ignore.case = TRUE
      )
    }

    # insert_cost_v300.sql builds cost rows via four UNION ALL branches that
    # each join synthea staging tables against the OMOP event tables and
    # payer_plan_period.  The most expensive branch joins:
    #   synthea.conditions  (137 K rows)
    #   synthea.encounters  (242 K rows)
    #   synthea.claims      (549 K rows)
    #   synthea.claims_transactions (4.6 M rows)
    # plus omop.person, visit_occurrence, condition_occurrence, payer_plan_period.
    # Without proper indexes, SQL Server builds a 4.6 M-row hash table for
    # claims_transactions and spills to tempdb, taking hours.
    #
    # Fix: force HASH JOIN + MAXDOP 1 so that SQL Server chooses hash-join
    # operators on the pre-built (non-spilling) hash tables and executes
    # serially, avoiding both the hash-spill and CXSYNC_PORT stall.
    if (tolower(basename(file_path)) == "insert_cost_v300.sql") {
      sql <- sub(
        "\\)\\s*as\\s+tmp\\s*;",
        ") as tmp\nOPTION (HASH JOIN, MAXDOP 1);",
        sql, perl = TRUE, ignore.case = TRUE
      )
    }

    # insert_condition_era.sql uses a gap-and-island CTE chain with nested window
    # functions (ROW_NUMBER, MAX OVER UNBOUNDED PRECEDING) and a cross-join
    # between start/end events.  SQL Server picks a parallel plan that stalls
    # indefinitely on CXSYNC_PORT thread synchronisation.
    # Fix: append OPTION(MAXDOP 1) to the SELECT INTO #tmp_ce query to force a
    # serial plan.  This drops runtime from hours to under a minute.
    if (tolower(basename(file_path)) == "insert_condition_era.sql") {
      sql <- sub(
        "(SELECT\\s[\\s\\S]*?FROM\\s+cteConditionEnds[\\s\\S]*?GROUP BY person_id,\\s*condition_concept_id,\\s*era_end_date)(\\s*;)",
        "\\1\nOPTION (MAXDOP 1)\\2",
        sql, perl = TRUE, ignore.case = TRUE
      )
    }

    # Date column VARCHAR→DATETIME2 conversion patch: staging date fields may
    # arrive in one of three forms depending on JDBC coercion behavior:
    #   1) Integer day offset from 1970-01-01 (for example: -10010, 5889)
    #   2) ISO timestamp string (yyyy-mm-ddThh:mm:ss[.fff][Z])
    #   3) ISO date string      (yyyy-mm-dd)
    # Integer-like tokens must be handled first; otherwise values such as
    # "5889" can be interpreted as year 5889 by style-23 conversion.
    date_expr <- paste0(
      "CASE ",
      "WHEN TRY_CONVERT(INT, TRY_CONVERT(VARCHAR(50), \\1.\\2)) IS NOT NULL THEN DATEADD(DAY, TRY_CONVERT(INT, TRY_CONVERT(VARCHAR(50), \\1.\\2)), CONVERT(DATETIME2, '1970-01-01', 23)) ",
      "ELSE COALESCE(TRY_CONVERT(DATETIME2, \\1.\\2, 126), TRY_CONVERT(DATETIME2, \\1.\\2, 23)) ",
      "END"
    )
    sql <- gsub(
      "\\b([a-z]+)\\.\\b(birthdate|startdate|stopdate|start|stop|START_DATE|STOP_DATE|BIRTHDATE|START|STOP)\\b",
      date_expr,
      sql, ignore.case = TRUE, perl = TRUE
    )

    execute_sql_with_retry(connection, sql)
  }

  # create_visit_rollup_tables_sql_server() generates and executes the three
  # visit assignment SQL scripts produced by ETLSyntheaBuilder:
  #   AllVisitTable.sql          — flattens all encounter rows into ALL_VISITS
  #   AAVITable.sql              — assigns visit_occurrence IDs (ASSIGN_ALL_VISIT_IDS)
  #   FINAL_VISIT_IDS (inline)   — deduplicates to one visit ID per encounter
  #                                using a priority-ranked window function
  # The final FINAL_VISIT_IDS step is re-implemented inline rather than from
  # a generated file to allow safe re-execution (IF OBJECT_ID ... DROP) and
  # to avoid hardcoded schema names in the generated output SQL.
  create_visit_rollup_tables_sql_server <- function() {
    etl_sql_dir <- file.path(getwd(), "output")
    dir.create(etl_sql_dir, recursive = TRUE, showWarnings = FALSE)
    run_step_with_retry("ETLSyntheaBuilder::CreateVisitRollupTables(sqlOnly)", ETLSyntheaBuilder::CreateVisitRollupTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      syntheaSchema = synthea_schema,
      cdmVersion = cdm_version,
      sqlOnly = TRUE
    ))

    conn_rollup <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_rollup), add = TRUE)

    execute_sql_file(conn_rollup, file.path("output", "AllVisitTable.sql"))
    execute_sql_file(conn_rollup, file.path("output", "AAVITable.sql"))

    final_visit_sql <- render_sql(
      "IF OBJECT_ID('@cdm_schema.FINAL_VISIT_IDS', 'U') IS NOT NULL
         DROP TABLE @cdm_schema.FINAL_VISIT_IDS;

       SELECT encounter_id, VISIT_OCCURRENCE_ID_NEW
       INTO @cdm_schema.FINAL_VISIT_IDS
       FROM (
         SELECT *,
             ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY PRIORITY) AS RN
         FROM (
             SELECT *,
                 CASE
                     WHEN encounterclass IN ('emergency', 'urgent') THEN
                         CASE
                             WHEN VISIT_TYPE = 'inpatient' AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 1
                             WHEN VISIT_TYPE IN ('emergency', 'urgent') AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 2
                             ELSE 99
                         END
                     WHEN encounterclass IN ('ambulatory', 'wellness', 'outpatient') THEN
                         CASE
                             WHEN VISIT_TYPE = 'inpatient' AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 1
                             WHEN VISIT_TYPE IN ('ambulatory', 'wellness', 'outpatient') AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 2
                             ELSE 99
                         END
                     WHEN encounterclass = 'inpatient' AND VISIT_TYPE = 'inpatient' AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 1
                     ELSE 99
                 END AS PRIORITY
             FROM @cdm_schema.ASSIGN_ALL_VISIT_IDS
         ) T1
       ) RankedVisits
       WHERE RN = 1;",
      cdm_schema = config$cdm_schema
    )
    execute_sql_with_retry(conn_rollup, final_visit_sql)
  }

  # ---------------------------------------------------------------------------
  # truncate_cdm_event_tables_sql_server()
  #
  # Clears every OMOP CDM domain table, the ETL vocab-map working tables, and
  # the visit-rollup working tables BEFORE any data are inserted.  This ensures
  # re-running the ETL always produces a clean dataset from the most recent
  # Synthea CSV files, with no rows carried over from previous runs.
  #
  # All statements are guarded with IF OBJECT_ID ... IS NOT NULL so the first
  # run (tables may not yet exist) succeeds without error.  TRUNCATE TABLE is
  # used (not DELETE) for speed — no per-row log entries — and is safe here
  # because OMOP CDM implementations typically do not enforce foreign-key
  # constraints.
  #
  # Tables truncated (25 total):
  #   19 CDM domain tables   : location, care_site, person, observation_period,
  #                            provider, visit_occurrence, visit_detail,
  #                            condition_occurrence, observation, measurement,
  #                            procedure_occurrence, drug_exposure,
  #                            condition_era, drug_era, cdm_source,
  #                            device_exposure, death, payer_plan_period, cost
  #   3 ETL map tables       : source_to_standard_vocab_map,
  #                            source_to_source_vocab_map, states_map
  #   3 visit rollup tables  : all_visits, ASSIGN_ALL_VISIT_IDS, FINAL_VISIT_IDS
  # ---------------------------------------------------------------------------
  truncate_cdm_event_tables_sql_server <- function() {
    message("[ETL] Truncating CDM event tables, map tables, and visit rollup tables ...")

    truncate_sql <- SqlRender::translate(
      SqlRender::render(
        "-- CDM domain tables
         IF OBJECT_ID('@cdm_schema.location',             'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.location;
         IF OBJECT_ID('@cdm_schema.care_site',            'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.care_site;
         IF OBJECT_ID('@cdm_schema.person',               'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.person;
         IF OBJECT_ID('@cdm_schema.observation_period',   'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.observation_period;
         IF OBJECT_ID('@cdm_schema.provider',             'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.provider;
         IF OBJECT_ID('@cdm_schema.visit_occurrence',     'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.visit_occurrence;
         IF OBJECT_ID('@cdm_schema.visit_detail',         'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.visit_detail;
         IF OBJECT_ID('@cdm_schema.condition_occurrence', 'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.condition_occurrence;
         IF OBJECT_ID('@cdm_schema.observation',          'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.observation;
         IF OBJECT_ID('@cdm_schema.measurement',          'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.measurement;
         IF OBJECT_ID('@cdm_schema.procedure_occurrence', 'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.procedure_occurrence;
         IF OBJECT_ID('@cdm_schema.drug_exposure',        'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.drug_exposure;
         IF OBJECT_ID('@cdm_schema.condition_era',        'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.condition_era;
         IF OBJECT_ID('@cdm_schema.drug_era',             'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.drug_era;
         IF OBJECT_ID('@cdm_schema.cdm_source',           'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.cdm_source;
         IF OBJECT_ID('@cdm_schema.device_exposure',      'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.device_exposure;
         IF OBJECT_ID('@cdm_schema.death',                'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.death;
         IF OBJECT_ID('@cdm_schema.payer_plan_period',    'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.payer_plan_period;
         IF OBJECT_ID('@cdm_schema.cost',                 'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.cost;
         -- ETL vocab-map working tables
         IF OBJECT_ID('@cdm_schema.source_to_standard_vocab_map', 'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.source_to_standard_vocab_map;
         IF OBJECT_ID('@cdm_schema.source_to_source_vocab_map',   'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.source_to_source_vocab_map;
         IF OBJECT_ID('@cdm_schema.states_map',                   'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.states_map;
         -- Visit rollup working tables
         IF OBJECT_ID('@cdm_schema.all_visits',           'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.all_visits;
         IF OBJECT_ID('@cdm_schema.ASSIGN_ALL_VISIT_IDS', 'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.ASSIGN_ALL_VISIT_IDS;
         IF OBJECT_ID('@cdm_schema.FINAL_VISIT_IDS',      'U') IS NOT NULL TRUNCATE TABLE @cdm_schema.FINAL_VISIT_IDS;",
        cdm_schema = config$cdm_schema
      ),
      targetDialect = config$dbms
    )

    conn_trunc <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_trunc), add = TRUE)

    # Execute each statement individually (SQL Server does not allow TRUNCATE
    # and IF-blocks to be batched as a single executeSQL call via JDBC in all
    # driver versions).
    #
    # Splitting strategy:
    #   - Pattern ";[ \t]*\r?\n" explicitly handles both LF (\n) and CRLF (\r\n)
    #     line endings so the fix is reliable on any platform.
    #   - sub(";+\\s*$", ...) strips any trailing semicolons AND trailing
    #     whitespace in one pass, preventing the ";;" double-semicolon that
    #     causes "String.indexOf(int)" NullPointerException in SQL Server JDBC.
    #   - grepl("\\S", stmts) filters whitespace-only/empty fragments (more
    #     robust than nchar > 0 which would keep "\r"-only strings).
    stmts <- strsplit(truncate_sql, ";[ \t]*\r?\n", perl = TRUE)[[1]]
    stmts <- trimws(stmts)
    stmts <- sub(";+\\s*$", "", stmts)
    stmts <- stmts[grepl("\\S", stmts)]
    for (stmt in stmts) {
      execute_sql_with_retry(conn_trunc, paste0(stmt, ";"))
    }

    message("[ETL] Truncation complete — all CDM event tables are empty and ready for reload.")
  }

  # load_event_tables_sql_server() drives the full domain INSERT workload:
  #   Phase A — Map SQL (3 files):
  #     create_source_to_standard_vocab_map.sql  — maps source codes (SNOMED,
  #       LOINC, RxNorm, CPT4) to their standard OMOP concept IDs.
  #     create_source_to_source_vocab_map.sql    — preserves source concept IDs
  #       for observation_source_concept_id and similar columns.
  #     create_states_map.sql                    — maps US state names to
  #       OMOP location concept IDs.
  #   Phase B — Domain INSERT SQL (19 files, one per OMOP CDM table):
  #     insert_location, insert_care_site, insert_person,
  #     insert_observation_period, insert_provider,
  #     insert_visit_occurrence, insert_visit_detail,
  #     insert_condition_occurrence, insert_observation, insert_measurement,
  #     insert_procedure_occurrence, insert_drug_exposure,
  #     insert_condition_era, insert_drug_era, insert_cdm_source,
  #     insert_device_exposure, insert_death, insert_payer_plan_period,
  #     insert_cost_v300.
  #
  # Every file is executed via execute_sql_file(), which applies the
  # SQL Server-specific patches for insert_person and insert_drug_era.
  # Each file ticks the progress bar so the operator can track domain progress.
  load_event_tables_sql_server <- function(progress_tracker = NULL) {
    etl_sql_dir <- file.path(getwd(), "output")
    dir.create(etl_sql_dir, recursive = TRUE, showWarnings = FALSE)
    run_step_with_retry("ETLSyntheaBuilder::CreateMapAndRollupTables(sqlOnly)", ETLSyntheaBuilder::CreateMapAndRollupTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      syntheaSchema = synthea_schema,
      cdmVersion = cdm_version,
      syntheaVersion = synthea_version,
      sqlOnly = TRUE
    ))

    run_step_with_retry("ETLSyntheaBuilder::LoadEventTables(sqlOnly)", ETLSyntheaBuilder::LoadEventTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      syntheaSchema = synthea_schema,
      cdmVersion = cdm_version,
      syntheaVersion = synthea_version,
      createIndices = FALSE,
      sqlOnly = TRUE
    ))

    conn_events <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_events), add = TRUE)

    map_sql_files <- c(
      file.path("output", "create_source_to_standard_vocab_map.sql"),
      file.path("output", "create_source_to_source_vocab_map.sql"),
      file.path("output", "create_states_map.sql")
    )
    for (sql_file in map_sql_files) {
      execute_sql_file(conn_events, sql_file)
      if (!is.null(progress_tracker)) {
        progress_tracker$tick(paste0("Loaded map SQL: ", basename(sql_file)))
      }
    }

    # After creating the vocab map tables, add composite covering indexes so the
    # 19 domain INSERT SQLs can use index seeks instead of table scans.  Each
    # INSERT filters on (source_code, source_vocabulary_id, target_domain_id /
    # target_vocabulary_id) so a composite key on those columns eliminates the
    # full-table-scan + hash-join pattern that is otherwise required.
    message("[PERF] Adding composite indexes on source_to_standard_vocab_map and source_to_source_vocab_map...")
    vocab_map_index_sql <- SqlRender::translate(
      SqlRender::render(
        "IF OBJECT_ID('@cdm_schema.source_to_standard_vocab_map', 'U') IS NOT NULL
         BEGIN
           IF NOT EXISTS (
             SELECT 1 FROM sys.indexes
             WHERE object_id = OBJECT_ID('@cdm_schema.source_to_standard_vocab_map')
               AND name = 'IX_stdvm_code_vocab_domain'
           )
           BEGIN
             CREATE INDEX IX_stdvm_code_vocab_domain
               ON @cdm_schema.source_to_standard_vocab_map
                 (source_code, source_vocabulary_id, target_domain_id)
               INCLUDE (target_concept_id, target_vocabulary_id,
                        target_standard_concept, target_invalid_reason,
                        source_concept_id);
           END;
         END;

         IF OBJECT_ID('@cdm_schema.source_to_source_vocab_map', 'U') IS NOT NULL
         BEGIN
           IF NOT EXISTS (
             SELECT 1 FROM sys.indexes
             WHERE object_id = OBJECT_ID('@cdm_schema.source_to_source_vocab_map')
               AND name = 'IX_srcvm_code_vocab'
           )
           BEGIN
             CREATE INDEX IX_srcvm_code_vocab
               ON @cdm_schema.source_to_source_vocab_map
                 (source_code, source_vocabulary_id)
               INCLUDE (source_concept_id, source_domain_id,
                        target_concept_id, target_vocabulary_id);
           END;
         END;",
        cdm_schema = config$cdm_schema
      ),
      targetDialect = config$dbms
    )
    execute_sql_with_retry(conn_events, vocab_map_index_sql)
    message("[PERF] Vocab map composite indexes ready.")

    event_sql_files <- c(
      file.path("output", "insert_location.sql"),
      file.path("output", "insert_care_site.sql"),
      file.path("output", "insert_person.sql"),
      file.path("output", "insert_observation_period.sql"),
      file.path("output", "insert_provider.sql"),
      file.path("output", "insert_visit_occurrence.sql"),
      file.path("output", "insert_visit_detail.sql"),
      file.path("output", "insert_condition_occurrence.sql"),
      file.path("output", "insert_observation.sql"),
      file.path("output", "insert_measurement.sql"),
      file.path("output", "insert_procedure_occurrence.sql"),
      file.path("output", "insert_drug_exposure.sql"),
      file.path("output", "insert_condition_era.sql"),
      file.path("output", "insert_drug_era.sql"),
      file.path("output", "insert_cdm_source.sql"),
      file.path("output", "insert_device_exposure.sql"),
      file.path("output", "insert_death.sql"),
      file.path("output", "insert_payer_plan_period.sql"),
      file.path("output", "insert_cost_v300.sql")
    )
    for (sql_file in event_sql_files) {
      execute_sql_file(conn_events, sql_file)
      if (!is.null(progress_tracker)) {
        progress_tracker$tick(paste0("Loaded event SQL: ", basename(sql_file)))
      }
    }

    # -------------------------------------------------------------------------
    # Post-INSERT fix-up: populate visit_occurrence.discharged_to_concept_id
    # and discharged_to_source_value from synthea.encounters.DISCHARGE.
    #
    # Why this step exists:
    #   ETLSyntheaBuilder's bundled insert_visit_occurrence.sql hard-codes
    #     discharged_to_concept_id   = 0
    #     discharged_to_source_value = NULL
    #   regardless of staging contents.  Studies whose external/synthea
    #   submodule points at a fork that emits a DISCHARGE column in
    #   encounters.csv (carrying the NUBC discharge_disposition code from
    #   GMF EncounterEnd states) therefore see their disposition silently
    #   dropped at INSERT time.  This UPDATE rewrites those two columns in
    #   place by joining visit_occurrence back to the synthea staging
    #   encounters table and resolving each NUBC code against the live OMOP
    #   vocabulary.
    #
    # Why we join via final_visit_ids and aggregate:
    #   Synthea's rollup (ALL_VISITS -> ASSIGN_ALL_VISIT_IDS -> FINAL_VISIT_IDS)
    #   merges multiple source encounter rows into a single visit_occurrence
    #   row.  Only the EncounterEnd state's encounter carries a DISCHARGE
    #   code; the admission / ICU / ward rows in the same rolled-up visit
    #   have an empty DISCHARGE.  Joining directly on
    #   visit_occurrence.visit_source_value would only catch the disposition
    #   if the chosen representative encounter happens to be the one with
    #   DISCHARGE set, which is not guaranteed by the rollup priority.
    #   Aggregating over all encounters that map to the same
    #   visit_occurrence_id_new via FINAL_VISIT_IDS lets us pick up the
    #   unique non-empty DISCHARGE value regardless of which row the rollup
    #   chose as the visit's representative.  HAVING ... IS NOT NULL skips
    #   visits whose source encounters all have empty DISCHARGE.
    #
    # COALESCE preference order for discharged_to_concept_id:
    #   1. standard CMS Place of Service concept (preferred — rolled up via
    #      concept_relationship 'Maps to' from the UB04 Pt dis status concept)
    #   2. UB04 Pt dis status concept itself (fallback when the 'Maps to'
    #      mapping is absent in this vocabulary build)
    #   3. 0 ('No matching concept') when DISCHARGE is null / empty / unknown
    #
    # Stock-synthea-safe: when the synthea fork does NOT emit a DISCHARGE
    # column, the staging DISCHARGE column added by step 10b is all NULL,
    # the inner subquery returns no rows, and the UPDATE is a no-op.
    # Idempotent: re-running rewrites the same column with the same derived
    # values.
    # -------------------------------------------------------------------------
    fixup_disposition_sql <- render_sql(
      "UPDATE vo
       SET vo.discharged_to_concept_id   = COALESCE(c_std.concept_id, c_ub04.concept_id, 0),
           vo.discharged_to_source_value = w.discharge
       FROM @cdm_schema.visit_occurrence vo
       INNER JOIN (
         SELECT fvi.visit_occurrence_id_new AS vo_id,
                -- Normalize: DatabaseConnector's bulk loader auto-detects the
                -- DISCHARGE column as numeric and stores '01' as '1'.  UB04
                -- Pt dis status concept_codes are always 2 digits in OMOP
                -- (01, 02, ..., 99), so left-pad single-digit values with '0'
                -- before the vocab join.  Multi-digit values pass through.
                MAX(CASE
                      WHEN LEN(NULLIF(LTRIM(RTRIM(e.discharge)), '')) = 1
                        THEN '0' + LTRIM(RTRIM(e.discharge))
                      ELSE NULLIF(LTRIM(RTRIM(e.discharge)), '')
                    END) AS discharge
         FROM @cdm_schema.final_visit_ids fvi
         INNER JOIN @synthea_schema.encounters e
           ON e.id = fvi.encounter_id
         GROUP BY fvi.visit_occurrence_id_new
         HAVING MAX(NULLIF(LTRIM(RTRIM(e.discharge)), '')) IS NOT NULL
       ) w
         ON w.vo_id = vo.visit_occurrence_id
       LEFT JOIN @cdm_schema.concept c_ub04
         ON c_ub04.vocabulary_id = 'UB04 Pt dis status'
        AND c_ub04.concept_code  = w.discharge
        AND c_ub04.invalid_reason IS NULL
       LEFT JOIN @cdm_schema.concept_relationship cr
         ON cr.concept_id_1     = c_ub04.concept_id
        AND cr.relationship_id  = 'Maps to'
        AND cr.invalid_reason  IS NULL
       LEFT JOIN @cdm_schema.concept c_std
         ON c_std.concept_id       = cr.concept_id_2
        AND c_std.standard_concept = 'S'
        AND c_std.invalid_reason  IS NULL;",
      cdm_schema     = config$cdm_schema,
      synthea_schema = synthea_schema
    )
    execute_sql_with_retry(conn_events, fixup_disposition_sql)
    log_msg(
      "Populated visit_occurrence.discharged_to_concept_id / ",
      "discharged_to_source_value from ", synthea_schema,
      ".encounters.DISCHARGE (via final_visit_ids rollup)."
    )
  }

  # ---------------------------------------------------------------------------
  # 6. Execution begins — emit run-identifying header to logs
  # ---------------------------------------------------------------------------
  log_msg("=== Step 5 CSV builder ETL ===")
  log_msg("run_name: ", run_name)
  log_msg("csv_input_dir: ", normalizePath(csv_input_dir, winslash = "/", mustWork = TRUE))
  log_msg("synthea_schema: ", synthea_schema)
  log_msg("synthea_version: ", synthea_version)
  log_msg("cdm_schema: ", config$cdm_schema)
  log_msg("vocabulary_source_schema: ", active_vocab_source_schema)
  log_msg("reload_vocab_from_csv: ", ifelse(isTRUE(reload_vocab_from_csv), "true", "false"))
  if (isTRUE(reload_vocab_from_csv)) {
    log_msg("vocab_file_loc: ", ifelse(is.null(active_vocab_file_loc), "<unset>", active_vocab_file_loc))
  }

  map_table_count <- 3L
  event_table_count <- 19L
  progress_total_steps <- 9L + map_table_count + event_table_count
  if (isTRUE(reload_vocab_from_csv)) {
    progress_total_steps <- progress_total_steps + 1L
  }
  progress <- create_progress_tracker(progress_total_steps)
  on.exit(progress$close(), add = TRUE)

  # ---------------------------------------------------------------------------
  # 7. CDM table structure and staging schema setup
  # ---------------------------------------------------------------------------
  # When using the shared vocab schema, wire synonyms BEFORE ensure_cdm_tables_exist()
  # so that the vocab-present check inside that function finds the synonym objects
  # and takes the "create only missing non-vocab tables" path instead of calling
  # CreateCDMTables for the full schema (which would create real vocab tables that
  # then conflict with the synonyms).
  if (isTRUE(use_shared_vocab_schema)) {
    log_msg("Vocabulary path: shared schema synonyms → '", shared_vocab_schema, "'")
    source("R/db_maintenance.R")
    create_vocab_synonyms(config, config$cdm_schema, shared_vocab_schema)
    progress$tick("Vocabulary synonyms wired to shared schema")
  }

  # Verify (or create) all OMOP CDM tables in the target schema.  This step
  # is idempotent — it only issues DDL for genuinely missing tables.
  ensure_cdm_tables_exist()
  progress$tick("CDM table structure verified")

  # Ensure the synthea staging schema exists.  CREATE SCHEMA is wrapped in an
  # IF SCHEMA_ID guard so it is safe to call on every run.
  conn_check <- connect_with_retry(connection_details)
  log_msg("CDM tables verified in ", config$cdm_schema, ".")

  execute_sql_with_retry(
    conn_check,
    paste0("IF SCHEMA_ID('", synthea_schema, "') IS NULL EXEC('CREATE SCHEMA ", synthea_schema, "');")
  )
  progress$tick("Synthea staging schema verified")

  # ---------------------------------------------------------------------------
  # 8. Vocabulary load
  # ---------------------------------------------------------------------------
  # Vocabulary loading — three paths in priority order:
  #
  # Path A (use_shared_vocab_schema = TRUE):
  #   Wire SQL Server synonyms in the target schema pointing to the shared
  #   omop_vocab schema.  No data is copied; vocab is available instantly.
  #   Requires infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template to have been run once.
  #
  # Path B (reload_vocab_from_csv = TRUE):
  #   Call ETLSyntheaBuilder::LoadVocabFromCsv with the OHDSI vocabulary CSV
  #   directory.  This loads ~130M rows across 9 vocabulary tables.
  #
  # Path C (reload_vocab_from_csv = FALSE):
  #   If the target schema has no vocabulary, bootstrap it from the reference
  #   schema (vocabulary_source_schema) via INSERT ... SELECT.
  #
  # Hard guard: regardless of path taken, assert_vocab_loaded_for_etl() will
  # stop execution if concept/concept_ancestor/concept_relationship are empty.
  if (isTRUE(use_shared_vocab_schema)) {
    # Synonyms already wired before ensure_cdm_tables_exist() above — nothing more to do.
    log_msg("Vocabulary synonyms confirmed in '", config$cdm_schema, "'.")

  } else if (isTRUE(reload_vocab_from_csv)) {
    if (is.null(active_vocab_file_loc) || !dir.exists(active_vocab_file_loc)) {
      stop(
        "reload_vocab_from_csv=TRUE but vocab_file_loc is not set to an existing directory: ",
        ifelse(is.null(active_vocab_file_loc), "<NULL>", active_vocab_file_loc),
        call. = FALSE
      )
    }

    # Pre-flight: ensure the transaction log is large enough for the vocab
    # bulk load.  CONCEPT_ANCESTOR alone is 75 M rows; JDBC batch inserts are
    # fully logged even in SIMPLE recovery, so we need ≥ 25 GB of log space
    # before we start.  ALTER DATABASE MODIFY FILE is async, so we must WAIT
    # and verify the log actually grew on disk before proceeding.
    log_msg("Pre-flight: expanding transaction log for bulk vocabulary load ...")
    tryCatch({
      conn_log <- connect_with_retry(connection_details)
      on.exit(DatabaseConnector::disconnect(conn_log), add = TRUE)

      log_meta_sql <- render_sql(
        "SELECT f.name AS log_name, f.size * 8.0 / 1024 AS size_mb
         FROM sys.master_files f
         JOIN sys.databases d ON f.database_id = d.database_id
         WHERE d.name = '@database' AND f.type_desc = 'LOG';",
        database = config$database
      )
      log_meta <- query_sql_with_retry(conn_log, log_meta_sql)
      names(log_meta) <- tolower(names(log_meta))

      if (nrow(log_meta) > 0L) {
        log_file_name <- as.character(log_meta$log_name[[1]])
        log_size_mb   <- as.numeric(log_meta$size_mb[[1]])
        target_mb     <- 25600L   # 25 GB

        # Switch to SIMPLE recovery so ETL checkpoints can truncate the log
        execute_sql_with_retry(conn_log,
          paste0("ALTER DATABASE [", config$database, "] SET RECOVERY SIMPLE;")
        )

        if (log_size_mb < target_mb) {
          log_msg(
            "Growing transaction log from ", round(log_size_mb, 0),
            " MB to ", target_mb, " MB ...", level = "WARN"
          )
          execute_sql_with_retry(conn_log, paste0(
            "ALTER DATABASE [", config$database, "] MODIFY FILE ",
            "(NAME = N'", log_file_name, "', ",
            "SIZE = ", target_mb, "MB, FILEGROWTH = 2048MB);"
          ))

          # ALTER DATABASE MODIFY FILE is async; SQL Server returns immediately
          # but allocates the space on disk in a background task.  We must poll
          # until the log size reaches the target, otherwise the bulk insert will
          # start before the log has actually grown and immediately hit "log full".
          log_msg("Waiting for transaction log to be allocated on disk (this may take 30-60s) ...")
          max_wait_attempts <- 120L
          wait_interval <- 3L
          for (wait_attempt in seq_len(max_wait_attempts)) {
            Sys.sleep(wait_interval)
            current_log_sql <- render_sql(
              "SELECT f.size * 8.0 / 1024 AS size_mb
               FROM sys.master_files f
               WHERE f.database_id = DB_ID('@database') AND f.type_desc = 'LOG' AND f.name = '@log_name';",
              database = config$database,
              log_name = log_file_name
            )
            current_log <- query_sql_with_retry(conn_log, current_log_sql, max_attempts = 1L)
            current_size_mb <- as.numeric(current_log$size_mb[[1]])

            if (current_size_mb >= target_mb * 0.95) {
              log_msg(
                "Transaction log allocated: ", round(current_size_mb, 0),
                " MB (>= 95% of target). Ready for bulk vocab load."
              )
              break
            }

            if (wait_attempt %% 10L == 0L) {
              log_msg(
                "Still waiting... current log size: ", round(current_size_mb, 0),
                " MB (target: ", target_mb, " MB)"
              )
            }
          }

          if (wait_attempt >= max_wait_attempts) {
            log_msg(
              "Log pre-growth did not complete within timeout; proceeding anyway. ",
              "Monitor for 'log full' errors and re-run if needed.",
              level = "WARN"
            )
          }
        } else {
          # Already large enough; just set generous autogrowth
          execute_sql_with_retry(conn_log, paste0(
            "ALTER DATABASE [", config$database, "] MODIFY FILE ",
            "(NAME = N'", log_file_name, "', FILEGROWTH = 2048MB);"
          ))
          log_msg("Log is already ", round(log_size_mb, 0),
                  " MB (>= target); autogrowth set to 2 GB.")
        }
      }
    }, error = function(e) {
      log_msg(
        "Could not pre-grow transaction log (non-fatal): ", conditionMessage(e),
        level = "WARN"
      )
    })

    log_msg(
      "Reloading vocabulary from CSV via ETLSyntheaBuilder::LoadVocabFromCsv (README-style) ..."
    )
    run_step_with_retry("ETLSyntheaBuilder::LoadVocabFromCsv", ETLSyntheaBuilder::LoadVocabFromCsv(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      vocabFileLoc = active_vocab_file_loc,
      delimiter = vocab_delimiter
    ))
    progress$tick("Vocabulary loaded from CSV")
  } else if (!isTRUE(vocab_is_loaded(conn_check, config$cdm_schema))) {
    log_msg(
      "Vocabulary precheck failed in target schema ", config$cdm_schema,
      "; attempting bootstrap from source schema ", active_vocab_source_schema, " ...",
      level = "WARN"
    )

    copied_vocab <- bootstrap_vocabulary_from_schema(
      connection = conn_check,
      target_schema = config$cdm_schema,
      source_schema = active_vocab_source_schema
    )

    if (isTRUE(copied_vocab)) {
      log_msg(
        "Vocabulary bootstrap complete for target schema ", config$cdm_schema,
        " using source schema ", active_vocab_source_schema, "."
      )
    }
  }

  assert_vocab_loaded_for_etl(conn_check, config$cdm_schema)
  log_msg("Vocabulary precheck passed in ", config$cdm_schema, ".")
  progress$tick("Vocabulary precheck passed")

  DatabaseConnector::disconnect(conn_check)

  # ---------------------------------------------------------------------------
  # 9. Optional reset — drop existing staging and event tables
  # ---------------------------------------------------------------------------
  # When reset_before_etl = TRUE, all Synthea staging rows and all OMOP event
  # table rows are removed so the load begins from a clean state.  This is the
  # recommended mode for study validation runs.  Three layers of cleanup are
  # applied in order of specificity to handle situations where earlier rounds
  # of the same run left partial state:
  #   a) ETLSyntheaBuilder::DropEventTables   — drops OMOP event rows
  #   b) ETLSyntheaBuilder::DropSyntheaTables — drops synthea staging rows
  #   c) drop_rollup_helper_tables + clear_schema_tables — defensive fallback
  #      for version mismatches or partial prior runs
  if (isTRUE(reset_before_etl)) {
    message("Reset requested: dropping event + synthea staging tables before reload ...")
    suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::DropEventTables", ETLSyntheaBuilder::DropEventTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema
    )), silent = TRUE))
    suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::DropSyntheaTables", ETLSyntheaBuilder::DropSyntheaTables(
      connectionDetails = connection_details,
      syntheaSchema = synthea_schema,
      syntheaVersion = synthea_version
    )), silent = TRUE))

    # Defensive cleanup to handle schema-version mismatches in DropSyntheaTables.
    conn_reset <- connect_with_retry(connection_details)
    drop_rollup_helper_tables(conn_reset, config$cdm_schema)
    clear_schema_tables(conn_reset, synthea_schema)
    DatabaseConnector::disconnect(conn_reset)

    # Some reset paths can remove non-vocabulary CDM tables; recreate if needed.
    ensure_cdm_tables_exist()
  }
  progress$tick("Reset and cleanup completed")

  # ---------------------------------------------------------------------------
  # 10. Create Synthea staging tables
  # ---------------------------------------------------------------------------
  # ETLSyntheaBuilder::CreateSyntheaTables executes the versioned CREATE TABLE
  # DDL bundled inside the package for the specified synthea_version.
  # These staging tables mirror the Synthea CSV column layout precisely — they
  # are the insertion target for the raw Synthea CSV data before the OMOP
  # mapping transforms are applied.
  run_step_with_retry("ETLSyntheaBuilder::CreateSyntheaTables", ETLSyntheaBuilder::CreateSyntheaTables(
    connectionDetails = connection_details,
    syntheaSchema = synthea_schema,
    syntheaVersion = synthea_version
  ))
  progress$tick("Synthea staging tables created")

  # ---------------------------------------------------------------------------
  # 10b. Add a DISCHARGE column to synthea.encounters.
  #
  # Stock synthea v3.3.0's CSV exporter does NOT write encounter.discharge to
  # encounters.csv, and ETLSyntheaBuilder's CreateSyntheaTables DDL therefore
  # does not define a DISCHARGE column on the staging table.  When a study
  # uses a synthea fork that DOES emit the discharge_disposition NUBC code
  # (e.g. the synthea-pad fork — see external/synthea pinning in study repos
  # that need this), the loader needs a staging column to land that value
  # in.  We add it pre-emptively here so the same template script works for
  # both stock and patched synthea builds: stock-synthea runs leave the
  # column all-NULL (the post-INSERT fix-up below is a no-op), patched-synthea
  # runs populate it.
  # IF NOT EXISTS guard keeps the step idempotent across re-runs.
  # ---------------------------------------------------------------------------
  conn_alter <- connect_with_retry(connection_details)
  on.exit(DatabaseConnector::disconnect(conn_alter), add = TRUE)
  alter_discharge_sql <- render_sql(
    "IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES
                WHERE TABLE_SCHEMA = '@synthea_schema'
                  AND TABLE_NAME   = 'encounters')
      AND NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
                       WHERE TABLE_SCHEMA = '@synthea_schema'
                         AND TABLE_NAME   = 'encounters'
                         AND COLUMN_NAME  = 'DISCHARGE')
     BEGIN
       ALTER TABLE [@synthea_schema].[encounters] ADD [DISCHARGE] VARCHAR(8) NULL;
     END;",
    synthea_schema = synthea_schema
  )
  execute_sql_with_retry(conn_alter, alter_discharge_sql)
  log_msg("Added/confirmed DISCHARGE VARCHAR(8) column on ", synthea_schema, ".encounters.")
  DatabaseConnector::disconnect(conn_alter)

  # ---------------------------------------------------------------------------
  # Pre-flight: scan all Synthea CSVs against staging schema and correct every
  # date-type mismatch and varchar-too-narrow column before the load is even
  # attempted.  This runs once and prevents the reactive retry loop from having
  # to discover problems one CSV/column at a time.
  # ---------------------------------------------------------------------------
  align_synthea_staging_schema_to_csvs <- function() {
    log_msg("Pre-flight: aligning synthea staging schema to CSV column widths and types ...")

    # Fetch all staging column metadata in one query.
    conn_align <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_align), add = TRUE)

    schema_sql <- render_sql(
      "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE,
              c.CHARACTER_MAXIMUM_LENGTH, c.ORDINAL_POSITION
       FROM INFORMATION_SCHEMA.COLUMNS c
       JOIN INFORMATION_SCHEMA.TABLES t
         ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
        AND c.TABLE_NAME = t.TABLE_NAME
       WHERE c.TABLE_SCHEMA = '@synthea_schema'
         AND t.TABLE_TYPE = 'BASE TABLE'
       ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;",
      synthea_schema = synthea_schema
    )
    schema_df <- query_sql_with_retry(conn_align, schema_sql)
    if (nrow(schema_df) == 0L) {
      log_msg("Pre-flight: no staging tables found — skipping alignment.", level = "WARN")
      return(invisible(NULL))
    }

    # Normalise column names returned by DatabaseConnector (may be camelCase).
    names(schema_df) <- tolower(names(schema_df))

    date_type_set <- c("date", "datetime", "datetime2", "smalldatetime")
    fixes_applied <- 0L

    # Group by table.
    staging_tables <- unique(as.character(schema_df$table_name))

    for (tbl in staging_tables) {
      csv_path <- file.path(csv_input_dir, paste0(tolower(tbl), ".csv"))
      if (!file.exists(csv_path)) {
        next
      }

      tbl_schema <- schema_df[tolower(as.character(schema_df$table_name)) == tolower(tbl), ]

      # Read entire CSV once for this table (suppressing progress bar noise).
      csv_data <- tryCatch(
        data.table::fread(csv_path, showProgress = FALSE, na.strings = c("", "NULL")),
        error = function(e) NULL
      )
      if (is.null(csv_data) || nrow(csv_data) == 0L) {
        next
      }

      csv_col_names_lower <- tolower(names(csv_data))

      alters <- character(0L)

      for (k in seq_len(nrow(tbl_schema))) {
        col_name   <- tolower(as.character(tbl_schema$column_name[[k]]))
        data_type  <- tolower(as.character(tbl_schema$data_type[[k]]))
        staged_len <- suppressWarnings(as.integer(tbl_schema$character_maximum_length[[k]]))
        if (is.na(staged_len)) staged_len <- -1L

        col_idx <- match(col_name, csv_col_names_lower)
        if (is.na(col_idx)) next

        # -- Date/datetime columns: convert to varchar(32) so the loader can
        #    send a string representation without type-binding mismatches.
        if (data_type %in% date_type_set) {
          alters <- c(alters, paste0(
            "ALTER TABLE [", synthea_schema, "].[", tbl,
            "] ALTER COLUMN [", col_name, "] VARCHAR(32) NULL;"
          ))
          next
        }

        # -- Varchar columns: widen if any CSV value exceeds the staged width.
        if (data_type %in% c("varchar", "nvarchar", "char", "nchar") && staged_len > 0L) {
          col_values <- as.character(csv_data[[col_idx]])
          observed_max <- suppressWarnings(max(nchar(col_values, type = "chars", allowNA = TRUE, keepNA = FALSE), na.rm = TRUE))
          if (!is.finite(observed_max)) observed_max <- 0L
          if (observed_max > staged_len) {
            # Round up to next power of 2 (minimum 64) to avoid repeated widening.
            target_len <- max(64L, 2L ^ ceiling(log2(observed_max + 1L)))
            alters <- c(alters, paste0(
              "ALTER TABLE [", synthea_schema, "].[", tbl,
              "] ALTER COLUMN [", col_name, "] VARCHAR(", target_len, ") NULL;"
            ))
          }
        }
      }

      if (length(alters) > 0L) {
        log_msg(
          "Pre-flight: fixing ", length(alters), " column(s) in synthea.", tbl,
          " (date→varchar or too-narrow varchar).",
          level = "WARN"
        )
        for (alt_sql in alters) {
          execute_sql_with_retry(conn_align, alt_sql)
          fixes_applied <- fixes_applied + 1L
        }
      }
    }

    if (fixes_applied > 0L) {
      log_msg("Pre-flight alignment complete: ", fixes_applied, " staging column(s) corrected.", level = "WARN")
    } else {
      log_msg("Pre-flight alignment complete: all staging columns are compatible with CSVs.")
    }
    invisible(NULL)
  }

  # Run the pre-flight alignment immediately after staging tables are created.
  align_synthea_staging_schema_to_csvs()

  # ---------------------------------------------------------------------------
  # 11. Reactive load-error detection helpers
  # ---------------------------------------------------------------------------
  # These functions are the second line of defence after the pre-flight pass.
  # They parse SQL Server error messages and return structured information so
  # load_synthea_tables_with_mitigations() can apply targeted fixes and retry.

  # is_int_date_type_clash_error() detects the SQL Server JDBC binding error
  # that occurs when the JDBC driver tries to send a string value into a DATE
  # column using integer type codes.  This happens because Synthea emits dates
  # as ISO-8601 strings but ETLSyntheaBuilder's batchedInsert uses int binding.
  is_int_date_type_clash_error <- function(err) {
    msg <- tolower(conditionMessage(err))
    grepl("operand type clash", msg, fixed = TRUE) &&
      grepl("int is incompatible with date", msg, fixed = TRUE)
  }

  # parse_truncation_error() extracts the table and column name from a
  # "String or binary data would be truncated" error message.  Returns a
  # named list(table_name, column_name) or NULL if the pattern does not match.
  parse_truncation_error <- function(err) {
    msg <- conditionMessage(err)
    m <- regexec("(?i)table '([^']+)',\\s*column '([^']+)'", msg, perl = TRUE)
    parts <- regmatches(msg, m)[[1]]
    if (length(parts) < 3L) {
      return(NULL)
    }

    table_ref <- parts[[2]]
    table_parts <- strsplit(table_ref, "\\.", perl = TRUE)[[1]]
    table_name <- table_parts[[length(table_parts)]]
    column_name <- parts[[3]]

    list(
      table_name = tolower(table_name),
      column_name = tolower(column_name)
    )
  }

  # widen_synthea_column_from_csv() reads the CSV for the affected table,
  # computes the maximum character length of the named column, and issues an
  # ALTER TABLE ... ALTER COLUMN VARCHAR(n) to accommodate it.  The target
  # width is rounded up to the next power of 2, clamped to a minimum of 64,
  # to reduce the likelihood of having to repeat the same fix on a future run.
  widen_synthea_column_from_csv <- function(table_name, column_name, min_length = 64L) {
    conn_widen <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_widen), add = TRUE)

    col_sql <- render_sql(
      "SELECT DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
       FROM INFORMATION_SCHEMA.COLUMNS
       WHERE TABLE_SCHEMA = '@synthea_schema'
         AND TABLE_NAME = '@table_name'
         AND COLUMN_NAME = '@column_name';",
      synthea_schema = synthea_schema,
      table_name = table_name,
      column_name = column_name
    )
    col_meta <- query_sql_with_retry(conn_widen, col_sql)
    if (nrow(col_meta) == 0L) {
      stop(
        "Cannot auto-widen staging column; column not found: ",
        synthea_schema, ".", table_name, ".", column_name,
        call. = FALSE
      )
    }

    current_len <- suppressWarnings(as.integer(col_meta$CHARACTER_MAXIMUM_LENGTH[[1]]))
    if (is.na(current_len) || current_len < 1L) {
      current_len <- 0L
    }

    csv_path <- file.path(csv_input_dir, paste0(table_name, ".csv"))
    if (!file.exists(csv_path)) {
      stop(
        "Cannot auto-widen staging column; CSV file not found for table '",
        table_name, "': ", csv_path,
        call. = FALSE
      )
    }

    csv_headers <- names(data.table::fread(
      csv_path,
      nrows = 0L,
      showProgress = FALSE
    ))
    matching_cols <- csv_headers[tolower(csv_headers) == tolower(column_name)]
    if (length(matching_cols) == 0L) {
      stop(
        "Cannot auto-widen staging column; CSV column not found: ",
        table_name, ".", column_name,
        call. = FALSE
      )
    }

    csv_col <- matching_cols[[1]]
    csv_col_data <- data.table::fread(
      csv_path,
      select = csv_col,
      showProgress = FALSE,
      na.strings = c("", "NULL")
    )

    value_len <- nchar(as.character(csv_col_data[[1]]), type = "chars", allowNA = TRUE, keepNA = FALSE)
    observed_max <- suppressWarnings(max(value_len, na.rm = TRUE))
    if (!is.finite(observed_max) || observed_max < 1) {
      observed_max <- min_length
    }

    target_len <- as.integer(max(current_len, observed_max, min_length))
    if (target_len <= current_len) {
      target_len <- as.integer(max(current_len, min_length))
    }

    alter_sql <- paste0(
      "ALTER TABLE [", synthea_schema, "].[", table_name,
      "] ALTER COLUMN [", column_name, "] VARCHAR(", target_len, ") NULL;"
    )
    execute_sql_with_retry(conn_widen, alter_sql)

    log_msg(
      "Widened staging column ", synthea_schema, ".", table_name, ".", column_name,
      " to VARCHAR(", target_len, ") based on CSV max length ", observed_max, ".",
      level = "WARN"
    )

    invisible(TRUE)
  }

  # relax_synthea_date_columns_for_loader() converts every date/datetime column
  # in the synthea staging schema to VARCHAR(32).  This is the reactive
  # complement to the pre-flight date-type conversion in
  # align_synthea_staging_schema_to_csvs().  It is called when an int/date
  # type-clash error is detected after the load has already started (e.g. when
  # the pre-flight ran before the staging tables were recreated in a different
  # connection).
  relax_synthea_date_columns_for_loader <- function() {
    log_msg(
      "Applying SQL Server staging mitigation: converting synthea date/datetime columns to varchar(32) for loader compatibility ...",
      level = "WARN"
    )

    conn_relax <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_relax), add = TRUE)

    discover_sql <- render_sql(
      "SELECT c.TABLE_NAME, c.COLUMN_NAME
       FROM INFORMATION_SCHEMA.COLUMNS c
       JOIN INFORMATION_SCHEMA.TABLES t
         ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
        AND c.TABLE_NAME = t.TABLE_NAME
       WHERE c.TABLE_SCHEMA = '@synthea_schema'
         AND t.TABLE_TYPE = 'BASE TABLE'
         AND c.DATA_TYPE IN ('date', 'datetime', 'datetime2', 'smalldatetime');",
      synthea_schema = synthea_schema
    )
    date_cols <- query_sql_with_retry(conn_relax, discover_sql)
    if (nrow(date_cols) == 0L) {
      return(invisible(FALSE))
    }

    for (k in seq_len(nrow(date_cols))) {
      table_name <- as.character(date_cols$TABLE_NAME[[k]])
      column_name <- as.character(date_cols$COLUMN_NAME[[k]])
      alter_sql <- render_sql(
        "ALTER TABLE @synthea_schema.@table_name
         ALTER COLUMN @column_name VARCHAR(32) NULL;",
        synthea_schema = synthea_schema,
        table_name = table_name,
        column_name = column_name
      )
      execute_sql_with_retry(conn_relax, alter_sql)
    }

    log_msg(
      "Mitigation complete: widened ", nrow(date_cols),
      " synthea date/datetime staging columns to varchar(32).",
      level = "WARN"
    )
    invisible(TRUE)
  }

  # ---------------------------------------------------------------------------
  # 12. Synthea CSV staging load
  # ---------------------------------------------------------------------------
  # load_synthea_tables() calls ETLSyntheaBuilder::LoadSyntheaTables which
  # iterates over every Synthea CSV file in csv_input_dir and inserts each
  # into its corresponding staging table in synthea_schema.
  #
  # bulkLoad=TRUE uses JDBC batched insert for speed (~10x faster).
  # bulkLoad=FALSE uses single-row inserts as a fallback for environments
  # where bulk operations are restricted.
  if (isTRUE(synthea_bulk_load)) {
    message("Loading Synthea staging with bulkLoad=TRUE")
  } else {
    message("Loading Synthea staging with bulkLoad=FALSE")
  }

  load_synthea_tables <- function(use_bulk_load) {
    run_step_with_retry("ETLSyntheaBuilder::LoadSyntheaTables", ETLSyntheaBuilder::LoadSyntheaTables(
      connectionDetails = connection_details,
      syntheaSchema = synthea_schema,
      syntheaFileLoc = csv_input_dir,
      bulkLoad = use_bulk_load
    ))
  }

  # load_synthea_tables_with_mitigations() is the retry orchestrator for the
  # staging load phase.  It calls load_synthea_tables() in a repeat loop and
  # applies targeted fixes when known SQL Server error classes are returned:
  #   - int/date type clash → relax_synthea_date_columns_for_loader() once.
  #   - varchar truncation  → widen_synthea_column_from_csv() for the exact
  #                           table+column reported.  Up to max_fix_attempts
  #                           fixes are applied before giving up.
  # Any other error is re-thrown immediately to avoid masking unexpected issues.
  load_synthea_tables_with_mitigations <- function(use_bulk_load, max_fix_attempts = 8L) {
    fix_attempts <- 0L
    int_date_fix_applied <- FALSE

    repeat {
      load_result <- tryCatch({
        load_synthea_tables(use_bulk_load)
        NULL
      }, error = function(e) {
        e
      })

      if (is.null(load_result)) {
        return(invisible(TRUE))
      }

      if (is_int_date_type_clash_error(load_result) && !isTRUE(int_date_fix_applied)) {
        warning(
          "Detected SQL Server int/date type clash during staging load. ",
          "Applying staging column mitigation and retrying with bulkLoad=FALSE."
        )
        relax_synthea_date_columns_for_loader()
        int_date_fix_applied <- TRUE
        fix_attempts <- fix_attempts + 1L
        next
      }

      trunc_info <- parse_truncation_error(load_result)
      if (!is.null(trunc_info) && fix_attempts < max_fix_attempts) {
        warning(
          "Detected SQL Server truncation in staging load at ",
          trunc_info$table_name, ".", trunc_info$column_name,
          ". Auto-widening column and retrying."
        )
        widen_synthea_column_from_csv(
          table_name = trunc_info$table_name,
          column_name = trunc_info$column_name
        )
        fix_attempts <- fix_attempts + 1L
        next
      }

      stop(load_result)
    }
  }

  if (isTRUE(synthea_bulk_load)) {
    loaded_with_bulk <- tryCatch({
      load_synthea_tables(TRUE)
      TRUE
    }, error = function(e) {
      warning(
        "Bulk Synthea staging load failed; retrying with bulkLoad=FALSE. Error: ",
        conditionMessage(e)
      )
      FALSE
    })

    if (!isTRUE(loaded_with_bulk)) {
      load_synthea_tables_with_mitigations(FALSE)
    }
  } else {
    load_synthea_tables_with_mitigations(FALSE)
  }
  progress$tick("Synthea CSV staging loaded")

  # ---------------------------------------------------------------------------
  # Truncate all CDM event tables before loading new data.
  # This runs unconditionally so every ETL execution produces a clean dataset
  # from the current Synthea CSV files, with no rows carried over from prior runs.
  # ---------------------------------------------------------------------------
  truncate_cdm_event_tables_sql_server()
  progress$tick("CDM event tables truncated")

  create_visit_rollup_tables_sql_server()
  progress$tick("Visit rollup tables materialized")
  
  # Create supporting indexes BEFORE load_event_tables_sql_server.
  #
  # 1. concept_ancestor indexes (on omop_vocab — the physical table):
  #    Support the drug_era ingredient mapping query and any cohort SQL that
  #    traverses the concept hierarchy.  IMPORTANT: the CDM schema exposes
  #    concept_ancestor via a SQL Server SYNONYM, not a real table, so
  #    OBJECT_ID(..., 'U') on the CDM schema always returns NULL.  Indexes
  #    must be created on the shared omop_vocab schema's physical table.
  # 2. concept_relationship covering index: support the source-to-standard
  #    vocab map build which joins concept_relationship on concept_id_1 and
  #    filters by relationship_id.  Without an index this is a 39M-row scan.
  # 3. condition_occurrence covering index: support the condition_era gap-and-
  #    island CTE which scans condition_occurrence twice (start + end events
  #    UNION ALL) partitioned by (person_id, condition_concept_id).
  message("[PERF] Creating pre-era indexes (omop_vocab concept_ancestor + concept_relationship + condition_occurrence)...")
  conn_indices_pre <- connect_with_retry(connection_details)
  on.exit(DatabaseConnector::disconnect(conn_indices_pre), add = TRUE)

  # concept_ancestor indexes — target the real table in omop_vocab, not the synonym.
  # vocab_schema is read from config (default: "omop_vocab").
  vocab_schema <- if (!is.null(config$vocab_schema) && nzchar(config$vocab_schema)) {
    config$vocab_schema
  } else {
    "omop_vocab"
  }

  index_sql_pre <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('@vocab_schema.concept_ancestor', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@vocab_schema.concept_ancestor')
             AND name = 'IX_concept_ancestor_ancestor'
         )
         BEGIN
           CREATE INDEX IX_concept_ancestor_ancestor
             ON @vocab_schema.concept_ancestor (ancestor_concept_id)
             INCLUDE (descendant_concept_id, min_levels_of_separation, max_levels_of_separation);
         END;

         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@vocab_schema.concept_ancestor')
             AND name = 'IX_concept_ancestor_descendant'
         )
         BEGIN
           CREATE INDEX IX_concept_ancestor_descendant
             ON @vocab_schema.concept_ancestor (descendant_concept_id)
             INCLUDE (ancestor_concept_id);
         END;
       END;",
      vocab_schema = vocab_schema
    ),
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, index_sql_pre)

  # concept_relationship covering index — supports the source-to-standard
  # vocab map CTE: WHERE cr.concept_id_1 = c.concept_id
  #                  AND cr.invalid_reason IS NULL
  #                  AND lower(cr.relationship_id) = 'maps to'
  cr_index_sql <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('@vocab_schema.concept_relationship', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@vocab_schema.concept_relationship')
             AND name = 'IX_concept_relationship_id1_rel'
         )
         BEGIN
           CREATE INDEX IX_concept_relationship_id1_rel
             ON @vocab_schema.concept_relationship (concept_id_1, relationship_id)
             INCLUDE (concept_id_2, invalid_reason);
         END;
       END;",
      vocab_schema = vocab_schema
    ),
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, cr_index_sql)

  # Covering index on concept(concept_id) INCLUDE (vocabulary_id, concept_class_id, ...):
  # The drug_era CTE joins concept_ancestor → concept on ancestor_concept_id = concept_id
  # then filters WHERE vocabulary_id='RxNorm' AND concept_class_id='Ingredient'.
  # Without INCLUDE columns the optimizer does a key lookup to the heap for every
  # matched row; with this covering index the filter resolves from the index leaf.
  concept_index_sql <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('@vocab_schema.concept', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@vocab_schema.concept')
             AND name = 'IX_concept_id_incl_vocab_class'
         )
         BEGIN
           CREATE INDEX IX_concept_id_incl_vocab_class
             ON @vocab_schema.concept (concept_id)
             INCLUDE (vocabulary_id, concept_class_id,
                      standard_concept, invalid_reason);
         END;
       END;",
      vocab_schema = vocab_schema
    ),
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, concept_index_sql)

  # Covering index on condition_occurrence for condition_era CTE performance.
  # The gap-and-island algorithm partitions by (person_id, condition_concept_id)
  # and orders by condition_start_date, so this index satisfies both scans
  # in the UNION ALL without touching the heap.
  co_index_sql <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('@cdm_schema.condition_occurrence', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@cdm_schema.condition_occurrence')
             AND name = 'IX_condition_occurrence_era'
         )
         BEGIN
           CREATE INDEX IX_condition_occurrence_era
             ON @cdm_schema.condition_occurrence
               (person_id, condition_concept_id, condition_start_date)
             INCLUDE (condition_occurrence_id, condition_end_date);
         END;
       END;",
      cdm_schema = config$cdm_schema
    ),
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, co_index_sql)

  # Index on drug_exposure(person_id, drug_concept_id, drug_exposure_start_date) to
  # support the drug_era CTE window functions (PARTITION BY person_id, ingredient_concept_id
  # ORDER BY drug_exposure_start_date). Without this index the era rollup does a full
  # table scan + tempdb sort over all 800K+ drug exposure rows, taking hours.
  de_index_sql <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('@cdm_schema.drug_exposure', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@cdm_schema.drug_exposure')
             AND name = 'IX_drug_exposure_era'
         )
         BEGIN
           CREATE INDEX IX_drug_exposure_era
             ON @cdm_schema.drug_exposure
               (person_id, drug_concept_id, drug_exposure_start_date)
             INCLUDE (drug_exposure_end_date, days_supply, drug_exposure_id);
         END;
       END;",
      cdm_schema = config$cdm_schema
    ),
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, de_index_sql)

  # Index on synthea.payer_transitions(patient) to speed up the payer_plan_period
  # join against synthea.patients and omop.person.
  ppt_index_sql <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('synthea.payer_transitions', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('synthea.payer_transitions')
             AND name = 'IX_payer_transitions_patient'
         )
         BEGIN
           CREATE INDEX IX_payer_transitions_patient
             ON synthea.payer_transitions (patient)
             INCLUDE (payer, start_date, end_date);
         END;
       END;",
      cdm_schema = config$cdm_schema
    ),
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, ppt_index_sql)

  # Index on synthea.payer_transitions(payer) supports the payer_plan_period
  # INSERT which starts FROM synthea.payers and joins payer_transitions on
  # pt.payer = pay.id.  The existing IX_payer_transitions_patient index covers
  # the reverse direction only; without this index SQL Server must scan all
  # ~91 K payer_transition rows once per payer (~10 scans).
  ppt_payer_index_sql <- SqlRender::translate(
    "IF OBJECT_ID('synthea.payer_transitions', 'U') IS NOT NULL
     BEGIN
       IF NOT EXISTS (
         SELECT 1 FROM sys.indexes
         WHERE object_id = OBJECT_ID('synthea.payer_transitions')
           AND name = 'IX_payer_transitions_payer'
       )
       BEGIN
         CREATE INDEX IX_payer_transitions_payer
           ON synthea.payer_transitions (payer)
           INCLUDE (patient, start_date, end_date);
       END;
     END;",
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, ppt_payer_index_sql)

  # Index on synthea.patients(id) covers the join
  # synthea.payer_transitions pt JOIN synthea.patients pat ON pt.patient = pat.id
  # in insert_payer_plan_period.sql.  synthea.patients is a heap by default;
  # without this index each payer_transition requires a full scan of 1 914 rows.
  patients_id_index_sql <- SqlRender::translate(
    "IF OBJECT_ID('synthea.patients', 'U') IS NOT NULL
     BEGIN
       IF NOT EXISTS (
         SELECT 1 FROM sys.indexes
         WHERE object_id = OBJECT_ID('synthea.patients')
           AND name = 'IX_patients_id'
       )
       BEGIN
         CREATE INDEX IX_patients_id
           ON synthea.patients (id);
       END;
     END;",
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, patients_id_index_sql)

  # Index on synthea.encounters(id) is used as a join key in multiple INSERT
  # files (insert_visit_occurrence, insert_cost_v300, etc.).
  encounters_id_index_sql <- SqlRender::translate(
    "IF OBJECT_ID('synthea.encounters', 'U') IS NOT NULL
     BEGIN
       IF NOT EXISTS (
         SELECT 1 FROM sys.indexes
         WHERE object_id = OBJECT_ID('synthea.encounters')
           AND name = 'IX_encounters_id'
       )
       BEGIN
         CREATE INDEX IX_encounters_id
           ON synthea.encounters (id)
           INCLUDE (patient, payer, provider, start);
       END;
     END;",
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, encounters_id_index_sql)

  # Index on synthea.claims(id) supports insert_cost_v300.sql which joins
  # synthea.claims_transactions ct ON ca.id = ct.claimid.  Without an index
  # on claims.id SQL Server must scan the 549 K claims table to locate each
  # matching claim row.
  claims_id_index_sql <- SqlRender::translate(
    "IF OBJECT_ID('synthea.claims', 'U') IS NOT NULL
     BEGIN
       IF NOT EXISTS (
         SELECT 1 FROM sys.indexes
         WHERE object_id = OBJECT_ID('synthea.claims')
           AND name = 'IX_claims_id'
       )
       BEGIN
         CREATE INDEX IX_claims_id
           ON synthea.claims (id)
           INCLUDE (patientid, appointmentid, providerid, primarypatientinsuranceid, servicedate, currentillnessdate, diagnosis1);
       END;
     END;",
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, claims_id_index_sql)

  # Index on synthea.claims_transactions(claimid) is the single most impactful
  # index for insert_cost_v300.sql: the condition branch joins
  #   synthea.claims ca JOIN synthea.claims_transactions ct ON ca.id = ct.claimid
  # across 4.6 M claims_transaction rows.  Without this index SQL Server builds
  # a 4.6 M-row hash table that spills to tempdb, causing hour-long runtimes.
  ct_claimid_index_sql <- SqlRender::translate(
    "IF OBJECT_ID('synthea.claims_transactions', 'U') IS NOT NULL
     BEGIN
       IF NOT EXISTS (
         SELECT 1 FROM sys.indexes
         WHERE object_id = OBJECT_ID('synthea.claims_transactions')
           AND name = 'IX_claims_transactions_claimid'
       )
       BEGIN
         CREATE INDEX IX_claims_transactions_claimid
           ON synthea.claims_transactions (claimid)
           INCLUDE (patientid, appointmentid, providerid, transfertype, amount);
       END;
     END;",
    targetDialect = config$dbms
  )
  execute_sql_with_retry(conn_indices_pre, ct_claimid_index_sql)

  message("[PERF] Pre-era indexes ready (vocab + CDM + synthea staging: payer_transitions, patients, encounters, claims, claims_transactions).")
  progress$tick("Pre-era indexes verified")
  
  load_event_tables_sql_server(progress)

  suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::CreateExtraIndices", ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connection_details,
    cdmSchema = config$cdm_schema,
    cdmVersion = cdm_version
  )), silent = TRUE))
  progress$tick("Extra CDM indices created")

  invisible(list(run_name = run_name, mode = "csv_builder"))
}
