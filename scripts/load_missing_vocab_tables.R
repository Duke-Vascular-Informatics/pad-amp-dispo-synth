#!/usr/bin/env Rscript
# =============================================================================
# scripts/load_missing_vocab_tables.R
#
# One-shot recovery script: loads only the omop_vocab tables that currently
# have 0 rows, skipping any table that already has data.
#
# Handles OMOP vocab CSVs where date columns are stored as YYYYMMDD integers
# (e.g. 20000101) but SQL Server schema columns are DATE type.
#
# Usage:
#   Rscript scripts/load_missing_vocab_tables.R
# =============================================================================

vocab_schema    <- "omop_vocab"
vocab_delimiter <- "\t"
vocab_file_loc  <- Sys.getenv("OHDSI_VOCAB_CSV_DIR", unset = "/omop_vocab")
chunk_rows      <- 250000L       # rows per INSERT batch

if (!file.exists("renv/activate.R")) {
  stop("Run from the project root directory. Current: ", getwd(), call. = FALSE)
}
source("renv/activate.R")
if (requireNamespace("renv", quietly = TRUE)) renv::load(project = getwd())

source("config.R")
source("R/drivers.R")
source("R/connection.R")

cfg                <- get_validation_config()
ensure_jdbc_bundle(cfg)
conn_details       <- build_connection_details(cfg)

# ---------------------------------------------------------------------------
# Known date columns per OMOP vocab table (stored as YYYYMMDD integers in CSV)
# ---------------------------------------------------------------------------
date_cols_map <- list(
  concept              = c("valid_start_date", "valid_end_date"),
  concept_relationship = c("valid_start_date", "valid_end_date"),
  drug_strength        = c("valid_start_date", "valid_end_date"),
  concept_ancestor     = character(0),
  concept_class        = character(0),
  concept_synonym      = character(0),
  domain               = character(0),
  relationship         = c("valid_start_date", "valid_end_date"),
  vocabulary           = c("vocabulary_concept_id")   # not a date, just a flag
)
# Only the above are truly date columns:
date_cols_map$vocabulary <- character(0)
date_cols_map$relationship <- character(0)   # relationship table has no date cols

# Final authoritative date-column list:
date_cols_by_table <- list(
  concept              = c("valid_start_date", "valid_end_date"),
  concept_relationship = c("valid_start_date", "valid_end_date"),
  drug_strength        = c("valid_start_date", "valid_end_date"),
  concept_ancestor     = character(0),
  concept_class        = character(0),
  concept_synonym      = character(0),
  domain               = character(0),
  relationship         = character(0),
  vocabulary           = character(0)
)

# NOT NULL string columns per table — replace NA with "" to satisfy constraints
# NOTE: invalid_reason and standard_concept are NULLABLE in OMOP CDM — do NOT
# include them here. NA in those columns must stay as SQL NULL.
not_null_str_cols <- list(
  concept              = c("concept_name", "domain_id", "vocabulary_id",
                           "concept_class_id", "concept_code"),
  concept_relationship = c("relationship_id"),
  concept_synonym      = c("concept_synonym_name", "language_concept_id"),
  drug_strength        = character(0),
  domain               = c("domain_name", "domain_concept_id"),
  relationship         = c("relationship_name", "is_hierarchical",
                           "defines_ancestry", "invalid_reason"),
  vocabulary           = c("vocabulary_name", "vocabulary_reference",
                           "vocabulary_version")
)

parse_omop_dates <- function(df, tbl_name) {
  # 1. Convert YYYYMMDD integer date columns to Date
  date_cols <- date_cols_by_table[[tbl_name]]
  for (col in date_cols) {
    if (col %in% colnames(df)) {
      df[[col]] <- as.Date(as.character(df[[col]]), format = "%Y%m%d")
    }
  }
  # 2. Replace NA in NOT NULL string columns with empty string
  nn_cols <- not_null_str_cols[[tbl_name]]
  if (!is.null(nn_cols)) {
    for (col in nn_cols) {
      if (col %in% colnames(df) && is.character(df[[col]])) {
        df[[col]][is.na(df[[col]])] <- ""
      }
    }
  }
  df
}

