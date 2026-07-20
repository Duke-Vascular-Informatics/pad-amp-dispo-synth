# =============================================================================
# install_packages.R
# Install all OHDSI HADES packages and CRAN dependencies required by this
# study template.  Also provisions the Microsoft JDBC driver bundle into the
# project-local drivers/ folder so the project is fully self-contained.
#
# Run ONCE in a fresh R session BEFORE running workflow/07_setup_analysis_env.R.
# Usage: Rscript setup/install_packages.R
# =============================================================================

# --- Java configuration (must be set before rJava / DatabaseConnector load) ---
# JAVA_HOME is read from the environment (set automatically in the dev container).
# Falls back to the Windows path for legacy Windows runs.
JAVA_HOME <- Sys.getenv("JAVA_HOME",
               unset = "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.18.8-hotspot")
java_bin  <- file.path(JAVA_HOME, "bin")

if (!dir.exists(JAVA_HOME)) {
  stop("Configured JAVA_HOME does not exist: ", JAVA_HOME,
       "\nSet the JAVA_HOME environment variable to your JDK 17 installation.")
}

Sys.setenv(JAVA_HOME = JAVA_HOME)
Sys.setenv(PATH = paste(
  normalizePath(java_bin, winslash = "/", mustWork = FALSE),
  Sys.getenv("PATH"), sep = .Platform$path.sep
))

# On Windows: add the JDBC auth DLL directory to java.library.path.
# On Linux/macOS: SQL auth is used; no DLL needed.
java_params <- paste0("-Djava.home=", normalizePath(JAVA_HOME, winslash = "/", mustWork = FALSE))
if (.Platform$OS.type == "windows") {
  auth_dll_dir <- normalizePath(
    file.path(getwd(), "drivers", "sqljdbc_13.2", "enu", "auth", "x64"),
    winslash = "/", mustWork = FALSE
  )
  if (dir.exists(auth_dll_dir)) {
    java_params <- c(java_params, paste0("-Djava.library.path=", auth_dll_dir))
    Sys.setenv(PATH = paste(
      normalizePath(auth_dll_dir, winslash = "/", mustWork = FALSE),
      Sys.getenv("PATH"), sep = .Platform$path.sep
    ))
  }
}
options(java.parameters = java_params)

# --- Activate renv (creates library in project directory) ---------------------
if (file.exists("renv/activate.R")) source("renv/activate.R")

# --- CRAN mirror --------------------------------------------------------------
options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))

# --- Ensure remotes / rJava are available for GitHub installs ----------------
if (!requireNamespace("remotes", quietly = TRUE)) renv::install("remotes")
if (!requireNamespace("rJava", quietly = TRUE)) renv::install("rJava")

# --- CRAN packages ------------------------------------------------------------
cran_packages <- c(
  # OHDSI CRAN-listed packages
  "SqlRender",           # SQL dialect translation
  "DatabaseConnector",   # JDBC database connectivity (>= 6.0)
  "Andromeda",           # Disk-based data frames for large cohort data
  "ParallelLogger",      # Logging framework used across OHDSI tools
  "CirceR",              # Cohort expression evaluation
  "FeatureExtraction",   # Feature engineering package used by PLP
  "CohortGenerator",          # Cohort generation helpers
  "PatientLevelPrediction",   # Supervised learning pipeline (PLP)
  "CohortMethod",             # Active comparator new-user / PS matching design
  "EvidenceSynthesis",        # Meta-analysis across databases / sites
  "EmpiricalCalibration",     # P-value and CI calibration using negative controls
  "SelfControlledCaseSeries", # SCCS design
  # ML backend packages (used by various PLP model types)
  "glmnet",              # Regularised regression (LASSO / Ridge / EN)
  "xgboost",             # Gradient boosted trees
  "randomForest",        # Random forest (optional)
  # Discrimination and calibration metrics
  "pROC",                # AUROC with confidence intervals
  "PRROC",               # Area under precision-recall curve (AUPRC)
  # Tidyverse data wrangling
  "ggplot2",             # Plots: calibration, ROC, feature importance
  "dplyr",               # filter, mutate, join, summarise
  "tibble",
  "tidyr",               # pivot_longer, pivot_wider, unnest
  "readr",               # Fast CSV reading / writing
  # Reporting and output
  "officer",             # Word (.docx) report generation
  "flextable",           # Formatted tables for Word / HTML output
  "openxlsx",            # Excel (.xlsx) output
  "knitr",               # R Markdown report rendering
  # Dev / housekeeping
  "remotes",
  "languageserver",
  "devtools"
)

