#!/usr/bin/env Rscript
# =============================================================================
# install_packages.R — __STUDY_LABEL__ bundle
#
# Installs all R packages required to run the analysis pipeline and generate
# the manuscript-format Word report.
#
# Do not run this directly — use the wrapper shell script instead:
#   bash install_r_packages.sh
#
# That script activates the openjdk conda environment (setting JAVA_HOME)
# and sets R_LIBS_USER before calling this script, both of which are required
# for rJava to compile correctly into a user-writable library.
#
# WHY NO R CMD javareconf:
#   R CMD javareconf writes to $(R RHOME)/etc/javaconf, a system-wide
#   directory. On HPC nodes users do not have write access there.
#   It is also unnecessary: rJava reads JAVA_HOME directly from the
#   environment at compile time, so as long as JAVA_HOME is set via
#   `conda activate openjdk`, rJava will compile without javareconf.
#
# WHAT IS INSTALLED:
#   Core pipeline  : DatabaseConnector, SqlRender, dplyr, ggplot2, pROC,
#                    PRROC, readr, scales
#   Report support : officer, flextable, writexl
#
# WHAT IS *NOT* INSTALLED (and why):
#   rJava     — installed automatically as a hard dep of DatabaseConnector.
#   RPostgres — optional dep for PostgreSQL; not needed for SQL Server,
#               and requires system headers unavailable on HPC nodes.
#   ssh       — optional dep for tunnel connections; not needed for Kerberos
#               JDBC approach, and requires libssh2 system headers.
#
#   Both are excluded via:
#     dependencies = c("Depends", "Imports", "LinkingTo")
#
# Uses the Duke CRAN mirror (archive.linux.duke.edu/cran) accessible from
# HPC nodes without an external internet connection.
# =============================================================================

options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

message("Installing R packages for __STUDY_LABEL__ bundle ...")
message("CRAN mirror: ", getOption("repos")["CRAN"])

# ---------------------------------------------------------------------------
# Step 1 — Verify JAVA_HOME and that jni.h is present
# ---------------------------------------------------------------------------
java_home <- Sys.getenv("JAVA_HOME")

if (nchar(trimws(java_home)) == 0) {
  stop(
    "JAVA_HOME is not set.\n\n",
    "Do not run install_packages.R directly.\n",
    "Use the wrapper script instead:\n",
    "  bash install_r_packages.sh\n\n",
    "That script runs `conda activate openjdk` which sets JAVA_HOME."
  )
}

message("JAVA_HOME: ", java_home)

jni_header <- file.path(java_home, "include", "jni.h")
if (!file.exists(jni_header)) {
  stop(
    "JDK header not found: ", jni_header, "\n\n",
    "The openjdk conda environment may not include JDK development headers.\n",
    "Verify with:\n",
    "  conda activate openjdk\n",
    "  find $JAVA_HOME/include -name 'jni.h'\n\n",
    "If jni.h is missing, reinstall the conda openjdk package:\n",
    "  conda install -n openjdk conda-forge::openjdk --force-reinstall"
  )
}

message("JDK headers found: ", jni_header)

lib_path <- .libPaths()[1]
message("Package library: ", lib_path)
if (!file.access(lib_path, mode = 2) == 0) {
  stop(
    "R package library is not writable: ", lib_path, "\n\n",
    "Do not run install_packages.R directly.\n",
    "Use the wrapper script instead:\n",
    "  bash install_r_packages.sh\n\n",
    "That script sets R_LIBS_USER to a user-writable directory."
  )
}

# ---------------------------------------------------------------------------
# Step 2 — Define required packages
# ---------------------------------------------------------------------------
core_packages <- c(
  "DatabaseConnector",   # OMOP CDM query via JDBC (pulls in rJava as a hard dep)
  "SqlRender",           # SQL parameterisation and dialect translation
  "dplyr",               # data manipulation
  "ggplot2",             # calibration and ROC plots
  "pROC",                # AUROC computation
  "PRROC",               # AUPRC computation
  "readr",               # CSV I/O
  "scales"               # axis/label formatting (percent scales, pretty breaks)
)

report_packages <- c(
  "officer",             # Word document generation (.docx)
  "flextable",           # formatted tables inside Word document
  "writexl"              # Excel export (.xlsx); pure R, no system libs
)

all_packages <- c(core_packages, report_packages)

# ---------------------------------------------------------------------------
# Step 3 — Install missing packages
# ---------------------------------------------------------------------------
missing_packages <- all_packages[
  !sapply(all_packages, requireNamespace, quietly = TRUE)
]

if (length(missing_packages) == 0) {
  message("All packages already installed — nothing to do.")
} else {
  message("Installing ", length(missing_packages), " package(s): ",
          paste(missing_packages, collapse = ", "))

  install.packages(
    missing_packages,
    dependencies = c("Depends", "Imports", "LinkingTo"),
    lib          = lib_path
  )
}

# ---------------------------------------------------------------------------
# Step 4 — Verify all packages load successfully
# ---------------------------------------------------------------------------
failed <- all_packages[
  !sapply(all_packages, requireNamespace, quietly = TRUE)
]

if (length(failed) > 0) {
  stop(
    "The following package(s) failed to install or load:\n",
    paste("  -", failed, collapse = "\n"), "\n\n",
    "Common causes on HPC:\n",
    "  - rJava: JAVA_HOME not set or jni.h not found.\n",
    "           Fix: use 'bash install_r_packages.sh' (not Rscript directly).\n",
    "  - Network: cannot reach the Duke CRAN mirror.\n",
    "           Fix: check HPC internet access and retry.\n",
    "  - DatabaseConnector: rJava failed, so it could not load.\n",
    "           Fix: resolve rJava first, then retry."
  )
}

message("")
message("All ", length(all_packages), " packages installed and verified.")
message("rJava version: ", as.character(packageVersion("rJava")))
message("DatabaseConnector version: ", as.character(packageVersion("DatabaseConnector")))
message("Package library: ", lib_path)
message("")
message("Next steps:")
message("  1. Confirm OMOP_RESULTS_SCHEMA in .env is set to your write schema.")
message("  2. Ensure Kerberos ticket is valid: klist")
message("     If expired: export KRB5CCNAME=FILE:~/krb5cc_java && kinit")
message("  3. Run: conda activate openjdk && bash run_analysis.sh")
