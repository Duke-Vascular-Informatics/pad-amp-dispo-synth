# =============================================================================
# R/db_maintenance.R
# SQL Server database maintenance helpers for bulk ETL operations.
# =============================================================================

# -----------------------------------------------------------------------------
# prepare_txlog_for_bulk_etl
#
# Purpose:
#   Run a pre-flight transaction log check and preparation before a large bulk
#   ETL (e.g., vocabulary CSV load). Called automatically by Step 5 before
#   invoking run_synthea_full_csv_builder_etl().
#
# What it does:
#   1. Connects using the same JDBC credentials as the rest of Step 5.
#   2. Checks recovery mode — switches to SIMPLE if currently FULL, so that
#      SQL Server can checkpoint-truncate the log between bulk insert batches.
#   3. Issues CHECKPOINT + DBCC SHRINKFILE to reclaim space from prior runs.
#   4. Pre-grows the log to target_min_mb (default 25 GB) with generous
#      autogrowth increments so SQL Server never stalls mid-insert.
#   5. Prints a clear summary of before/after sizes.
#
# Arguments:
#   cfg            List returned by get_validation_config().
#   target_min_mb  Minimum log size in MB to ensure before ETL (default 25600).
#   autogrowth_mb  Autogrowth increment in MB to set (default 2048).
#   shrink_to_mb   Target size in MB for DBCC SHRINKFILE before pre-growing
#                  (default 1024). Frees space consumed by previous failed runs.
#
# Returns: invisibly TRUE on success; stops with an informative message on
#          any failure so Step 5 aborts cleanly before touching OMOP tables.
# -----------------------------------------------------------------------------
prepare_txlog_for_bulk_etl <- function(cfg,
                                       # REDUCED 2026-08-06 from 25600. A 25 GB pre-grow
                                       # exhausts mssql_dev's 79 GB volume: the data files
                                       # already hold ~24 GB (omop_vocab alone is 10.5 GB),
                                       # so pre-growing the log to 25 GB leaves nothing for
                                       # the CDM being loaded and the ETL dies at 99% full.
                                       # 8 GB is ample for a ~1.7k-patient Synthea load.
                                       target_min_mb = 8192L,
                                       autogrowth_mb = 2048L,
                                       shrink_to_mb  = 1024L) {

  cat("\n[txlog] ── Transaction log pre-flight check ──────────────────────────\n")
  cat("[txlog] Database:", cfg$database, "on", cfg$server, "\n")

  # ---------------------------------------------------------------------------
  # Build connection details (same pattern used throughout Step 5).
  # ---------------------------------------------------------------------------
  connection_details <- DatabaseConnector::createConnectionDetails(
    dbms     = cfg$dbms,
    server   = cfg$server,
    user     = cfg$user,
    password = cfg$password,
    pathToDriver = cfg$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", cfg$database,
      ";trustServerCertificate=true",
      ";portNumber=", cfg$sql_server_port
    )
  )

  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[txlog] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # ---------------------------------------------------------------------------
  # 1. Check and set recovery mode.
  # ---------------------------------------------------------------------------
  recovery_sql <- paste0(
    "SELECT recovery_model_desc FROM sys.databases WHERE name = '",
    gsub("'", "''", cfg$database), "';"
  )
  recovery_row <- DatabaseConnector::querySql(conn, recovery_sql)
  colnames(recovery_row) <- tolower(colnames(recovery_row))
  current_mode <- recovery_row$recovery_model_desc[[1]]

  if (tolower(current_mode) != "simple") {
    cat("[txlog] Recovery mode is", current_mode, "— switching to SIMPLE for bulk ETL\n")
    DatabaseConnector::executeSql(
      conn,
      paste0("ALTER DATABASE [", cfg$database, "] SET RECOVERY SIMPLE;")
    )
    cat("[txlog] \u2713 Recovery mode set to SIMPLE\n")
  } else {
    cat("[txlog] \u2713 Recovery mode already SIMPLE\n")
  }

  # ---------------------------------------------------------------------------
  # 2. Look up the log file logical name and current size.
  # ---------------------------------------------------------------------------
  logfile_sql <- paste0(
    "SELECT name, size * 8.0 / 1024 AS size_mb ",
    "FROM sys.master_files ",
    "WHERE database_id = DB_ID('", gsub("'", "''", cfg$database), "') ",
    "  AND type_desc = 'LOG';"
  )
  log_row <- DatabaseConnector::querySql(conn, logfile_sql)
  colnames(log_row) <- tolower(colnames(log_row))

  if (nrow(log_row) == 0L) {
    stop("[txlog] Could not locate transaction log file for database '",
         cfg$database, "'.", call. = FALSE)
  }

  log_name    <- log_row$name[[1]]
  size_before <- round(log_row$size_mb[[1]], 1)
  cat("[txlog] Log file: '", log_name, "' — current size: ", size_before, " MB\n", sep = "")

  # ---------------------------------------------------------------------------
  # 3. CHECKPOINT + DBCC SHRINKFILE to reclaim space from prior runs.
  # ---------------------------------------------------------------------------
  # Note: DBCC SHRINKFILE returns a result set, so querySql() must be used
  # instead of executeSql() to avoid a "result set generated for update" error.
  cat("[txlog] Running CHECKPOINT + DBCC SHRINKFILE to reclaim prior-run space ...\n")
  DatabaseConnector::executeSql(conn, "CHECKPOINT;")
  tryCatch(
    DatabaseConnector::querySql(
      conn,
      paste0("DBCC SHRINKFILE (", log_name, ", ", as.integer(shrink_to_mb), ");")
    ),
    error = function(e) {
      cat("[txlog] SHRINKFILE note (non-fatal):", conditionMessage(e), "\n")
    }
  )

  log_after_shrink <- DatabaseConnector::querySql(conn, logfile_sql)
  colnames(log_after_shrink) <- tolower(colnames(log_after_shrink))
  size_after_shrink <- round(log_after_shrink$size_mb[[1]], 1)
  cat("[txlog] \u2713 After shrink: ", size_after_shrink, " MB\n", sep = "")

  # ---------------------------------------------------------------------------
  # 4. Pre-grow log to target_min_mb if still below it, and set autogrowth.
  # ---------------------------------------------------------------------------
  if (size_after_shrink < target_min_mb) {
    cat("[txlog] Pre-growing log from ", size_after_shrink, " MB to ",
        target_min_mb, " MB ...\n", sep = "")
    DatabaseConnector::executeSql(
      conn,
      paste0(
        "ALTER DATABASE [", cfg$database, "] MODIFY FILE (",
        "NAME = N'", log_name, "', ",
        "SIZE = ", as.integer(target_min_mb), "MB, ",
        "FILEGROWTH = ", as.integer(autogrowth_mb), "MB);"
      )
    )
  } else {
    cat("[txlog] Log already >= ", target_min_mb, " MB — updating autogrowth only\n", sep = "")
    DatabaseConnector::executeSql(
      conn,
      paste0(
        "ALTER DATABASE [", cfg$database, "] MODIFY FILE (",
        "NAME = N'", log_name, "', ",
        "FILEGROWTH = ", as.integer(autogrowth_mb), "MB);"
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 5. Final size report.
  # ---------------------------------------------------------------------------
  log_final <- DatabaseConnector::querySql(conn, logfile_sql)
  colnames(log_final) <- tolower(colnames(log_final))
  size_final <- round(log_final$size_mb[[1]], 1)

  cat("[txlog] \u2713 Final log size : ", size_final, " MB\n", sep = "")
  cat("[txlog] \u2713 Autogrowth     : ", autogrowth_mb, " MB per increment\n", sep = "")
  cat("[txlog] \u2713 Ready for bulk ETL\n")
  cat("[txlog] ──────────────────────────────────────────────────────────────\n\n")

  # ---------------------------------------------------------------------------
  # 6. Pre-grow tempdb data files to prevent auto-growth stalls during era ETL.
  # ---------------------------------------------------------------------------
  # The drug_era and condition_era CTEs produce multi-million-row intermediate
  # result sets that spill to tempdb when they exceed the memory grant.  If
  # tempdb files are tiny (SQL Server default: 8 MB), each spill triggers
  # thousands of auto-growth events that stall the workload for hours.
  # Pre-growing data files to 2 GB each (with 512 MB increments) is safe:
  # tempdb is always recreated at instance restart, so the space is never
  # permanently wasted.
  prepare_tempdb_for_era_etl(cfg)

  invisible(TRUE)
}


# -----------------------------------------------------------------------------
# prepare_tempdb_for_era_etl
#
# Pre-grow tempdb data files to prevent auto-growth stalls during the era ETL
# CTEs (drug_era, condition_era) which spill large intermediate result sets.
#
# SQL Server recreates tempdb at every restart, so auto-growth events are not
# persisted and each run starts from the initial file sizes configured in
# sys.master_files.  This function ensures each data file is at least
# target_data_mb (default 2048 MB) with a generous autogrowth increment.
# -----------------------------------------------------------------------------
prepare_tempdb_for_era_etl <- function(cfg,
                                       target_data_mb   = 2048L,
                                       autogrowth_data_mb = 512L,
                                       target_log_mb    = 1024L) {

  cat("[tempdb] Pre-growing tempdb to suppress era-CTE auto-growth stalls...\n")

  connection_details <- DatabaseConnector::createConnectionDetails(
    dbms     = cfg$dbms,
    server   = cfg$server,
    user     = cfg$user,
    password = cfg$password,
    pathToDriver = cfg$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=master",           # ALTER DATABASE tempdb requires master context
      ";trustServerCertificate=true",
      ";portNumber=", cfg$sql_server_port
    )
  )

  conn_tempdb <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      cat("[tempdb] WARNING: could not connect to master to pre-grow tempdb: ",
          conditionMessage(e), "\n")
      return(NULL)
    }
  )
  if (is.null(conn_tempdb)) return(invisible(FALSE))
  on.exit(DatabaseConnector::disconnect(conn_tempdb), add = TRUE)

  # Retrieve all tempdb file names and current sizes.
  files_sql <- paste0(
    "SELECT name, type_desc, size * 8.0 / 1024 AS size_mb ",
    "FROM sys.master_files WHERE database_id = DB_ID('tempdb') ORDER BY type_desc, name;"
  )
  files_df <- tryCatch(
    DatabaseConnector::querySql(conn_tempdb, files_sql),
    error = function(e) {
      cat("[tempdb] WARNING: could not query tempdb files: ", conditionMessage(e), "\n")
      return(data.frame())
    }
  )
  if (nrow(files_df) == 0L) return(invisible(FALSE))
  colnames(files_df) <- tolower(colnames(files_df))

  for (i in seq_len(nrow(files_df))) {
    fname     <- files_df$name[[i]]
    ftype     <- files_df$type_desc[[i]]
    fsize_mb  <- round(files_df$size_mb[[i]], 1)
    target_mb <- if (tolower(ftype) == "rows") target_data_mb else target_log_mb
    grow_mb   <- if (tolower(ftype) == "rows") autogrowth_data_mb else 256L

    if (fsize_mb < target_mb) {
      cat("[tempdb]   Growing '", fname, "' from ", fsize_mb, " MB to ",
          target_mb, " MB ...\n", sep = "")
      tryCatch(
        DatabaseConnector::executeSql(
          conn_tempdb,
          paste0(
            "ALTER DATABASE tempdb MODIFY FILE (",
            "NAME = N'", fname, "', ",
            "SIZE = ", as.integer(target_mb), "MB, ",
            "FILEGROWTH = ", as.integer(grow_mb), "MB);"
          )
        ),
        error = function(e) {
          cat("[tempdb]   Note (non-fatal): ", conditionMessage(e), "\n")
        }
      )
    } else {
      cat("[tempdb]   '", fname, "': already ", fsize_mb, " MB \u2713\n", sep = "")
    }
  }

  cat("[tempdb] \u2713 tempdb pre-growth complete (era-CTE spills will not stall)\n")
  invisible(TRUE)
}


