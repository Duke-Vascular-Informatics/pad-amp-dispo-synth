#!/usr/bin/env bash
# =============================================================================
# workflow/09_build_portable_analysis_bundle.sh
#
# Step 9 — Build and publish the protected analytic space portable analysis bundle.
#
# PURPOSE
# -------
# Packages the study's analysis into a self-contained bundle for execution on
# the protected analytic space (Phoenix protected analytic space), then pushes
# it to a Git remote so the site can clone or pull it directly.
#
# A dated zip is also written to dist/ as a local fallback (useful if GitLab
# is unreachable from HPC cluster or for offline transfers via scp).
#
# PREREQUISITES
# -------------
# Set the following variables in OMOP_Dev/.env (one level above this repo):
#
#   BUNDLE_GITLAB_REMOTE   Full SSH URL of the target GitLab repo.
#                          e.g. git@your.gitlab.instance:netid/study-bundle.git
#   BUNDLE_GIT_USER_NAME   Your name for git commits inside the bundle repo.
#   BUNDLE_GIT_USER_EMAIL  Your institutional email for git commits.
#
#   INST_OMOP_SERVER              SQL Server hostname for the institutional OMOP DB.
#   INST_OMOP_DATABASE            Database name.
#   INST_OMOP_SPN_HOST            Kerberos SPN hostname (often same as server).
#   INST_OMOP_VOCAB_SCHEMA        Vocabulary schema.
#   INST_OMOP_CDM_SCHEMA          CDM schema.
#   INST_OMOP_RESULTS_SCHEMA      Personal write schema (domain\netid).
#   INST_OMOP_CDM_DATABASE_ID     Short DB identifier for output files.
#   INST_OMOP_CDM_DATABASE_NAME   Human-readable DB name for output files.
#   INST_OMOP_CDM_DATABASE_DESCRIPTION  Description for output files.
#
# SSH authentication: the dev container must have access to an SSH agent with
# your Git remote SSH key loaded.  Docker Desktop on macOS forwards the host
# agent automatically when SSH_AUTH_SOCK is set in devcontainer.json.
# Verify with: ssh -T git@your.gitlab.instance
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   1. Syncs shared R source files from the main project into portable/$STUDY_NAME/
#      so the bundle always reflects the current analysis code.
#   2. Copies the MSSQL JDBC JAR from drivers/jdbc-runtime/ into the bundle.
#   3. Commits the updated bundle to the portable/$STUDY_NAME/.git repo and
#      pushes to the 'main' branch on your.gitlab.instance.
#   4. Builds a dated zip fallback in dist/ for offline transfers.
#
# FILES AUTO-SEEDED ON FIRST RUN (from setup/bundle_templates/, never overwritten)
# -------------------------------------------------------------------------
#   portable/$STUDY_NAME/setup_env.sh        Conda env + kinit setup (Step 1 of 2)
#   portable/$STUDY_NAME/install_r_packages.sh  R package installer wrapper (Step 2 of 2)
#   portable/$STUDY_NAME/install_packages.R  R package installer (called by above)
#   portable/$STUDY_NAME/run_analysis.sh     HPC launcher (sets LD_LIBRARY_PATH, sources .env)
#
# FILES NOT OVERWRITTEN (bundle-specific, must be committed manually)
# -------------------------------------------------------------------------
#   portable/$STUDY_NAME/config.R            HPC cluster SQL Server + conda paths
#   portable/$STUDY_NAME/run_analysis.R      HPC cluster entry-point R script
#   portable/$STUDY_NAME/R/connection.R      Kerberos / JVM setup for the protected analytic space
#
# DEPLOYMENT ON HPC cluster (after this script runs)
# -------------------------------------------
#   ssh <netid>@your.hpc.cluster.hostname
#   cd /path/to/your/workspace/
#   git clone --branch main git@your.gitlab.instance:<remote> <study-name>
#   # — or to pull updates into an existing clone: —
#   cd <study-name> && git pull origin main
#
#   # Place the HPC support team JDBC wrapper one level above the bundle:
#   #   /path/to/your/workspace/drivers/prcc-jdbc-mssql-1.0-SNAPSHOT.jar
#   bash setup_env.sh
#   conda activate openjdk
#   export KRB5CCNAME=FILE:~/krb5cc_java && kinit
#   Rscript run_analysis.R
# =============================================================================

# NOTE: pipefail is intentionally NOT set. This script parses study_params.yaml
# with many `grep pattern file | sed ...` chains where the grep legitimately
# finds zero matches for commented-out/optional YAML keys (e.g. `# cohort_table: ~`).
# Under pipefail, that zero-match grep exit status propagates and kills the
# whole pipeline even though every such chain already has a `[[ -z "$var" ]] &&
# var="default"` fallback immediately after. Each individual command below
# still respects `set -e` on its own exit status.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# SSH agent fallback for docker exec sessions.
# devcontainer.json mounts the macOS host agent at /ssh-agent and sets
# SSH_AUTH_SOCK=/ssh-agent via remoteEnv — but remoteEnv only applies to
# VS Code-launched terminals, not bare docker exec calls.  If SSH_AUTH_SOCK
# is unset (or points to a non-existent socket) and /ssh-agent is present,
# use it so the GitLab push succeeds from either context.
# ---------------------------------------------------------------------------
if [[ -z "${SSH_AUTH_SOCK:-}" || ! -S "${SSH_AUTH_SOCK}" ]] && [[ -S /ssh-agent ]]; then
  export SSH_AUTH_SOCK=/ssh-agent
fi

