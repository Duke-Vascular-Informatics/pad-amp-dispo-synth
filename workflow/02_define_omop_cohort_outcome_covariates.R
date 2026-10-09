#!/usr/bin/env Rscript
# =============================================================================
# workflow/02_define_omop_cohort_outcome_covariates.R
#
# Step 2: Declare and validate WHAT this synthetic dataset must support.
#
# PURPOSE
# -------
# A -synth repo does not define cohorts, outcomes or covariates of its own. What
# the dataset must contain is defined by the studies that will use it, listed in
# consumers.yaml, and their cohort definitions (inst/Cohorts.csv and
# inst/cohorts/*.json in each Strategus repo) are read directly, so nothing is
# copied here and nothing can drift out of sync.
#
# This step reads consumers.yaml and prints, for every consuming study, the
# cohorts the Synthea module must be able to produce and the final data must
# contain, by role:
#   target     - the study's one target cohort
#   outcome    - its outcome cohorts
#   covariate  - every other cohort in its Cohorts.csv (Strategus treats the
#                remaining cohorts as covariate cohorts)
# and reports anything that would stop the later checks from running (a study
# repo that is not cloned, a missing manifest or cohort JSON, a target or outcome
# id that cannot be resolved).
#
# It does NOT connect to a database. The later steps use the same list:
#   workflow/03  checks the Synthea module can produce these cohorts
#                (scripts/module_coverage_check.R)
#   workflow/06  checks the final data contains them
#                (scripts/consumer_cohort_qc.R)
#
# It also registers this repo in the workspace studies.yaml on first run.
# =============================================================================

# -----------------------------------------------------------------------------
# Chunk 1 - Workflow bootstrap
# -----------------------------------------------------------------------------
bootstrap_path <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    normalizePath(
      file.path(dirname(sub("^--file=", "", file_arg[1])), "workflow_bootstrap.R"),
      winslash = "/",
      mustWork = FALSE
    )
  } else {
    "workflow/workflow_bootstrap.R"
  }
})
source(bootstrap_path)
set_workflow_root()

# Read the repo settings (schemas, study name) from config.R, which reads
# study_params.yaml. Every later workflow step reads the same config.
source("config.R")
config <- get_validation_config()
source("R/consumer_qc.R")

# -----------------------------------------------------------------------------
# Chunk 2 - Read consumers.yaml
# -----------------------------------------------------------------------------
# consumers.yaml ships with the template, so a missing file is a stop, not a
# warning. An empty list is only a warning: the dataset then has no downstream
# study to be checked against.
# -----------------------------------------------------------------------------
if (!file.exists("consumers.yaml")) {
  stop("consumers.yaml not found. It lists the Strategus studies that will use this ",
       "dataset and defines what the Synthea module and the final data must contain. ",
       "Restore it from the template and add your consuming studies.")
}
consumer_cfg <- read_consumers("consumers.yaml")

# -----------------------------------------------------------------------------
# Chunk 3 - What the module and the dataset must cover
# -----------------------------------------------------------------------------
# Problems are warnings, not stops: a consuming study may simply not be cloned
# into the workspace yet.
# -----------------------------------------------------------------------------
cat("=================================================================\n")
cat("Step 2: what this dataset must support (consumers.yaml)\n")
cat("=================================================================\n")
cat("Dataset id : ", consumer_cfg$dataset_id, "\n", sep = "")

if (length(consumer_cfg$consumers) == 0) {
  warning("[Step 2] consumers.yaml lists no consuming studies, so the Synthea module and the ",
          "final data are not checked against any study's cohorts. Add each Strategus study ",
          "that will use this dataset.", call. = FALSE)
} else {
  seen <- inspect_consumers(consumer_cfg$consumers, getwd())
  if (!is.null(seen$manifest)) {
    for (nm in unique(seen$manifest$consumer)) {
      m <- seen$manifest[seen$manifest$consumer == nm, , drop = FALSE]
      cat("\n", nm, ": ", sum(m$role == "target"), " target, ", sum(m$role == "outcome"),
          " outcome, ", sum(m$role == "covariate"), " covariate cohort(s)", "\n", sep = "")
      for (i in seq_len(nrow(m))) {
        cat(sprintf("  %-9s %-9s %s%s\n", m$role[i], m$cohort_id[i], m$cohort_name[i],
                    if (m$expected_empty[i]) "   (expected empty)" else ""))
      }
    }
  }
  for (p in seen$problems) warning("[Step 2] consumer: ", p, call. = FALSE)
  for (h in seen$hints)    warning("[Step 2] consumer: ", h, call. = FALSE)
}

cat("\nNext: design the Synthea module, then run workflow/03, which checks that the\n",
    "module can produce these cohorts before any data is generated.\n", sep = "")

# -----------------------------------------------------------------------------
# Chunk 4 - Study registry
# Purpose:
# - Register this study in the workspace-level studies.yaml index on first run.
# - Subsequent runs are idempotent: already-registered studies are skipped.
# - Fails gracefully when studies.yaml is absent (e.g., standalone repo outside
#   the standard workspace layout).
# Output:
# - Appends one YAML entry to <workspace_root>/studies.yaml.
# -----------------------------------------------------------------------------

# Workspace root is one level above the study repo root (standard layout).
workspace_root <- normalizePath(file.path(getwd(), ".."), mustWork = FALSE)
registry_path  <- file.path(workspace_root, "studies.yaml")

if (!file.exists(registry_path)) {
  message(
    "[Step 2] Study registry not found at: ", registry_path, "\n",
    "         Skipping auto-registration. To enable, create studies.yaml at\n",
    "         the workspace root using the template in synthea-omop-template."
  )
} else {
  study_dir <- basename(getwd())

  # Check for an existing entry by scanning raw text — avoids a hard yaml dep.
  # NOTE: entries are list items ("  - dir: <name>"), so the match must allow
  # for the "- " list marker between the leading whitespace and "dir:", and
  # must anchor on the line end so a prefix (e.g. "foo") can't match "foo-bar".
  registry_text <- paste(readLines(registry_path, warn = FALSE), collapse = "\n")
  already_registered <- grepl(
    paste0("(^|\\n)\\s*-\\s*dir:\\s+['\"]?", study_dir, "['\"]?\\s*(\\n|$)"),
    registry_text,
    perl = TRUE
  )

  if (already_registered) {
    message("[Step 2] Study already registered in studies.yaml: ", study_dir)
  } else {
    # Resolve GitHub remote slug (https://github.com/org/repo or git@github.com:org/repo).
    github_slug <- tryCatch({
      raw <- trimws(system("git remote get-url origin 2>/dev/null", intern = TRUE))
      raw <- sub("\\.git$", "", raw)
      raw <- sub("^https?://github\\.com/", "", raw)
      raw <- sub("^git@github\\.com:", "", raw)
      raw
    }, error = function(e) "")

    new_entry <- paste0(
      "\n  - dir: ", study_dir, "\n",
      "    github: ", github_slug, "\n",
      "    study_name: ", config$study_name, "\n",
      "    pipeline_role: synth\n",
      "    description: \"\"  # TODO [CONFIG]: add a one-line study description\n",
      "    registered: ", format(Sys.Date(), "%Y-%m-%d"), "\n"
    )

    cat(new_entry, file = registry_path, append = TRUE)
    message("[Step 2] Registered study in studies.yaml: ", study_dir,
            " (", registry_path, ")")
  }
}
