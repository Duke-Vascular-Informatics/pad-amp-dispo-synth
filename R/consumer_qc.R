# =============================================================================
# R/consumer_qc.R
#
# PURPOSE
#   Consumer-study QC: prove that the synthetic dataset this -synth repo
#   produces still contains the patients that each consuming Strategus study
#   needs, so regenerating or changing the dataset cannot silently break a
#   study that depends on it.
#
#   For every study listed in consumers.yaml this module:
#     1. reads that study's cohort manifest (inst/Cohorts.csv) and circe JSON,
#     2. renders SQL from the JSON exactly as Strategus does at run time
#        (Strategus never reads inst/sql/*.sql; CohortGenerator re-renders from
#        the JSON with CirceR), so the QC tests the logic the study will run,
#     3. instantiates every cohort against the synthetic CDM with HADES
#        CohortGenerator into a scratch cohort table,
#     4. counts subjects per cohort and, for outcomes, subjects who are also in
#        the target cohort,
#     5. compares each count with a per-role minimum and drops the scratch
#        tables.
#
#   In a Strategus study the COHORT ROLES are:
#     target     - the one target cohort (targetId in the spec script)
#     outcome    - outcome cohorts (outcomeIds in the spec script)
#     covariate  - every other cohort in inst/Cohorts.csv. Strategus treats the
#                  remaining cohorts as covariate cohorts, so checking cohorts,
#                  covariates and outcomes is one mechanism.
#
# INPUTS   consumers.yaml (this repo), each consumer's inst/Cohorts.csv,
#          inst/cohorts/<id>.json, and CreateStrategusAnalysisSpecification.R
# OUTPUT   data frame of per-cohort results (see evaluate_consumer_results())
#
# SIDE EFFECTS
#   Creates and drops scratch cohort tables (prefix qc_consumer_) in the
#   results schema. Never writes to the CDM schema.
#
# LIMITS (by design)
#   - Cohort membership is checked at the subject level. Time-at-risk windows
#     and covariate windows are not re-run; a pass means the cohorts are
#     populated, not that every downstream estimate will be estimable.
#   - A hand-authored (circe escape hatch) cohort is checked using the
#     placeholder JSON that Strategus will actually run, not its .sql; such
#     cohorts are flagged in the output.
# =============================================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

# NOTE: SqlRender::render(sql, ...) partial-matches argument names, so a template
# parameter called `s` or `sq` binds to render()'s own `sql` argument instead.
# Always use descriptive parameter names (schema_name, table_name, ...).

# -----------------------------------------------------------------------------
# read_consumers
#
# Reads and validates consumers.yaml, applying defaults.
#
# @param path  Path to consumers.yaml.
# @return list(dataset_id = <chr|NA>, consumers = list of normalised entries,
#         not_checked = studies in the registry's used_by that are deliberately
#         not QC'd, e.g. retired studies or non-Strategus consumers).
#         Each entry has: study, repo_dir, cohorts_manifest, cohorts_json_dir,
#         spec_script, target_id, outcome_ids, expected_empty, discharge_disposition_check
#         (+ min_discharge_visits, min_non_home_visits, min_discharge_mapped_pct), min_target_subjects,
#         min_outcome_subjects, min_covariate_subjects.
# -----------------------------------------------------------------------------
read_consumers <- function(path = "consumers.yaml") {
  if (!file.exists(path)) stop("consumers file not found: ", path)
  y <- yaml::read_yaml(path)
  entries <- y$consumers %||% list()

  as_int <- function(x) if (is.null(x) || length(x) == 0 || all(is.na(x))) NULL else as.integer(unlist(x))

  consumers <- lapply(entries, function(co) {
    if (is.null(co$study) || !nzchar(co$study)) {
      stop("every consumers.yaml entry needs a `study` (the consumer repo's directory name)")
    }
    list(
      study                  = co$study,
      repo_dir               = co$repo_dir,
      cohorts_manifest       = co$cohorts_manifest %||% "inst/Cohorts.csv",
      cohorts_json_dir       = co$cohorts_json_dir %||% "inst/cohorts",
      spec_script            = co$spec_script %||% "CreateStrategusAnalysisSpecification.R",
      target_id              = as_int(co$target_id),
      outcome_ids            = as_int(co$outcome_ids),
      expected_empty         = as_int(co$expected_empty),
      min_target_subjects    = as.numeric(co$min_target_subjects    %||% 100),
      min_outcome_subjects   = as.numeric(co$min_outcome_subjects   %||% 10),
      min_covariate_subjects = as.numeric(co$min_covariate_subjects %||% 1),
      # Opt-in discharge-disposition check (see check_discharge_disposition()).
      discharge_disposition_check = isTRUE(co$discharge_disposition_check),
      min_discharge_visits       = as.numeric(co$min_discharge_visits       %||% 1),
      min_non_home_visits        = as.numeric(co$min_non_home_visits        %||% 1),
      min_discharge_mapped_pct   = as.numeric(co$min_discharge_mapped_pct   %||% 90)
    )
  })

  studies <- vapply(consumers, function(co) co$study, character(1))
  if (anyDuplicated(studies)) {
    stop("duplicate consumer study in consumers.yaml: ",
         paste(unique(studies[duplicated(studies)]), collapse = ", "))
  }
  not_checked <- as.character(unlist(y$not_checked %||% list()))
  list(dataset_id = y$dataset_id %||% NA_character_, consumers = consumers,
       not_checked = not_checked)
}

