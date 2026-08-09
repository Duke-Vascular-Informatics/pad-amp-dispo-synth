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

# Vocabulary MAP strategy.
#
# ETLSyntheaBuilder materializes source_to_standard_vocab_map (~4.5M rows) and
# source_to_source_vocab_map (~6.3M rows) — together ~3.9 GB — into the CDM
# schema on every run. Both are a pure function of the vocabulary, so when the
# vocabulary is shared every CDM schema was building a byte-identical copy.
#
# TRUE  = build them once in shared_map_schema and reach them via synonyms.
#         Rebuilt automatically when the OMOP vocabulary release changes.
# FALSE = per-schema copies (the original ETLSyntheaBuilder behaviour).
#
# Ignored unless use_shared_vocab_schema is also TRUE — maps may only be shared
# by schemas that share the vocabulary they are derived from.
use_shared_vocab_maps <- TRUE
shared_map_schema     <- "omop_etl_maps"

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
target_cdm_schema_base <- "omop_synth_pad_amp_v2"  # v2 — VERSIONED target.
  # CHANGED 2026-08-06 for pad_amp v2. The registry's versions: scheme requires a
  # NEW physical schema per version rather than an in-place regeneration, because
  # pad-amp-ed-desc and pad-amp-nhd-prog are PINNED to v1
  # (omop_synth_pad_amp_dispo) and are merged/PRCC-verified against its counts.
  # Do NOT point this back at the v1 schema.  # PINNED override (NOT the
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

# ---------------------------------------------------------------------------
# INTERLOCK — refuse to regenerate over a registry-pinned CDM schema.
#
# Step 5 runs with reset_before_etl = TRUE, which DROPS AND REBUILDS every table
# in target_cdm_schema.  Several physical schemas in
# ../synthetic_data/registry.yaml are pinned by downstream studies verified
# against their exact counts, and at least one (pad_amp v1,
# omop_synth_pad_amp_dispo) cannot be rebuilt at all: it predates the 2026-08-08
# visit-rollup ETL fixes, and its generation_params.seed is null, so neither the
# CDM nor the Synthea CSVs behind it are reproducible.  Overwriting one is
# unrecoverable.  Until now the only thing preventing that was whoever edits
# target_cdm_schema_base above reading the registry first; this makes it a hard
# stop instead.
#
# SCOPE, AND ITS LIMITS.  This can only protect a version block declaring BOTH
# physical_schema and a non-empty pinned_consumers.  Legacy single-block registry
# entries record no physical schema at all, so they cannot be matched — they are
# reported as unprotected rather than silently treated as safe.  Add a
# physical_schema field to such an entry to bring it under the interlock.
#
# A version whose status is `needs_regeneration` is deliberately EXEMPT: the
# registry is stating that this schema is meant to be rebuilt in place, and
# blocking it would obstruct the one rebuild the interlock should allow.  The
# run still prints a loud ALLOWED notice, because a rebuild invalidates the
# pinned consumers' counts either way.
#
# DELIBERATE OVERRIDE (you are rebuilding a pinned schema on purpose):
#   ALLOW_PINNED_CDM_SCHEMA=1 Rscript workflow/05_etl_csv_to_omop.R
# ---------------------------------------------------------------------------

# `%||%` is base R from 4.4.0; define it defensively so this guard also works
# under an older R in a stale container image.
if (!exists("%||%")) `%||%` <- function(x, y) if (is.null(x)) y else x

# Walk up from start_dir looking for synthetic_data/registry.yaml.  Walking
# rather than a fixed "../" keeps this correct when Step 5 runs from a git
# worktree (.claude/worktrees/<name>) or any other nesting depth.  Returns
# NA_character_ when the study repo is cloned standalone, without the workspace.
find_synthetic_data_registry <- function(start_dir = getwd()) {
  dir <- normalizePath(start_dir, winslash = "/", mustWork = FALSE)
  repeat {
    candidate <- file.path(dir, "synthetic_data", "registry.yaml")
    if (file.exists(candidate)) {
      return(candidate)
    }
    parent <- dirname(dir)
    if (identical(parent, dir)) {
      return(NA_character_)
    }
    dir <- parent
  }
}

