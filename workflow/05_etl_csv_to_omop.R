#!/usr/bin/env Rscript
# Step 5: ETL Synthea output CSV files into OMOP CDM using ETLSyntheaBuilder.
#
# Purpose:
# - Execute a full-domain Synthea CSV -> OMOP ETL run for this study.
# - Keep ETLBuilder table lifecycle isolated to a dedicated schema to avoid
#   DDL/constraint mismatches with previously created OMOP tables.
#
# What this wrapper script does:
# 1) Verifies expected project context (Step 1 must have been run).
# 2) Activates renv and prepares Java/JDBC settings used by OHDSI packages.
# 3) Validates required packages and installs missing packages via renv.
# 4) Prints explicit runtime configuration for auditability.
# 5) Calls scripts/etl/run_synthea_full_csv_builder_etl.R to perform ETL.
#
# Default Step 5 strategy:
# - Target CDM schema: omop_synth_pad_amp_dispo (from study_params.yaml cdm_schema)
# - Vocabulary mode   : ETLSyntheaBuilder::LoadVocabFromCsv (README-style)
# - Vocabulary folder : supplied via env var OHDSI_VOCAB_CSV_DIR
#
# Expected vocabulary folder contents:
# - CONCEPT.csv
# - CONCEPT_ANCESTOR.csv
# - CONCEPT_CLASS.csv
# - CONCEPT_RELATIONSHIP.csv
# - CONCEPT_SYNONYM.csv
# - DOMAIN.csv
# - DRUG_STRENGTH.csv
# - RELATIONSHIP.csv
# - VOCABULARY.csv
# - SOURCE_TO_CONCEPT_MAP.csv
#
# Usage example (PowerShell):
#   $env:OHDSI_VOCAB_CSV_DIR = "C:\\path\\to\\Vocabulary_YYYYMMDD"
#   Rscript workflow/05_etl_csv_to_omop.R
#
# Notes:
# - This script intentionally keeps values explicit and readable instead of
#   over-generalizing with many CLI switches.
# - Edit the settings block below when you need a one-off rerun variant.

# -----------------------------------------------------------------------------
# Step-level runtime settings
# -----------------------------------------------------------------------------
# Path to Synthea CSV output directory produced by Step 4.
# Priority:
#  1) SYNTHEA_CSV_DIR env var (explicit override)
#  2) SYNTHEA_HOME env var, joined with "output/csv"
#  3) <repo_root>/external/synthea/output/csv — matches Step 4's default,
#     resolves the synthea submodule path relative to this script's location
#     so the default works regardless of the caller's cwd.
#  4) legacy project-relative folder fallback
default_synthea_home <- local({
  # Parse `--file=` to find this script's directory; fall back to "workflow/"
  # when sourced interactively. Mirrors the bootstrap_path pattern in Step 2.
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  script_dir <- if (length(file_arg) > 0) {
    dirname(sub("^--file=", "", file_arg[1]))
  } else {
    "workflow"
  }
  normalizePath(file.path(script_dir, "..", "external", "synthea"),
                winslash = "/", mustWork = FALSE)
})
csv_input_dir <- Sys.getenv(
  "SYNTHEA_CSV_DIR",
  unset = file.path(
    Sys.getenv("SYNTHEA_HOME", unset = default_synthea_home),
    "output",
    "csv"
  )
)
if (!dir.exists(csv_input_dir)) {
  csv_input_dir <- "../synthea-data/output/csv"
}

# ETL run identifier that appears in logs/output metadata.
# Derived from cfg$study_name after config loads; placeholder set here.
run_name <- NULL  # resolved after cfg loads below

# TRUE  = drop/recreate staging/event artifacts before load.
# FALSE = incremental/reuse behavior where possible.
reset_before_etl <- TRUE

# TRUE  = attempt SQL Server bulk insert path first.
# FALSE = force non-bulk row load path.
synthea_bulk_load <- TRUE

# TRUE  = print verbose ETL logs/progress ticks.
verbose <- TRUE

# Vocabulary strategy — choose ONE of the following:
#
# use_shared_vocab_schema = TRUE  (recommended after first-time setup)
#   Wires SQL Server synonyms pointing to the shared omop_vocab schema.
#   No data is copied; setup takes ~1 second.
#   Prerequisite: run infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template once on this instance.
#
# use_shared_vocab_schema = FALSE + reload_vocab_from_csv = TRUE
#   Loads vocabulary fresh from CSV on every run (~30-60 min, ~25 GB log).
#   Use only on a new instance before infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template has been run.
#
# use_shared_vocab_schema = FALSE + reload_vocab_from_csv = FALSE
#   Bootstraps vocab via INSERT...SELECT from vocabulary_source_schema.
use_shared_vocab_schema <- TRUE
shared_vocab_schema     <- "omop_vocab"

