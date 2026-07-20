# =============================================================================
# config.R — Portable Bundle Configuration
#
# Institution-specific connection values are read from environment variables.
# Set them in a .env file at the bundle root or export them in your shell
# before launching R.
#
# Authentication: Kerberos (NetID). Run setup_env.sh first to obtain
# a Kerberos ticket. Java is provided by the conda openjdk environment; this
# script resolves JAVA_HOME automatically from the active environment.
#
# This file was seeded by workflow/09_build_portable_analysis_bundle.sh from
# setup/bundle_templates/config.R with values derived from study_params.yaml.
# It is never overwritten by subsequent step 9 runs — edit it here directly
# if site-specific adjustments are needed.
# =============================================================================

get_validation_config <- function() {

  # ---------------------------------------------------------------------------
  # Java — resolved automatically from the conda openjdk environment.
  # Run `conda activate openjdk` BEFORE starting R so that JAVA_HOME is set.
  # ---------------------------------------------------------------------------
  java_home <- Sys.getenv("JAVA_HOME")
  if (nchar(trimws(java_home)) == 0) {
    # Fallback: resolve from the running java binary on PATH
    java_bin_path <- trimws(system("which java 2>/dev/null", intern = TRUE))
    if (length(java_bin_path) > 0 && nchar(java_bin_path) > 0) {
      java_home <- normalizePath(file.path(dirname(java_bin_path), ".."),
                                 mustWork = FALSE)
    }
  }
  if (nchar(trimws(java_home)) == 0) {
    stop(
      "JAVA_HOME is not set and 'java' is not on PATH.\n",
      "Run: conda activate openjdk\n",
      "Then re-launch R from the same shell."
    )
  }

  # ---------------------------------------------------------------------------
  # JDBC driver — bundled JAR in drivers/ (no download needed)
  # ---------------------------------------------------------------------------
  jdbc_runtime_dir <- file.path(getwd(), "drivers")

  # ---------------------------------------------------------------------------
  # Institution-provided JDBC wrapper JAR — required for Kerberos authentication.
  # Set OMOP_HPC_JAR in .env to override the default path.
  # ---------------------------------------------------------------------------
  hpc_jar_default <- file.path(
    dirname(normalizePath(getwd(), mustWork = FALSE)),
    "drivers",
    "prcc-jdbc-mssql-1.0-SNAPSHOT.jar"
  )
  hpc_jar <- Sys.getenv("OMOP_HPC_JAR", unset = hpc_jar_default)

  # Bracket-quote a SQL Server identifier containing backslash, space, hyphen,
  # or dot (e.g. results_schema = "domain\netid"). Applied once at config
  # creation so all consumers can use the value directly in SQL.
  .bq <- function(x) {
    if (nchar(x) > 0 && grepl("[\\\\\\s\\-\\.]", x, perl = TRUE) &&
        !grepl("^\\[", x))
      paste0("[", x, "]")
    else x
  }

  # ---------------------------------------------------------------------------
  # SQL Server connection — values read from .env (pre-populated by step 9)
  # ---------------------------------------------------------------------------
  list(
    # Java
    java_home        = java_home,
    jdbc_runtime_dir = jdbc_runtime_dir,
    hpc_jar          = hpc_jar,

    # ---- CONNECTION (read from environment variables — set in .env) ---------
    server           = Sys.getenv("OMOP_SERVER",         unset = "YOUR_SERVER.example.com"),
    database         = Sys.getenv("OMOP_DATABASE",       unset = "YOUR_DATABASE"),
    spn_host         = Sys.getenv("OMOP_SPN_HOST",       unset = "YOUR_SPN_HOST"),
    vocab_schema     = Sys.getenv("OMOP_VOCAB_SCHEMA",   unset = "omop_vocab"),
    cdm_schema       = Sys.getenv("OMOP_CDM_SCHEMA",     unset = "omop_cdm"),
    results_database = NA,
    results_schema   = .bq(Sys.getenv("OMOP_RESULTS_SCHEMA", unset = "your_results_schema")),
    # ---- END CONNECTION -----------------------------------------------------

    dbms         = "sql server",
    cohort_table = "__COHORT_TABLE__",

    # Cohort definition IDs written into the cohort table
    target_cohort_id  = 1L,
    outcome_cohort_id = 2L,

    # SQL templates for cohort instantiation (read by cohorts.R / build_cohorts)
    target_cohort_sql  = file.path(getwd(), "cohorts", "__TARGET_SQL_FILE__"),
    outcome_cohort_sql = file.path(getwd(), "cohorts", "__OUTCOME_SQL_FILE__"),

    # ---------------------------------------------------------------------------
    # Target cohort parameters — injected into the target SQL file by SqlRender.
    # Verify all concept IDs against the live vocabulary before use.
    # ---------------------------------------------------------------------------
    # Visit type filter. c(9201L) = Inpatient only. integer(0) = all visit types.
    target_visit_concept_ids     = __TARGET_VISIT_CONCEPT_IDS__,

    # Minimum age at index date in years. 0L = no age filter.
    target_min_age               = __TARGET_MIN_AGE__L,

    # Index event ancestor concept IDs (procedure_occurrence rollup). [vocab query]
    target_index_concept_ids     = __TARGET_INDEX_CONCEPT_IDS__,

    # Prior-outcome washout. integer(0) = washout disabled.
    target_washout_concept_ids   = __TARGET_WASHOUT_CONCEPT_IDS__,
    target_washout_lookback_days = __TARGET_WASHOUT_LOOKBACK_DAYS__L,

    # Outcome ancestor concept IDs. integer(0) when outcome SQL is self-contained.
    outcome_concept_ids          = __OUTCOME_CONCEPT_IDS__,

    # ---------------------------------------------------------------------------
    # Pre-existing ATLAS cohorts (optional — set use_atlas_cohorts = TRUE if
    # cohorts are already in results schema from ATLAS; FALSE = build from SQL)
    # ---------------------------------------------------------------------------
    use_atlas_cohorts       = FALSE,
    atlas_cohort_schema     = "results",
    atlas_cohort_table      = "cohort",
    atlas_target_cohort_id  = NA_integer_,
    atlas_outcome_cohort_id = NA_integer_,

    # ---------------------------------------------------------------------------
    # Study identity — used by the report template for routing and file naming.
    # ---------------------------------------------------------------------------
    study_name   = "__STUDY_NAME__",
    study_design = "__STUDY_DESIGN__",

    # ---------------------------------------------------------------------------
    # Risk score pipeline settings
    # ---------------------------------------------------------------------------
    model_name                 = "__STUDY_NAME__",
    risk_score_lookup_file     = file.path(getwd(), "covariates", "risk_lookup.csv"),
    # Pipeline CSVs (person_level_scores.csv, metrics.csv, etc.) land here.
    risk_score_output_folder   = file.path(getwd(), "output", "risk_score_eval"),
    covariate_definitions_file = file.path(getwd(), "covariates", "covariates.csv"),
    covariate_concepts_file    = file.path(getwd(), "covariates", "covariate_concepts.csv"),
    # Top-level output folder — manuscript report (.docx) is written here.
    output_folder              = file.path(getwd(), "output"),

    # ---------------------------------------------------------------------------
    # Report generation — must match the pipeline run above.
    # score_type:   "integer" | "lasso"
    # outcome_label: plain-English outcome name used in report headings and text.
    # ---------------------------------------------------------------------------
    score_type             = "__SCORE_TYPE__",
    outcome_label          = "__OUTCOME_LABEL__",
    model_type_description = "integer risk score",
    var_imp_file           = "model/varImp.rds",

    prediction_window_days = __PRED_WINDOW__L,

    # Study date window — from study_params.yaml
    study_start_date = "__STUDY_START__",
    study_end_date   = "__STUDY_END__",

    # Database identifier metadata (written into output files)
    cdm_database_id          = Sys.getenv("OMOP_CDM_DATABASE_ID",
                                           unset = "your_cdm_v5.4"),
    cdm_database_name        = Sys.getenv("OMOP_CDM_DATABASE_NAME",
                                           unset = "Your Institution OMOP CDM"),
    cdm_database_description = Sys.getenv("OMOP_CDM_DATABASE_DESCRIPTION",
                                           unset = "Brief description of the patient population and database.")
  )
}
