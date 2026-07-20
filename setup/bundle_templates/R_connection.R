# =============================================================================
# R/connection.R — transportable bundle edition
#
# Configures Java and connects to SQL Server via Kerberos authentication on
# protected analytic space, following the approach provided by your HPC support team.
#
# Authentication model:
#   - The user runs `kinit` (via setup_env.sh) before starting R.
#     The Kerberos ticket is stored at ~/krb5cc_java.
#   - A JAAS config (drivers/jaas.conf) is written at runtime pointing the
#     MSSQL JDBC driver at the Krb5LoginModule and ticket cache.
#   - The JVM is explicitly initialised via rJava::.jinit() BEFORE
#     library(DatabaseConnector) is called — this is required so that
#     java.parameters (including the JAAS path) take effect.
#   - Two JARs are added to the classpath:
#       1. hpc-jdbc-wrapper.jar  (your HPC support team wrapper, ~/drivers/)
#       2. mssql-jdbc-13.2.1.jre11.jar       (bundled in drivers/)
#   - The JDBC URL uses integratedSecurity=true + authenticationScheme=JavaKerberos.
#   - No username or password is embedded in the script.
#
# Call order (enforced by run_analysis.R):
#   1. source("config.R")          — resolves java_home, hpc_jar, jdbc_runtime_dir
#   2. configure_java_hpc(config) — sets java.parameters, writes jaas.conf,
#                                    calls .jinit(), adds JARs to classpath
#   3. library(DatabaseConnector)  — JVM already running; picks up classpath
#   4. build_connection_details()  — constructs JDBC URL, returns ConnectionDetails
# =============================================================================

# ---------------------------------------------------------------------------
# write_jaas_conf()
#
# Generates a JAAS (Java Authentication and Authorization Service) config file
# at jaas_path and returns its absolute path.
#
# The MSSQL JDBC driver requires a JAAS config when using JavaKerberos
# authentication so the JVM knows which Kerberos login module to use.
# The generated file points the driver at the Krb5LoginModule and tells it
# to use the existing ticket cache obtained by `kinit` (doNotPrompt=true).
#
# The ticketCache path is taken from the KRB5CCNAME environment variable
# (set by setup_env.sh as FILE:~/krb5cc_java) with the FILE: prefix
# stripped and ~ expanded.  If KRB5CCNAME is unset the ticketCache line is
# omitted and the JVM falls back to its default cache location.
#
# The file is (re)written every time configure_java_hpc() is called so the
# path is always current; this is safe because configure_java_hpc() must
# run before rJava is loaded.
# ---------------------------------------------------------------------------
write_jaas_conf <- function(jaas_path) {

  # Resolve Kerberos ticket cache path from the environment variable set by
  # setup_env.sh: KRB5CCNAME=FILE:~/krb5cc_java
  krb5_env  <- Sys.getenv("KRB5CCNAME")
  krb5_file <- path.expand(sub("^FILE:", "", krb5_env))

  # Standard JAAS stanza for the MSSQL JDBC Kerberos login module.
  # SQLJDBCDriver is the entry name the MSSQL JDBC driver looks up by default.
  # JAAS syntax requires the semicolon to terminate the LAST option line —
  # it cannot appear on its own line or the JVM will fail to parse the stanza.
  if (nchar(krb5_file) > 0) {
    # ticketCache is the last line — semicolon appended to it.
    last_line <- paste0('   ticketCache="', krb5_file, '";\n')
    middle    <- "   useTicketCache=true\n"
  } else {
    # useTicketCache is the last line when no explicit cache path is available.
    last_line <- "   useTicketCache=true;\n"
    middle    <- ""
  }

  jaas_content <- paste0(
    "SQLJDBCDriver {\n",
    "   com.sun.security.auth.module.Krb5LoginModule required\n",
    "   doNotPrompt=true\n",
    middle,
    last_line,
    "};\n"
  )

  writeLines(jaas_content, jaas_path)
  message("JAAS config written: ", jaas_path)
  invisible(jaas_path)
}