# -----------------------------------------------------------------------------
# parse_spec_roles
#
# Reads the cohort roles out of a consumer's CreateStrategusAnalysisSpecification.R
# by pattern-matching the `targetId <-`, `outcomeIds <-` and `HAND_AUTHORED <-`
# assignments, which the strategus-study-template defines. Comments are
# stripped first. Anything it cannot parse comes back NULL / empty so the
# caller can ask for explicit target_id / outcome_ids in consumers.yaml.
#
# @return list(target_id = <int|NULL>, outcome_ids = <int>, hand_authored = <int>)
# -----------------------------------------------------------------------------
parse_spec_roles <- function(spec_path) {
  if (!file.exists(spec_path)) {
    return(list(target_id = NULL, outcome_ids = integer(0), hand_authored = integer(0)))
  }
  txt <- readLines(spec_path, warn = FALSE)
  txt <- sub("#.*$", "", txt)
  txt <- paste(txt, collapse = "\n")

  ints_after <- function(var, allow_vector) {
    pat <- paste0("(?<![A-Za-z0-9_.])", var, "\\s*(?:<-|=)\\s*(",
                  if (allow_vector) "c\\([^)]*\\)|integer\\(0\\)|" else "",
                  "[0-9]+L?)")
    m <- regmatches(txt, regexec(pat, txt, perl = TRUE))[[1]]
    if (length(m) < 2) return(NULL)
    ids <- regmatches(m[2], gregexpr("[0-9]+", m[2]))[[1]]
    if (identical(m[2], "integer(0)")) ids <- character(0)
    as.integer(ids)
  }

  target <- ints_after("targetId", allow_vector = FALSE)
  if (!is.null(target) && length(target) == 1 && target == 0L) target <- NULL  # template placeholder
  outcomes <- ints_after("outcomeIds", allow_vector = TRUE) %||% integer(0)
  outcomes <- outcomes[outcomes != 0L]                                          # template placeholder
  hand <- ints_after("HAND_AUTHORED", allow_vector = TRUE) %||% integer(0)

  list(target_id = target, outcome_ids = outcomes, hand_authored = hand)
}

# -----------------------------------------------------------------------------
# resolve_consumer_dir
#
# A consumer repo is a sibling of this repo in the workspace unless repo_dir
# says otherwise. Study identity is taken from the configured name, never from
# a file path (see strategus-study-template conventions, section 11.2).
# -----------------------------------------------------------------------------
resolve_consumer_dir <- function(consumer, repo_root) {
  if (!is.null(consumer$repo_dir) && nzchar(consumer$repo_dir)) {
    d <- consumer$repo_dir
    if (!grepl("^(/|[A-Za-z]:)", d)) d <- file.path(repo_root, d)
    return(normalizePath(d, winslash = "/", mustWork = FALSE))
  }
  normalizePath(file.path(repo_root, "..", consumer$study), winslash = "/", mustWork = FALSE)
}