# Stop the run when `schema` is a physical schema some study is pinned to.
# No-ops (with an explanatory message) when the registry cannot be found or
# cannot be parsed — a missing workspace must not block a standalone clone from
# building its own CDM, and this guard is a safety net, not a dependency.
assert_target_schema_not_pinned <- function(schema) {
  override <- tolower(trimws(Sys.getenv("ALLOW_PINNED_CDM_SCHEMA", unset = "")))
  registry_path <- find_synthetic_data_registry()

  if (is.na(registry_path)) {
    message(
      "[interlock] synthetic_data/registry.yaml not found above ", getwd(), ".\n",
      "            Pinned-schema check SKIPPED (standalone clone?). ",
      "Target: ", schema
    )
    return(invisible(FALSE))
  }

  registry <- tryCatch(yaml::read_yaml(registry_path), error = function(e) e)
  if (inherits(registry, "error")) {
    message(
      "[interlock] Could not parse ", registry_path, ": ", conditionMessage(registry), "\n",
      "            Pinned-schema check SKIPPED. Target: ", schema
    )
    return(invisible(FALSE))
  }

  # Collect every (schema, dataset, version, consumers) tuple the registry
  # declares, plus the entries too old to declare one.
  pinned <- list()
  rebuildable <- list()
  unprotected <- character(0)
  for (dataset in registry$datasets %||% list()) {
    if (is.null(dataset$versions)) {
      unprotected <- c(unprotected, dataset$id %||% "<unnamed>")
      next
    }
    for (v in dataset$versions) {
      consumers <- unlist(v$pinned_consumers %||% list(), use.names = FALSE)
      if (is.null(v$physical_schema) || !nzchar(v$physical_schema)) next
      if (length(consumers) == 0) next
      # A version the registry itself marks as needing regeneration is meant to
      # be rebuilt in place — that is the whole point of the status.  Blocking it
      # would make the interlock an obstacle to the one rebuild it should permit.
      if (identical(tolower(v$status %||% ""), "needs_regeneration")) {
        rebuildable[[length(rebuildable) + 1]] <- list(
          schema = v$physical_schema, dataset = dataset$id %||% "<unnamed>",
          version = v$version %||% "<unversioned>", consumers = consumers
        )
        next
      }
      pinned[[length(pinned) + 1]] <- list(
        schema    = v$physical_schema,
        dataset   = dataset$id %||% "<unnamed>",
        version   = v$version %||% "<unversioned>",
        consumers = consumers
      )
    }
  }

  # SQL Server identifiers are case-insensitive; compare accordingly.
  hit <- Filter(function(p) tolower(p$schema) == tolower(schema), pinned)

  if (length(hit) == 0) {
    # Distinguish "unknown schema" from "pinned, but the registry says rebuild
    # it" — the latter is a deliberate pass and should say so out loud, because
    # it still invalidates the pinned consumers' counts.
    allowed <- Filter(function(p) tolower(p$schema) == tolower(schema), rebuildable)
    if (length(allowed) > 0) {
      a <- allowed[[1]]
      message(
        "[interlock] ALLOWED — '", a$schema, "' (", a$dataset, " ", a$version,
        ") is pinned by ", paste(a$consumers, collapse = ", "),
        " but the registry marks it status: needs_regeneration, so an in-place\n",
        "            rebuild is the intended action. Rebuild each consumer's ",
        "overlay and re-verify its counts afterward."
      )
      return(invisible(TRUE))
    }
    message(
      "[interlock] OK — '", schema, "' is not pinned by any registered dataset ",
      "(", length(pinned), " pinned schema(s) checked",
      if (length(unprotected)) paste0("; ", length(unprotected),
        " legacy entr(y/ies) declare no physical_schema and cannot be checked: ",
        paste(unprotected, collapse = ", ")) else "",
      ")."
    )
    return(invisible(TRUE))
  }

  h <- hit[[1]]
  detail <- paste0(
    "  schema   : ", h$schema, "\n",
    "  dataset  : ", h$dataset, " (", h$version, ")\n",
    "  pinned by: ", paste(h$consumers, collapse = ", "), "\n",
    "  registry : ", registry_path
  )

  if (override %in% c("1", "true", "yes")) {
    message(
      "[interlock] OVERRIDDEN via ALLOW_PINNED_CDM_SCHEMA — proceeding to ",
      "REBUILD a pinned schema.\n", detail, "\n",
      "            Every consumer above must have its overlay rebuilt and its ",
      "counts re-verified after this run."
    )
    return(invisible(TRUE))
  }

  stop(
    "Step 5 refused to run: the target CDM schema is PINNED by a registered dataset.\n\n",
    detail, "\n\n",
    "reset_before_etl drops and rebuilds every table in this schema, and a pinned\n",
    "version is generally not reproducible (pre-2026-08-08 ETL and/or a null\n",
    "generation seed), so overwriting it cannot be undone.\n\n",
    "To add a version instead (the normal path): point target_cdm_schema_base in\n",
    "workflow/05_etl_csv_to_omop.R at a NEW schema, e.g. omop_synth_<id>_v<N+1>,\n",
    "add a matching version block to the registry, then migrate consumers one at a\n",
    "time with synthetic_data/scripts/generate_overlay_schema.R.\n\n",
    "If you really do intend to rebuild this schema in place:\n",
    "  ALLOW_PINNED_CDM_SCHEMA=1 Rscript workflow/05_etl_csv_to_omop.R",
    call. = FALSE
  )
}

assert_target_schema_not_pinned(target_cdm_schema)

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
# This call shrinks space left over from prior runs and pre-grows the log
# before touching any OMOP tables, preventing mid-ETL "transaction log full"
# failures.
#
# HOW BIG. The 25 GB default was sized for two things: a vocabulary CSV load
# (CONCEPT_ANCESTOR, 75 M rows) and create_source_to_standard_vocab_map, which
# built the whole source->standard map from the ~6.3 M-concept vocabulary in a
# single transaction.
#
#   - Loading vocabulary from CSV still needs the full 25 GB.
#   - Using shared vocab maps, neither statement runs: vocabulary comes from
#     synonyms and the map is built once in shared_map_schema. Measured, the
#     remaining domain INSERTs never pushed the log past ~1.6 GB.
#
# Pre-growing to 25 GB regardless is not free — on a small VM disk it starves
# the data file and the ETL dies at 99% full mid-load, which is a failure this
# workspace has hit repeatedly. Size the request to the path actually taken.
# ---------------------------------------------------------------------------
source("R/db_maintenance.R")

txlog_target_mb <- if (isTRUE(reload_vocab_from_csv)) {
  25600L   # full vocabulary CSV load — needs the original headroom
} else if (isTRUE(use_shared_vocab_maps) && isTRUE(use_shared_vocab_schema)) {
  4096L    # shared vocab + shared maps — only domain INSERTs are logged here
} else {
  16384L   # per-schema vocab maps still build in this database
}
message("Transaction log target : ", txlog_target_mb, " MB")
prepare_txlog_for_bulk_etl(cfg, target_min_mb = txlog_target_mb)

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
  use_shared_vocab_maps    = use_shared_vocab_maps,
  shared_map_schema        = shared_map_schema,
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