# ---------------------------------------------------------------------------
# configure_java_hpc()
#
# Sets JAVA_HOME and PATH, writes jaas.conf, sets java.parameters, then
# explicitly initialises the JVM via rJava::.jinit() and adds both JDBC JARs
# to the classpath.
#
# MUST be called BEFORE library(DatabaseConnector) — run_analysis.R does this.
# Once the JVM is running, java.parameters cannot be changed.
# ---------------------------------------------------------------------------
configure_java_hpc <- function(config) {
  java_home <- config$java_home

  if (is.null(java_home) || nchar(trimws(java_home)) == 0) {
    stop(
      "java_home is empty in config. Activate the conda openjdk environment\n",
      "before starting R:\n",
      "  conda activate openjdk\n",
      "  bash run_analysis.sh"
    )
  }

  Sys.setenv(JAVA_HOME = java_home)

  # Prepend <java_home>/bin to PATH so the correct java binary is first.
  java_bin <- file.path(java_home, "bin")
  Sys.setenv(PATH = paste(java_bin, Sys.getenv("PATH"), sep = ":"))

  # Add $JAVA_HOME/lib/server to LD_LIBRARY_PATH so the dynamic linker can
  # find libjvm.so at runtime when rJava calls dyn.load().
  # Without this, rJava compiles successfully but fails to load on the protected analytic space with:
  #   "libjvm.so: cannot open shared object file: No such file or directory"
  # The JVM shared library lives inside the conda env's JDK rather than in a
  # standard system path, so it must be added explicitly before .jinit().
  jvm_lib <- file.path(java_home, "lib", "server")
  current_ld <- Sys.getenv("LD_LIBRARY_PATH")
  if (!grepl(jvm_lib, current_ld, fixed = TRUE)) {
    Sys.setenv(LD_LIBRARY_PATH = paste(jvm_lib, current_ld, sep = ":"))
  }
  message("LD_LIBRARY_PATH includes: ", jvm_lib)

  # Write jaas.conf to drivers/ and capture its absolute path.
  jaas_conf_path <- normalizePath(
    file.path(config$jdbc_runtime_dir, "jaas.conf"),
    mustWork = FALSE
  )
  write_jaas_conf(jaas_conf_path)

  # Set JVM startup options BEFORE the JVM is initialised.
  # -Djava.home                       : confirm java.home for rJava.
  # -Djava.security.auth.login.config : JAAS config for Kerberos login module.
  # -Xmx4g                            : 4 GB heap for large JDBC result sets.
  #
  # --add-opens flags (Java 17+ module system compatibility):
  #   Java 9+ introduced the module system (JPMS) which restricts access to
  #   internal JDK classes by default.  The MSSQL JDBC driver and Kerberos
  #   authentication code access several internal packages that are now
  #   encapsulated in modules.  Without --add-opens, the JVM raises:
  #     "Could not initialize class sun.security.util.FilePermCompat"
  #   or similar NoClassDefFoundError / InaccessibleObjectException errors.
  #   Each --add-opens line opens the named package to all unnamed modules
  #   (ALL-UNNAMED = code on the classpath, including our JDBC JARs).
  options(java.parameters = c(
    paste0("-Djava.home=",                       normalizePath(java_home, mustWork = FALSE)),
    paste0("-Djava.security.auth.login.config=", jaas_conf_path),
    "-Xmx4g",
    # Security / Kerberos internals accessed by MSSQL JDBC + Krb5LoginModule
    "--add-opens=java.base/sun.security.util=ALL-UNNAMED",
    "--add-opens=java.base/sun.security.krb5=ALL-UNNAMED",
    "--add-opens=java.base/sun.security.krb5.internal=ALL-UNNAMED",
    "--add-opens=java.base/sun.security.krb5.internal.ccache=ALL-UNNAMED",
    "--add-opens=java.base/sun.security.krb5.internal.crypto=ALL-UNNAMED",
    "--add-opens=java.base/sun.security.krb5.internal.ktab=ALL-UNNAMED",
    # JAAS internals accessed by Krb5LoginModule
    "--add-opens=java.base/javax.security.auth.kerberos=ALL-UNNAMED",
    "--add-opens=java.security.jgss/sun.security.jgss.krb5=ALL-UNNAMED"
  ))

  # Explicitly initialise the JVM now (before library(DatabaseConnector) loads
  # rJava implicitly) so the java.parameters above are honoured.
  library(rJava)
  rJava::.jinit()

  # Add both JDBC JARs to the running JVM's classpath:
  #   1. your HPC support team Kerberos wrapper — required for authentication on the protected analytic space.
  #   2. Standard MSSQL JDBC driver   — bundled in drivers/.
  hpc_jar     <- normalizePath(config$hpc_jar,     mustWork = FALSE)
  bundled_jar  <- normalizePath(
    file.path(config$jdbc_runtime_dir,
              "mssql-jdbc-13.2.1.jre11.jar"),
    mustWork = FALSE
  )

  if (!file.exists(hpc_jar)) {
    stop(
      "Institution-provided JDBC wrapper JAR not found: ", hpc_jar, "\n",
      "Expected at ~/drivers/hpc-jdbc-wrapper.jar.\n",
      "Contact your HPC support team to obtain this file, or set OMOP_HPC_JAR in .env."
    )
  }
  if (!file.exists(bundled_jar)) {
    stop("Bundled MSSQL JDBC JAR not found: ", bundled_jar)
  }

  rJava::.jaddClassPath(hpc_jar)
  rJava::.jaddClassPath(bundled_jar)
  message("Classpath: ", basename(hpc_jar), " + ", basename(bundled_jar))

  # Tell DatabaseConnector where to scan for JDBC JARs (fallback).
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER =
               normalizePath(config$jdbc_runtime_dir, mustWork = FALSE))

  message("Java configured: ", java_home)
  invisible(config)
}

