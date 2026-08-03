#!/usr/bin/env Rscript
# Step 3: Validate and regenerate Synthea module artifacts (diagram and readiness checks).
#
# PURPOSE
# -------
# Auto-detects and validates the study Synthea GMF module (any .json in synthea/modules/
# other than study_template.json) and
# regenerates the HTML state-diagram viewer. The HTML file is the primary artefact
# for SME review — open it in any browser to inspect every state, its type, and its
# clinical codes before data generation is finalised.
#
# CLINICAL SME REVIEW WORKFLOW
# -----------------------------
# The JSON module encodes both the simulation logic and all clinical code assignments.
# Reviewers should work through the following questions with a clinical SME before
# data generation is finalised:
#
#   1. STATE FLOW
#      - Does the clinical pathway (eligibility → exposure condition → comorbidities
#        → treatment strategy → index procedure → observation window → outcome) reflect
#        real clinical practice for this study?
#      - Are the branching probabilities for each Covariate_N_Check state (default 30%)
#        replaced with literature-derived or institutional prevalence estimates?
#      - Is the Treatment_Strategy oversampling proportion (default 90% exposed) justified
#        by the study's outcome enrichment requirements? Document the real-world proportion.
#      - Does the Outcome_Assessment probability (default 20%) reflect the expected
#        incidence of the outcome in the target population?
#
#   2. CONDITION / PROCEDURE CODES
#      - Exposure_Condition_Onset  : SNOMED-CT REPLACE_ME  — qualifying condition
#      - Covariate_1_Onset        : SNOMED-CT REPLACE_ME  — covariate_1 (condition domain)
#      - Covariate_2_Onset        : SNOMED-CT REPLACE_ME  — covariate_2 (procedure domain)
#      - Covariate_3_Onset        : SNOMED-CT REPLACE_ME  — covariate_3 (drug domain)
#      - Covariate_4_Onset        : SNOMED-CT REPLACE_ME  — covariate_4
#      - Index_Procedure          : SNOMED-CT REPLACE_ME  — index procedure
#      - Outcome_Onset            : SNOMED-CT REPLACE_ME  — study outcome
#      - Outcome_Management       : SNOMED-CT REPLACE_ME  — outcome treatment
#      All REPLACE_ME tokens must be replaced with verified concept codes from a
#      live [vocab query] before this step passes the readiness check (see Chunk 6).
#      Run: Rscript scripts/concept_lookup.R "<term>" <Domain>
#
#   3. ENCOUNTER CODES
#      - Index_Diagnosis_Encounter : SNOMED-CT REPLACE_ME  — outpatient evaluation
#      - Index_Admission_Encounter : SNOMED-CT REPLACE_ME  — inpatient admission
#      - Outcome_Encounter         : SNOMED-CT REPLACE_ME  — outcome encounter
#      Confirm encounter codes map to the visit_concept_ids used in target_surgery.sql
#      and study_params.yaml > target > visit_concept_ids.
#
#   4. COVARIATE ALIGNMENT
#      - Confirm each Covariate_N_Onset concept code matches concept_id in
#        covariates/covariate_concepts.csv for the corresponding covariate_N row.
#      - Confirm Covariate_2_Onset type is 'Procedure' if domain = 'procedure'.
#      - Confirm Covariate_3_Onset type is 'MedicationOrder' if domain = 'drug'.
#      - Confirm covariate_4 has a row in covariates/covariates.csv.
#
#   5. TIMING PARAMETERS
#      - Pre_Index_Workup_Delay: does the range match the typical time from
#        diagnosis to procedure in your study population?
#      - Post_Discharge_Observation_Delay: does the range align with
#        prediction_window_days in study_params.yaml?
#      - Post_Index_Inpatient_Delay: is the inpatient stay duration realistic?
#
# HOW TO REVISE
# -------------
#   1. Edit synthea/modules/study_template.json (state types, codes, probabilities,
#      timing ranges) based on SME feedback.
#   2. Re-run this step to regenerate the diagram:
#        Rscript workflow/03_generate_synthea_module_artifacts.R
#   3. Open synthea/modules/study_template.diagram.html in a browser to review.
#   4. Repeat until the SME signs off on the module.
#   5. Proceed to Step 4 (generate Synthea CSV) only after sign-off and after the
#      REPLACE_ME readiness check below reports 0 remaining placeholders.

