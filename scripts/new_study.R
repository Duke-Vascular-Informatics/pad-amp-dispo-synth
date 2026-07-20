#!/usr/bin/env Rscript
# =============================================================================
# scripts/new_study.R
# Initialize a fresh study_params.yaml for a new study.
#
# Usage (from project root):
#   Rscript scripts/new_study.R <study_name>
#
# Creates study_params.yaml pre-filled with the study name, or prints the
# command to copy the template if study_params.yaml already exists.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) {
  cat("Usage: Rscript scripts/new_study.R <study_name>\n")
  cat("  study_name: lowercase, underscores only (e.g. hip_replace_vte)\n")
  quit(status = 1L)
}

study_name <- args[1L]
if (!grepl("^[a-z][a-z0-9_]*$", study_name)) {
  stop("study_name must be lowercase letters, numbers, and underscores only (e.g. hip_replace_vte)")
}

dest <- file.path(getwd(), "study_params.yaml")
if (file.exists(dest)) {
  stop(
    "study_params.yaml already exists.\n",
    "  To start over: delete it and re-run this script.\n",
    "  To keep the current study: edit study_params.yaml directly."
  )
}

template <- file.path(getwd(), "study_params.yaml.example")
if (!file.exists(template)) {
  stop("study_params.yaml.example not found. Run from the project root directory.")
}

lines <- readLines(template, warn = FALSE)

# Pre-fill study_name with the supplied value.
# results_schema, cohort_table, and output_folder all auto-derive from study_name
# in config.R via .slugify(), so pre-filling output_folder here is redundant and
# would create a stale literal if study_name is later changed.
lines <- gsub('"my_study"', paste0('"', study_name, '"'), lines, fixed = TRUE)

writeLines(lines, dest)

message("Created study_params.yaml for study: ", study_name)

# =============================================================================
# Step 2: Create synthea-pad branch and register as a submodule.
#
# Branch name uses kebab-case (underscores → hyphens) to match the study repo
# naming convention used across the OHDSI PAD analysis portfolio.
# =============================================================================

study_branch <- gsub("_", "-", study_name)
synthea_url  <- "https://github.com/adam-mdmph/synthea-pad.git"
synthea_dir  <- file.path(getwd(), "external", "synthea")

message("")
message("Setting up synthea-pad submodule for branch: ", study_branch)

# Fork the new study branch from synthea-pad/main — the canonical dev-space
# trunk that incorporates validated improvements from all analysis branches.
# git submodule add requires the remote branch to exist before it is called,
# so we create it via the GitHub API (no full clone needed).
message("  Creating study branch '", study_branch, "' from synthea-pad/main ...")

base_sha_raw <- system2(
  "gh",
  c("api", "repos/adam-mdmph/synthea-pad/git/ref/heads/main",
    "--jq", ".object.sha"),
  stdout = TRUE, stderr = TRUE
)
if (!is.null(attr(base_sha_raw, "status")) && attr(base_sha_raw, "status") != 0)
  stop("Could not resolve synthea-pad/main SHA:\n", paste(base_sha_raw, collapse = "\n"))
base_sha <- trimws(paste(base_sha_raw, collapse = ""))

create_raw <- system2(
  "gh",
  c("api", "repos/adam-mdmph/synthea-pad/git/refs",
    "--method", "POST",
    "--field", paste0("ref=refs/heads/", study_branch),
    "--field", paste0("sha=", base_sha)),
  stdout = TRUE, stderr = TRUE
)
if (!is.null(attr(create_raw, "status")) && attr(create_raw, "status") != 0)
  stop("Branch creation failed:\n", paste(create_raw, collapse = "\n"))
message("  Branch '", study_branch, "' created from synthea-pad/main.")

# Register external/synthea as a submodule pinned to the new branch
message("  Registering external/synthea as submodule ...")
ret <- system2("git", c("submodule", "add", "-b", study_branch, synthea_url, synthea_dir),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git submodule add failed:\n", paste(ret, collapse = "\n"))
}

ret <- system2("git", c("submodule", "update", "--init", synthea_dir),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git submodule update failed:\n", paste(ret, collapse = "\n"))
}

ret <- system2("git", c("add", ".gitmodules", "external/synthea"),
               stdout = TRUE, stderr = TRUE)
ret <- system2("git",
               c("commit", "-m",
                 paste0("chore: add synthea-pad submodule (", study_branch, " branch)")),
               stdout = TRUE, stderr = TRUE)

message("  Submodule registered and committed.")
message("")
message("Next steps:")
message("  1. Edit study_params.yaml — fill in every TODO item")
message("  2. Rscript scripts/find_todos.R            — check remaining placeholders")
message("  3. Add study-specific Synthea modules to:")
message("       external/synthea/src/main/resources/modules/")
message("     then commit and push:")
message("       cd external/synthea")
message("       git add . && git commit -m 'feat: add modules for ", study_name, "'")
message("       git push origin ", study_branch)
message("       cd ../..")
message("       git add external/synthea && git commit -m 'chore: update synthea-pad submodule'")
message("  4. Rscript workflow/02_define_omop_cohort_outcome_covariates.R  — validate")
message("  5. Edit covariates/covariates.csv and covariates/covariate_concepts.csv")
message("  6. Rscript workflow/08_run_analysis_and_manuscript_report.R")