# ---------------------------------------------------------------------------
# Load HPC cluster config from .env files (two-pass: workspace then study)
#
# Pass 1 — workspace .env (OMOP_Dev/.env): shared INST_OMOP_* connection
#           details and default BUNDLE_* values.
# Pass 2 — per-study .env (REPO_ROOT/.env): study-specific overrides for
#           BUNDLE_GITLAB_REMOTE, BUNDLE_GIT_USER_*, INST_OMOP_* schemas,
#           and any other per-study keys.  Loaded second so it wins over
#           the workspace defaults.
#
# When run inside the dev container: vars are already injected by
# docker-compose; the per-study load still adds analysis-specific keys.
# ---------------------------------------------------------------------------
for ENV_FILE in "$REPO_ROOT/../.env" "$REPO_ROOT/.env"; do
  if [[ -f "$ENV_FILE" ]]; then
    # Export BUNDLE_* and INST_OMOP_* variables; eval handles quoted values
    while IFS= read -r line; do
      [[ "$line" =~ ^BUNDLE_|^INST_OMOP_ ]] && export "${line?}"
    done < "$ENV_FILE"
  fi
done

BUNDLE_GITLAB_REMOTE="${BUNDLE_GITLAB_REMOTE:-}"
BUNDLE_GIT_USER_NAME="${BUNDLE_GIT_USER_NAME:-}"
BUNDLE_GIT_USER_EMAIL="${BUNDLE_GIT_USER_EMAIL:-}"
BUNDLE_BRANCH="main"

# Derive the bundle folder name from study_name in study_params.yaml so that
# each study's portable folder is named after the analysis (e.g. my-study).
# Falls back to "transportable_bundle" if study_params.yaml is not yet configured.
STUDY_NAME=$(grep '^study_name:' "$REPO_ROOT/study_params.yaml" 2>/dev/null \
  | sed 's/.*study_name:[[:space:]]*//' \
  | sed 's/#.*$//' \
  | tr -d '"'"'"' ' \
  | tr -d '\r')
STUDY_NAME="${STUDY_NAME:-transportable_bundle}"

# ---------------------------------------------------------------------------
# Validate config
# ---------------------------------------------------------------------------
if [[ -z "$BUNDLE_GITLAB_REMOTE" || "$BUNDLE_GITLAB_REMOTE" == *"CHANGE_ME"* ]]; then
  echo "[Step 9] ERROR: BUNDLE_GITLAB_REMOTE is not set or still contains CHANGE_ME."
  echo "         Edit OMOP_Dev/.env and set BUNDLE_GITLAB_REMOTE to the full SSH URL."
  echo "         Example: git@your.gitlab.instance:netid/your-study-bundle.git"
  exit 1
fi

BUNDLE="$REPO_ROOT/portable/$STUDY_NAME"
DIST="$REPO_ROOT/dist"

if [[ ! -d "$BUNDLE" ]]; then
  echo "[Step 9] ERROR: portable bundle directory not found: $BUNDLE"
  exit 1
fi

mkdir -p "$DIST"

