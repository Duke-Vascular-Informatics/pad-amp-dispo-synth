param()

# =============================================================================
# workflow/09_build_portable_analysis_bundle.ps1
#
# Step 9 - Build the protected analytic space portable analysis bundle.
#
# PURPOSE
# -------
# This script packages the PAD/OLER SSI integer risk score external validation
# analysis into a self-contained zip file that can be transferred to and run on
# the protected analytic space.
#
# The bundle lives in portable/<study_name>/ in this repository, where <study_name>
# is read from study_params.yaml at runtime.  Step 9 keeps that bundle up-to-date
# by pulling in the latest shared R source files and JDBC driver JAR from the main
# project before zipping everything up.
#
# DEPLOYMENT WORKFLOW
# -------------------
# 1. Run this script on the developer workstation to produce a dated zip in
#    dist/ (e.g. dist/<study_name>_20260410.zip).
# 2. Transfer the zip to the protected analytic space:
#      scp dist/<study_name>_<date>.zip <netid>@your.hpc.cluster.hostname:/path/to/your/workspace/
# 3. On the protected analytic space, unzip keeping the dated zip folder name (do NOT rename it):
#      cd /path/to/your/workspace
#      unzip <study_name>_<date>.zip -d <study_name>_<date>
#    This produces: /path/to/your/workspace/<study_name>_<date>/
# 4. Also place the your HPC support team custom JDBC wrapper JAR one level above the
#    bundle, in a drivers/ sibling folder:
#      /path/to/your/workspace/drivers/hpc-jdbc-wrapper.jar
#    config.R resolves this path automatically as dirname(bundle)/drivers/.
#    (This JAR is provided by your HPC support team and is NOT included in the
#    bundle because it is a site-specific file we do not redistribute.)
# 5. Follow setup_env.sh and config.R instructions to fill in credentials
#    and database connection details, then run:
#      cd /path/to/your/workspace/<study_name>_<date>
#      bash setup_env.sh
#      conda activate openjdk
#      export KRB5CCNAME=FILE:~/krb5cc_java && kinit
#      Rscript run_analysis.R
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   1. Syncs shared R source files from the main project (R/, risk_score/,
#      cohorts/) into portable/<study_name>/ so the bundle always reflects the
#      current analysis code.
#   2. Copies the standard MSSQL JDBC JAR from drivers/jdbc-runtime/ into
#      portable/<study_name>/drivers/ so HPC cluster has the driver it needs.
#   3. Builds a dated zip: dist/<study_name>_<YYYYMMDD>.zip.
#      Previous zips in dist/ are retained so that any version already
#      transferred to HPC cluster can still be reproduced or compared.
#
# FILES THAT ARE *NOT* OVERWRITTEN BY THIS SCRIPT
# ------------------------------------------------
# The following files inside portable/<study_name>/ are bundle-specific.  They
# contain site-specific configuration, Kerberos authentication logic, and
# install steps that differ between the developer workstation and the protected analytic space.
# Overwriting them with the main-project versions would break HPC cluster execution:
#
#   portable/<study_name>/R/connection.R
#       Configures the JVM (JAVA_HOME, heap, JAAS config), adds both JDBC JARs
#       to the classpath via rJava::.jaddClassPath(), and builds the full JDBC
#       URL with authenticationScheme=JavaKerberos.  Completely different from
#       the standard Windows ODBC connection used on the developer workstation.
#
#   portable/<study_name>/config.R
#       Resolves JAVA_HOME from the active conda environment, sets the path to
#       the your HPC support team custom JAR (~/drivers/), and contains CHANGE_ME
#       placeholders for the SQL Server host, database, and schema names.
#
#   portable/<study_name>/run_analysis.R
#       Entry-point script for HPC cluster execution.  Calls configure_java_hpc()
#       BEFORE library(DatabaseConnector) — this ordering is required so that
#       java.parameters and the classpath are set before the JVM starts.
#
#   portable/<study_name>/install_packages.R
#       Installs R packages from CRAN/Bioconductor using the miniforge/conda R
#       environment available on the protected analytic space; includes packages not needed on Windows.
#
#   portable/<study_name>/setup_env.sh
#       Shell script that activates the conda openjdk environment, obtains a
#       Kerberos ticket (kinit), and sets KRB5CCNAME so the JAAS config can
#       find the ticket cache file.
# =============================================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..")
Push-Location $repoRoot

try {

    # Derive bundle folder name from study_name in study_params.yaml so that
    # each study's portable folder is named after the analysis (e.g. my-study).
    # Falls back to "<study_name>" if study_params.yaml is not yet configured.
    $studyParamsPath = Join-Path $repoRoot "study_params.yaml"
    $studyName = "<study_name>"
    if (Test-Path $studyParamsPath) {
        $match = Select-String -Path $studyParamsPath -Pattern '^\s*study_name:\s*["\x27]?([A-Za-z0-9_-]+)'
        if ($match) { $studyName = $match.Matches[0].Groups[1].Value }
    }

    $bundle = Join-Path $repoRoot "portable\$studyName"
    $dist   = Join-Path $repoRoot "dist"

    # Verify the bundle skeleton exists.  It is checked into version control and
    # must be present before this script runs.  The dist/ output directory is
    # created on first use if it does not yet exist.
    if (!(Test-Path $bundle)) { throw "portable bundle directory not found: $bundle" }
    if (!(Test-Path $dist))   { New-Item -ItemType Directory -Path $dist | Out-Null }

    # -------------------------------------------------------------------------
    # Generate-BundleReadme — writes README.md from study_params.yaml
    # -------------------------------------------------------------------------
    function Generate-BundleReadme {
        param([string]$BundleDir)

        $yaml        = Get-Content (Join-Path $repoRoot "study_params.yaml") -Raw
        $sname       = ([regex]'(?m)^study_name:\s*["\x27]?([^"''\s#]+)').Match($yaml).Groups[1].Value
        $predWindow  = ([regex]'(?m)^prediction_window_days:\s*(\d+)').Match($yaml).Groups[1].Value
        $studyDesign = ([regex]'(?m)^study_design:\s*["\x27]?([^"''\s#]+)').Match($yaml).Groups[1].Value
        if (-not $predWindow) { $predWindow = "30" }

        $plp      = ([regex]'(?m)plp_model_validation:\s*(true|false)').Match($yaml).Groups[1].Value
        $intScore = ([regex]'(?m)integer_risk_score:\s*(true|false)').Match($yaml).Groups[1].Value
        $wordRpt  = ([regex]'(?m)word_report:\s*(true|false)').Match($yaml).Groups[1].Value
        $charFlag = ([regex]'(?m)cohort_characterization:\s*(true|false)').Match($yaml).Groups[1].Value

        $analysisDesc = if ($plp -eq "true") {
            "External validation of a PatientLevelPrediction (PLP) Random Forest model predicting ${predWindow}-day outcomes."
        } elseif ($intScore -eq "true") {
            "External validation of an integer risk score predicting ${predWindow}-day outcomes."
        } elseif ($charFlag -eq "true") {
            "Cohort characterization — FeatureExtraction covariate summary of the target cohort."
        } else {
            "OMOP observational study ($studyDesign)."
        }

        $outputTable = if ($plp -eq "true") {
            @"
| File | Description |
|------|-------------|
| ``person_level_scores.csv`` | Per-patient predicted probabilities, observed outcomes, and prediction window flags |
| ``risk_score_eval/person_level_scores.csv`` | Copy used by the report module |
| ``risk_score_eval/covariate_summary.csv`` | Per-covariate activation rates across the validation cohort |
| ``risk_score_eval/metrics.csv`` | AUROC, AUPRC, Brier score, ECE, calibration intercept and slope with 95% bootstrap CIs |
| ``risk_score_eval/ece_subgroup.csv`` | Expected Calibration Error by demographic subgroup |
| ``roc_curve.png`` | ROC curve |
| ``calibration_lookup.png`` | Calibration plot |$(if ($wordRpt -eq "true") {"`n| ``${sname}_report_<date>.docx`` | Manuscript-format Word report with performance tables and calibration figures |"})
"@
        } elseif ($intScore -eq "true") {
            @"
| File | Description |
|------|-------------|
| ``person_level_scores.csv`` | Per-patient covariate points, total score, and predicted probabilities |
| ``risk_score_eval/covariate_summary.csv`` | Covariate-level activation counts and mean points |
| ``risk_score_eval/metrics.csv`` | AUROC, AUPRC, Brier score, ECE, calibration metrics with 95% CIs |
| ``risk_score_eval/calibration_table_lookup.csv`` | Calibration decile table — published lookup model |
| ``risk_score_eval/calibration_table_recalibrated.csv`` | Calibration decile table — recalibrated model |
| ``calibration_lookup.png`` | Calibration plot — lookup model |
| ``calibration_recalibrated.png`` | Calibration plot — recalibrated model |$(if ($wordRpt -eq "true") {"`n| ``${sname}_report_<date>.docx`` | Manuscript-format Word report |"})
"@
        } else {
            "See ``output/`` directory for analysis outputs."
        }

        $readme = @"
# $sname — Protected Analytic Space Bundle

$analysisDesc

**Generated:** $(Get-Date -Format 'yyyy-MM-dd') by ``workflow/09_build_portable_analysis_bundle.ps1``

**Authentication:** Kerberos (institutional NetID) — no passwords stored in any file.
**Java:** conda openjdk from miniforge — no system Java required.
**JDBC driver:** pre-bundled in ``drivers/`` — no internet access needed after setup.

---

## Quick Start

``````bash
# One-time setup
cd ~/$sname
bash setup_env.sh          # creates conda env, runs kinit, installs R packages
# Edit config.R — fill in server, database, spn_host, schemas

# Every session
cd ~/$sname
export KRB5CCNAME=FILE:~/krb5cc_java
kinit                      # enter institutional credentials when prompted
conda activate openjdk
bash run_analysis.sh
``````

Results are written to ``output/``.

---

## config.R — Required Fields

| Field | Description |
|-------|-------------|
| ``server`` | SQL Server hostname |
| ``database`` | Database containing the OMOP CDM |
| ``spn_host`` | Kerberos SPN hostname (usually same as ``server``) |
| ``vocab_schema`` | Schema with vocabulary tables |
| ``cdm_schema`` | Schema with CDM clinical tables |
| ``results_schema`` | Schema where cohort table will be written (needs CREATE TABLE) |

Fill in every ``CHANGE_ME`` value before running.

---

## Output Files

$outputTable

---

## Renewing a Kerberos Ticket

Kerberos tickets expire after ~10 hours. On ``GSS initiate failed`` or ``Login failed``:

``````bash
export KRB5CCNAME=FILE:~/krb5cc_java
kinit
``````

Then re-run ``bash run_analysis.sh``.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| ``GSS initiate failed`` / Kerberos error | Ticket expired | ``export KRB5CCNAME=FILE:~/krb5cc_java && kinit`` |
| ``KDC not found`` | Not on HPC login node | Launch shell via cluster portal |
| ``Login failed for user`` | Wrong ``spn_host`` | Check ``spn_host`` in config.R; ask HPC support for correct SPN |
| ``JAVA_HOME is not set`` | conda env not active | ``conda activate openjdk`` then re-run |
| ``No mssql-jdbc*.jar found`` | Missing JAR in drivers/ | Re-transfer bundle; confirm ``drivers/mssql-jdbc-*.jre11.jar`` exists |
| ``fill in the following fields in config.R`` | ``CHANGE_ME`` not replaced | Edit config.R |
| ``Run this script in a FRESH R session`` | Java already loaded | Open new terminal, re-activate conda, re-run |
| ``CREATE TABLE permission denied`` | Insufficient DB permissions | Ask HPC support for CREATE TABLE on ``results_schema`` |
"@
        Set-Content -Path (Join-Path $BundleDir "README.md") -Value $readme -Encoding UTF8
        Write-Host "  README.md generated from study_params.yaml"
    }

    # -------------------------------------------------------------------------
    # Step 1 - Sync R source files from main project into bundle
    #
    # WHY: The analysis R source files (risk score pipeline, cohort definitions,
    # demographics, report generation) are developed and tested on the developer
    # workstation under R/ and related directories.  The transportable bundle must always
    # run the same version of these shared files.  Rather than maintaining two
    # separate copies manually, this script copies the canonical versions into
    # the bundle at build time.
    #
    # The helper function Copy-BundleFile handles three things:
    #   a) Warns and skips gracefully if a source file is unexpectedly missing
    #      (so a missing optional file doesn't abort the whole build).
    #   b) Creates intermediate destination directories if they don't exist yet.
    #   c) Logs each copy operation to the console for traceability.
    #
    # FILE INVENTORY (what each file does):
    #
    #   R/risk_score_pipeline.R
    #       Core pipeline: joins cohort table to OMOP condition/procedure data,
    #       scores each patient using the integer risk score components, computes
    #       AUROC, AUPRC, ECE, calibration tables, bootstrap CIs, subgroup bias
    #       assessment, and writes all output CSVs and PNGs.
    #
    #   R/cohorts.R
    #       Instantiates target (PAD surgery) and outcome (SSI) cohorts from SQL
    #       templates.  Handles both custom SQL (cohorts/*.sql) and pre-existing
    #       ATLAS cohorts via use_atlas_cohorts flag in config.R.
    #
    #   R/cohort_demographics.R
    #       Queries the OMOP person table to retrieve sex, race, ethnicity, and
    #       age at index for each patient.  Used by the subgroup bias assessment
    #       section of the pipeline (compute_subgroup_bias).
    #
    #   R/report_extended.R  →  portable/<study_name>/R/report.R
    #       Generates the manuscript-ready Word document (officer/flextable),
    #       including the discrimination/calibration table, calibration plots,
    #       and the subgroup ECE forest plot.  Note the filename translation:
    #       the bundle always calls this file report.R regardless of the source
    #       name in the main project.
    #
    #   risk_score/components.csv
    #       Lookup table of integer risk score component names, weights, and
    #       directions.  Defines which clinical covariates contribute to the
    #       score and by how many points.
    #
    #   risk_score/component_concepts.csv
    #       Maps each risk score component to one or more OMOP standard concept
    #       IDs so the pipeline can look up the component in the CDM without
    #       hard-coding vocabulary-specific codes.
    #
    #   risk_score/risk_lookup.csv
    #       Pre-computed risk probability lookup table: maps each possible
    #       integer total score to the predicted 90-day SSI probability from the
    #       original derivation study.
    #
    #   cohorts/target_surgery.sql
    #       OMOP SQL template that identifies the PAD surgery target cohort
    #       (index event = PAD-related lower-extremity vascular surgery).
    #       Uses SqlRender parameterisation for schema/table substitution.
    #
    #   cohorts/outcome_ssi.sql
    #       OMOP SQL template that identifies the SSI outcome cohort (surgical
    #       site infection diagnosed within the prediction window after the index
    #       procedure date).
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Syncing R source files ..." -ForegroundColor Cyan

    # Helper: copy one file from the main project into the bundle.
    # $src and $dst are paths relative to $repoRoot.
    function Copy-BundleFile($src, $dst) {
        $srcPath = Join-Path $repoRoot $src
        $dstPath = Join-Path $repoRoot $dst
        if (!(Test-Path $srcPath)) { Write-Warning "Not found, skipping: $src"; return }
        $dstDir = Split-Path -Parent $dstPath
        if (!(Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
        Copy-Item -Path $srcPath -Destination $dstPath -Force
        Write-Host "  $src -> $dst"
    }

    # --- Shared R analysis modules ---
    Copy-BundleFile "R\risk_score_pipeline.R"        "portable\$studyName\R\risk_score_pipeline.R"
    Copy-BundleFile "R\cohorts.R"                    "portable\$studyName\R\cohorts.R"
    Copy-BundleFile "R\cohort_demographics.R"        "portable\$studyName\R\cohort_demographics.R"
    # report_extended.R is the developer-workstation filename; the bundle
    # always loads it as report.R (see run_analysis.R: source("R/report.R")).
    Copy-BundleFile "R\report_extended.R"            "portable\$studyName\R\report.R"

    # --- Integer risk score reference data ---
    Copy-BundleFile "risk_score\components.csv"          "portable\$studyName\risk_score\components.csv"
    Copy-BundleFile "risk_score\component_concepts.csv"  "portable\$studyName\risk_score\component_concepts.csv"
    Copy-BundleFile "risk_score\risk_lookup.csv"         "portable\$studyName\risk_score\risk_lookup.csv"

    # --- OMOP cohort SQL templates ---
    Copy-BundleFile "cohorts\target_surgery.sql"     "portable\$studyName\cohorts\target_surgery.sql"
    Copy-BundleFile "cohorts\outcome_ssi.sql"        "portable\$studyName\cohorts\outcome_ssi.sql"

    # Generate README from study_params.yaml — overwrites any previous README
    Write-Host "[Step 9] Generating bundle README ..." -ForegroundColor Cyan
    Generate-BundleReadme -BundleDir $bundle

    # -------------------------------------------------------------------------
    # Step 2 - Sync MSSQL JDBC JAR into bundle/drivers/
    #
    # WHY: Connecting to the institutional SQL Server from a Linux/HPC R session requires
    # the Microsoft MSSQL JDBC driver.  This is the *standard* JDBC JAR from
    # Microsoft (mssql-jdbc-*.jre11.jar).  It is separate from the your HPC support team
    # custom wrapper JAR (hpc-jdbc-wrapper.jar), which is NOT
    # included in this bundle for the following reasons:
    #
    #   1. It is provided directly by your HPC support team and is not ours to
    #      redistribute in a shared zip.
    #   2. Its location on each user's HPC cluster home directory may vary; config.R
    #      resolves it dynamically from ~/drivers/ at runtime.
    #
    # The standard MSSQL JDBC JAR is committed into drivers/jdbc-runtime/ in
    # this repository and IS included in the bundle because:
    #   - It is publicly available from Microsoft under the MIT licence.
    #   - Including it means the bundle is self-contained for the standard
    #     driver — users only need to obtain the institution-provided wrapper separately.
    #
    # The JAR is found by glob (mssql-jdbc-*.jre11.jar) so that a version bump
    # in the filename does not require editing this script.  Only the first
    # match is copied; there should never be more than one version present.
    #
    # IMPORTANT: drivers/jaas.conf is NOT copied here.  That file is generated
    # at runtime by connection.R (write_jaas_conf()) because its content depends
    # on the user's live Kerberos ticket cache path (KRB5CCNAME), which is only
    # known on the protected analytic space at the moment R is launched.
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Syncing JDBC JAR ..." -ForegroundColor Cyan

    $jdbcSrc = Get-ChildItem -Path (Join-Path $repoRoot "drivers\jdbc-runtime") `
                             -Filter "mssql-jdbc-*.jre11.jar" `
                             -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -eq $jdbcSrc) {
        # Non-fatal: the JAR may have already been placed in the bundle manually.
        # The script warns but continues so the zip can still be built.
        Write-Warning "JDBC JAR not found in drivers\jdbc-runtime\ - skipping."
    } else {
        $jdbcDst = Join-Path $bundle "drivers\$($jdbcSrc.Name)"
        Copy-Item -Path $jdbcSrc.FullName -Destination $jdbcDst -Force
        Write-Host "  $($jdbcSrc.Name) -> portable\$studyName\drivers\"
    }

    # -------------------------------------------------------------------------
    # Step 3 - Build dated zip (previous zips are kept)
    #
    # WHY A DATED FILENAME:
    #   Each build receives a date-stamped name (<study_name>_YYYYMMDD.zip)
    #   so that multiple versions can coexist in dist/.  This matters because:
    #     - A zip may already be in transit to or deployed on the protected analytic space when a new
    #       build is made.  The dated name lets us identify which version is
    #       running on the protected analytic space at any given time.
    #     - If a regression is introduced and HPC cluster results change unexpectedly,
    #       an earlier zip can be retrieved and re-deployed without a git checkout.
    #     - The date provides an audit trail linking HPC cluster results to a specific
    #       snapshot of the analysis code.
    #
    # WHY PREVIOUS ZIPS ARE NOT DELETED:
    #   Old zips are intentionally retained.  Every build produces a unique
    #   filename so no zip is ever overwritten.  dist/ is in .gitignore so
    #   the zip files do not bloat the repository; they are local build
    #   artefacts only.
    #
    # FILENAME SCHEME — multiple builds on the same day:
    #   First build of the day  : <study_name>_YYYYMMDD.zip
    #   Second build of the day : <study_name>_YYYYMMDD_1.zip
    #   Third build of the day  : <study_name>_YYYYMMDD_2.zip
    #   ...and so on.
    #   The counter is found by scanning dist/ for existing files that match
    #   the date prefix and taking the next available number.
    #
    # WHAT IS INCLUDED IN THE ZIP:
    #   Everything under portable/<study_name>/* is zipped EXCEPT output/.
    #   The output/ directory is excluded because:
    #     - It is created at runtime by run_integer_risk_score_pipeline().
    #     - Including a pre-existing directory in the zip causes it to be
    #       extracted with the permissions stored in the zip (often read-only
    #       on Linux), making it unwritable when the pipeline tries to save CSVs.
    #   Included items:
    #     - R/            shared analysis modules (just synced in Step 1)
    #     - risk_score/   integer score reference CSVs
    #     - cohorts/      OMOP SQL templates
    #     - drivers/      mssql-jdbc-*.jre11.jar (just synced in Step 2)
    #     - config.R             bundle config with CHANGE_ME placeholders
    #     - run_analysis.R       HPC cluster entry-point script
    #     - connection.R         HPC cluster Kerberos/JVM setup (inside R/)
    #     - install_packages.R   R package installer (called by install_r_packages.sh)
    #     - setup_env.sh    Step 1: conda env creation + Kerberos ticket
    #     - install_r_packages.sh  Step 2: activates env + runs install_packages.R
    #
    # WHAT IS *NOT* IN THE ZIP:
    #     - hpc-jdbc-wrapper.jar  (your HPC support team JAR, not ours to ship)
    #     - jaas.conf                           (generated at runtime from env vars)
    #     - Any files under dist/, workflow/, or the main project R/ directly
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Building zip ..." -ForegroundColor Cyan

    $stamp    = Get-Date -Format "yyyyMMdd"
    $base     = "${studyName}_$stamp"

    # Find the next available filename for today.
    # Existing files that match today's date are counted so the new zip always
    # gets a unique name:
    #   <study_name>_YYYYMMDD.zip      (no suffix — first of the day)
    #   <study_name>_YYYYMMDD_1.zip    (second build)
    #   <study_name>_YYYYMMDD_2.zip    (third build)  ...
    $existing = @(Get-ChildItem -Path $dist -Filter "${base}*.zip" -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        $zipName = "${base}.zip"
    } else {
        $zipName = "${base}_$($existing.Count).zip"
    }

    $zipPath = Join-Path $dist $zipName

    # Exclude output/ — it is created at runtime by run_integer_risk_score_pipeline().
    # Including it causes Linux to extract it with read-only permissions, which
    # prevents the pipeline from writing result CSVs.
    $zipItems = Get-ChildItem -Path $bundle |
                Where-Object { $_.Name -ne "output" } |
                ForEach-Object { $_.FullName }
    Compress-Archive -Path $zipItems -DestinationPath $zipPath

    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host ""
    Write-Host "Step 9 complete: $zipName ($sizeMB MB)" -ForegroundColor Green
    Write-Host "Location: $zipPath" -ForegroundColor Green

} finally {
    Pop-Location
}