# -----------------------------------------------------------------------------
# read_consumer_manifest
#
# Reads a consumer's cohort manifest (inst/Cohorts.csv) without touching its
# cohort definitions: data.frame(cohortId, cohortName). Rows with cohort_id 0 are
# the template's example row and are skipped.
# -----------------------------------------------------------------------------
read_consumer_manifest <- function(consumer_dir, consumer) {
  manifest_path <- file.path(consumer_dir, consumer$cohorts_manifest)
  if (!file.exists(manifest_path)) stop("cohort manifest not found: ", manifest_path)
  manifest <- read.csv(manifest_path, stringsAsFactors = FALSE)
  names(manifest) <- SqlRender::snakeCaseToCamelCase(names(manifest))
  if (!all(c("cohortId", "cohortName") %in% names(manifest))) {
    stop(manifest_path, " needs cohort_id and cohort_name columns")
  }
  manifest <- manifest[manifest$cohortId != 0, , drop = FALSE]
  if (nrow(manifest) == 0) stop(manifest_path, " lists no cohorts")
  if (anyDuplicated(manifest$cohortId)) stop("duplicate cohort_id in ", manifest_path)
  manifest$cohortId <- as.integer(manifest$cohortId)
  manifest[, c("cohortId", "cohortName")]
}

# -----------------------------------------------------------------------------
# inspect_consumers   (no database, no Java)
#
# What the dataset and the Synthea module must cover: each consumer's cohorts and
# their roles, plus anything that would stop the QC from running (repo not
# cloned, manifest or cohort JSON missing, target/outcome ids unresolvable).
# Used by workflow/02 to print the requirements before the module is built.
#
# @return list(manifest = data.frame(consumer, cohort_id, cohort_name, role,
#         expected_empty), problems = character, hints = character)
#         `hints` are advisory (e.g. a consumer reads discharge disposition but has not
#         opted in to discharge_disposition_check).
# -----------------------------------------------------------------------------
inspect_consumers <- function(consumers, repo_root = getwd()) {
  rows <- list(); problems <- character(0); hints <- character(0)
  for (co in consumers) {
    dir <- resolve_consumer_dir(co, repo_root)
    if (!dir.exists(dir)) {
      problems <- c(problems, paste0(co$study, ": repository not found at ", dir)); next
    }
    spec <- parse_spec_roles(file.path(dir, co$spec_script))
    target <- co$target_id %||% spec$target_id
    outcomes <- if (length(co$outcome_ids)) co$outcome_ids else spec$outcome_ids
    if (is.null(target) || length(outcomes) == 0) {
      problems <- c(problems, paste0(co$study, ": could not determine target and outcome ids from ",
                                     co$spec_script, "; set target_id and outcome_ids in consumers.yaml"))
    }
    manifest <- tryCatch(read_consumer_manifest(dir, co), error = function(e) {
      problems <<- c(problems, paste0(co$study, ": ", conditionMessage(e))); NULL })
    if (is.null(manifest)) next
    no_json <- manifest$cohortId[!file.exists(file.path(dir, co$cohorts_json_dir, paste0(manifest$cohortId, ".json")))]
    if (length(no_json)) problems <- c(problems, paste0(co$study, ": missing cohort JSON for id(s) ",
                                                         paste(no_json, collapse = ", ")))
    dd <- detect_discharge_dependence(dir, co, manifest$cohortId)
    if (length(dd) && !isTRUE(co$discharge_disposition_check)) {
      hints <- c(hints, paste0(co$study, ": cohort(s) ", paste(dd, collapse = ", "),
        " read discharge disposition (discharged_to_*) in their SQL, but discharge_disposition_check is not set. ",
        "Set it to true in consumers.yaml so the synthetic data is checked for discharge dispositions."))
    }
    role <- ifelse(!is.null(target) & manifest$cohortId %in% target, "target",
            ifelse(manifest$cohortId %in% outcomes, "outcome", "covariate"))
    rows[[length(rows) + 1L]] <- data.frame(
      consumer = co$study, cohort_id = manifest$cohortId, cohort_name = manifest$cohortName,
      role = role, expected_empty = manifest$cohortId %in% co$expected_empty,
      stringsAsFactors = FALSE)
  }
  list(manifest = if (length(rows)) do.call(rbind, rows) else NULL, problems = problems, hints = hints)
}