# -----------------------------------------------------------------------------
# Chunk 1 - Workflow bootstrap
# Purpose:
# Resolve and source the shared workflow bootstrap helper, then normalize the
# working directory to the repository root.
# Code path notes:
# - If script is executed via Rscript, parse --file= to resolve helper path.
# - If sourced interactively, fall back to project-relative helper path.
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

# -----------------------------------------------------------------------------
# Chunk 2 - Dependency guard for jsonlite
# Purpose:
# Ensure the JSON parser package is present before attempting to read the module
# artifact. This is a hard stop because all downstream logic depends on it.
# Code path notes:
# - Success: continue.
# - Failure: stop immediately with install guidance.
# -----------------------------------------------------------------------------
if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install via renv first.")
}

# -----------------------------------------------------------------------------
# Chunk 3 - Module artifact existence and structural checks
# Purpose:
# Validate the core input artifact and confirm the expected Synthea structure.
# Code path notes:
# - Missing file: stop with path-specific error.
# - Empty / malformed states collection: stop (cannot run coverage checks).
# - Valid structure: proceed to concept coverage evaluation.
# -----------------------------------------------------------------------------
# Auto-detect the study module JSON: scan synthea/modules/ for any .json file
# that is not the placeholder study_template.json.  This lets researchers drop
# their module file in without editing this script.
module_candidates <- list.files("synthea/modules", pattern = "\\.json$", full.names = TRUE)
module_candidates <- module_candidates[basename(module_candidates) != "study_template.json"]

if (length(module_candidates) == 0L) {
  stop(
    "No study module JSON found in synthea/modules/. ",
    "Copy your Synthea GMF module file there (e.g. synthea/modules/my_study.json) ",
    "then re-run Step 3."
  )
}
if (length(module_candidates) > 1L) {
  warning(
    "Multiple study module JSON files found in synthea/modules/; using the first: ",
    module_candidates[1],
    call. = FALSE
  )
}
module_path <- module_candidates[1]

if (!file.exists(module_path)) {
  stop("Module file not found after detection: ", module_path)
}

module <- jsonlite::fromJSON(module_path, simplifyVector = FALSE)
if (is.null(module$states) || length(module$states) == 0) {
  stop("Synthea module has no states: ", module_path)
}

# -----------------------------------------------------------------------------
# Chunk 3b - Sync module JSON into Synthea checkout modules folder
# Purpose:
# Ensure the validated module JSON is copied into the Synthea runtime module
# directory so downstream CSV generation can execute against the latest module.
# Code path notes:
# - Preferred destination is the user's explicit local Synthea checkout path.
# - If unavailable, fall back to SYNTHEA_HOME and then repo-local external/synthea.
# - If no valid modules directory is found, fail fast with guidance.
# -----------------------------------------------------------------------------
modules_dir_candidates <- c(
  "C:/Users/rapiduser/source/repos/synthea/src/main/resources/modules",
  if (nzchar(Sys.getenv("SYNTHEA_HOME"))) {
    file.path(Sys.getenv("SYNTHEA_HOME"), "src", "main", "resources", "modules")
  },
  "external/synthea/src/main/resources/modules"
)
modules_dir_candidates <- unique(modules_dir_candidates)
modules_dir_candidates <- modules_dir_candidates[nzchar(modules_dir_candidates)]

target_modules_dir <- NA_character_
for (candidate in modules_dir_candidates) {
  if (dir.exists(candidate)) {
    target_modules_dir <- normalizePath(candidate, winslash = "/", mustWork = TRUE)
    break
  }
}