# ---------------------------------------------------------------------------
# generate_bundle_readme — writes README.md to the bundle from study_params.yaml
# ---------------------------------------------------------------------------
generate_bundle_readme() {
  local dest="$1"
  local yaml="$REPO_ROOT/study_params.yaml"

  local sname pred_window study_design outcome_label
  sname=$(grep '^study_name:' "$yaml" \
    | sed 's/.*study_name:[[:space:]]*//' | cut -d'#' -f1 \
    | tr -d '"'"'"' ' | tr -d '\r')
  pred_window=$(grep '^prediction_window_days:' "$yaml" | grep -oE '[0-9]+' | head -1)
  pred_window="${pred_window:-30}"
  study_design=$(grep '^study_design:' "$yaml" \
    | sed 's/.*study_design:[[:space:]]*//' | cut -d'#' -f1 \
    | tr -d '"'"'"' ' | tr -d '\r')
  # outcome_label is nested under report: in study_params.yaml; grab the first match
  outcome_label=$(grep 'outcome_label:' "$yaml" \
    | sed 's/.*outcome_label:[[:space:]]*//' | cut -d'#' -f1 \
    | tr -d '"' | tr -d "'" | tr -d '\r' | head -1)
  outcome_label="${outcome_label:-outcome}"

  local plp int_score char_flag word_rpt
  plp=$(grep 'plp_model_validation:'   "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)
  int_score=$(grep '^\s*integer_risk_score:' "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)
  char_flag=$(grep 'cohort_characterization:' "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)
  word_rpt=$(grep 'word_report:' "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)

  local analysis_desc
  if   [[ "$plp"       == "true" ]]; then
    analysis_desc="External validation of a PatientLevelPrediction (PLP) model predicting ${pred_window}-day ${outcome_label}."
  elif [[ "$int_score" == "true" ]]; then
    analysis_desc="External validation of an integer risk score predicting ${pred_window}-day ${outcome_label}."
  elif [[ "$char_flag" == "true" ]]; then
    analysis_desc="Cohort characterization — FeatureExtraction covariate summary of the target cohort."
  else
    analysis_desc="OMOP observational study (${study_design})."
  fi

  cat > "$dest/README.md" << EOF
# ${sname} — Protected Analytic Space Bundle

${analysis_desc}

**Generated:** $(date +%Y-%m-%d) by \`workflow/09_build_portable_analysis_bundle.sh\`

**Authentication:** Kerberos (institutional NetID) — no passwords stored in any file.
**Java:** conda openjdk from miniforge — no system Java required.
**JDBC driver:** pre-bundled in \`drivers/\` — no internet access needed after setup.

---

## Getting Started

**First time setup (run once):**

1. Create the project folder on the HPC login node:
   \`\`\`bash
   mkdir ~/${sname}
   \`\`\`
2. Open that folder in VS Code via the Remote SSH extension.
3. In the VS Code terminal (which opens inside \`~/${sname}\`), clone the repository into the current directory:
   \`\`\`bash
   git clone ${BUNDLE_GITLAB_REMOTE} .
   \`\`\`

**To update an existing clone:**

\`\`\`bash
git pull origin main
\`\`\`

---

## Quick Start

\`\`\`bash
# One-time setup (after cloning)
bash setup_env.sh             # creates conda env, runs kinit, installs R packages
# Edit .env — set OMOP_RESULTS_SCHEMA to your personal write schema (domain\netid)

# Every session
export KRB5CCNAME=FILE:~/krb5cc_java
kinit                      # enter institutional credentials when prompted
conda activate openjdk
bash run_analysis.sh
\`\`\`

Results are written to \`output/\`.

---

## .env — Configuration

Connection details are pre-populated from the study coordinator's workspace.
**You only need to update \`OMOP_RESULTS_SCHEMA\`** if you need to write to a
different schema than the pre-filled value (format: \`domain\\netid\`).

| Field | Description |
|-------|-------------|
| \`OMOP_SERVER\` | SQL Server hostname (pre-filled) |
| \`OMOP_DATABASE\` | Database containing the OMOP CDM (pre-filled) |
| \`OMOP_SPN_HOST\` | Kerberos SPN hostname (pre-filled) |
| \`OMOP_VOCAB_SCHEMA\` | Schema with vocabulary tables (pre-filled) |
| \`OMOP_CDM_SCHEMA\` | Schema with CDM clinical tables (pre-filled) |
| \`OMOP_RESULTS_SCHEMA\` | Write schema — pre-filled; change only if running as a different user |

---

## Output Files

EOF

  if [[ "$plp" == "true" ]]; then
    cat >> "$dest/README.md" << EOF
| File | Description |
|------|-------------|
| \`person_level_scores.csv\` | Per-patient predicted probabilities, observed outcomes, and prediction window flags |
| \`risk_score_eval/person_level_scores.csv\` | Copy used by the report module |
| \`risk_score_eval/covariate_summary.csv\` | Per-covariate activation rates across the validation cohort |
| \`risk_score_eval/metrics.csv\` | AUROC, AUPRC, Brier score, ECE, calibration intercept and slope with 95% bootstrap CIs |
| \`risk_score_eval/ece_subgroup.csv\` | Expected Calibration Error by demographic subgroup |
| \`roc_curve.png\` | ROC curve |
| \`calibration_lookup.png\` | Calibration plot |
EOF
    if [[ "$word_rpt" == "true" ]]; then
      printf '| `%s_report_<date>.docx` | Manuscript-format Word report with performance tables and calibration figures |\n' \
        "$sname" >> "$dest/README.md"
    fi
  elif [[ "$int_score" == "true" ]]; then
    cat >> "$dest/README.md" << EOF
| File | Description |
|------|-------------|
| \`person_level_scores.csv\` | Per-patient covariate points, total score, and predicted probabilities |
| \`risk_score_eval/covariate_summary.csv\` | Covariate-level activation counts and mean points |
| \`risk_score_eval/metrics.csv\` | AUROC, AUPRC, Brier score, ECE, calibration metrics with 95% CIs |
| \`risk_score_eval/calibration_table_lookup.csv\` | Calibration decile table — published lookup model |
| \`risk_score_eval/calibration_table_recalibrated.csv\` | Calibration decile table — recalibrated model |
| \`calibration_lookup.png\` | Calibration plot — lookup model |
| \`calibration_recalibrated.png\` | Calibration plot — recalibrated model |
EOF
    if [[ "$word_rpt" == "true" ]]; then
      printf '| `%s_report_<date>.docx` | Manuscript-format Word report with Tables 1–4, ROC curve, and calibration figures |\n' \
        "$sname" >> "$dest/README.md"
    fi
  else
    echo "See \`output/\` directory for analysis outputs." >> "$dest/README.md"
  fi

  cat >> "$dest/README.md" << 'STATIC_EOF'

---

## Renewing a Kerberos Ticket

Kerberos tickets expire after ~10 hours. On `GSS initiate failed` or `Login failed`:

```bash
export KRB5CCNAME=FILE:~/krb5cc_java
kinit
```

Then re-run `bash run_analysis.sh`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `GSS initiate failed` / Kerberos error | Ticket expired | `export KRB5CCNAME=FILE:~/krb5cc_java && kinit` |
| `KDC not found` | Not on HPC login node | Launch shell via cluster portal |
| `Login failed for user` | Wrong `spn_host` | Check `OMOP_SPN_HOST` in `.env`; ask HPC support |
| `JAVA_HOME is not set` | conda env not active | `conda activate openjdk` then re-run |
| `No mssql-jdbc*.jar found` | Missing JAR in drivers/ | Re-transfer bundle; confirm `drivers/mssql-jdbc-*.jre11.jar` exists |
| `fill in the following fields in config.R` | `OMOP_RESULTS_SCHEMA` still placeholder | Edit `.env` |
| `Run this script in a FRESH R session` | Java already loaded | Open new terminal, re-activate conda, re-run |
| `CREATE TABLE permission denied` | Insufficient DB permissions | Ask HPC support for CREATE TABLE on `results_schema` |
STATIC_EOF

  echo "  README.md generated from study_params.yaml"
}

# ---------------------------------------------------------------------------
# generate_bundle_env — writes .env to the bundle with institution-specific
# OMOP connection details sourced from the workspace .env (INST_OMOP_* vars).
#
# Each value is single-quoted so that backslashes in schema names
# (e.g. OMOP_RESULTS_SCHEMA='dhe\apj20') are preserved literally when the
# file is sourced by run_analysis.sh with set -o allexport.
#
# Arguments:
#   $1  dest        — bundle directory to write .env into
#   $2  generic      — "true" forces placeholder values even when INST_OMOP_*
#                      is set (used for the offline zip so it doesn't leak the
#                      pusher's own site's connection details to a recipient
#                      at a different institution). Defaults to "false".
# ---------------------------------------------------------------------------
generate_bundle_env() {
  local dest="$1"
  local generic="${2:-false}"

  local server database spn_host vocab_schema cdm_schema results_schema
  local cdm_id cdm_name cdm_desc header_note

  if [[ "$generic" == "true" ]]; then
    server="YOUR_SERVER.example.com"; database="YOUR_DATABASE"; spn_host="YOUR_SPN_HOST"
    vocab_schema="omop_vocab"; cdm_schema="omop_cdm"; results_schema="your_results_schema"
    cdm_id="your_cdm_v5.4"; cdm_name="Your Institution OMOP CDM"
    cdm_desc="Brief description of the patient population and database."
    header_note="This is a CONNECTION-AGNOSTIC bundle: every OMOP_* value below is a\n# placeholder. Fill in your own institution's SQL Server connection details\n# before running Step 8/9 R scripts — nothing site-specific is pre-filled."
  else
    if [[ -z "${INST_OMOP_SERVER:-}" ]]; then
      echo "  [WARN] INST_OMOP_SERVER not set in .env — .env will contain placeholders."
      echo "         Add INST_OMOP_* variables to OMOP_Dev/.env and re-run step 9."
    fi
    server="${INST_OMOP_SERVER:-YOUR_SERVER.example.com}"
    database="${INST_OMOP_DATABASE:-YOUR_DATABASE}"
    spn_host="${INST_OMOP_SPN_HOST:-YOUR_SPN_HOST}"
    vocab_schema="${INST_OMOP_VOCAB_SCHEMA:-omop_vocab}"
    cdm_schema="${INST_OMOP_CDM_SCHEMA:-omop_cdm}"
    results_schema="${INST_OMOP_RESULTS_SCHEMA:-your_results_schema}"
    cdm_id="${INST_OMOP_CDM_DATABASE_ID:-your_cdm_v5.4}"
    cdm_name="${INST_OMOP_CDM_DATABASE_NAME:-Your Institution OMOP CDM}"
    cdm_desc="${INST_OMOP_CDM_DATABASE_DESCRIPTION:-Brief description of the patient population and database.}"
    header_note="All connection values are pre-populated by the study coordinator.\n# Only change OMOP_RESULTS_SCHEMA if you need to write to a different schema\n# (e.g. you are a collaborator with a different domain\\\\netid write schema)."
  fi

  {
    echo "# ============================================================================="
    echo "# .env — Site-specific OMOP connection for the portable analysis bundle."
    echo "#"
    echo "# Generated by workflow/09_build_portable_analysis_bundle.sh."
    echo "#"
    printf "# %b\n" "$header_note"
    echo "# ============================================================================="
    echo ""
    echo "# SQL Server connection"
  } > "$dest/.env"

  printf "OMOP_SERVER='%s'\n"                   "$server"         >> "$dest/.env"
  printf "OMOP_DATABASE='%s'\n"                 "$database"       >> "$dest/.env"
  printf "OMOP_SPN_HOST='%s'\n\n"               "$spn_host"       >> "$dest/.env"
  printf "# Schema names\n"                                       >> "$dest/.env"
  printf "OMOP_VOCAB_SCHEMA='%s'\n"             "$vocab_schema"   >> "$dest/.env"
  printf "OMOP_CDM_SCHEMA='%s'\n\n"             "$cdm_schema"     >> "$dest/.env"
  printf "# Personal write schema — pre-filled; change only if running as a different user\n" >> "$dest/.env"
  printf "OMOP_RESULTS_SCHEMA='%s'\n\n"         "$results_schema" >> "$dest/.env"
  printf "# Database metadata (written into output files)\n"      >> "$dest/.env"
  printf "OMOP_CDM_DATABASE_ID='%s'\n"          "$cdm_id"         >> "$dest/.env"
  printf "OMOP_CDM_DATABASE_NAME='%s'\n"        "$cdm_name"       >> "$dest/.env"
  printf "OMOP_CDM_DATABASE_DESCRIPTION='%s'\n" "$cdm_desc"       >> "$dest/.env"

  printf "\n# CRAN mirror — injected from workspace .env (CRAN_MIRROR)\n"                                >> "$dest/.env"
  printf "CRAN_MIRROR='%s'\n" \
    "${CRAN_MIRROR:-https://cloud.r-project.org}"                                                         >> "$dest/.env"

  if [[ "$generic" == "true" ]]; then
    echo "  .env written with connection-agnostic placeholders (generic bundle)"
  else
    echo "  .env written with site-specific OMOP connection details"
  fi
}

# ---------------------------------------------------------------------------
# seed_bundle_hpc_scripts — seeds HPC launcher scripts into the bundle on
# first run (only when the file does not already exist).
#
# Each script is copied from setup/bundle_templates/ and the placeholder
# __STUDY_LABEL__ is substituted with $STUDY_NAME so banners and headers
# identify the study. Existing files are never overwritten so site-specific
# customisations (e.g. custom module names, conda env paths) are preserved.
# ---------------------------------------------------------------------------
seed_bundle_hpc_scripts() {
  local dest="$1"
  local label="$2"
  local templates="$REPO_ROOT/setup/bundle_templates"
  local yaml="$REPO_ROOT/study_params.yaml"

  if [[ ! -d "$templates" ]]; then
    echo "  [WARN] setup/bundle_templates/ not found — skipping HPC script seeding."
    echo "         Add the templates directory or seed scripts manually."
    return
  fi

  # ---------------------------------------------------------------------------
  # Parse study_params.yaml for config.R placeholder substitution.
  # All values fall back to safe defaults if the YAML key is absent or
  # commented out (e.g. cohort_table is optional in the template YAML).
  # ---------------------------------------------------------------------------
  local cohort_table pred_window study_start study_end outcome_sql_file
  local visit_ids index_ids washout_ids washout_days min_age outcome_ids

  cohort_table=$(grep '^cohort_table:' "$yaml" 2>/dev/null \
    | sed 's/.*cohort_table:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$cohort_table" ]] && cohort_table="${label}_cohort"

  pred_window=$(grep '^prediction_window_days:' "$yaml" 2>/dev/null \
    | sed 's/.*prediction_window_days:[[:space:]]*//' \
    | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$pred_window" ]] && pred_window="90"

  study_start=$(grep '^study_start_date:' "$yaml" 2>/dev/null \
    | sed 's/.*study_start_date:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$study_start" ]] && study_start="2017-01-01"

  study_end=$(grep '^study_end_date:' "$yaml" 2>/dev/null \
    | sed 's/.*study_end_date:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$study_end" ]] && study_end="2025-12-31"

  # Target sql_file is the first sql_file: line in study_params.yaml.
  # This study uses a custom target SQL file (target_amputation.sql), not the
  # bundle template's hardcoded default (target_surgery.sql) — that mismatch
  # previously caused an "Incorrect syntax near ')'" error on the protected
  # analytic space because the wrong cohort SQL was instantiated.
  target_sql_file=$(grep 'sql_file:' "$yaml" 2>/dev/null | sed -n '1p' \
    | sed 's/.*sql_file:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | tr -d '[:space:]')
  target_sql_file=$(basename "${target_sql_file:-target_surgery.sql}")

  # Outcome sql_file is the second sql_file: line in study_params.yaml
  # (target cohort is first, outcome is second). Extract just the filename.
  outcome_sql_file=$(grep 'sql_file:' "$yaml" 2>/dev/null | sed -n '2p' \
    | sed 's/.*sql_file:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | tr -d '[:space:]')
  outcome_sql_file=$(basename "${outcome_sql_file:-outcome.sql}")

  # study_design drives run_analysis.R's pipeline branch (descriptive vs.
  # prognostic_model vs. causal_inference) — must match study_params.yaml,
  # not be hardcoded to one design.
  study_design_val=$(grep '^study_design:' "$yaml" 2>/dev/null \
    | sed 's/.*study_design:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | sed 's/[[:space:]]*$//')
  [[ -z "$study_design_val" ]] && study_design_val="prognostic_model"

  # Helper: convert a YAML integer list "[9201]" or "[4236706, 4225375]" or "[]"
  # into an R expression: "c(9201L)", "c(4236706L, 4225375L)", or "integer(0)".
  _yaml_ids_to_r() {
    local raw
    raw=$(printf '%s' "$1" | tr -d '[]' | sed 's/[[:space:]]//g' | sed 's/#.*//')
    if [[ -z "$raw" ]]; then
      printf 'integer(0)'
    else
      local ids
      ids=$(printf '%s' "$raw" | tr ',' '\n' | grep -E '^[0-9]+$' \
              | sed 's/$/L/' | tr '\n' ',' | sed 's/,$//')
      [[ -z "$ids" ]] && printf 'integer(0)' || printf 'c(%s)' "$ids"
    fi
  }

  # Helper: extract a "key:" value from within an (optionally anchored) YAML
  # section, handling BOTH list styles used across study_params.yaml files:
  #   inline:     ancestor_concept_ids: [9201, 4225375]
  #   multi-line: ancestor_concept_ids:
  #                 - 9201    # comment
  #                 - 4225375
  # Returns a comma-separated digit string (possibly with a trailing comma;
  # harmless for _yaml_ids_to_r, which filters non-digit tokens) or "" if the
  # key has no value (e.g. `ancestor_concept_ids: []` or the key is absent).
  #
  # BUG THIS FIXES: the previous single-line `sed` extraction only handled
  # the inline style. For a multi-line list, the line "ancestor_concept_ids:"
  # has nothing after the colon, so the old logic silently produced an empty
  # ID list -> `IN ()` in the rendered SQL -> "Incorrect syntax near ')'"
  # on the protected analytic space.
  _extract_yaml_ids() {
    local yaml="$1" anchor="$2" key="$3"
    awk -v anchor="$anchor" -v key="$key" '
      BEGIN { in_section = (anchor == ""); found = 0; collecting = 0 }
      {
        line = $0
        if (anchor != "" && line ~ anchor) { in_section = 1 }
        if (in_section && !found && index(line, key ":") > 0) {
          found = 1
          pos = index(line, key ":")
          rest = substr(line, pos + length(key) + 1)
          sub(/#.*/, "", rest)
          gsub(/^[ \t]+|[ \t]+$/, "", rest)
          if (rest != "" && rest != "[]") { print rest; exit }
          collecting = 1
          next
        }
        if (collecting) {
          if (match(line, /^[ \t]*-[ \t]*[0-9]+/)) {
            item = line
            sub(/^[ \t]*-[ \t]*/, "", item)
            sub(/#.*/, "", item)
            gsub(/[ \t]+$/, "", item)
            printf "%s,", item
          } else {
            exit
          }
        }
      }
    ' "$yaml" 2>/dev/null
  }

  # Concept ID fields — using the section-aware extractor above.
  # target.visit_concept_ids (appears once under target:)
  visit_ids=$(_yaml_ids_to_r "$(_extract_yaml_ids "$yaml" "" "visit_concept_ids")")

  # target.min_age_at_index
  min_age=$(grep 'min_age_at_index:' "$yaml" 2>/dev/null | head -1 \
    | sed 's/.*min_age_at_index:[[:space:]]*//' | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$min_age" ]] && min_age="0"

  # target.index_event.ancestor_concept_ids — first ancestor_concept_ids after index_event:
  index_ids=$(_yaml_ids_to_r "$(_extract_yaml_ids "$yaml" "index_event:" "ancestor_concept_ids")")

  # target.washout.ancestor_concept_ids — first ancestor_concept_ids after washout:
  washout_ids=$(_yaml_ids_to_r "$(_extract_yaml_ids "$yaml" "washout:" "ancestor_concept_ids")")

  # target.washout.lookback_days — first lookback_days after washout:
  washout_days=$(awk '/washout:/{f=1} f && /lookback_days:/{print; f=0}' "$yaml" 2>/dev/null \
    | head -1 | sed 's/.*lookback_days:[[:space:]]*//' | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$washout_days" ]] && washout_days="365"

  # outcome.ancestor_concept_ids — first ancestor_concept_ids after ^outcome:
  outcome_ids=$(_yaml_ids_to_r "$(_extract_yaml_ids "$yaml" "^outcome:" "ancestor_concept_ids")")

  # report.score_type and report.outcome_label — from the report: block in YAML
  score_type=$(awk '/^report:/{f=1} f && /score_type:/{print; f=0}' "$yaml" 2>/dev/null \
    | head -1 | sed 's/.*score_type:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | tr -d '[:space:]')
  [[ -z "$score_type" ]] && score_type="integer"

  outcome_label=$(awk '/^report:/{f=1} f && /outcome_label:/{print; f=0}' "$yaml" 2>/dev/null \
    | head -1 | sed 's/.*outcome_label:[[:space:]]*//' | tr -d '"' | tr -d "'" \
    | sed 's/#.*//' | sed 's/[[:space:]]*$//')
  [[ -z "$outcome_label" ]] && outcome_label="Outcome"

  # Root-level scripts seeded as-is (with study label substitution)
  local scripts=("setup_env.sh" "install_r_packages.sh" "install_packages.R" "run_analysis.sh")
  for script in "${scripts[@]}"; do
    local src="$templates/$script"
    local dst="$dest/$script"
    if [[ ! -f "$src" ]]; then
      echo "  [WARN] Template not found, skipping: setup/bundle_templates/$script"
      continue
    fi
    if [[ -f "$dst" ]]; then
      echo "  [SKIP] Already exists (not overwritten): $script"
    else
      sed "s/__STUDY_LABEL__/${label}/g" "$src" > "$dst"
      chmod +x "$dst" 2>/dev/null || true
      echo "  [SEED] $script"
    fi
  done

  # R/ files stored in templates as R_<name>.R to avoid confusion with main repo files.
  # These are HPC-specific versions (Kerberos auth, pre-bundled JDBC) that differ
  # from the devcontainer versions in the main repo's R/ directory.
  # Note: written as explicit pairs rather than an associative array so this script
  # runs under macOS bash 3.2 (which does not support declare -A).
  local _r_tmpls="R_connection.R R_drivers.R"
  local _r_dests="R/connection.R R/drivers.R"
  local _i=1
  for tmpl_name in $_r_tmpls; do
    local r_dest
    r_dest=$(printf '%s' "$_r_dests" | tr ' ' '\n' | sed -n "${_i}p")
    local src="$templates/$tmpl_name"
    local dst="$dest/$r_dest"
    if [[ ! -f "$src" ]]; then
      echo "  [WARN] Template not found, skipping: setup/bundle_templates/$tmpl_name"
      _i=$((_i + 1)); continue
    fi
    if [[ -f "$dst" ]]; then
      echo "  [SKIP] Already exists (not overwritten): $r_dest"
    else
      mkdir -p "$(dirname "$dst")"
      sed "s/__STUDY_LABEL__/${label}/g" "$src" > "$dst"
      echo "  [SEED] $r_dest"
    fi
    _i=$((_i + 1))
  done

  # config.R — seeded once with all study-specific placeholder values substituted.
  # Placeholders are populated from study_params.yaml so every field is correct
  # on first run; the file is never overwritten so site-level edits are preserved.
  local config_src="$templates/config.R"
  local config_dst="$dest/config.R"
  if [[ ! -f "$config_src" ]]; then
    echo "  [WARN] Template not found, skipping: setup/bundle_templates/config.R"
  elif [[ -f "$config_dst" ]]; then
    echo "  [SKIP] Already exists (not overwritten): config.R"
  else
    sed \
      -e "s/__COHORT_TABLE__/${cohort_table}/g" \
      -e "s/__TARGET_SQL_FILE__/${target_sql_file}/g" \
      -e "s/__OUTCOME_SQL_FILE__/${outcome_sql_file}/g" \
      -e "s/__STUDY_DESIGN__/${study_design_val}/g" \
      -e "s/__STUDY_NAME__/${label}/g" \
      -e "s/__PRED_WINDOW__/${pred_window}/g" \
      -e "s/__STUDY_START__/${study_start}/g" \
      -e "s/__STUDY_END__/${study_end}/g" \
      -e "s/__TARGET_VISIT_CONCEPT_IDS__/${visit_ids}/g" \
      -e "s/__TARGET_MIN_AGE__/${min_age}/g" \
      -e "s/__TARGET_INDEX_CONCEPT_IDS__/${index_ids}/g" \
      -e "s/__TARGET_WASHOUT_CONCEPT_IDS__/${washout_ids}/g" \
      -e "s/__TARGET_WASHOUT_LOOKBACK_DAYS__/${washout_days}/g" \
      -e "s/__OUTCOME_CONCEPT_IDS__/${outcome_ids}/g" \
      -e "s/__SCORE_TYPE__/${score_type}/g" \
      -e "s|__OUTCOME_LABEL__|${outcome_label}|g" \
      "$config_src" > "$config_dst"
    echo "  [SEED] config.R"
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — Sync shared R source files into the bundle
# ---------------------------------------------------------------------------
echo "[Step 9] Syncing R source files ..."

copy_bundle_file() {
  local src="$REPO_ROOT/$1"
  local dst="$REPO_ROOT/$2"
  if [[ ! -f "$src" ]]; then
    echo "  [WARN] Not found, skipping: $1"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  echo "  $1 -> $2"
}

# Shared R analysis modules (HPC-specific R/drivers.R and R/connection.R are
# seeded from setup/bundle_templates/ by seed_bundle_hpc_scripts() — never
# copied from the main repo, which has devcontainer-only versions of those files)
copy_bundle_file "R/cohorts.R"               "portable/$STUDY_NAME/R/cohorts.R"
copy_bundle_file "R/cohort_demographics.R"   "portable/$STUDY_NAME/R/cohort_demographics.R"
copy_bundle_file "R/risk_score_pipeline.R"   "portable/$STUDY_NAME/R/risk_score_pipeline.R"
# report_extended.R is loaded as report.R on the protected analytic space (see run_analysis.R)
copy_bundle_file "R/report_extended.R"       "portable/$STUDY_NAME/R/report.R"
# report_helpers.R, report_prognostic.R, and report_descriptive.R are sourced
# by report_extended.R at runtime (dispatched by config$study_design); all
# three must travel with the bundle or the analysis will halt with
# "No such file or directory" once the report step runs.
copy_bundle_file "R/report_helpers.R"        "portable/$STUDY_NAME/R/report_helpers.R"
copy_bundle_file "R/report_prognostic.R"     "portable/$STUDY_NAME/R/report_prognostic.R"
copy_bundle_file "R/report_descriptive.R"    "portable/$STUDY_NAME/R/report_descriptive.R"
# Descriptive-design analysis pipeline (Table 1, VA-FI ORs, discrimination/
# calibration) — required when study_design == "descriptive"; run_analysis.R
# branches on config$study_design to call this instead of the integer risk
# score pipeline.
copy_bundle_file "scripts/analysis/descriptive_ed_analysis.R" \
                 "portable/$STUDY_NAME/scripts/analysis/descriptive_ed_analysis.R"

# run_analysis.R — canonical bundle entry point kept in sync with template.
# Always overwritten so the report call and pipeline paths stay current.
copy_bundle_file "setup/bundle_templates/run_analysis.R" "portable/$STUDY_NAME/run_analysis.R"

# Covariate definition CSVs — copy all CSVs from covariates/ into covariates/
# in the bundle. config.R expects them there (risk_score/ is a deprecated alias).
if compgen -G "$REPO_ROOT/covariates/*.csv" > /dev/null 2>&1; then
  for _csv in "$REPO_ROOT/covariates/"*.csv; do
    [[ -f "$_csv" ]] && copy_bundle_file "covariates/$(basename "$_csv")" \
      "portable/$STUDY_NAME/covariates/$(basename "$_csv")"
  done
else
  echo "  [WARN] No CSV files found in covariates/ — skipping."
fi

# Model artifacts — copy all .rds and .json files from model/ when present.
# These are needed for the Word report (varImp.rds, modelSettings.rds,
# hyperParamSearch.rds, populationSettings.rds). Subdirectories (e.g.
# python_model/) are skipped; only top-level files are included.
if [[ -d "$REPO_ROOT/model" ]]; then
  for _mf in "$REPO_ROOT/model/"*.rds "$REPO_ROOT/model/"*.json; do
    [[ -f "$_mf" ]] && copy_bundle_file "model/$(basename "$_mf")" \
      "portable/$STUDY_NAME/model/$(basename "$_mf")"
  done
fi

# OMOP cohort SQL templates — copy all .sql files from cohorts/ so the correct
# files are included regardless of study-specific naming conventions.
for _sql in "$REPO_ROOT/cohorts/"*.sql; do
  [[ -f "$_sql" ]] && copy_bundle_file "cohorts/$(basename "$_sql")" \
    "portable/$STUDY_NAME/cohorts/$(basename "$_sql")"
done

# Generate README from study_params.yaml — overwrites any previous README
echo "[Step 9] Generating bundle README ..."
generate_bundle_readme "$BUNDLE"

# Generate .env with institution-specific OMOP connection details from INST_OMOP_*
echo "[Step 9] Generating bundle .env from INST_OMOP_* ..."
generate_bundle_env "$BUNDLE"

# Seed HPC launcher scripts on first run (skips any that already exist)
echo "[Step 9] Seeding HPC launcher scripts ..."
seed_bundle_hpc_scripts "$BUNDLE" "$STUDY_NAME"

# ---------------------------------------------------------------------------
# Step 2 — Sync MSSQL JDBC JAR into bundle/drivers/
# ---------------------------------------------------------------------------
echo "[Step 9] Syncing JDBC JAR ..."

JDBC_JAR=$(find "$REPO_ROOT/drivers/jdbc-runtime" -name "mssql-jdbc-*.jre11.jar" 2>/dev/null | head -1)
if [[ -z "$JDBC_JAR" ]]; then
  echo "  [WARN] JDBC JAR not found in drivers/jdbc-runtime/ — skipping."
else
  mkdir -p "$BUNDLE/drivers"
  cp -f "$JDBC_JAR" "$BUNDLE/drivers/"
  echo "  $(basename "$JDBC_JAR") -> portable/$STUDY_NAME/drivers/"
fi

# ---------------------------------------------------------------------------
# Step 3 — Commit and push to GitLab (main branch)
# ---------------------------------------------------------------------------
echo "[Step 9] Pushing bundle to GitLab ($BUNDLE_GITLAB_REMOTE, branch: $BUNDLE_BRANCH) ..."

# Verify SSH access before attempting push
echo "  Checking SSH connectivity to GitLab ..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "$(echo "$BUNDLE_GITLAB_REMOTE" | sed 's|git@\([^:]*\):.*|\1|')" \
        2>&1 | grep -qiE 'welcome|authenticated|gitlab'; then
  echo "  [WARN] SSH connectivity check was inconclusive — proceeding anyway."
  echo "         If the push fails, run: ssh -T git@your.gitlab.instance"
fi

cd "$BUNDLE"

# Initialise git repo inside the bundle on first run
if [[ ! -d ".git" ]]; then
  echo "  Initialising git repo in portable/$STUDY_NAME/ ..."
  git init -b "$BUNDLE_BRANCH"
  git remote add origin "$BUNDLE_GITLAB_REMOTE"
else
  # Ensure remote is set to the configured URL (update if it changed)
  if git remote get-url origin &>/dev/null; then
    git remote set-url origin "$BUNDLE_GITLAB_REMOTE"
  else
    git remote add origin "$BUNDLE_GITLAB_REMOTE"
  fi
  # Switch to / create the target branch (BUNDLE_BRANCH) if not already on it
  if ! git rev-parse --verify "$BUNDLE_BRANCH" &>/dev/null; then
    git checkout -b "$BUNDLE_BRANCH"
  else
    git checkout "$BUNDLE_BRANCH"
  fi
fi

# Set git identity for bundle commits (uses .env values or falls back to global)
if [[ -n "$BUNDLE_GIT_USER_NAME" && "$BUNDLE_GIT_USER_NAME" != "CHANGE_ME" ]]; then
  git config user.name  "$BUNDLE_GIT_USER_NAME"
  git config user.email "$BUNDLE_GIT_USER_EMAIL"
fi

# Ensure output/ is gitignored inside the bundle (the bundle writes results there at runtime)
if ! grep -qx "output/" .gitignore 2>/dev/null; then
  echo "output/" >> .gitignore
fi

# Stage all changes
git add -A

# Commit only if there are staged changes
COMMIT_MSG="chore: sync analysis bundle $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if git diff --cached --quiet; then
  echo "  No changes to commit — bundle is already up to date."
else
  git commit -m "$COMMIT_MSG"
  echo "  Committed: $COMMIT_MSG"
fi

# Push to remote (--force-with-lease is safer than --force: rejects if remote
# has commits we haven't seen, preventing accidental overwrites)
if git push --force-with-lease origin "$BUNDLE_BRANCH" 2>&1; then
  echo "  [OK] Pushed to $BUNDLE_GITLAB_REMOTE ($BUNDLE_BRANCH)"
else
  # First push to a new remote requires --set-upstream; retry with it
  echo "  Retrying with --set-upstream (first push to new remote) ..."
  git push --set-upstream origin "$BUNDLE_BRANCH"
  echo "  [OK] Pushed (with --set-upstream) to $BUNDLE_GITLAB_REMOTE ($BUNDLE_BRANCH)"
fi

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 4 — Build dated zip fallback in dist/
#
# The zip is CONNECTION-AGNOSTIC by design: it is meant to be handed to
# collaborators at other institutions (who may not have access to this
# study's GitLab remote at all), so it must never carry this pusher's own
# site-specific OMOP_SERVER/DATABASE/schema values. .env is regenerated with
# generate_bundle_env(..., generic=true) immediately before zipping, then the
# git-tracked site-specific .env is restored via `git checkout` afterward so
# the working tree (and the GitLab-pushed bundle) are unaffected.
# ---------------------------------------------------------------------------
echo "[Step 9] Building zip fallback (connection-agnostic) ..."

STAMP=$(date +"%Y%m%d")
BASE="${STUDY_NAME}_${STAMP}"

# Find the next available filename for today (STUDY_NAME_YYYYMMDD.zip,
# then _1.zip, _2.zip, ... if multiple builds are made on the same day)
EXISTING_COUNT=$(find "$DIST" -name "${BASE}*.zip" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$EXISTING_COUNT" -eq 0 ]]; then
  ZIP_NAME="${BASE}.zip"
else
  ZIP_NAME="${BASE}_${EXISTING_COUNT}.zip"
fi
ZIP_PATH="$DIST/$ZIP_NAME"

# Swap in a placeholder .env for the zip only.
generate_bundle_env "$BUNDLE" true

# Zip everything under portable/$STUDY_NAME/ except output/ (created at runtime)
(
  cd "$BUNDLE"
  find . -mindepth 1 \
         ! -path "./output*" \
         ! -path "./.git*" \
    | sort \
    | zip -q "$ZIP_PATH" -@
)

# Restore the site-specific .env that was committed/pushed to GitLab so the
# working tree matches what's on the remote (git-tracked, so `checkout`
# reverts the placeholder swap cleanly).
( cd "$BUNDLE" && git checkout -- .env )

SIZE_MB=$(du -sm "$ZIP_PATH" | cut -f1)
echo ""
echo "[Step 9] GitLab push : $BUNDLE_GITLAB_REMOTE (branch: $BUNDLE_BRANCH)"
echo "[Step 9] Zip fallback: $ZIP_PATH (${SIZE_MB} MB) — connection-agnostic, safe to share externally"
echo ""
echo "Step 9 complete."
echo ""
echo "To deploy on the protected analytic space:"
echo "  git clone --branch $BUNDLE_BRANCH $BUNDLE_GITLAB_REMOTE $STUDY_NAME"
echo "  # or to update an existing clone:"
echo "  cd $STUDY_NAME && git pull origin $BUNDLE_BRANCH"
