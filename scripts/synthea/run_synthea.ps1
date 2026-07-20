param(
  [Parameter(Mandatory = $false)]
  [string]$SyntheaHome = $env:SYNTHEA_HOME,

  [Parameter(Mandatory = $false)]
  [int]$Population = 1000,

  [Parameter(Mandatory = $false)]
  [string]$ModuleFile = "",

  [Parameter(Mandatory = $false)]
  [string]$ModuleName = "study_template",

  [Parameter(Mandatory = $false)]
  [string]$State = "North Carolina",

  [Parameter(Mandatory = $false)]
  [string]$AgeRange = "18-100",

  [Parameter(Mandatory = $false)]
  [bool]$RequireModuleOnly = $true
)

# RESEARCHER_ADJUSTS:
# - ModuleName: set to the basename (without .json) of your study module file.
# - AgeRange: set to match your study's eligible age range (e.g., "60-100").
# - State: set to any US state string recognised by Synthea.

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SyntheaHome)) {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
  $SyntheaHome = Join-Path $repoRoot "external/synthea"
}

# Derive ModuleFile from repo root + module name if not explicitly provided.
if ([string]::IsNullOrWhiteSpace($ModuleFile)) {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
  $ModuleFile = Join-Path $repoRoot "synthea\modules\$ModuleName.json"
}

$syntheaBat = Join-Path $SyntheaHome "run_synthea.bat"
if (!(Test-Path $syntheaBat)) {
  if ($RequireModuleOnly) {
    throw @"
Module-only generation requires a full Synthea checkout with run_synthea.bat.
Current SyntheaHome appears to be a standalone jar distribution:
  $SyntheaHome

The standalone jar CLI supports -d (extra module directory) but does not expose
a module whitelist flag, so it cannot guarantee generation only through
$ModuleName.json.
"@
  }
  throw "Could not find run_synthea.bat at: $syntheaBat"
}

if (!(Test-Path $ModuleFile)) {
  throw "Module file not found: $ModuleFile"
}

$modulesDir = Join-Path $SyntheaHome "src\main\resources\modules"
if (!(Test-Path $modulesDir)) {
  throw "Could not find Synthea modules directory: $modulesDir"
}

# Ensure the custom module is available to Synthea.
Copy-Item -Path $ModuleFile -Destination (Join-Path $modulesDir "$ModuleName.json") -Force

Push-Location $SyntheaHome
try {
  Write-Host "Running Synthea with module '$ModuleName' for $Population patients (CSV output)..." -ForegroundColor Cyan

  $exporterArgs = @("--exporter.csv.export=true", "--exporter.fhir.export=false", "--exporter.json.export=false")

  # This Synthea checkout supports -m for module filtering.
  # Do not use --modules here: App.java treats unknown --args as config keys,
  # which silently disables module restriction.
  if ($RequireModuleOnly) {
    $attempts = ,(@("-p", "$Population", "-a", "$AgeRange", "-m", "$ModuleName", "$State") + $exporterArgs)
  } else {
    $attempts = ,(@("-p", "$Population", "-a", "$AgeRange", "$State") + $exporterArgs)
  }

  # Start-Process can split multi-word arguments unless they are explicitly
  # quoted as a single command-line token. This helper keeps state names such as
  # "North Carolina" intact when passed to run_synthea.bat.
  $quoteArg = {
    param([string]$value)
    if ($null -eq $value) { return '""' }
    $escaped = $value -replace '"', '\\"'
    if ($escaped -match '[\s"]') { return ('"' + $escaped + '"') }
    return $escaped
  }

  $success = $false

  foreach ($args in $attempts) {
    $groovyTokens = $args | ForEach-Object {
      $tok = $_ -replace "'", "''"
      "'$tok'"
    }
    $groovyParams = "[" + ($groovyTokens -join ",") + ",]"
    $gradlewArgs = "run -Params=$groovyParams"

    Write-Host ("Attempt: .\\gradlew.bat " + $gradlewArgs) -ForegroundColor Yellow

    & '.\gradlew.bat' run "-Params=$groovyParams"
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
      $success = $true
      break
    }
  }

  if (-not $success) {
    throw "Synthea failed for all module-restricted command variants. Check console logs above."
  }

  $csvOutputDir = Join-Path $SyntheaHome "output\csv"

  Write-Host "Synthea completed successfully." -ForegroundColor Green
  Write-Host "CSV output folder: $csvOutputDir" -ForegroundColor Green
}
finally {
  Pop-Location
}
