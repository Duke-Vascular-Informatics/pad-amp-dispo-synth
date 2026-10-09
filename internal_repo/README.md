# internal_repo/

A previous version of this template used this directory as a local package mirror
for packages required in a downstream secure analytic environment (the now-removed
deployment-bundle workflow) that weren't available on CRAN. That capability is no
longer documented or recommended — new analysis work, including any such packaging
need, belongs in a separate repo built from `strategus-study-template`. See git
history for how this directory was used.

Packages needed for synthetic data generation itself (ETLSyntheaBuilder, Synthea
tooling, and the rest of this repo's `renv.lock`) are CRAN- or OHDSI-drat-available
and handled by `renv` directly — they never needed this directory.

## Currently empty

No binaries are needed here for this repo's documented Steps 1–6.
