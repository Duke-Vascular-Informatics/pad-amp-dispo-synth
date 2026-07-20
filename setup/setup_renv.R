# =============================================================================
# setup_renv.R
# One-time renv initialisation for the SSI validation project.
#
# Run this FIRST in a fresh R session, then run setup/install_packages.R.
# Usage: source("setup/setup_renv.R")
# =============================================================================

options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))

# Install renv if not present
if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

# Initialise renv only if not already done (preserves existing lock file)
if (!file.exists("renv.lock")) {
  renv::init(bare = TRUE)   # bare = TRUE: set up renv without auto-installing
} else {
  renv::activate()
}

message("renv initialised.")
message("Next step: source('setup/install_packages.R') to install PLP and dependencies.")