# -----------------------------------------------------------------------------
# create_vocab_synonyms
#
# Purpose:
#   Create SQL Server SYNONYM objects in a target CDM schema that point to
#   all 10 OMOP vocabulary tables in a shared vocabulary schema.  Synonyms
#   are transparent to all downstream SQL — queries against
#   target_schema.concept resolve through to shared_vocab_schema.concept
#   without any data being copied.
#
#   This eliminates the need to copy ~10 GB of vocabulary into every CDM
#   schema, and avoids the 25 GB transaction log hit of LoadVocabFromCsv on
#   each ETL run.
#
# Arguments:
#   cfg                List returned by get_validation_config().
#   target_schema      CDM schema to create synonyms in (e.g. "omop_synth_pad_oler_ssi_02").
#   shared_vocab_schema Schema containing the real vocabulary tables (default "omop_vocab").
#
# Returns: invisibly TRUE on success; stops with a message if shared vocab
#          schema is missing or unpopulated.
# -----------------------------------------------------------------------------
create_vocab_synonyms <- function(cfg, target_schema, shared_vocab_schema = "omop_vocab") {

  vocab_tables <- c(
    "vocabulary", "concept_class", "domain", "relationship",
    "concept", "concept_relationship", "concept_synonym",
    "concept_ancestor", "drug_strength", "source_to_concept_map"
  )

  cat("\n[vocab] ── Creating vocabulary synonyms ─────────────────────────────\n")
  cat("[vocab] Source schema :", shared_vocab_schema, "\n")
  cat("[vocab] Target schema :", target_schema, "\n")

  connection_details <- DatabaseConnector::createConnectionDetails(
    dbms     = cfg$dbms,
    server   = cfg$server,
    user     = cfg$user,
    password = cfg$password,
    pathToDriver = cfg$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", cfg$database,
      ";trustServerCertificate=true",
      ";portNumber=", cfg$sql_server_port
    )
  )

  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[vocab] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # Verify the shared vocabulary schema exists and is populated.
  check_sql <- paste0(
    "SELECT COUNT(*) AS n FROM sys.schemas WHERE name = '",
    gsub("'", "''", shared_vocab_schema), "';"
  )
  schema_check <- DatabaseConnector::querySql(conn, check_sql)
  colnames(schema_check) <- tolower(colnames(schema_check))
  if (as.integer(schema_check$n[[1]]) == 0L) {
    stop(
      "[vocab] Shared vocabulary schema '", shared_vocab_schema, "' does not exist. ",
      "Run Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template first to load vocabulary.",
      call. = FALSE
    )
  }

  # Verify concept table is populated in the shared schema.
  concept_check_sql <- paste0(
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM [", shared_vocab_schema, "].[concept]) ",
    "THEN 1 ELSE 0 END AS has_rows;"
  )
  concept_check <- tryCatch(
    DatabaseConnector::querySql(conn, concept_check_sql),
    error = function(e) stop(
      "[vocab] Could not query shared vocab schema '", shared_vocab_schema,
      "': ", conditionMessage(e), call. = FALSE
    )
  )
  colnames(concept_check) <- tolower(colnames(concept_check))
  if (as.integer(concept_check$has_rows[[1]]) == 0L) {
    stop(
      "[vocab] Shared vocabulary schema '", shared_vocab_schema,
      "' exists but concept table is empty. ",
      "Run Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template to load vocabulary.",
      call. = FALSE
    )
  }

  # Ensure target schema exists.
  DatabaseConnector::executeSql(
    conn,
    paste0(
      "IF SCHEMA_ID('", gsub("'", "''", target_schema), "') IS NULL ",
      "EXEC('CREATE SCHEMA [", target_schema, "]');"
    )
  )

  # Create synonyms for each vocabulary table (skip if already exists).
  created <- 0L
  skipped <- 0L
  for (tbl in vocab_tables) {
    exists_sql <- paste0(
      "SELECT COUNT(*) AS n FROM sys.synonyms s ",
      "JOIN sys.schemas sc ON s.schema_id = sc.schema_id ",
      "WHERE sc.name = '", gsub("'", "''", target_schema), "' ",
      "  AND s.name  = '", gsub("'", "''", tbl), "';"
    )
    exists_res <- DatabaseConnector::querySql(conn, exists_sql)
    colnames(exists_res) <- tolower(colnames(exists_res))

    if (as.integer(exists_res$n[[1]]) > 0L) {
      skipped <- skipped + 1L
      next
    }

    DatabaseConnector::executeSql(
      conn,
      paste0(
        "CREATE SYNONYM [", target_schema, "].[", tbl, "] ",
        "FOR [", shared_vocab_schema, "].[", tbl, "];"
      )
    )
    created <- created + 1L
  }

  cat("[vocab] \u2713 Synonyms created :", created, "\n")
  cat("[vocab] \u2713 Already existed  :", skipped, "\n")
  cat("[vocab] \u2713 All", length(vocab_tables),
      "vocabulary tables wired to", shared_vocab_schema, "\n")
  cat("[vocab] ──────────────────────────────────────────────────────────────\n\n")

  invisible(TRUE)
}


