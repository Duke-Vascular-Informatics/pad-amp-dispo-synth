#!/usr/bin/env Rscript
# =============================================================================
# scripts/concept_lookup.R
#
# OMOP vocabulary lookup — command-line equivalent of the /concept-lookup
# Claude Code skill.
#
# PURPOSE
# -------
# Queries the live omop_vocab vocabulary against this project's SQL Server
# instance to find standard OMOP concept IDs for a clinical term.  Run this
# before writing any concept_id into code, SQL, or a CSV file.
#
# USAGE
# -----
#   Rscript scripts/concept_lookup.R "<clinical term>" [domain]
#
# Arguments:
#   <clinical term>  Required. The clinical concept to search for. Quote
#                    multi-word terms.
#   [domain]         Optional. One of: Condition, Drug, Procedure,
#                    Measurement, Observation, Visit.  Omit to search all
#                    domains.
#
# Examples:
#   Rscript scripts/concept_lookup.R "total hip replacement" Procedure
#   Rscript scripts/concept_lookup.R "venous thromboembolism" Condition
#   Rscript scripts/concept_lookup.R "cefazolin"
#
# OUTPUT
# ------
# Prints two tables to the console:
#   1. Direct name / synonym matches (top 20 standard concepts)
#   2. Top-5 descendants of the best candidate (for ancestor rollup review)
#
# Results are labelled [vocab query] — safe to use in code and CSV for this
# vocabulary version.
#
# PREREQUISITES
# -------------
#   - Java 17 (JAVA_HOME set) and the JDBC driver (provisioned by workflow/01)
#   - DatabaseConnector and SqlRender installed in the project renv library
# =============================================================================

# -----------------------------------------------------------------------------
# 0. Bootstrap — locate project root the same way workflow scripts do
# -----------------------------------------------------------------------------
args_full <- commandArgs(trailingOnly = FALSE)
file_arg  <- grep("^--file=", args_full, value = TRUE)
if (length(file_arg) > 0) {
  script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                      winslash = "/"))
  proj_root  <- dirname(script_dir)   # scripts/ is one level below root
} else {
  proj_root <- getwd()
}
setwd(proj_root)

# Activate renv so the project library is on the search path.
if (file.exists("renv/activate.R")) source("renv/activate.R")

# Source infrastructure helpers.
source("config.R")
source("R/drivers.R")
source("R/connection.R")


# -----------------------------------------------------------------------------
# 1. Parse command-line arguments
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  cat("Usage: Rscript scripts/concept_lookup.R \"<clinical term>\" [domain]\n")
  cat("       domain: Condition | Drug | Procedure | Measurement | Observation | Visit\n")
  cat("Example: Rscript scripts/concept_lookup.R \"diabetes mellitus\" Condition\n")
  quit(status = 1)
}

search_term   <- args[1]
domain_filter <- if (length(args) >= 2) tools::toTitleCase(tolower(args[2])) else NULL

valid_domains <- c("Condition", "Drug", "Procedure",
                   "Measurement", "Observation", "Visit")
if (!is.null(domain_filter) && !domain_filter %in% valid_domains) {
  cat("Unknown domain '", domain_filter, "'. Valid options: ",
      paste(valid_domains, collapse = ", "), "\n", sep = "")
  quit(status = 1)
}

cat("\n=== OMOP Concept Lookup ===\n")
cat("Term  :", search_term, "\n")
cat("Domain:", if (!is.null(domain_filter)) domain_filter else "(all domains)", "\n\n")


# -----------------------------------------------------------------------------
# 2. Initialise Java / JDBC and open a database connection
# -----------------------------------------------------------------------------
config <- get_validation_config()
configure_java(config)
library(DatabaseConnector)
library(SqlRender)

connection_details <- build_connection_details(config)
conn <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)


# -----------------------------------------------------------------------------
# 3. Step 1 — Direct name match (and synonym fallback)
#
# Searches concept_name first; falls back to concept_synonym when fewer than
# 3 direct hits are found.  Both queries target standard, non-invalid concepts
# in omop_vocab.concept.
# -----------------------------------------------------------------------------
domain_clause <- if (!is.null(domain_filter)) {
  paste0("  AND c.domain_id = '", domain_filter, "'\n")
} else {
  ""
}

# Primary: concept_name LIKE match, ordered by exact match → shortest name.
sql_direct <- SqlRender::render(
  "SELECT TOP 20
       c.concept_id,
       c.concept_name,
       c.domain_id,
       c.vocabulary_id,
       c.concept_class_id,
       c.standard_concept,
       c.concept_code
   FROM @vocab_schema.concept c
   WHERE c.standard_concept = 'S'
     AND c.invalid_reason IS NULL
     AND LOWER(c.concept_name) LIKE LOWER('%@term%')
     @domain_clause
   ORDER BY
       CASE WHEN LOWER(c.concept_name) = LOWER('@term') THEN 0 ELSE 1 END,
       LEN(c.concept_name),
       c.concept_name",
  vocab_schema  = config$vocab_schema,
  term          = search_term,
  domain_clause = domain_clause
)

results <- DatabaseConnector::querySql(conn,
  SqlRender::translate(sql_direct, "sql server"),
  snakeCaseToCamelCase = FALSE
)

