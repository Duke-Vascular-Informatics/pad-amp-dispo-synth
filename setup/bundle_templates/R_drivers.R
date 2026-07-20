# =============================================================================
# R/drivers.R — transportable bundle edition
#
# The MSSQL JDBC 13.2.1 JAR is bundled directly in drivers/ so no download is
# needed. This file provides ensure_jdbc_bundle() which simply verifies the JAR
# is present and sets the DATABASECONNECTOR_JAR_FOLDER environment variable.
#
# On the local Windows dev setup the equivalent file downloads and extracts the
# full JDBC zip. On HPC/Linux the zip extraction step is skipped — the JAR is
# included in the bundle directly.
# =============================================================================

# ---------------------------------------------------------------------------
# ensure_jdbc_bundle()
#
# Verifies that a mssql-jdbc*.jar exists in config$jdbc_runtime_dir and sets
# the DATABASECONNECTOR_JAR_FOLDER env var so DatabaseConnector can find it.
# Calls stop() with an actionable message if the JAR is absent.
# ---------------------------------------------------------------------------
ensure_jdbc_bundle <- function(config) {
  dir <- config$jdbc_runtime_dir

  jars <- list.files(dir,
                     pattern = "mssql-jdbc.*\\.jar$",
                     full.names = TRUE)

  if (length(jars) == 0) {
    stop(
      "No mssql-jdbc*.jar found in: ", dir, "\n",
      "Expected: drivers/mssql-jdbc-13.2.1.jre11.jar\n",
      "Re-unzip the transportable bundle or contact the study coordinator to obtain the JAR."
    )
  }

  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = normalizePath(dir, mustWork = FALSE))
  message("JDBC driver verified: ", jars[[1]])
  invisible(config)
}
