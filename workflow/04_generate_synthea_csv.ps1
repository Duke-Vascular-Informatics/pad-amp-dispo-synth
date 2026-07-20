# -----------------------------------------------------------------------------
# Step 4: Generate Synthea CSV data for the study template workflow.
#
# High-level behavior:
# 1) Resolve runtime parameters (Synthea path, population size, age range, state).
# 2) Switch working directory to repository root for stable relative paths.
# 3) Invoke the Synthea runner script in module-only mode.
# 4) Always restore prior working directory, even on failure.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Chunk 1 - Runtime parameters
# Purpose:
# Define all user-configurable knobs for Synthea generation.
# Code path notes:
# - SyntheaHome: prefer $env:SYNTHEA_HOME when provided; otherwise use local
#   default path.
# - Population/AgeRange/State: forwarded directly to downstream runner script.
# -----------------------------------------------------------------------------
param(
  [string]$SyntheaHome = $env:SYNTHEA_HOME,
  [int]$Population = 1000,
  [string]$AgeRange = "60-100",
  [string]$State = "North Carolina"
)

# -----------------------------------------------------------------------------
# Chunk 2 - Fail-fast shell behavior
# Purpose:
# Treat non-terminating PowerShell errors as terminating so workflow failures do
# not continue silently.
# -----------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Chunk 3 - Resolve repository root and set execution location
# Purpose:
# Compute repository root relative to this script file and enter it so all
# script-relative paths remain stable regardless of caller's current directory.
# Code path notes:
# - Push-Location stores prior location on stack.
# - Pop-Location in finally block guarantees restoration.
# -----------------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")

# If SYNTHEA_HOME is not set, default to the repository submodule location.
if ([string]::IsNullOrWhiteSpace($SyntheaHome)) {
  $SyntheaHome = Join-Path $repoRoot "external/synthea"
}

Push-Location $repoRoot

# -----------------------------------------------------------------------------
# Chunk 4 - Invoke Synthea module generation script
# Purpose:
# Execute the canonical Synthea runner for study template data generation.
# Code path notes:
# - Pre-flight guard verifies Step 3 module sync output exists in
#   <SyntheaHome>/src/main/resources/modules/study_template.json.
# - -RequireModuleOnly $true ensures module artifacts are required and validated.
# - Any error bubbles up due to $ErrorActionPreference = "Stop".
# -----------------------------------------------------------------------------
try {
  $moduleFileName = "study_template.json"
  $modulesDir = Join-Path $SyntheaHome "src/main/resources/modules"
  $syncedModulePath = Join-Path $modulesDir $moduleFileName

  if (!(Test-Path $modulesDir)) {
    throw "Expected Synthea modules directory not found under SyntheaHome: $modulesDir"
  }

  if (!(Test-Path $syncedModulePath)) {
    throw @"
Expected module file from Step 3 was not found:
  $syncedModulePath

Run Step 3 first to sync the module JSON into your Synthea checkout:
  Rscript workflow/03_generate_synthea_module_artifacts.R
"@
  }

  Write-Host "Verified Step 3 module sync: $syncedModulePath" -ForegroundColor Cyan

  & "scripts/synthea/run_synthea.ps1" `
    -SyntheaHome $SyntheaHome `
    -Population $Population `
    -AgeRange $AgeRange `
    -State $State `
    -RequireModuleOnly $false
}

# -----------------------------------------------------------------------------
# Chunk 5 - Directory cleanup guarantee
# Purpose:
# Restore original working directory regardless of success/failure so this
# script has no persistent side effects on caller shell context.
# -----------------------------------------------------------------------------
finally {
  Pop-Location
}

# -----------------------------------------------------------------------------
# Chunk 6 - Completion banner
# Purpose:
# Provide clear terminal confirmation that Step 4 finished successfully.
# -----------------------------------------------------------------------------
Write-Host "Step 4 complete: Synthea CSV data generated." -ForegroundColor Green
