# =============================================================================
# R/connection.R
# Build a DatabaseConnector connectionDetails object for the OMOP SQL Server
# instance.  The JDBC driver is provisioned locally by R/drivers.R and does
# not depend on any external project.
# =============================================================================

# Set Java environment variables.
# On Windows: also loads the JDBC auth DLL for Windows Integrated Security.
# On Linux/macOS: just sets JAVA_HOME and the jar folder; SQL auth is used.
configure_java <- function(config) {
  if (!dir.exists(config$java_home)) {
    stop("JAVA_HOME directory not found: ", config$java_home,
         "\nUpdate java_home in config.R or set the JAVA_HOME environment variable.")
  }

  Sys.setenv(JAVA_HOME = config$java_home)
  Sys.setenv(PATH = paste(
    normalizePath(config$java_bin, winslash = "/", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  ))

  if (.Platform$OS.type == "windows" && dir.exists(config$jdbc_auth_dir)) {
    options(java.parameters = paste0(
      "-Djava.library.path=",
      normalizePath(config$jdbc_auth_dir, winslash = "/")
    ))
    Sys.setenv(PATH = paste(
      normalizePath(config$jdbc_auth_dir, winslash = "/"),
      Sys.getenv("PATH"),
      sep = .Platform$path.sep
    ))
  } else {
    options(java.parameters = paste0(
      "-Djava.home=",
      normalizePath(config$java_home, winslash = "/", mustWork = FALSE)
    ))
  }

  # Tell DatabaseConnector where the JDBC jar lives.
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = config$jdbc_runtime_dir)

  invisible(config)
}

# Build a DatabaseConnector connectionDetails object.
# Uses SQL auth (SA user + password from config) on all platforms.
build_connection_details <- function(config) {
  # Download and stage the JDBC bundle on first run; no-op on subsequent runs.
  ensure_jdbc_bundle(config)
  configure_java(config)

  DatabaseConnector::createConnectionDetails(
    dbms         = config$dbms,
    server       = config$server,
    user         = config$user,
    password     = config$password,
    pathToDriver = config$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", config$database,
      ";trustServerCertificate=true",
      ";portNumber=", config$sql_server_port,
      ";connectRetryCount=3",
      ";connectRetryInterval=10",
      ";socketTimeout=0",    # disable socket timeout — prevents connection drop during large batch inserts
      ";queryTimeout=0"      # disable per-statement query timeout for bulk ETL operations
    )
  )
}

# Return TRUE for transient connectivity issues that should be retried.
is_transient_db_error <- function(err_msg) {
  if (is.null(err_msg) || !nzchar(err_msg)) {
    return(FALSE)
  }

  msg <- tolower(err_msg)
  transient_patterns <- c(
    "connection reset",
    "error reading prelogin response",
    "prelogin error",
    "timed out",
    "timeout",
    "connection refused",
    "transport-level error",
    "communications link failure",
    "broken pipe",
    "connection closed",
    "connection is broken",
    "recovery is not possible",
    "socket",
    "io exception",
    "cannot open database",
    "requested by the login"
  )
  any(vapply(transient_patterns, grepl, logical(1), x = msg, fixed = TRUE))
}

# Execute an expression with exponential backoff retry for transient DB errors.
with_db_retry <- function(
    expr,
    operation_name = "database operation",
    max_attempts = 5L,
    initial_delay_seconds = 2,
    backoff_multiplier = 2) {
  if (max_attempts < 1) {
    stop("max_attempts must be >= 1")
  }

  attempt <- 1L
  delay <- initial_delay_seconds
  repeat {
    res <- try(eval.parent(substitute(expr)), silent = TRUE)
    if (!inherits(res, "try-error")) {
      return(res)
    }

    err_msg <- as.character(res)
    is_transient <- is_transient_db_error(err_msg)
    if (!is_transient || attempt >= max_attempts) {
      stop(
        operation_name,
        " failed after ", attempt, " attempt(s). Last error: ", err_msg
      )
    }

    message(
      operation_name,
      " failed (attempt ", attempt, "/", max_attempts,
      "); retrying in ", delay, "s. Error: ", err_msg
    )
    Sys.sleep(delay)
    delay <- delay * backoff_multiplier
    attempt <- attempt + 1L
  }
}

connect_with_retry <- function(
    connection_details,
    max_attempts = 5L,
    initial_delay_seconds = 2) {
  with_db_retry(
    DatabaseConnector::connect(connection_details),
    operation_name = "DatabaseConnector::connect",
    max_attempts = max_attempts,
    initial_delay_seconds = initial_delay_seconds
  )
}

query_sql_with_retry <- function(
    connection,
    sql,
    snake_case_to_camel_case = FALSE,
    max_attempts = 3L,
    initial_delay_seconds = 1) {
  with_db_retry(
    DatabaseConnector::querySql(
      connection,
      sql,
      snakeCaseToCamelCase = snake_case_to_camel_case
    ),
    operation_name = "DatabaseConnector::querySql",
    max_attempts = max_attempts,
    initial_delay_seconds = initial_delay_seconds
  )
}

execute_sql_with_retry <- function(
    connection,
    sql,
    max_attempts = 3L,
    initial_delay_seconds = 1) {
  with_db_retry(
    DatabaseConnector::executeSql(connection, sql),
    operation_name = "DatabaseConnector::executeSql",
    max_attempts = max_attempts,
    initial_delay_seconds = initial_delay_seconds
  )
}

run_db_preflight <- function(
    connection_details,
    required_successes = 3L,
    max_attempts = 10L,
    delay_seconds = 2) {
  if (required_successes < 1) {
    stop("required_successes must be >= 1")
  }
  if (max_attempts < required_successes) {
    stop("max_attempts must be >= required_successes")
  }

  consecutive_successes <- 0L
  attempt <- 1L
  while (attempt <= max_attempts) {
    ok <- FALSE
    conn <- NULL
    res <- try({
      conn <- connect_with_retry(connection_details, max_attempts = 1L)
      query_sql_with_retry(conn, "SELECT 1 AS ok;", max_attempts = 1L)
      ok <- TRUE
    }, silent = TRUE)
    if (!is.null(conn)) {
      try(DatabaseConnector::disconnect(conn), silent = TRUE)
    }

    if (ok) {
      consecutive_successes <- consecutive_successes + 1L
      if (consecutive_successes >= required_successes) {
        message(
          "DB preflight passed: ", consecutive_successes,
          " consecutive successful checks."
        )
        return(invisible(TRUE))
      }
    } else {
      consecutive_successes <- 0L
      err_msg <- if (inherits(res, "try-error")) as.character(res) else "unknown error"
      message("DB preflight check failed (attempt ", attempt, "/", max_attempts, "): ", err_msg)
    }

    Sys.sleep(delay_seconds)
    attempt <- attempt + 1L
  }

  stop(
    "DB preflight failed: did not reach ", required_successes,
    " consecutive successful checks in ", max_attempts, " attempts."
  )
}
