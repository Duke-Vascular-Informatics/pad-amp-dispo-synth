# internal_repo/

Local package mirror for air-gapped HPC environments where CRAN is not
accessible. Used by `setup/install_packages.R` when `USE_INTERNAL_REPO=true`.

## What belongs here

Only packages that meet **all three** criteria:

1. Required in the **secure analytic environment** (i.e. used by the portable bundle)
2. **Not available on CRAN** — verify with `available.packages()["PkgName", ]`
3. Cannot be installed from the OHDSI drat repo in the secure environment

Packages used only for synthetic data generation (ETLSyntheaBuilder, Synthea
tooling) do not belong here — they never run in the secure environment.
CRAN-available packages (most HADES packages) are handled by renv directly.

## Currently empty

All analysis packages required by the portable bundle are available on CRAN.
No binaries are needed at this time.

## Adding a binary

If a future analysis dependency meets all three criteria above:

```r
options(repos = c(CRAN = "https://cloud.r-project.org"))
dir.create("internal_repo/bin/windows/contrib/4.5", recursive = TRUE)
download.packages(
  "PackageName",
  destdir = "internal_repo/bin/windows/contrib/4.5",
  type    = "win.binary"
)
```

Commit the `.zip` and update this README with the package, version, and
reason it cannot be sourced from CRAN or the OHDSI drat repo.
