#!/usr/bin/env bash
# =============================================================================
# install_r_packages.sh
#
# Step 2 of 2 — R package installation for the __STUDY_LABEL__ bundle
# on the protected analytic space (HPC cluster).
#
# Run this AFTER setup_env.sh has completed successfully.
# You only need to run this once — packages persist between sessions.
#
# FULL SETUP SEQUENCE (first time):
#   bash setup_env.sh             # Step 1 — Java + Kerberos
#   bash install_r_packages.sh    # Step 2 — R packages (this script)
#
# What this script does:
#   1. Loads miniforge and activates the openjdk conda environment so that
#      JAVA_HOME is set correctly before R package compilation begins.
#   2. Runs `Rscript install_packages.R`, which:
#        a. Verifies JAVA_HOME and jni.h are present (required for rJava).
#        b. Installs all required R packages from the Duke CRAN mirror,
#           skipping any that are already installed.
#        c. Verifies all packages load successfully and prints a summary.
#
# Prerequisites:
#   - setup_env.sh must have been run first (conda env must exist)
#   - R must be on PATH (module load R, or available in conda env)
# =============================================================================

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR"

echo ""
echo "======================================================================"
echo "  __STUDY_LABEL__ — R Package Installation (Step 2 of 2)"
echo "  Bundle: $BUNDLE_DIR"
echo "======================================================================"
echo ""

# -----------------------------------------------------------------------------
# Step 1 — Activate conda environment so JAVA_HOME is set for compilation
# -----------------------------------------------------------------------------
echo "[1/4] Activating conda environment ..."

module load miniforge

if ! conda env list | grep -qE '^openjdk[[:space:]]'; then
  echo "ERROR: conda env 'openjdk' not found."
  echo "       Please run setup_env.sh first:"
  echo "         bash setup_env.sh"
  exit 1
fi

conda activate openjdk

echo "      JAVA_HOME  = ${JAVA_HOME:-<not set>}"
echo ""

# -----------------------------------------------------------------------------
# Step 2 — Fix linker paths for rJava compilation
#
# R is installed system-wide and was compiled against system libraries.
# conda's linker only searches inside the conda env by default; adding
# system library directories to LDFLAGS lets it find R's system dependencies.
# -----------------------------------------------------------------------------
echo "[2/4] Configuring linker paths for rJava compilation ..."

SYS_LIB_PATHS="/usr/lib64:/usr/lib/x86_64-linux-gnu:/usr/lib"

export LDFLAGS="-L${CONDA_PREFIX}/lib $(echo $SYS_LIB_PATHS | tr ':' '\n' | sed 's/^/-L/' | tr '\n' ' ') ${LDFLAGS:-}"
export CPPFLAGS="-I${CONDA_PREFIX}/include -I/usr/include ${CPPFLAGS:-}"

JVM_LIB=$(find "${CONDA_PREFIX}" -name "libjvm.so" 2>/dev/null | head -1)
if [[ -z "$JVM_LIB" ]]; then
  JVM_LIB=$(find "${JAVA_HOME}" -name "libjvm.so" 2>/dev/null | head -1)
fi
if [[ -z "$JVM_LIB" ]]; then
  echo "WARNING: libjvm.so not found — rJava may fail to load after install."
  JVM_LIB_DIR=""
else
  JVM_LIB_DIR="$(dirname "$JVM_LIB")"
  echo "      libjvm.so found: $JVM_LIB"
fi

export LD_LIBRARY_PATH="${JVM_LIB_DIR:+${JVM_LIB_DIR}:}${CONDA_PREFIX}/lib:${SYS_LIB_PATHS}:${LD_LIBRARY_PATH:-}"
echo "      LD_LIBRARY_PATH: ${LD_LIBRARY_PATH}"
echo ""

# -----------------------------------------------------------------------------
# Step 3 — Set a user-writable R package library
# -----------------------------------------------------------------------------
echo "[3/4] Configuring user R package library ..."

R_VERSION=$(Rscript -e "cat(paste(R.version\$major, R.version\$minor, sep='.'))" 2>/dev/null | tr -d ' ')
R_PLATFORM=$(Rscript -e "cat(R.version\$platform)" 2>/dev/null | tr -d ' ')
USER_RLIB="${HOME}/R/${R_PLATFORM}-library/${R_VERSION%.*}"

mkdir -p "$USER_RLIB"
export R_LIBS_USER="$USER_RLIB"

echo "      R version  : $R_VERSION"
echo "      R platform : $R_PLATFORM"
echo "      R_LIBS_USER: $R_LIBS_USER"
echo ""

# -----------------------------------------------------------------------------
# Step 4 — Run the R package installer
# -----------------------------------------------------------------------------
echo "[4/4] Installing R packages ..."

if ! command -v Rscript &>/dev/null; then
  echo "ERROR: Rscript not found on PATH."
  echo "       Load the R module before running this script:"
  echo "         module load R"
  exit 1
fi

echo "      Using R: $(command -v Rscript)"
echo ""

Rscript install_packages.R

echo ""
cat <<SUMMARY
======================================================================
  R package installation complete.

  To run the analysis:
       conda activate openjdk
       bash run_analysis.sh

  Confirm OMOP_RESULTS_SCHEMA in .env is set to your write schema
  (format: domain\netid) before running the analysis.
======================================================================
SUMMARY