# =============================================================================
# SHARED ETL VOCABULARY MAPS
#
# ETLSyntheaBuilder materializes two large working tables into the CDM schema
# on every run:
#
#   source_to_standard_vocab_map   ~4.5M rows / ~1.6 GB
#   source_to_source_vocab_map     ~6.3M rows / ~2.3 GB
#
# Both are built by create_source_to_{standard,source}_vocab_map.sql, whose only
# inputs are @cdm_schema.CONCEPT, @cdm_schema.CONCEPT_RELATIONSHIP and
# @cdm_schema.source_to_concept_map. In this workspace all three are SYNONYMS
# into the shared omop_vocab schema (see create_vocab_synonyms above), so the
# output is a deterministic function of one shared input — every CDM schema was
# computing a byte-identical ~3.9 GB copy of the same thing.
#
# These helpers build the pair ONCE in a shared schema and wire each CDM schema
# to it with synonyms, exactly as create_vocab_synonyms does for vocabulary.
# Beyond the ~3.9 GB per dataset, this also removes the ~25 GB transaction-log
# spike of create_source_to_standard_vocab_map from every ETL run — that step
# has aborted full loads on this workspace's 80 GB VM disk more than once.
#
# STALENESS IS THE TRADE-OFF. Per-schema maps were rebuilt from current
# vocabulary on every ETL, so they could never go stale. A shared map can. Both
# helpers therefore key off the OMOP vocabulary release marker
# (vocabulary.vocabulary_version WHERE vocabulary_id = 'None') recorded in
# <shared_map_schema>.map_build_info, and rebuild automatically when it moves.
# =============================================================================

