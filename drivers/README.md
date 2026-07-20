# drivers/

JDBC driver bundle for SQL Server connectivity. All contents except the downloaded zip
are excluded from git (see `.gitignore`) and are provisioned automatically on first run
by `R/drivers.R` via `setup/install_packages.R`.

## Contents

| Path | Description | Tracked |
|------|-------------|---------|
| `mssql-jdbc-13.2.1.zip` | Downloaded Microsoft JDBC driver archive | Yes (download cache) |
| `sqljdbc_13.2/` | Extracted driver directory (jre11 jar + Windows auth DLL) | No |
| `jdbc-runtime/` | Runtime jar staged for DatabaseConnector discovery | No |

## How provisioning works

1. `ensure_jdbc_bundle()` in `R/drivers.R` checks whether the runtime jar already exists.
2. If not, it downloads `mssql-jdbc-13.2.1.zip` from Microsoft, extracts it, and copies
   the jre11 jar into `drivers/jdbc-runtime/`.
3. Windows Integrated Security requires the `mssql-jdbc_auth` DLL to be present in
   `drivers/sqljdbc_13.2/enu/auth/x64/`. `check_auth_dll()` verifies this at startup.

To re-provision from scratch, delete `drivers/jdbc-runtime/` and re-run Step 01.