if (is.na(target_modules_dir)) {
  # Degrade to a warning rather than stop() — the module validation checks
  # (concept coverage, state structure) above still ran and are useful even
  # when the local Synthea checkout is absent.  Step 4 (CSV generation) will
  # catch the missing runtime when it actually needs it.
  warning(
    "Could not find a Synthea modules directory. Checked: ",
    paste(modules_dir_candidates, collapse = ", "),
    ". Module will NOT be copied to the runtime. ",
    "Run: git submodule update --init external/synthea  before Step 4.",
    call. = FALSE
  )
  cat("[SKIP] Synthea module copy skipped — no runtime directory found.\n")
} else {

target_module_path <- file.path(target_modules_dir, basename(module_path))

# ---------------------------------------------------------------------------
# Prune modules this repo synced under a DIFFERENT name on an earlier run.
#
# Why this exists: Step 4 runs `./run_synthea` with no -m module filter, so
# Synthea loads and executes EVERY .json in this directory. The removal below
# only deletes the file matching the current basename, so a module renamed
# between runs left its old copy behind and Synthea silently ran both. That
# actually happened here: the 2026-07-20 generation ran both pad_amp_ed.json
# and a pre-split pad_amp_ed_desc.json, each emitting the same index
# amputation procedure (SNOMED 88312006), so patients could be processed by
# two overlapping amputation pathways. Discovered 2026-07-31 during the
# pad-amp-dispo rename.
#
# The manifest records exactly what this repo put here, so pruning can never
# touch a stock Synthea module (85 of them ship in the checkout) — only files
# we wrote ourselves on a previous run.
# ---------------------------------------------------------------------------
sync_manifest_path <- file.path(target_modules_dir, ".synced_by_this_repo")
if (file.exists(sync_manifest_path)) {
  previously_synced <- readLines(sync_manifest_path, warn = FALSE)
  previously_synced <- previously_synced[nzchar(previously_synced)]
  stale <- setdiff(previously_synced, basename(module_path))
  for (stale_name in stale) {
    stale_path <- file.path(target_modules_dir, stale_name)
    if (file.exists(stale_path)) {
      if (!file.remove(stale_path)) {
        stop("Failed to remove stale synced module: ", stale_path)
      }
      cat("[PRUNE] Removed stale module synced under a former name: ",
          stale_name, "\n", sep = "")
    }
  }
}

# Replace prior version explicitly to avoid any ambiguity about which file is
# active in the Synthea checkout.
if (file.exists(target_module_path)) {
  removed <- file.remove(target_module_path)
  if (!removed) {
    stop("Failed to remove existing module file before copy: ", target_module_path)
  }
}

copy_ok <- file.copy(module_path, target_module_path, overwrite = FALSE)
if (!copy_ok) {
  stop("Failed to copy module JSON to Synthea modules folder: ", target_module_path)
}

if (!file.exists(target_module_path)) {
  stop("Module copy reported success but destination file is missing: ", target_module_path)
}

src_size <- file.info(module_path)$size
dst_size <- file.info(target_module_path)$size
if (!identical(src_size, dst_size)) {
  stop(
    "Module copy verification failed (size mismatch). Source bytes=", src_size,
    ", destination bytes=", dst_size,
    ". Destination: ", target_module_path
  )
}

writeLines(basename(module_path), sync_manifest_path)

cat("Synthea module synced to: ", target_module_path, "\n", sep = "")

# Backstop for modules synced before the manifest existed (or by a sibling repo).
# Workspace-authored modules open their remarks with the "SYNTHEA MODULE —"
# header convention; none of the 85 stock Synthea modules contain that string,
# so it discriminates cleanly. Stock modules are never flagged.
other_modules <- setdiff(
  list.files(target_modules_dir, pattern = "\\.json$"),
  basename(module_path)
)
foreign_custom <- Filter(function(f) {
  any(grepl("SYNTHEA MODULE",
            readLines(file.path(target_modules_dir, f), warn = FALSE),
            fixed = TRUE))
}, other_modules)
if (length(foreign_custom) > 0) {
  stop(
    "Workspace-authored module(s) left in the Synthea runtime directory: ",
    paste(foreign_custom, collapse = ", "), ".\n",
    "  Step 4 runs Synthea with no -m filter, so these WILL also execute and ",
    "contaminate the generated cohort.\n",
    "  Remove them from ", target_modules_dir, " before running Step 4."
  )
}

} # end else (target_modules_dir found)

# ---------------------------------------------------------------------------
# REPLACE_ME READINESS CHECK
# ---------------------------------------------------------------------------
# Scan all concept codes in the module JSON for remaining REPLACE_ME placeholder
# tokens. Every REPLACE_ME must be replaced with a verified concept code from a
# live [vocab query] before synthetic data generation (Step 4) is run.
#
# Failures are printed as warnings so the script still completes (allowing the
# HTML to be generated for SME review), but a count of remaining placeholders is
# reported so nothing is silently skipped.