# -----------------------------------------------------------------------------
# load_consumer_cohorts
#
# Builds the cohort definition set for one consumer: cohortId, cohortName,
# json, sql. SQL is rendered from the JSON with CirceR the way Strategus does
# (generateStats = FALSE: membership is identical and no inclusion-statistics
# tables are needed for QC). Manifest rows with cohort_id 0 are the template's
# example row and are skipped.
# -----------------------------------------------------------------------------
load_consumer_cohorts <- function(consumer_dir, consumer) {
  manifest <- read_consumer_manifest(consumer_dir, consumer)
  json_dir <- file.path(consumer_dir, consumer$cohorts_json_dir)
  rows <- lapply(seq_len(nrow(manifest)), function(i) {
    cid <- as.integer(manifest$cohortId[i])
    json_path <- file.path(json_dir, paste0(cid, ".json"))
    if (!file.exists(json_path)) {
      stop("missing cohort JSON for id ", cid, ": ", json_path,
           "\n  Strategus runs the JSON, so every manifest row needs one.")
    }
    json <- paste(readLines(json_path, warn = FALSE), collapse = "\n")
    sql <- CirceR::buildCohortQuery(
      CirceR::cohortExpressionFromJson(json),
      options = CirceR::createGenerateOptions(generateStats = FALSE)
    )
    data.frame(cohortId = cid, cohortName = manifest$cohortName[i],
               json = json, sql = sql, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

# -----------------------------------------------------------------------------
# evaluate_consumer_results   (pure; no database)
#
# Turns subject counts into a PASS/FAIL table.
#
# @param consumer       normalised consumer entry (thresholds)
# @param cohort_names   named character vector: names = cohort ids
# @param roles          list(target_id, outcome_ids) -- all other ids are covariates
# @param subjects       named numeric: subjects per cohort id (missing = 0)
# @param overlap        named numeric: for outcome ids, subjects also in the target
# @param failed         named character: cohort id -> generation error message
# @param hand_authored  integer ids flagged as hand-authored in the spec script
# @return data.frame(consumer, cohort_id, cohort_name, role, subjects,
#         subjects_in_target, threshold, metric, status, note)
# -----------------------------------------------------------------------------
evaluate_consumer_results <- function(consumer, cohort_names, roles, subjects,
                                      overlap = numeric(0), failed = character(0),
                                      hand_authored = integer(0)) {
  ids <- as.integer(names(cohort_names))
  rows <- lapply(ids, function(id) {
    key <- as.character(id)
    role <- if (isTRUE(id == roles$target_id)) "target"
            else if (id %in% roles$outcome_ids) "outcome"
            else "covariate"
    n <- unname(subjects[key]); if (is.na(n)) n <- 0
    ov <- if (role == "outcome") { v <- unname(overlap[key]); if (is.na(v)) 0 else v } else NA_real_

    threshold <- switch(role, target = consumer$min_target_subjects,
                              outcome = consumer$min_outcome_subjects,
                              covariate = consumer$min_covariate_subjects)
    # A cohort the study knows is empty on synthetic data (e.g. an outcome Synthea
    # does not generate) has no minimum; it is reported, not failed.
    is_expected_empty <- id %in% consumer$expected_empty
    if (is_expected_empty) threshold <- 0
    value  <- if (role == "outcome") ov else n
    metric <- if (role == "outcome") "subjects_in_target" else "subjects"

    note <- character(0)
    status <- if (value >= threshold) "PASS" else "FAIL"
    if (key %in% names(failed)) {
      status <- "FAIL"; note <- c(note, paste0("generation failed: ", failed[[key]]))
    }
    if (is_expected_empty) {
      note <- c(note, paste0("expected empty on synthetic data (", value, " found)"))
    }
    if (id %in% hand_authored) {
      note <- c(note, "hand-authored: checked on the placeholder JSON Strategus will run")
    }
    data.frame(consumer = consumer$study, cohort_id = id,
               cohort_name = unname(cohort_names[key]), role = role,
               subjects = n, subjects_in_target = ov, threshold = threshold,
               metric = metric, status = status,
               note = paste(note, collapse = "; "), stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

# -----------------------------------------------------------------------------
# check_registry_agreement   (pure apart from reading YAML)
#
# consumers.yaml is what drives the QC; the workspace registry's `used_by` is
# the shared record. They must agree, or one of them is out of date. Returns a
# character vector of problems (empty when they agree or nothing to compare).
#
# `used_by` entries may be plain strings or maps with a `study_id`. The dataset's
# own producer (source_repo) is not a consumer and is ignored, as is any study
# named in `not_checked` (a retired study, or one that is not a Strategus repo).
# -----------------------------------------------------------------------------
check_registry_agreement <- function(dataset_id, studies, registry_path,
                                     not_checked = character(0)) {
  if (is.na(dataset_id) || !nzchar(dataset_id)) {
    return("consumers.yaml has no dataset_id, so it cannot be compared with synthetic_data/registry.yaml")
  }
  if (!file.exists(registry_path)) {
    return(paste0("registry not found at ", registry_path, "; agreement not checked"))
  }
  reg <- yaml::read_yaml(registry_path)
  hit <- Filter(function(d) identical(d$id, dataset_id), reg$datasets %||% list())
  if (length(hit) == 0) {
    return(paste0("dataset '", dataset_id, "' is not in ", registry_path))
  }
  entry_name <- function(u) if (is.list(u)) as.character(u$study_id %||% "") else as.character(u)
  used_by <- vapply(hit[[1]]$used_by %||% list(), entry_name, character(1))
  used_by <- setdiff(used_by, c(hit[[1]]$source_repo, not_checked, ""))
  problems <- character(0)
  for (s in setdiff(studies, used_by)) {
    problems <- c(problems, paste0("'", s, "' is in consumers.yaml but not in registry used_by for ", dataset_id))
  }
  for (s in setdiff(used_by, studies)) {
    problems <- c(problems, paste0("'", s, "' is in registry used_by for ", dataset_id, " but not in consumers.yaml (its cohorts are not being checked)"))
  }
  problems
}

# -----------------------------------------------------------------------------
# resolve_active_cdm_schema
#
# Mirrors resolve_cdm_schema() in scripts/quality_check_etl.R so both QC stages
# test the same schema: use `default_schema` if it holds person rows; otherwise
# the highest-numbered omop_synth_<study>_<n> schema that does (SQL Server).
# -----------------------------------------------------------------------------
resolve_active_cdm_schema <- function(connection, default_schema, study_name) {
  count_person <- function(schema) {
    tryCatch({
      sql <- SqlRender::translate(
        SqlRender::render("SELECT COUNT(*) AS n FROM @schema_name.person;", schema_name = schema),
        targetDialect = connection@dbms)
      as.numeric(DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)$n[[1]])
    }, error = function(e) 0)
  }
  if (count_person(default_schema) > 0) return(default_schema)

  base <- paste0("omop_synth_", study_name)
  rows <- DatabaseConnector::querySql(
    connection,
    paste0("SELECT name FROM sys.schemas WHERE name = '", gsub("'", "''", base),
           "' OR name LIKE '", gsub("'", "''", base), "[_]%';"),
    snakeCaseToCamelCase = TRUE)
  cands <- as.character(rows$name)
  suffix <- suppressWarnings(as.integer(sub(paste0("^", base, "_([0-9]+)$"), "\\1", cands)))
  for (cand in cands[order(ifelse(is.na(suffix), -1L, suffix), decreasing = TRUE)]) {
    if (count_person(cand) > 0) return(cand)
  }
  default_schema
}

# -----------------------------------------------------------------------------
# drop_scratch_tables
#
# Drops every table named in a CohortGenerator cohortTableNames list (cohort,
# inclusion/summary/censor stats, checksum, subset attrition). Failures are
# ignored: cleanup must never mask the QC result.
# -----------------------------------------------------------------------------
drop_scratch_tables <- function(connection, schema, table_names) {
  for (tbl in unique(unlist(table_names, use.names = FALSE))) {
    try(DatabaseConnector::executeSql(connection, SqlRender::translate(
      SqlRender::render("IF OBJECT_ID('@schema_name.@table_name', 'U') IS NOT NULL DROP TABLE @schema_name.@table_name;",
                        schema_name = schema, table_name = tbl),
      targetDialect = connection@dbms), progressBar = FALSE, reportOverallTime = FALSE),
      silent = TRUE)
  }
  invisible(NULL)
}

# -----------------------------------------------------------------------------
# detect_discharge_dependence   (no database)
#
# Finds cohorts of a consuming study whose own SQL reads discharge disposition
# (visit_occurrence.discharged_to_*). circe cannot express such a cohort, so these
# are hand-authored SQL files under inst/sql/sql_server/<id>.sql; a study whose
# outcome or target is "non-home discharge" depends on the synthetic data actually
# carrying discharge dispositions. Used to warn when a consumer relies on them but
# has not opted in to discharge_disposition_check.
#
# @return integer vector of cohort ids whose SQL references discharged_to_*
# -----------------------------------------------------------------------------
detect_discharge_dependence <- function(consumer_dir, consumer, cohort_ids) {
  hits <- integer(0)
  sql_dir <- file.path(consumer_dir, "inst", "sql", "sql_server")
  for (id in cohort_ids) {
    f <- file.path(sql_dir, paste0(id, ".sql"))
    if (file.exists(f) && any(grepl("discharged_to", readLines(f, warn = FALSE), ignore.case = TRUE))) {
      hits <- c(hits, as.integer(id))
    }
  }
  hits
}

# -----------------------------------------------------------------------------
# check_discharge_disposition
#
# Opt-in check (consumers.yaml: discharge_disposition_check: true) for any
# synthetic dataset used by an analysis that depends on discharge disposition.
# The consumer cohort QC cannot see this: a discharge-disposition cohort is
# hand-authored SQL, and Strategus runs only its placeholder JSON, so the cohort
# check passes even when the dataset carries no dispositions at all.
#
# It reads visit_occurrence in the CDM and verifies that:
#   - discharge dispositions were loaded       (discharged_to_source_value populated)
#   - they were mapped to OMOP concepts        (discharged_to_concept_id non-zero)
#   - home discharge is present                (NUBC 01, the reference category)
#   - non-home discharge is present            (any other NUBC code)
#
# @param connection   DatabaseConnector connection (read-only use)
# @param cdm_schema   schema holding the synthetic CDM (qualified if needed)
# @param consumer     normalised consumer entry (thresholds)
# @return data.frame(consumer, check, value, threshold, status, note)
# -----------------------------------------------------------------------------
check_discharge_disposition <- function(connection, cdm_schema, consumer) {
  sql <- SqlRender::translate(SqlRender::render(
    "SELECT COUNT(*) AS visits_total,
            SUM(CASE WHEN discharged_to_source_value IS NOT NULL THEN 1 ELSE 0 END) AS visits_with_source,
            SUM(CASE WHEN discharged_to_source_value IS NOT NULL
                      AND discharged_to_concept_id IS NOT NULL
                      AND discharged_to_concept_id <> 0 THEN 1 ELSE 0 END) AS visits_mapped,
            SUM(CASE WHEN LTRIM(RTRIM(discharged_to_source_value)) = '01' THEN 1 ELSE 0 END) AS home_visits,
            SUM(CASE WHEN discharged_to_source_value IS NOT NULL
                      AND LTRIM(RTRIM(discharged_to_source_value)) <> '01' THEN 1 ELSE 0 END) AS non_home_visits
     FROM @cdm_schema.visit_occurrence;", cdm_schema = cdm_schema),
    targetDialect = connection@dbms)
  r <- DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)
  num <- function(x) { v <- suppressWarnings(as.numeric(x)); if (length(v) == 0 || is.na(v)) 0 else v }
  with_source <- num(r$visitsWithSource); mapped <- num(r$visitsMapped)
  mapped_pct <- if (with_source > 0) 100 * mapped / with_source else 0

  row <- function(check, value, threshold, note)
    data.frame(consumer = consumer$study, check = check, value = value, threshold = threshold,
               status = if (value >= threshold) "PASS" else "FAIL", note = note, stringsAsFactors = FALSE)
  rbind(
    row("discharge_dispositions_present", with_source, consumer$min_discharge_visits,
        paste0("visits with discharged_to_source_value, of ", num(r$visitsTotal), " visits")),
    row("discharge_codes_mapped_pct", round(mapped_pct, 1), consumer$min_discharge_mapped_pct,
        "% of those visits with a non-zero discharged_to_concept_id"),
    row("home_discharge_present", num(r$homeVisits), 1, "visits with NUBC 01 (home), the reference category"),
    row("non_home_discharge_present", num(r$nonHomeVisits), consumer$min_non_home_visits,
        "visits with any other NUBC code")
  )
}

# -----------------------------------------------------------------------------
# qualify_schema
#
# On SQL Server, DatabaseConnector (which CohortGenerator uses to list tables)
# reads a single-part schema name as a DATABASE name, so cohort and CDM schemas
# must be given as <database>.<schema> (the same rule as the Strategus
# conventions, section 4). Schemas that already contain a dot are left alone, and
# so is everything when `database` is NULL (e.g. SQLite in the tests).
# -----------------------------------------------------------------------------
qualify_schema <- function(schema, database = NULL) {
  if (is.null(database) || !nzchar(database) || grepl(".", schema, fixed = TRUE)) return(schema)
  paste0(database, ".", schema)
}

# -----------------------------------------------------------------------------
# run_consumer_cohort_qc
#
# Runs the QC for every consumer against one CDM schema.
#
# Every per-consumer failure, including an unexpected error from SQL, is caught
# and reported in `problems`, and the scratch tables are always dropped.
# (Under Rscript an uncaught error does NOT unwind `finally`/`on.exit`, so
# relying on those alone would leave scratch tables behind.)
#
# @param connection_details  DatabaseConnector connectionDetails
# @param cdm_schema          schema holding the synthetic CDM (read only)
# @param results_schema      schema for scratch cohort tables (must exist)
# @param consumers           the `consumers` list from read_consumers()
# @param repo_root           root of this -synth repo (siblings resolve from it)
# @param database            database name; qualifies the two schemas above as
#                            <database>.<schema> (needed on SQL Server)
# @return list(results = data.frame, discharge = data.frame (opt-in discharge-disposition
#         check rows, or NULL), problems = character): `problems` holds
#         consumers that could not be checked at all (repo missing, no usable
#         roles, JSON missing, SQL error); each is a hard failure under
#         --enforce_thresholds.
# -----------------------------------------------------------------------------
run_consumer_cohort_qc <- function(connection_details, cdm_schema, results_schema,
                                   consumers, repo_root = getwd(), database = NULL) {
  cdm_schema     <- qualify_schema(cdm_schema, database)
  results_schema <- qualify_schema(results_schema, database)

  connection <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
  dbms <- connection@dbms

  all_results <- list()
  discharge <- list()
  problems <- character(0)
  add_problem <- function(study, msg) problems <<- c(problems, paste0(study, ": ", msg))

  for (co in consumers) {
    dir <- resolve_consumer_dir(co, repo_root)
    if (!dir.exists(dir)) {
      add_problem(co$study, paste0("repository not found at ", dir,
                                   " (clone it into the workspace, or set repo_dir)"))
      next
    }

    # Opt-in: for a study whose analysis depends on discharge disposition. Run first
    # so a problem with the study's cohorts cannot hide it.
    if (isTRUE(co$discharge_disposition_check)) {
      discharge[[co$study]] <- tryCatch(check_discharge_disposition(connection, cdm_schema, co),
        error = function(e) { add_problem(co$study, paste0("discharge-disposition check failed: ", conditionMessage(e))); NULL })
    }

    spec <- parse_spec_roles(file.path(dir, co$spec_script))
    roles <- list(target_id = co$target_id %||% spec$target_id,
                  outcome_ids = if (length(co$outcome_ids)) co$outcome_ids else spec$outcome_ids)
    if (is.null(roles$target_id) || length(roles$outcome_ids) == 0) {
      add_problem(co$study, paste0("could not determine target and outcome cohort ids from ",
                                   co$spec_script, "; set target_id and outcome_ids in consumers.yaml"))
      next
    }

    cohorts <- tryCatch(load_consumer_cohorts(dir, co), error = function(e) {
      add_problem(co$study, conditionMessage(e)); NULL })
    if (is.null(cohorts)) next
    missing_roles <- setdiff(c(roles$target_id, roles$outcome_ids), cohorts$cohortId)
    if (length(missing_roles)) {
      add_problem(co$study, paste0("role cohort id(s) not in the manifest: ",
                                   paste(missing_roles, collapse = ", ")))
      next
    }

    slug <- gsub("[^a-z0-9]+", "_", tolower(co$study))
    table_names <- CohortGenerator::getCohortTableNames(cohortTable = paste0("qc_consumer_", slug))

    outcome <- tryCatch({
      CohortGenerator::createCohortTables(connection = connection, cohortDatabaseSchema = results_schema,
                                          cohortTableNames = table_names, incremental = FALSE)
      gen <- CohortGenerator::generateCohortSet(
        connection = connection, cdmDatabaseSchema = cdm_schema,
        cohortDatabaseSchema = results_schema, cohortTableNames = table_names,
        cohortDefinitionSet = cohorts, stopOnError = FALSE, incremental = FALSE)

      tbl <- paste0(results_schema, ".", table_names$cohortTable)
      counts <- DatabaseConnector::querySql(connection, SqlRender::translate(SqlRender::render(
        "SELECT cohort_definition_id, COUNT(DISTINCT subject_id) AS subjects
         FROM @tbl GROUP BY cohort_definition_id;", tbl = tbl), targetDialect = dbms),
        snakeCaseToCamelCase = TRUE)
      overlap <- DatabaseConnector::querySql(connection, SqlRender::translate(SqlRender::render(
        "SELECT o.cohort_definition_id AS cohort_definition_id,
                COUNT(DISTINCT o.subject_id) AS subjects
         FROM @tbl o
         INNER JOIN @tbl t ON t.subject_id = o.subject_id AND t.cohort_definition_id = @tid
         WHERE o.cohort_definition_id IN (@oids)
         GROUP BY o.cohort_definition_id;",
        tbl = tbl, tid = roles$target_id, oids = roles$outcome_ids), targetDialect = dbms),
        snakeCaseToCamelCase = TRUE)

      failed_rows <- gen[gen$generationStatus == "FAILED", , drop = FALSE]
      list(counts = counts, overlap = overlap, failed_rows = failed_rows)
    }, error = function(e) {
      add_problem(co$study, paste0("QC query failed: ", conditionMessage(e)))
      NULL
    }, finally = {
      # CohortGenerator also creates checksum and subset-attrition tables that
      # dropCohortStatsTables() leaves behind, so drop every scratch table.
      drop_scratch_tables(connection, results_schema, table_names)
    })
    if (is.null(outcome)) next

    named <- function(df, col) setNames(as.numeric(df[[col]]), as.character(df$cohortDefinitionId))
    failed <- if (nrow(outcome$failed_rows)) {
      setNames(as.character(outcome$failed_rows$generationStatus), as.character(outcome$failed_rows$cohortId))
    } else character(0)

    all_results[[co$study]] <- evaluate_consumer_results(
      consumer = co,
      cohort_names = setNames(cohorts$cohortName, as.character(cohorts$cohortId)),
      roles = roles,
      subjects = named(outcome$counts, "subjects"),
      overlap = if (nrow(outcome$overlap)) named(outcome$overlap, "subjects") else numeric(0),
      failed = failed,
      hand_authored = spec$hand_authored)
  }

  list(results = if (length(all_results)) do.call(rbind, unname(all_results)) else NULL,
       discharge = if (length(discharge)) do.call(rbind, unname(discharge)) else NULL,
       problems = problems)
}