# Working tables shared across CDM schemas. states_map is deliberately NOT here:
# it is tiny and ETLSyntheaBuilder rewrites it per run, so sharing buys nothing.
.SHARED_VOCAB_MAP_TABLES <- c(
  "source_to_standard_vocab_map",
  "source_to_source_vocab_map"
)

# Version of the map-building logic in this file.
#
# WHY THIS EXISTS. omop_etl_maps is a single object shared by every repo on the
# instance, but the code that builds it is vendored into each repo's own copy of
# this file and those copies drift (measured 2026-08-07: the runner had drifted
# ~125 lines between the template and pad-amp-dispo-synth). Keying rebuilds on
# the vocabulary version alone is therefore not enough — two repos can hold
# different builder logic while the vocabulary sits still, and whichever runs
# first would silently impose its maps on the other.
#
# BUMP THIS whenever a change here alters the SHAPE or CONTENT of the maps:
# different columns, different indexes, a different template set, or different
# filtering. Do NOT bump for comments, logging, or refactors that leave the
# resulting tables byte-identical.
#
# Semantics, enforced in build_shared_vocab_maps():
#   recorded <  current  -> this repo is newer; rebuild and take ownership.
#   recorded == current  -> agree; reuse.
#   recorded >  current  -> this repo is OLDER than whoever built the maps.
#                           Refuse the shared path and fall back to per-schema
#                           maps rather than downgrade a shared object another
#                           repo depends on. Fix by syncing this repo.
.SHARED_VOCAB_MAP_BUILDER_VERSION <- 1L

# -----------------------------------------------------------------------------
# .db_maintenance_connection_details
#
# Purpose:
#   Build DatabaseConnector connection details from a get_validation_config()
#   list. Internal helper for the shared-map functions below so the JDBC
#   argument shape lives in one place.
#
# Arguments:
#   cfg  List returned by get_validation_config().
#
# Returns: a DatabaseConnector connectionDetails object.
# -----------------------------------------------------------------------------
.db_maintenance_connection_details <- function(cfg) {
  DatabaseConnector::createConnectionDetails(
    dbms         = cfg$dbms,
    server       = cfg$server,
    user         = cfg$user,
    password     = cfg$password,
    pathToDriver = cfg$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", cfg$database,
      ";trustServerCertificate=true",
      ";portNumber=", cfg$sql_server_port
    )
  )
}

# -----------------------------------------------------------------------------
# .shared_map_vocab_version
#
# Purpose:
#   Read the OMOP vocabulary release marker used as the shared maps' staleness
#   key. OMOP records the release string on the vocabulary row whose
#   vocabulary_id is 'None' (e.g. "v5.0 27-AUG-25").
#
# Arguments:
#   conn                 Open DatabaseConnector connection.
#   shared_vocab_schema  Schema holding the real vocabulary tables.
#
# Returns: the version string, or NA_character_ if the marker row is absent.
# -----------------------------------------------------------------------------
.shared_map_vocab_version <- function(conn, shared_vocab_schema) {
  res <- DatabaseConnector::querySql(
    conn,
    paste0(
      "SELECT TOP 1 vocabulary_version AS v FROM [",
      shared_vocab_schema, "].[vocabulary] WHERE vocabulary_id = 'None';"
    )
  )
  colnames(res) <- tolower(colnames(res))
  if (nrow(res) == 0L || is.na(res$v[[1]])) {
    return(NA_character_)
  }
  as.character(res$v[[1]])
}

