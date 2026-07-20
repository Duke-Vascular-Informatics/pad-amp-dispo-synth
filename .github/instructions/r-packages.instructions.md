---
description: "Use when installing, loading, or suggesting R packages. Enforces HADES-first priority, tidyverse fallback, project CRAN mirror, and renv workflow."
applyTo: "**/*.R"
---

# R Package Management Rules

## Package Selection Priority (MANDATORY)

When recommending or selecting packages for any analysis task, apply this strict priority order:

### 1. HADES packages (always first)

Use the OHDSI Health Analytics Data-to-Evidence Suite (HADES) whenever the method is covered.
Consult the **Book of OHDSI** (https://ohdsi.github.io/TheBookOfOhdsi/) for the canonical
workflow before reaching for any other package.

| HADES Package | Primary Use | CRAN? |
|---|---|---|
| `DatabaseConnector` | DB connection (SQL Server, PostgreSQL, Redshift) | Yes |
| `SqlRender` | Parameterized SQL authoring and dialect translation | Yes |
| `FeatureExtraction` | Covariate extraction for PLP and CohortMethod | Prebuilt binary |
| `PatientLevelPrediction` | Prognostic modelling | Prebuilt binary |
| `CohortMethod` | Active comparator new-user causal inference | Prebuilt binary |
| `CohortGenerator` | Cohort instantiation from ATLAS JSON | Prebuilt binary |
| `CohortDiagnostics` | Cohort phenotype QC and diagnostics | Prebuilt binary |
| `EvidenceSynthesis` | Meta-analysis across sites | Prebuilt binary |
| `SelfControlledCaseSeries` | SCCS causal inference | Prebuilt binary |
| `EmpiricalCalibration` | P-value / CI calibration using negative controls | Yes |
| `DataQualityDashboard` | OMOP CDM data quality checks | Prebuilt binary |

HADES packages not on CRAN ship as prebuilt binaries in `internal_repo/bin/` for offline
installation. Do not suggest installing these from GitHub in analysis code.

### 2. tidyverse packages (second)

When the task is outside HADES scope (data wrangling, visualization, string manipulation,
file I/O), use tidyverse packages:

```
dplyr, tidyr, ggplot2, readr, purrr, stringr, lubridate, forcats, tibble
```

All tidyverse packages are available on the project CRAN mirror.

### 3. Other CRAN packages (third)

Any package not covered by HADES or tidyverse must be available on the project-configured
CRAN mirror (set via `CRAN_MIRROR` in `.env`; defaults to `https://cloud.r-project.org`).

Common approved additions for OMOP studies:

```
officer      # Word report generation
flextable    # Formatted tables in Word/HTML
openxlsx     # Excel output
pROC         # ROC curves and AUC
PRROC        # Precision-recall curves
knitr        # Report rendering
rmarkdown    # R Markdown documents
```

### Never suggest

- Packages available only on GitHub (unless they are OHDSI HADES packages in `internal_repo/bin/`)
- Packages available only on Bioconductor
- Python or Julia packages or interop layers (`reticulate`, `rJulia`)
- `dbplyr`, `odbc`, or `DBI` directly (use `DatabaseConnector` instead)

---

## CRAN Mirror

Always use the project-configured CRAN mirror — read from the `CRAN_MIRROR` environment
variable (set in `.env`).  Never hardcode a mirror URL:

```r
options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))
```

---

## renv

This project uses `renv` for reproducible package management:

- **Install packages**: `renv::install("package")` — never bare `install.packages()`
- **After adding packages**: run `renv::snapshot()` to update `renv.lock`
- **Restore environment**: `renv::restore()` on a fresh clone
- Never edit `renv.lock` manually; always use `renv::snapshot()` after changes

---

## Loading Packages in Scripts

Follow the OHDSI convention: load all packages at the top of the script, after `renv`
activation and config loading, with a comment explaining why each package is needed:

```r
# Core HADES infrastructure — always required
library(DatabaseConnector)   # OMOP CDM database connection
library(SqlRender)            # SQL parameterization and dialect translation

# Analysis-specific HADES packages
library(FeatureExtraction)    # covariate extraction for PLP model
library(PatientLevelPrediction)  # prognostic model development and validation

# Output packages (tidyverse / CRAN)
library(dplyr)      # data frame manipulation
library(ggplot2)    # result visualization
library(officer)    # Word report generation
library(flextable)  # formatted tables in Word output
```

---

## Version Alignment

- Do not suggest upgrading pinned package refs without validating compatibility first.
- R version: **4.5.x** — avoid packages that require R >= 4.6.
- Check `renv.lock` for the current pinned versions before suggesting an install.