# Map: CSV filename → target table name in omop_vocab
vocab_file_map <- list(
  "CONCEPT.csv"              = "concept",
  "CONCEPT_ANCESTOR.csv"     = "concept_ancestor",
  "CONCEPT_CLASS.csv"        = "concept_class",
  "CONCEPT_RELATIONSHIP.csv" = "concept_relationship",
  "CONCEPT_SYNONYM.csv"      = "concept_synonym",
  "DOMAIN.csv"               = "domain",
  "DRUG_STRENGTH.csv"        = "drug_strength",
  "RELATIONSHIP.csv"         = "relationship",
  "VOCABULARY.csv"           = "vocabulary"
)

cat("\n=== Targeted Vocab Table Loader ===\n")
cat("Schema      :", vocab_schema, "\n")
cat("Vocab dir   :", vocab_file_loc, "\n\n")

conn <- DatabaseConnector::connect(conn_details)

# Check which tables currently have 0 rows
missing_tables <- character(0)
for (csv_file in names(vocab_file_map)) {
  tbl <- vocab_file_map[[csv_file]]
  cnt <- tryCatch({
    r <- DatabaseConnector::querySql(
      conn,
      paste0("SELECT COUNT(*) AS n FROM [", vocab_schema, "].[", tbl, "]")
    )
    as.integer(r[[1]])
  }, error = function(e) -1L)

  if (cnt == 0L) {
    csv_path <- file.path(vocab_file_loc, csv_file)
    if (file.exists(csv_path)) {
      missing_tables <- c(missing_tables, csv_file)
      cat("[MISSING]", tbl, "(0 rows) — will load from", csv_file, "\n")
    } else {
      cat("[SKIP]", tbl, "— CSV not found:", csv_path, "\n")
    }
  } else if (cnt < 0L) {
    cat("[ERROR]  Cannot query", tbl, "— check schema\n")
  } else {
    cat("[OK]    ", tbl, "already has", format(cnt, big.mark = ","), "rows — skipping\n")
  }
}

DatabaseConnector::disconnect(conn)

if (length(missing_tables) == 0L) {
  cat("\nAll vocab tables already populated — nothing to do.\n")
  quit(save = "no", status = 0)
}

cat("\nLoading", length(missing_tables), "missing table(s)...\n\n")

if (!requireNamespace("data.table", quietly = TRUE)) {
  install.packages("data.table", repos = "https://cloud.r-project.org")
}

for (csv_file in missing_tables) {
  tbl      <- vocab_file_map[[csv_file]]
  csv_path <- file.path(vocab_file_loc, csv_file)
  file_mb  <- round(file.info(csv_path)$size / 1e6, 1)

  cat("[LOAD]", tbl, "(", file_mb, "MB) from", csv_file, "...\n")
  start_t <- proc.time()

  conn_load <- DatabaseConnector::connect(conn_details)

  tryCatch({
    # Read column names from header row only first
    header_df <- data.table::fread(
      csv_path, sep = vocab_delimiter, quote = "",
      nrows = 0L, header = TRUE,
      stringsAsFactors = FALSE, data.table = FALSE
    )
    col_names <- tolower(colnames(header_df))

    if (file_mb > 100) {
      cat("  Chunked read (", chunk_rows, "rows/batch)\n", sep = "")
      total_rows <- 0L
      chunk_num  <- 0L

      repeat {
        chunk_num  <- chunk_num + 1L
        skip_lines <- 1L + (chunk_num - 1L) * chunk_rows  # +1 for header

        chunk <- tryCatch(
          data.table::fread(
            csv_path, sep = vocab_delimiter, quote = "",
            nrows = chunk_rows, skip = skip_lines,
            header = FALSE, col.names = col_names,
            stringsAsFactors = FALSE, data.table = FALSE,
            na.strings = c("", "NA")
          ),
          error = function(e) {
            cat("  fread error at chunk", chunk_num, ":", conditionMessage(e), "\n")
            data.frame()
          }
        )

        if (nrow(chunk) == 0L) break

        chunk <- parse_omop_dates(chunk, tbl)

        DatabaseConnector::insertTable(
          connection        = conn_load,
          tableName         = paste0(vocab_schema, ".", tbl),
          data              = chunk,
          dropTableIfExists = FALSE,
          createTable       = FALSE,
          tempTable         = FALSE
        )

        total_rows <- total_rows + nrow(chunk)
        elapsed_m  <- (proc.time() - start_t)[["elapsed"]] / 60
        cat(sprintf("  Chunk %d — %s rows total (%.1f min elapsed)\n",
                    chunk_num, format(total_rows, big.mark = ","), elapsed_m))

        if (nrow(chunk) < chunk_rows) break
      }

    } else {
      # Small file: read all at once
      df <- data.table::fread(
        csv_path, sep = vocab_delimiter, quote = "",
        header = TRUE, stringsAsFactors = FALSE, data.table = FALSE,
        na.strings = c("", "NA")
      )
      colnames(df) <- tolower(colnames(df))
      df         <- parse_omop_dates(df, tbl)
      total_rows <- nrow(df)
      cat("  Inserting", format(total_rows, big.mark = ","), "rows...\n")

      DatabaseConnector::insertTable(
        connection        = conn_load,
        tableName         = paste0(vocab_schema, ".", tbl),
        data              = df,
        dropTableIfExists = FALSE,
        createTable       = FALSE,
        tempTable         = FALSE
      )
    }

    elapsed <- (proc.time() - start_t)[["elapsed"]]
    cat(sprintf("  [DONE] %s — %s rows in %.1f min\n\n",
                tbl, format(total_rows, big.mark = ","), elapsed / 60))

  }, error = function(e) {
    cat("[ERROR] Failed to load", tbl, ":", conditionMessage(e), "\n\n")
  })

  DatabaseConnector::disconnect(conn_load)
}