# -----------------------------------------------------------------------------
# .shared_map_object_count
#
# Purpose:
#   Count catalog objects of one type by schema + name. Used by both functions
#   below to distinguish "real table" from "synonym" from "absent", which is the
#   distinction the whole synonym approach turns on.
#
# Arguments:
#   conn         Open DatabaseConnector connection.
#   catalog_view Either "sys.tables" or "sys.synonyms".
#   schema_name  Schema to look in.
#   object_name  Object to look for.
#
# Returns: integer count (0 or 1 in practice).
# -----------------------------------------------------------------------------
.shared_map_object_count <- function(conn, catalog_view, schema_name, object_name) {
  as.integer(DatabaseConnector::querySql(conn, paste0(
    "SELECT COUNT(*) AS n FROM ", catalog_view, " o ",
    "JOIN sys.schemas s ON s.schema_id = o.schema_id ",
    "WHERE s.name = '", gsub("'", "''", schema_name), "' ",
    "  AND o.name = '", gsub("'", "''", object_name), "';"
  ))[[1]])
}

# -----------------------------------------------------------------------------
# build_shared_vocab_maps
#
# Purpose:
#   Materialize source_to_standard_vocab_map and source_to_source_vocab_map
#   once into a shared schema, with the composite covering indexes the 19 domain
#   INSERT SQLs need, and stamp the vocabulary version they were built from.
#
#   Idempotent: on a second call with unchanged vocabulary it verifies and
#   returns without rebuilding. When the vocabulary release marker has moved (or
#   force = TRUE) it rebuilds both tables from scratch.
#
# How the SQL is obtained:
#   The same ETLSyntheaBuilder templates the ETL itself uses, rendered with
#   cdm_schema = shared_map_schema. That schema is given its own vocabulary
#   synonyms first, so the templates' reads of @cdm_schema.CONCEPT and friends
#   resolve into shared_vocab_schema while their writes land in the shared map
#   schema. No template is copied or forked.
#
# Arguments:
#   cfg                  List returned by get_validation_config().
#   shared_map_schema    Schema to hold the shared maps (default "omop_etl_maps").
#   shared_vocab_schema  Schema holding the real vocabulary (default "omop_vocab").
#   cdm_version          OMOP CDM version selecting the SQL template set;
#                        "5.3" or "5.4" (default "5.4").
#   force                Rebuild even when the recorded vocabulary version
#                        matches (default FALSE).
#
# Returns: invisibly list(rebuilt, usable, vocab_version).
#   usable = FALSE means the shared maps exist but were built by a NEWER
#   builder version than this repo carries, so this repo must not use or
#   rebuild them — the caller should fall back to per-schema maps. Every other
#   outcome returns usable = TRUE.
#
# Side effects: creates shared_map_schema, its vocabulary synonyms, the two map
#   tables, two composite indexes, and the map_build_info stamp table.
#
# NOTE ON COST: a rebuild is the expensive operation the per-schema design paid
#   on every ETL — expect several minutes and a large transaction-log burst. It
#   should happen once per vocabulary release, not once per dataset.
# -----------------------------------------------------------------------------
build_shared_vocab_maps <- function(cfg,
                                    shared_map_schema   = "omop_etl_maps",
                                    shared_vocab_schema = "omop_vocab",
                                    cdm_version         = "5.4",
                                    force               = FALSE) {

  # Mirrors ETLSyntheaBuilder::CreateVocabMapTables' own version switch so the
  # shared build always uses the same templates the per-schema build would have.
  sql_file_path <- if (identical(cdm_version, "5.3")) {
    "cdm_version/v531"
  } else if (identical(cdm_version, "5.4")) {
    "cdm_version/v540"
  } else {
    stop("[maps] Unsupported cdm_version '", cdm_version,
         "'. ETLSyntheaBuilder supports \"5.3\" and \"5.4\".", call. = FALSE)
  }

  cat("\n[maps] ── Shared ETL vocabulary maps ───────────────────\n")
  cat("[maps] Map schema   :", shared_map_schema, "\n")
  cat("[maps] Vocab schema :", shared_vocab_schema, "\n")

  # Give the shared map schema its own vocabulary synonyms. This both creates
  # the schema and makes the ETLSyntheaBuilder templates resolvable there, and
  # re-uses that function's existing "shared vocab present and populated" checks.
  create_vocab_synonyms(cfg, shared_map_schema, shared_vocab_schema)

  connection_details <- .db_maintenance_connection_details(cfg)
  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[maps] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  vocab_version <- .shared_map_vocab_version(conn, shared_vocab_schema)
  cat("[maps] Vocab version:", ifelse(is.na(vocab_version), "<unknown>", vocab_version), "\n")

  # ---------------------------------------------------------------------------
  # Decide whether a rebuild is needed.
  #
  # Rebuild when any of: the stamp table is missing, either map table is
  # missing, the recorded vocabulary version differs from the live one, the
  # recorded builder version is older than this file's, or force = TRUE.
  # An unknown live version (NA) is treated as "cannot prove fresh" and forces a
  # rebuild rather than silently trusting a possibly stale map.
  #
  # The one case that is NOT a rebuild is a recorded builder version NEWER than
  # this file's — see .SHARED_VOCAB_MAP_BUILDER_VERSION. Rebuilding there would
  # downgrade a shared object another repo is relying on, so the caller is told
  # the shared path is unusable and falls back to per-schema maps instead.
  # ---------------------------------------------------------------------------
  stamp_exists <- .shared_map_object_count(
    conn, "sys.tables", shared_map_schema, "map_build_info") > 0L

  maps_present <- vapply(.SHARED_VOCAB_MAP_TABLES, function(tbl) {
    .shared_map_object_count(conn, "sys.tables", shared_map_schema, tbl) > 0L
  }, logical(1))

  recorded_version <- NA_character_
  recorded_builder <- NA_integer_
  if (stamp_exists) {
    # builder_version was added after the first release of this helper, so a
    # stamp table written by the earlier version will not have the column.
    # Probe for it rather than letting the SELECT fail; a missing column reads
    # as NA, which forces a rebuild below and re-creates the table with it.
    has_builder_col <- as.integer(DatabaseConnector::querySql(conn, paste0(
      "SELECT COUNT(*) AS n FROM sys.columns ",
      "WHERE object_id = OBJECT_ID('", shared_map_schema, ".map_build_info') ",
      "  AND name = 'builder_version';"
    ))[[1]]) > 0L

    rec <- DatabaseConnector::querySql(conn, paste0(
      "SELECT TOP 1 vocab_version AS v, ",
      if (has_builder_col) "builder_version AS b " else "CAST(NULL AS INT) AS b ",
      "FROM [", shared_map_schema, "].[map_build_info] ORDER BY built_at DESC;"
    ))
    colnames(rec) <- tolower(colnames(rec))
    if (nrow(rec) > 0L) {
      recorded_version <- as.character(rec$v[[1]])
      if (!is.na(rec$b[[1]])) recorded_builder <- as.integer(rec$b[[1]])
    }
  }

  # Someone else built these maps with newer logic than this repo carries.
  # Do not touch them; tell the caller to use per-schema maps for this run.
  if (!is.na(recorded_builder) &&
      recorded_builder > .SHARED_VOCAB_MAP_BUILDER_VERSION) {
    warning("[maps] '", shared_map_schema, "' was built by builder version ",
            recorded_builder, " but this repo carries version ",
            .SHARED_VOCAB_MAP_BUILDER_VERSION,
            ". Refusing to downgrade a shared object. Sync this repo ",
            "(/sync-template) to use the shared maps; falling back to ",
            "per-schema maps for now.", call. = FALSE)
    cat("[maps] ──────────────────────────────────────────────\n\n")
    return(invisible(list(rebuilt = FALSE, usable = FALSE,
                          vocab_version = vocab_version)))
  }

  needs_rebuild <- isTRUE(force) ||
    !stamp_exists ||
    !all(maps_present) ||
    is.na(vocab_version) ||
    is.na(recorded_version) ||
    !identical(recorded_version, vocab_version) ||
    is.na(recorded_builder) ||
    recorded_builder < .SHARED_VOCAB_MAP_BUILDER_VERSION

  if (!needs_rebuild) {
    cat("[maps] ✓ Shared maps are current for this vocabulary — nothing to do.\n")
    cat("[maps] ──────────────────────────────────────────────\n\n")
    return(invisible(list(rebuilt = FALSE, usable = TRUE,
                          vocab_version = vocab_version)))
  }

  if (stamp_exists && !identical(recorded_version, vocab_version)) {
    cat("[maps] ! Vocabulary changed since last build (was '",
        ifelse(is.na(recorded_version), "<none>", recorded_version),
        "') — rebuilding.\n", sep = "")
  }
  if (stamp_exists && identical(recorded_version, vocab_version) &&
      (is.na(recorded_builder) ||
       recorded_builder < .SHARED_VOCAB_MAP_BUILDER_VERSION)) {
    cat("[maps] ! Builder logic changed since last build (was ",
        ifelse(is.na(recorded_builder), "<unversioned>", recorded_builder),
        ", now ", .SHARED_VOCAB_MAP_BUILDER_VERSION, ") — rebuilding.\n", sep = "")
  }

  # ---------------------------------------------------------------------------
  # Rebuild. The templates open with their own
  # "if object_id(...) is not null drop table", so this explicit drop is only
  # belt-and-braces for a previous partial run.
  # ---------------------------------------------------------------------------
  for (tbl in .SHARED_VOCAB_MAP_TABLES) {
    DatabaseConnector::executeSql(
      conn,
      paste0("IF OBJECT_ID('", shared_map_schema, ".", tbl,
             "', 'U') IS NOT NULL DROP TABLE [", shared_map_schema, "].[", tbl, "];"),
      progressBar = FALSE, reportOverallTime = FALSE
    )
  }

  for (query in paste0("create_", .SHARED_VOCAB_MAP_TABLES, ".sql")) {
    cat("[maps] Building ", query, " (this is the slow step) ...\n", sep = "")
    translated_sql <- SqlRender::loadRenderTranslateSql(
      sqlFilename = paste0(sql_file_path, "/", query),
      packageName = "ETLSyntheaBuilder",
      dbms        = cfg$dbms,
      cdm_schema  = shared_map_schema
    )
    DatabaseConnector::executeSql(conn, translated_sql,
                                  progressBar = FALSE, reportOverallTime = FALSE)
  }

  # ---------------------------------------------------------------------------
  # Composite covering indexes.
  #
  # These were previously created per CDM schema by the ETL runner. They must
  # live on the real tables here, because a synonym cannot carry an index — a
  # CDM schema pointing at these maps uses the base table's indexes directly.
  # Each domain INSERT filters on (source_code, source_vocabulary_id,
  # target_domain_id / target_vocabulary_id), so these turn full-table scans
  # plus hash joins into index seeks.
  # ---------------------------------------------------------------------------
  cat("[maps] Adding composite covering indexes ...\n")
  DatabaseConnector::executeSql(conn, SqlRender::translate(SqlRender::render(
    "IF NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE object_id = OBJECT_ID('@map_schema.source_to_standard_vocab_map')
                      AND name = 'IX_stdvm_code_vocab_domain')
     BEGIN
       CREATE INDEX IX_stdvm_code_vocab_domain
         ON @map_schema.source_to_standard_vocab_map
           (source_code, source_vocabulary_id, target_domain_id)
         INCLUDE (target_concept_id, target_vocabulary_id,
                  target_standard_concept, target_invalid_reason,
                  source_concept_id);
     END;",
    map_schema = shared_map_schema), targetDialect = cfg$dbms),
    progressBar = FALSE, reportOverallTime = FALSE)

  DatabaseConnector::executeSql(conn, SqlRender::translate(SqlRender::render(
    "IF NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE object_id = OBJECT_ID('@map_schema.source_to_source_vocab_map')
                      AND name = 'IX_srcvm_code_vocab')
     BEGIN
       CREATE INDEX IX_srcvm_code_vocab
         ON @map_schema.source_to_source_vocab_map
           (source_code, source_vocabulary_id)
         INCLUDE (source_concept_id, source_domain_id,
                  target_concept_id, target_vocabulary_id);
     END;",
    map_schema = shared_map_schema), targetDialect = cfg$dbms),
    progressBar = FALSE, reportOverallTime = FALSE)

  # ---------------------------------------------------------------------------
  # Stamp the build so the next caller can prove freshness without rebuilding.
  # ---------------------------------------------------------------------------
  # Dropped and recreated rather than created-if-missing, so a stamp table
  # written by an earlier helper version (no builder_version column) is
  # migrated in place instead of needing an ALTER path. It holds exactly one
  # row, so there is nothing to preserve.
  DatabaseConnector::executeSql(conn, paste0(
    "IF OBJECT_ID('", shared_map_schema, ".map_build_info', 'U') IS NOT NULL ",
    "DROP TABLE [", shared_map_schema, "].[map_build_info];"
  ), progressBar = FALSE, reportOverallTime = FALSE)

  DatabaseConnector::executeSql(conn, paste0(
    "CREATE TABLE [", shared_map_schema, "].[map_build_info] (",
    "  vocab_version   VARCHAR(255) NULL,",
    "  builder_version INT          NULL,",
    "  built_at        DATETIME2    NOT NULL,",
    "  cdm_version     VARCHAR(10)  NULL,",
    "  s2std_row_count BIGINT       NULL,",
    "  s2src_row_count BIGINT       NULL);"
  ), progressBar = FALSE, reportOverallTime = FALSE)

  DatabaseConnector::executeSql(conn, paste0(
    "INSERT INTO [", shared_map_schema, "].[map_build_info] ",
    "(vocab_version, builder_version, built_at, cdm_version, ",
    " s2std_row_count, s2src_row_count) ",
    "SELECT ",
    ifelse(is.na(vocab_version), "NULL",
           paste0("'", gsub("'", "''", vocab_version), "'")), ", ",
    as.integer(.SHARED_VOCAB_MAP_BUILDER_VERSION), ", ",
    "SYSUTCDATETIME(), '", gsub("'", "''", cdm_version), "', ",
    "(SELECT COUNT_BIG(*) FROM [", shared_map_schema, "].[source_to_standard_vocab_map]), ",
    "(SELECT COUNT_BIG(*) FROM [", shared_map_schema, "].[source_to_source_vocab_map]);"
  ), progressBar = FALSE, reportOverallTime = FALSE)

  counts <- DatabaseConnector::querySql(conn, paste0(
    "SELECT s2std_row_count AS a, s2src_row_count AS b FROM [",
    shared_map_schema, "].[map_build_info];"
  ))
  colnames(counts) <- tolower(colnames(counts))
  cat("[maps] ✓ source_to_standard_vocab_map rows:",
      format(counts$a[[1]], big.mark = ","), "\n")
  cat("[maps] ✓ source_to_source_vocab_map   rows:",
      format(counts$b[[1]], big.mark = ","), "\n")
  cat("[maps] ✓ Shared maps built and stamped (builder v",
      .SHARED_VOCAB_MAP_BUILDER_VERSION, ").\n", sep = "")
  cat("[maps] ──────────────────────────────────────────────\n\n")

  invisible(list(rebuilt = TRUE, usable = TRUE, vocab_version = vocab_version))
}