# Synonym fallback: join concept_synonym when direct hits are sparse.
if (nrow(results) < 3) {
  sql_synonym <- SqlRender::render(
    "SELECT TOP 10
         c.concept_id,
         c.concept_name,
         c.domain_id,
         c.vocabulary_id,
         c.concept_class_id,
         c.standard_concept,
         c.concept_code
     FROM @vocab_schema.concept c
     JOIN @vocab_schema.concept_synonym cs ON c.concept_id = cs.concept_id
     WHERE c.standard_concept = 'S'
       AND c.invalid_reason IS NULL
       AND LOWER(cs.concept_synonym_name) LIKE LOWER('%@term%')
       @domain_clause
     ORDER BY LEN(cs.concept_synonym_name), c.concept_name",
    vocab_schema  = config$vocab_schema,
    term          = search_term,
    domain_clause = domain_clause
  )
  syn_results <- DatabaseConnector::querySql(conn,
    SqlRender::translate(sql_synonym, "sql server"),
    snakeCaseToCamelCase = FALSE
  )
  names(results)     <- toupper(names(results))
  names(syn_results) <- toupper(names(syn_results))
  # Combine, deduplicating by concept_id.
  results <- unique(rbind(results, syn_results))
}


# -----------------------------------------------------------------------------
# 4. Print candidate concepts table
# -----------------------------------------------------------------------------
if (nrow(results) == 0) {
  cat("No standard concepts found for '", search_term, "'",
      if (!is.null(domain_filter)) paste0(" in domain ", domain_filter), ".\n",
      "Try a broader term or omit the domain filter.\n", sep = "")
  quit(status = 0)
}

# Normalise column names to uppercase for consistent indexing regardless of
# JDBC driver version (some drivers return lowercase, others uppercase).
names(results) <- toupper(names(results))

cat("--- Candidate standard concepts (", nrow(results), " found) ---\n", sep = "")
print(results[, c("CONCEPT_ID", "CONCEPT_CODE", "CONCEPT_NAME", "DOMAIN_ID",
                   "VOCABULARY_ID", "CONCEPT_CLASS_ID")],
      row.names = FALSE)
cat("\n")


# -----------------------------------------------------------------------------
# 5. Step 2 — Descendant expansion for the best candidate
#
# Shows the top 10 descendants of the first (best-ranked) concept so the
# analyst can verify that ancestor rollup captures the right clinical scope.
# -----------------------------------------------------------------------------
best_id <- results$CONCEPT_ID[1]
best_nm <- results$CONCEPT_NAME[1]

sql_desc <- SqlRender::render(
  "SELECT TOP 10
       c.concept_id,
       c.concept_name,
       c.domain_id,
       c.vocabulary_id,
       ca.min_levels_of_separation AS levels_below
   FROM @vocab_schema.concept_ancestor ca
   JOIN @vocab_schema.concept c
     ON c.concept_id = ca.descendant_concept_id
   WHERE ca.ancestor_concept_id = @ancestor_id
     AND c.standard_concept = 'S'
     AND c.invalid_reason  IS NULL
     AND ca.min_levels_of_separation > 0
   ORDER BY ca.min_levels_of_separation, c.concept_name",
  vocab_schema = config$vocab_schema,
  ancestor_id  = best_id
)

desc_results <- DatabaseConnector::querySql(conn,
  SqlRender::translate(sql_desc, "sql server"),
  snakeCaseToCamelCase = FALSE
)

cat("--- Top descendants of recommended concept (id=", best_id,
    " / '", best_nm, "') ---\n", sep = "")
if (nrow(desc_results) == 0) {
  cat("  (no descendants — this is a leaf concept)\n")
} else {
  print(desc_results, row.names = FALSE)
}
cat("\n")


# -----------------------------------------------------------------------------
# 6. Recommendation and label
# -----------------------------------------------------------------------------
cat("Recommended concept_id : ", best_id, "\n", sep = "")
cat("Concept name           : ", best_nm, "\n", sep = "")
cat("Concept code           : ", results$CONCEPT_CODE[1], "\n", sep = "")
cat("Domain                 : ", results$DOMAIN_ID[1], "\n", sep = "")
cat("Vocabulary             : ", results$VOCABULARY_ID[1], "\n", sep = "")
cat("Concept class          : ", results$CONCEPT_CLASS_ID[1], "\n\n", sep = "")
cat("[vocab query] Confirmed against", config$vocab_schema,
    "in this SQL Server instance.\n")
cat("Safe to use in code and cohort definitions for this vocabulary version.\n\n")
cat("Use it in a cohort definition's concept set (in the consuming Strategus repo).\n\n")
cat("To use in phenotype_library/catalog.yaml:\n")
cat("  concept_id:", best_id, "\n")
cat("  concept_name: \"", best_nm, "\"\n", sep = "")
cat("  concept_code: \"", results$CONCEPT_CODE[1], "\"\n", sep = "")
cat("  concept_class_id: \"", results$CONCEPT_CLASS_ID[1], "\"\n", sep = "")
cat("  vocabulary:", results$VOCABULARY_ID[1], "\n")
cat("  domain_id:", results$DOMAIN_ID[1], "\n\n")