# ---------------------------------------------------------------------------
# Post-load NULL corrections
#
# Several OMOP CDM vocabulary columns are NULLABLE but R's data.table::fread
# reads empty fields as NA, and DatabaseConnector::insertTable converts those
# to empty strings ('') rather than SQL NULL.  The ETLSyntheaBuilder vocab-map
# SQL relies on IS NULL checks (e.g. C1.INVALID_REASON IS NULL to find valid
# standard concepts), so we must restore proper NULLs after loading.
# ---------------------------------------------------------------------------
cat("=== Post-load NULL corrections ===\n")
conn_fix <- DatabaseConnector::connect(conn_details)

nullable_fixes <- list(
  # concept: invalid_reason = NULL for active concepts (D/U for deprecated)
  # standard_concept = NULL for non-standard; 'S' standard; 'C' classification
  list(tbl = "concept",
       sql = paste0(
         "UPDATE [", vocab_schema, "].[concept] ",
         "SET invalid_reason = NULL WHERE invalid_reason = '';\n",
         "UPDATE [", vocab_schema, "].[concept] ",
         "SET standard_concept = NULL WHERE standard_concept = '';"
       ),
       label = "concept.invalid_reason + standard_concept"),
  list(tbl = "concept_relationship",
       sql = paste0(
         "UPDATE [", vocab_schema, "].[concept_relationship] ",
         "SET invalid_reason = NULL WHERE invalid_reason = '';"
       ),
       label = "concept_relationship.invalid_reason"),
  list(tbl = "drug_strength",
       sql = paste0(
         "UPDATE [", vocab_schema, "].[drug_strength] ",
         "SET invalid_reason = NULL WHERE invalid_reason = '';"
       ),
       label = "drug_strength.invalid_reason"),
  list(tbl = "relationship",
       sql = paste0(
         "UPDATE [", vocab_schema, "].[relationship] ",
         "SET invalid_reason = NULL WHERE invalid_reason = '';"
       ),
       label = "relationship.invalid_reason")
)

for (fix in nullable_fixes) {
  tryCatch({
    DatabaseConnector::executeSql(conn_fix, fix$sql)
    cat("[OK]", fix$label, "— NULLs restored\n")
  }, error = function(e) {
    cat("[WARN]", fix$label, "fix failed (non-fatal):", conditionMessage(e), "\n")
  })
}

DatabaseConnector::disconnect(conn_fix)

# Final row count verification
cat("\n=== Final row counts ===\n")
conn_final <- DatabaseConnector::connect(conn_details)
for (tbl in unlist(vocab_file_map)) {
  cnt <- tryCatch({
    r <- DatabaseConnector::querySql(
      conn_final,
      paste0("SELECT COUNT(*) AS n FROM [", vocab_schema, "].[", tbl, "]")
    )
    as.integer(r[[1]])
  }, error = function(e) -1L)
  status <- if (cnt > 0) "[OK]   " else "[EMPTY]"
  cat(status, tbl, ":", format(cnt, big.mark = ","), "rows\n")
}
DatabaseConnector::disconnect(conn_final)

cat("\n=== Done ===\n")