# -----------------------------------------------------------------------------
# create_vocab_map_synonyms
#
# Purpose:
#   Point a CDM schema's source_to_standard_vocab_map / source_to_source_vocab_map
#   at the shared copies built by build_shared_vocab_maps(), so the ETL's 19
#   domain INSERT SQLs resolve through synonyms with no change to their text.
#
# Why this is transparent to the rest of the ETL (verified against this
# workspace's SQL Server before the change was written):
#   - A JOIN through a synonym behaves identically to one against the base
#     table, and uses the base table's indexes.
#   - OBJECT_ID('<schema>.<name>', 'U') returns NULL for a synonym, so the
#     runner's existing IF-guarded TRUNCATE and CREATE INDEX blocks skip
#     themselves automatically — they need no edit.
#   - TRUNCATE TABLE through a synonym is rejected by SQL Server, so the shared
#     tables cannot be emptied by an unguarded caller.
#   - SELECT * INTO a synonym's name is also rejected, so if the map-creation
#     SQL is ever run against a wired schema by mistake it fails loudly instead
#     of silently forking a private copy.
#
# Arguments:
#   cfg                     List returned by get_validation_config().
#   target_schema           CDM schema to wire.
#   shared_map_schema       Schema holding the shared maps (default "omop_etl_maps").
#   replace_existing_tables When TRUE, drop a real (non-synonym) map table found
#                           in target_schema so the synonym can be created.
#                           Default FALSE. The ETL runner passes TRUE because
#                           the map-creation SQL it replaces opened with its own
#                           unconditional DROP TABLE of the same object, making
#                           it behaviour-preserving there. Left FALSE for
#                           interactive use, where dropping a table the operator
#                           did not expect would be surprising.
#
# Returns: invisibly TRUE when both synonyms are in place; FALSE when one or
#          more could not be wired (a warning explains which and why).
# -----------------------------------------------------------------------------
create_vocab_map_synonyms <- function(cfg,
                                      target_schema,
                                      shared_map_schema       = "omop_etl_maps",
                                      replace_existing_tables = FALSE) {

  cat("[maps] Wiring", target_schema, "->", shared_map_schema, "\n")

  connection_details <- .db_maintenance_connection_details(cfg)
  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[maps] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # Refuse to wire a schema that carries its own source-to-concept mappings.
  # The shared maps fold source_to_concept_map into their output, so a schema
  # with custom STCM rows would silently inherit the wrong mappings. In this
  # workspace STCM is itself a synonym into the shared vocabulary and is empty,
  # so this guard is normally a no-op — it exists so a future study that starts
  # using custom mappings opts out automatically instead of getting bad data.
  if (.shared_map_object_count(conn, "sys.tables", target_schema,
                               "source_to_concept_map") > 0L) {
    stcm_rows <- as.integer(DatabaseConnector::querySql(conn, paste0(
      "SELECT COUNT(*) AS n FROM [", target_schema, "].[source_to_concept_map];"
    ))[[1]])
    if (stcm_rows > 0L) {
      warning("[maps] '", target_schema, "' has ", stcm_rows,
              " custom source_to_concept_map rows, which the shared maps do not ",
              "include. Leaving this schema on per-schema maps.", call. = FALSE)
      return(invisible(FALSE))
    }
  }

  all_wired <- TRUE
  for (tbl in .SHARED_VOCAB_MAP_TABLES) {

    # Already a synonym here? Nothing to do.
    if (.shared_map_object_count(conn, "sys.synonyms", target_schema, tbl) > 0L) {
      next
    }

    # A real table of the same name blocks the synonym.
    if (.shared_map_object_count(conn, "sys.tables", target_schema, tbl) > 0L) {
      if (!isTRUE(replace_existing_tables)) {
        warning("[maps] '", target_schema, ".", tbl, "' is a real table; not wired. ",
                "Drop it (synthetic_data/scripts/reclaim_etl_scratch.R --apply) or ",
                "call with replace_existing_tables = TRUE.", call. = FALSE)
        all_wired <- FALSE
        next
      }
      DatabaseConnector::executeSql(
        conn,
        paste0("DROP TABLE [", target_schema, "].[", tbl, "];"),
        progressBar = FALSE, reportOverallTime = FALSE
      )
    }

    DatabaseConnector::executeSql(
      conn,
      paste0("CREATE SYNONYM [", target_schema, "].[", tbl, "] ",
             "FOR [", shared_map_schema, "].[", tbl, "];"),
      progressBar = FALSE, reportOverallTime = FALSE
    )
  }

  if (all_wired) {
    cat("[maps] ✓", target_schema, "uses the shared vocabulary maps.\n")
  }
  invisible(all_wired)
}