# -----------------------------------------------------------------------------
# Chunk 4 - Helper: collect all coded entries from Synthea states
# Purpose:
# Traverse every state and gather all (system, code, display) triples from:
# - state-level codes[] arrays
# - Observation value_code payloads
# Code path notes:
# - Duplicates are collapsed with unique() before placeholder checks.
# - Missing code or system fields are skipped safely.
# -----------------------------------------------------------------------------
collect_module_codes <- function(states) {
  found <- data.frame(state = character(), system = character(),
                      code = character(), display = character(),
                      stringsAsFactors = FALSE)
  for (state_name in names(states)) {
    st <- states[[state_name]]
    if (!is.null(st$codes)) {
      for (cd in st$codes) {
        if (!is.null(cd$system) && !is.null(cd$code)) {
          found <- rbind(found, data.frame(
            state   = state_name,
            system  = cd$system,
            code    = as.character(cd$code),
            display = if (!is.null(cd$display)) cd$display else "",
            stringsAsFactors = FALSE
          ))
        }
      }
    }
    if (!is.null(st$value_code)) {
      vc <- st$value_code
      if (!is.null(vc$system) && !is.null(vc$code)) {
        found <- rbind(found, data.frame(
          state   = state_name,
          system  = vc$system,
          code    = as.character(vc$code),
          display = if (!is.null(vc$display)) vc$display else "",
          stringsAsFactors = FALSE
        ))
      }
    }
  }
  unique(found)
}

module_codes <- collect_module_codes(module$states)

# -----------------------------------------------------------------------------
# Chunk 5 - REPLACE_ME placeholder scan
# Purpose:
# Identify any concept codes still set to the REPLACE_ME sentinel value.
# Each hit is a state whose clinical concept has not yet been verified against
# the live omop_vocab schema. See CLAUDE.md Rule 1 for the vocabulary workflow.
# Code path notes:
# - REPLACE_ME in code field: primary placeholder indicator.
# - Warnings are non-fatal so HTML diagram still generates for SME review.
# -----------------------------------------------------------------------------
placeholder_rows <- module_codes[module_codes$code == "REPLACE_ME", ]
n_placeholders <- nrow(placeholder_rows)

if (n_placeholders > 0L) {
  for (i in seq_len(n_placeholders)) {
    warning(sprintf(
      "[REPLACE_ME] State '%s': code is still REPLACE_ME. Display: '%s'.\n  Resolve with: Rscript scripts/concept_lookup.R \"<term>\" <Domain>",
      placeholder_rows$state[i],
      placeholder_rows$display[i]
    ), call. = FALSE)
  }
}

# -----------------------------------------------------------------------------
# Chunk 6 - Readiness summary
# Purpose:
# Provide a concise pass/fail summary after placeholder scan completes.
# Code path notes:
# - n_placeholders == 0: all concepts resolved; safe to proceed to Step 4.
# - n_placeholders > 0: remaining placeholders must be resolved first.
# -----------------------------------------------------------------------------
if (n_placeholders == 0L) {
  cat(sprintf(
    "Readiness check PASSED: no REPLACE_ME placeholders found in %d coded states.\n",
    nrow(module_codes)
  ))
} else {
  cat(sprintf(
    "Readiness check: %d REPLACE_ME placeholder(s) remain in module JSON.\n",
    n_placeholders
  ))
  cat("Resolve all placeholders before running Step 4 (Synthea data generation).\n")
  cat("See synthea/README.md Customisation checklist and CLAUDE.md Rule 1.\n")
}

# -----------------------------------------------------------------------------
# Chunk 8 - Diagram regeneration subprocess
# Purpose:
# Rebuild the HTML state-diagram artifact from the validated module JSON.
# Code path notes:
# - status == 0: generation succeeded; continue to completion message.
# - status != 0: hard stop because downstream SME review artifact is missing.
# -----------------------------------------------------------------------------
# Regenerate the HTML diagram viewer from the module JSON.
args <- c("scripts/synthea/generate_synthea_mermaid.R", module_path, sub("\\.json$", ".diagram.html", module_path))
rscript_bin <- if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
status <- system2(file.path(R.home("bin"), rscript_bin), args = args)
if (!identical(status, 0L)) {
  stop("Failed to generate Synthea diagram HTML.")
}

# -----------------------------------------------------------------------------
# Chunk 9 - Completion banner
# Purpose:
# Confirm that validation paths completed and the review artifact was generated.
# -----------------------------------------------------------------------------
cat("Step 3 complete: module validated and diagram HTML generated.\n")


