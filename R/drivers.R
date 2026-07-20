# =============================================================================
# R/drivers.R
# Self-contained JDBC driver provisioning for the Microsoft SQL Server JDBC
# driver (mssql-jdbc 13.2.1).
#
# On first run, ensure_jdbc_bundle() downloads the official Microsoft JDBC
# zip from go.microsoft.com, extracts the jre11 jar and Windows auth DLL into
# the project-local drivers/ folder, and copies the jar to drivers/jdbc-runtime/
# so that DatabaseConnector can find it via DATABASECONNECTOR_JAR_FOLDER.
#
# Subsequent runs detect that the files already exist and return immediately,
# so there is no unnecessary network traffic.
# =============================================================================

# Download the JDBC zip (once) and unzip into drivers/
download_jdbc_zip <- function(config) {
  dir.create(config$path_to_driver, recursive = TRUE, showWarnings = FALSE)

  jdbc_zip <- file.path(
    config$path_to_driver,
    paste0("mssql-jdbc-", config$sql_server_jdbc_version, ".zip")
  )

  if (!file.exists(jdbc_zip)) {
    message("Downloading Microsoft JDBC driver ", config$sql_server_jdbc_version,
            " ...")
    utils::download.file(
      url      = config$jdbc_zip_url,
      destfile = jdbc_zip,
      mode     = "wb",
      quiet    = FALSE
    )
    message("Download complete: ", jdbc_zip)
  }

  if (!dir.exists(config$jdbc_home)) {
    message("Extracting JDBC zip ...")
    utils::unzip(jdbc_zip, exdir = config$path_to_driver)
    message("Extraction complete: ", config$jdbc_home)
  }

  invisible(jdbc_zip)
}

# Locate the jre11 jar inside the extracted bundle.
find_jdbc_jar <- function(config) {
  pinned <- file.path(
    config$jdbc_jar_folder,
    paste0("mssql-jdbc-", config$sql_server_jdbc_version, ".jre11.jar")
  )

  candidates <- unique(c(
    pinned,
    list.files(config$jdbc_jar_folder,
               pattern = "mssql-jdbc-.*\\.jre11\\.jar$",
               full.names = TRUE)
  ))
  candidates <- candidates[file.exists(candidates)]

  if (length(candidates) == 0) {
    stop(
      "Cannot find mssql-jdbc-*.jre11.jar in: ", config$jdbc_jar_folder, "\n",
      "The JDBC zip may not have extracted correctly.  ",
      "Delete drivers/ and re-run to trigger a fresh download."
    )
  }

  candidates[[1]]
}

# Copy the jar into drivers/jdbc-runtime/ so DatabaseConnector can discover it.
stage_runtime_jar <- function(jdbc_jar, config) {
  dir.create(config$jdbc_runtime_dir, recursive = TRUE, showWarnings = FALSE)
  runtime_jar <- file.path(config$jdbc_runtime_dir, basename(jdbc_jar))

  if (!file.exists(runtime_jar)) {
    file.copy(jdbc_jar, runtime_jar, overwrite = FALSE)
    message("Staged runtime jar: ", runtime_jar)
  }

  runtime_jar
}

# Verify the Windows Integrated Security auth DLL is present.
# The DLL ships inside the JDBC zip under enu/auth/x64/ and is needed to
# authenticate with SQL Server using Windows Kerberos / NTLM.
# On non-Windows platforms (Linux, macOS) this check is skipped because
# SQL auth is used instead of Windows Integrated Security.
check_auth_dll <- function(config) {
  if (.Platform$OS.type != "windows") {
    return(invisible(NULL))
  }

  dll_dir <- config$jdbc_auth_dir
  if (!dir.exists(dll_dir)) {
    stop(
      "Windows auth DLL folder not found after extraction: ", dll_dir, "\n",
      "Expected layout: drivers/sqljdbc_13.2/enu/auth/x64/\n",
      "Delete drivers/ and re-run to trigger a fresh download + extraction."
    )
  }

  dlls <- list.files(dll_dir, pattern = "\\.dll$", full.names = TRUE)
  if (length(dlls) == 0) {
    stop(
      "No .dll files found in: ", dll_dir, "\n",
      "The JDBC zip may have extracted incompletely.  ",
      "Delete drivers/ and re-run."
    )
  }

  invisible(dlls[[1]])
}

# ---------------------------------------------------------------------------
# Main entry point.  Call this once before building a connection.
# Safe to call repeatedly – skips all work if the runtime jar exists.
# ---------------------------------------------------------------------------
ensure_jdbc_bundle <- function(config) {
  runtime_jar <- file.path(
    config$jdbc_runtime_dir,
    paste0("mssql-jdbc-", config$sql_server_jdbc_version, ".jre11.jar")
  )

  if (file.exists(runtime_jar)) {
    # Fast path: driver already staged, nothing to do.
    return(invisible(config))
  }

  message("JDBC driver not found – provisioning now ...")
  download_jdbc_zip(config)
  jdbc_jar <- find_jdbc_jar(config)
  check_auth_dll(config)
  stage_runtime_jar(jdbc_jar, config)

  message("JDBC driver ready: ", runtime_jar)
  invisible(config)
}