# -----------------------------------------------------------------------------
# remove_vocab_map_synonyms
#
# Purpose:
#   Un-wire a CDM schema from the shared vocab maps by dropping the two
#   synonyms, so the per-schema map SQL can build real tables there again.
#
# Why this is needed:
#   The properties that make the shared path safe also make the fallback path
#   fail without this. SELECT * INTO is rejected against a synonym name, so a
#   run that decides mid-flight to fall back to per-schema maps — because the
#   shared maps were built by a newer builder version, or because this schema
#   turned out to carry custom source_to_concept_map rows — would hit that
#   error on a schema wired by an EARLIER run. Dropping the synonyms first
#   turns a hard failure into a clean, if more expensive, per-schema build.
#
#   Only synonyms are dropped. If the object is a real table this is a no-op:
#   that table is the per-schema map already, and it is the fallback's target.
#
# Arguments:
#   cfg            List returned by get_validation_config().
#   target_schema  CDM schema to un-wire.
#
# Returns: invisibly the number of synonyms dropped.
# -----------------------------------------------------------------------------
remove_vocab_map_synonyms <- function(cfg, target_schema) {

  connection_details <- .db_maintenance_connection_details(cfg)
  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[maps] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  dropped <- 0L
  for (tbl in .SHARED_VOCAB_MAP_TABLES) {
    if (.shared_map_object_count(conn, "sys.synonyms", target_schema, tbl) > 0L) {
      DatabaseConnector::executeSql(
        conn,
        paste0("DROP SYNONYM [", target_schema, "].[", tbl, "];"),
        progressBar = FALSE, reportOverallTime = FALSE
      )
      dropped <- dropped + 1L
    }
  }

  if (dropped > 0L) {
    cat("[maps] Un-wired", target_schema, "from the shared maps (",
        dropped, "synonyms dropped ) — per-schema maps will be rebuilt.\n")
  }
  invisible(dropped)
}