# ---------------------------------------------------------------------------
# build_connection_details()
#
# Builds a DatabaseConnector ConnectionDetails object using the full JDBC URL
# approach confirmed by your HPC support team for Kerberos authentication on the protected analytic space:
#
#   jdbc:sqlserver://<server>;databaseName=<db>;integratedSecurity=true;
#     authenticationScheme=JavaKerberos;trustServerCertificate=true
#
# configure_java_hpc() must have been called before this function (and before
# library(DatabaseConnector)) so the JVM is already running with the correct
# classpath and JAAS config.
#
# Prerequisites:
#   1. configure_java_hpc(config) called before library(DatabaseConnector).
#   2. KRB5CCNAME set and a valid Kerberos ticket obtained via kinit.
# ---------------------------------------------------------------------------
build_connection_details <- function(config) {
  ensure_jdbc_bundle(config)

  # Validate Kerberos ticket is present.
  krb5 <- Sys.getenv("KRB5CCNAME")
  if (nchar(krb5) == 0) {
    warning(
      "KRB5CCNAME is not set. Kerberos authentication may fail.\n",
      "Run: export KRB5CCNAME=FILE:~/krb5cc_java && kinit"
    )
  }

  # Check that the ticket cache file exists.
  krb5_file <- path.expand(sub("^FILE:", "", krb5))
  if (nchar(krb5_file) > 0 && !file.exists(krb5_file)) {
    warning(
      "Kerberos ticket cache not found: ", krb5_file, "\n",
      "Run `kinit` before starting R."
    )
  }

  # Full JDBC URL — matches the approach confirmed by your HPC support team.
  #
  # serverSpn: The Kerberos Service Principal Name (SPN) registered for the
  # SQL Server instance in Active Directory.  Without this, the JDBC driver
  # tries to construct the SPN automatically from the server hostname, which
  # often fails with "Integrated authentication failed" because the guessed
  # SPN does not match what is registered in AD.
  #
  # SPN format:
  #   MSSQLSvc/<host>       — when using the default port 1433
  #   MSSQLSvc/<host>:<port> — when using a non-default port
  #
  # We extract the port from config$server (format "host:port") if present
  # and append it to the SPN.  spn_host in config.R is the hostname only.
  server_port <- sub("^[^:]+:?", "", config$server)   # "" if no port specified
  if (nchar(server_port) > 0) {
    spn <- paste0("MSSQLSvc/", config$spn_host, ":", server_port)
  } else {
    spn <- paste0("MSSQLSvc/", config$spn_host)
  }

  jdbc_url <- paste0(
    "jdbc:sqlserver://", config$server,
    ";databaseName=",         config$database,
    ";integratedSecurity=true",
    ";authenticationScheme=JavaKerberos",
    ";serverSpn=",            spn,
    ";trustServerCertificate=true"
  )

  message("Building connection: ", config$server, " / ", config$database,
          " (JavaKerberos)")
  message("Server SPN: ", spn)

  DatabaseConnector::createConnectionDetails(
    dbms             = "sql server",
    connectionString = jdbc_url,
    pathToDriver     = config$jdbc_runtime_dir
  )
}