# TRUE  = reload vocab into target CDM schema from CSV folder.
# FALSE = do not use CSV vocab load path (helper script may use fallback logic).
reload_vocab_from_csv <- FALSE

# Required when reload_vocab_from_csv = TRUE.
# Set in shell, for example: $env:OHDSI_VOCAB_CSV_DIR = "C:\\Vocabulary_20250301"
vocab_file_loc <- Sys.getenv("OHDSI_VOCAB_CSV_DIR", unset = "C:/Users/rapiduser/omop-vocab")

# OHDSI vocabulary distributions are tab-delimited.
vocab_delimiter <- "\t"

# Fresh CDM schema used only for ETLSyntheaBuilder-driven table lifecycle.
# Derived from cfg$study_name after config loads: omop_synth_<study_name>.
# Set to a non-NULL string here only to override the derived value.
target_cdm_schema_base <- "omop_synth_pad_amp_dispo"  # PINNED override (NOT the
  # study_name-derived omop_synth_pad_amp_dispo_synth). This -synth repo's study_name is
  # pad_amp_dispo_synth, but the physical CDM schema is intentionally the _desc name: it is
  # registered in ../synthetic_data/registry.yaml (id: pad_amp_dispo) and consumed by
  # pad-amp-ed-desc AND pad-oler-aki-desc via view-overlays. Writing here REPLACES the
  # previous dataset in place (reset_before_etl = TRUE). Matches study_params.yaml cdm_schema.
target_cdm_schema <- NA_character_  # resolved after cfg loads below

# Fallback vocabulary source schema if CSV reload is disabled.
vocabulary_source_schema <- "cdm_synthea"

# Guardrail to ensure this script is run from the project root after Step 1 setup.
assert_step1_environment <- function() {
  required_paths <- c(
    "renv/activate.R",
    "config.R",
    "scripts/etl/run_synthea_full_csv_builder_etl.R"
  )
  missing_paths <- required_paths[!file.exists(required_paths)]

  if (length(missing_paths) > 0) {
    stop(
      paste0(
        "Step 5 could not find required project files in the current working directory: ",
        paste(missing_paths, collapse = ", "),
        "\nCurrent working directory: ", normalizePath(getwd(), winslash = "/", mustWork = FALSE),
        "\nRun workflow/01_setup_synthea_etl_qc_env.R first to set up the environment and working directory, then rerun Step 5."
      ),
      call. = FALSE
    )
  }
}

assert_step1_environment()

# Activate project package library.
source("renv/activate.R")
if (requireNamespace("renv", quietly = TRUE)) {
  renv::load(project = getwd())
}

# Load central configuration and initialize Java for rJava/DatabaseConnector.
source("config.R")
cfg <- get_validation_config()

# Derive target CDM schema from study name unless overridden above.
# Produces e.g. "omop_synth_pad_oler_macce_val" for study_name = "pad-oler-macce-val".
if (is.null(target_cdm_schema_base)) {
  target_cdm_schema_base <- paste0("omop_synth_", cfg$study_name)
}
target_cdm_schema <- target_cdm_schema_base