installed <- rownames(installed.packages())
for (pkg in cran_packages) {
  if (!pkg %in% installed) {
    message("Installing ", pkg, " from CRAN ...")
    renv::install(pkg)
  }
}

# --- OHDSI GitHub-only packages -----------------------------------------------
# Keep this list limited to packages that are not available on CRAN.

github_packages <- list(
  list(package = "ETLSyntheaBuilder",      repo = "OHDSI/ETL-Synthea",            ref = "v2.1.0"),
  list(package = "Achilles",               repo = "OHDSI/Achilles",               ref = "main"),
  list(package = "DataQualityDashboard",   repo = "OHDSI/DataQualityDashboard",   ref = "main"),
  list(package = "CohortDiagnostics",      repo = "OHDSI/CohortDiagnostics",      ref = "main")
)

available_cran <- tryCatch(rownames(available.packages()), error = function(e) character(0))

for (p in github_packages) {
  pkg_name <- p$package

  # Use renv::install() with the "owner/repo@ref" specifier so renv records
  # the GitHub source in its metadata and renv::snapshot() can track it.
  # This is intentionally not skipped even if already installed, because a
  # prior binary install may have left the package with an "unknown source"
  # that would cause renv::snapshot() to abort.
  message("Installing ", pkg_name, " from GitHub via renv (", p$repo, " @ ", p$ref, ") ...")
  renv::install(paste0(p$repo, "@", p$ref))
}

# --- reticulate + Python model constraints -----------------------------------
# If model/python_model/ exists this study uses a Python-backed PLP model.
# reticulate is the R-Python bridge.  Version constraints for the Python
# environment are declared in model/python_requirements.txt — apply them
# before running the analysis (see instructions in that file).
if (dir.exists("model/python_model")) {
  if (!requireNamespace("reticulate", quietly = TRUE)) {
    message("Installing reticulate ...")
    renv::install("reticulate", prompt = FALSE)
  }

  req_file <- "setup/python_requirements.txt"
  if (file.exists(req_file)) {
    message("\n*** Python model constraints detected ***")
    message("  setup/python_requirements.txt specifies version pins required")
    message("  for pickle compatibility with model/python_model/model.pkl.")
    message("  Ensure your Python virtualenv satisfies these constraints before")
    message("  running the analysis pipeline.")
    message("  See setup/python_requirements.txt for install instructions.")
    message("  Inside the devcontainer /opt/mlenv is pre-configured — no action needed.")
  }
}

# --- Snapshot environment ----------------------------------------------------
if (requireNamespace("renv", quietly = TRUE)) {
  renv::snapshot(prompt = FALSE)
}

# --- Provision JDBC driver bundle --------------------------------------------
# Downloads mssql-jdbc-13.2.1.zip from Microsoft and stages the jar + auth DLL
# into drivers/ if not already present.  Safe to call repeatedly.
message("\nProvisioning JDBC driver ...")
source("config.R")
source("R/drivers.R")
ensure_jdbc_bundle(get_validation_config())
message("JDBC driver provisioned.")

message("\nAll packages installed and JDBC driver ready.")
message("Next step: Rscript workflow/07_setup_analysis_env.R to verify the environment.")
