# setup/

Environment bootstrap scripts for package/runtime readiness.

For end-to-end setup order, use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).
For Docker, SQL Server, and vocabulary infrastructure details, use
[charon's docs/SETUP.md](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/SETUP.md).

## Files

| File | Description | When to run |
|------|-------------|-------------|
| `setup_renv.R` | Activates the renv project library and restores packages from `renv.lock`. Ensures all R package versions match the locked environment. | Every session (called by Step 01) |
| `install_packages.R` | Installs any packages missing from the renv library (CRAN-first, GitHub fallback for OHDSI-only packages). Also provisions the JDBC driver bundle via `R/drivers.R`. | First run or after `renv.lock` changes |

## Related setup script (outside this folder)

| File | Description | When to run |
|------|-------------|-------------|
| `../infrastructure/scripts/setup_omop_vocab_schema.R` | Loads the OMOP standard vocabulary into the shared `omop_vocab` schema on SQL Server. Creates and populates vocabulary tables from Athena CSV files. | Once per SQL Server instance |

## Prerequisites for ../infrastructure/scripts/setup_omop_vocab_schema.R

- OMOP vocabulary CSV files downloaded from [Athena](https://athena.ohdsi.org)
- Sufficient disk space (~25 GB for full vocabulary load)
- A pre-existing SQL Server database to host the `omop_vocab` schema
- Connection details configured in `config.R`