# Derive run name from study name for consistent log/output labelling.
if (is.null(run_name)) {
  run_name <- paste0(cfg$study_name, "-csv-", format(Sys.time(), "%Y%m%d-%H%M%S"))
}
if (!is.null(cfg$java_home) && nzchar(cfg$java_home) && dir.exists(cfg$java_home)) {
  java_bin <- file.path(cfg$java_home, "bin")
  Sys.setenv(JAVA_HOME = cfg$java_home)
  Sys.setenv(PATH = paste(
    normalizePath(java_bin, winslash = "/", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  ))
  options(java.parameters = c(
    "-Xmx4g",  # 4 GB heap — prevents OOM during bulk CSV-to-staging load
    "-Xms512m",
    paste0("-Djava.home=", normalizePath(cfg$java_home, winslash = "/", mustWork = FALSE))
  ))

  # Set the JDBC Windows Integrated Authentication native library path so that
  # DatabaseConnector can locate sqljdbc_auth.dll without needing manual env-var
  # setup before invoking Rscript.  Both JAVA_TOOL_OPTIONS and PATH are required:
  # - JAVA_TOOL_OPTIONS passes -Djava.library.path to the JVM at startup.
  # - PATH lets Windows resolve the DLL's own dependencies from the same directory.
  if (!is.null(cfg$jdbc_auth_dir) && nzchar(cfg$jdbc_auth_dir) && dir.exists(cfg$jdbc_auth_dir)) {
    jdbc_auth_native <- normalizePath(cfg$jdbc_auth_dir, winslash = "/", mustWork = FALSE)
    Sys.setenv(JAVA_TOOL_OPTIONS = paste0("-Djava.library.path=", jdbc_auth_native))
    Sys.setenv(PATH = paste(
      jdbc_auth_native,
      Sys.getenv("PATH"),
      sep = .Platform$path.sep
    ))
  }
}

required_pkgs <- c("DatabaseConnector", "SqlRender", "data.table")
missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  # Use CRAN_MIRROR env var (set in .env) or fall back to cloud.r-project.org.
  options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))
  message("Installing missing Step 5 packages via renv: ", paste(missing_pkgs, collapse = ", "))
  for (pkg in missing_pkgs) {
    renv::install(pkg)
  }
  if (requireNamespace("renv", quietly = TRUE)) {
    renv::load(project = getwd())
  }
}

missing_pkgs_after_install <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs_after_install) > 0) {
  stop(
    "Step 5 cannot continue; missing packages after install attempt: ",
    paste(missing_pkgs_after_install, collapse = ", ")
  )
}

message("=== Step 5 configuration ===")
message("JDBC auth DLL directory: ", if (!is.null(cfg$jdbc_auth_dir) && dir.exists(cfg$jdbc_auth_dir)) cfg$jdbc_auth_dir else "<not found>")
message("Target CDM schema      : ", target_cdm_schema)
message("Reload vocab from CSV  : ", ifelse(reload_vocab_from_csv, "true", "false"))
if (reload_vocab_from_csv) {
  message("Vocab CSV directory    : ", ifelse(nzchar(vocab_file_loc), vocab_file_loc, "<unset>"))
  if (!nzchar(vocab_file_loc)) {
    stop(
      "OHDSI_VOCAB_CSV_DIR is not set. Set this environment variable to the vocabulary CSV folder before running Step 5.",
      call. = FALSE
    )
  }
}
message("Vocabulary source schema (fallback): ", vocabulary_source_schema)
message("Reset before ETL       : ", ifelse(reset_before_etl, "true", "false"))
message("Synthea bulk load      : ", ifelse(synthea_bulk_load, "true", "false"))
message("CSV input directory    : ", normalizePath(csv_input_dir, winslash = "/", mustWork = FALSE))
message("Run name               : ", run_name)

# ---------------------------------------------------------------------------
# Pre-flight: check and prepare the SQL Server transaction log.
# The vocabulary CSV load (CONCEPT_ANCESTOR: 75 M rows) requires a large
# log headroom even in SIMPLE recovery.  This call shrinks any space left
# over from prior runs and pre-grows the log to 25 GB before touching any
# OMOP tables, preventing mid-ETL "transaction log full" failures.
# ---------------------------------------------------------------------------
source("R/db_maintenance.R")
prepare_txlog_for_bulk_etl(cfg)

# Delegate actual ETL execution to the main ETLBuilder orchestration script.
source("scripts/etl/run_synthea_full_csv_builder_etl.R")

run_synthea_full_csv_builder_etl(
  csv_input_dir            = csv_input_dir,
  run_name                 = run_name,
  cdm_schema               = target_cdm_schema,
  vocabulary_source_schema = vocabulary_source_schema,
  reload_vocab_from_csv    = reload_vocab_from_csv,
  vocab_file_loc           = vocab_file_loc,
  vocab_delimiter          = vocab_delimiter,
  reset_before_etl         = reset_before_etl,
  synthea_bulk_load        = synthea_bulk_load,
  use_shared_vocab_schema  = use_shared_vocab_schema,
  shared_vocab_schema      = shared_vocab_schema,
  verbose                  = verbose
)

cat(
  "Step 5 complete: full-domain CSV ETL loaded to OMOP.",
  "run_name=", run_name,
  ", cdm_schema=", target_cdm_schema,
  ", reload_vocab_from_csv=", ifelse(reload_vocab_from_csv, "true", "false"),
  ", vocab_source_schema=", vocabulary_source_schema,
  ", reset_before_etl=", ifelse(reset_before_etl, "true", "false"),
  ", synthea_bulk_load=", ifelse(synthea_bulk_load, "true", "false"),
  "\n",
  sep = ""
)
