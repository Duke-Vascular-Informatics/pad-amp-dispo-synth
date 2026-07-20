# OMOP Study Template

This GitHub repo is a reusable starter kit for electronic health care record based observational studies, utilizing an OMOP CDM v5.4 SQL Server database.
The type of analyses supported include **cohort characterization**, **prognostic modelling**, and **causal inference**
using Synthea-generated synthetic patient data and the OHDSI toolstack (DatabaseConnector, SqlRender, FeatureExtraction,
PatientLevelPrediction, CohortMethod).

The template is self-contained and optimized to develop analytic code with any AI coding assistant
(GitHub Copilot, Claude Code, or others). The purpose of this development workflow is to create
transportable offline-capable code: all R packages are pinned in `renv.lock`, the JDBC driver is bundled,
and OHDSI packages ship as prebuilt binaries so the resulting analytic code runs in air-gapped or
restricted-network environments.

---

## Start Here (Canonical Setup Guide)

To avoid duplicated or conflicting instructions, this README is intentionally high-level.

## Scope

- Owns: repository orientation, architecture map, and links to canonical docs.
- Does not own: step-by-step execution details or command snippets that may drift.
- Canonical procedural source: [../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).
- Canonical commands source: [../docs/COMMANDS.md](../docs/COMMANDS.md).

- Use [../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) as the **single source of truth** for end-to-end setup and execution.
- Use the root `omop-dev-workspace` README for shared Docker, SQL Server, dev container, and vocabulary setup.

## Quick Start (Condensed)

1. Create a repo from this template and name it using:
  `<disease_cohort_abbrev>_<treatment_abbrev>_<outcome_abbrev>_<methodology_abbrev>`
2. Clone the new study repo into your local `omop-dev-workspace/` as a subfolder.
3. Open the workspace in VS Code Dev Containers (from the workspace root).
4. From inside the study repo container, run the required bootstrap step:
   `Rscript workflow/01_setup_synthea_etl_qc_env.R`
5. Fill in `study_params.yaml`, `cohorts/*.sql`, and `covariates/*.csv`.
6. Validate and run using canonical commands in [../docs/COMMANDS.md](../docs/COMMANDS.md).

For full step-by-step commands and skip logic, follow [../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).
For workspace-level setup (Docker, SQL Server, OMOP vocabulary, and dev container),
use the root workspace README in `omop-dev-workspace/`.

---

## What to change vs. what to leave alone

| Change for every study | Leave as-is |
|------------------------|-------------|
| `study_params.yaml` | `config.R` (infrastructure only — no study edits needed) |
| `cohorts/*.sql` | `R/drivers.R`, `R/connection.R`, `R/cohorts.R` |
| `covariates/*.csv` | `setup/` |
| `analyses:` flags in `study_params.yaml` | `workflow/07`, `workflow/08` (no code editing) |
| `output_folder` in `study_params.yaml` | `renv.lock` (update only to add a new package) |

---

## Dev Container Scope

This study template is designed to run inside the shared root workspace container.
Keep machine-level setup instructions in the workspace README and keep this README
focused on template usage.

Workspace-first note: open `omop-dev-workspace/` in VS Code and use the single
shared root-level container definition for the workspace.

---

## Workflow Reference

Run Step 1 once immediately after opening this study repo in the dev container. This is
the per-repo bootstrap checkpoint (renv/packages, JDBC checks, and DB preflight), distinct
from one-time workspace infrastructure setup.

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `workflow/01_setup_synthea_etl_qc_env.R` | Install packages, verify DB connectivity, provision JDBC driver |
| 2 | `workflow/02_define_omop_cohort_outcome_covariates.R` | **Validate your study definition** — cohort SQL, covariate CSVs, concept IDs |
| 3 | `workflow/03_generate_synthea_module_artifacts.R` | Validate Synthea disease module and regenerate HTML diagram |
| 4 | `workflow/04_generate_synthea_csv.ps1` / `.sh` | Generate Synthea synthetic patients (skip for real CDM data) |
| 5 | `workflow/05_etl_csv_to_omop.R` | ETL Synthea CSV → OMOP CDM (skip for real CDM data) |
| 6 | `workflow/06_quality_check_defined_phenotypes.R` | Post-ETL data quality checks |
| 7 | `workflow/07_setup_analysis_env.R` | Verify analysis packages are installed |
| 8 | `workflow/08_run_analysis_and_manuscript_report.R` | **Your analysis and outputs** |
| 9 | `workflow/09_build_portable_analysis_bundle.ps1` / `.sh` | Package bundle for deployment to external sites |

Each step script is standalone and resolves the project root automatically, so it can be
run from any shell working directory:

```bash
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

Step 8 must be run in a **fresh R session** (the Java/JDBC guard will stop it otherwise).

---

## Repository Structure

```
<your-study>/
  config.R                    ← single source of truth for all settings
  workflow/                   ← numbered step scripts (01–09)
  R/                          ← reusable infrastructure functions
  setup/                      ← renv + package install helpers
  scripts/                    ← ETL, Synthea runner, QC utilities
  cohorts/                    ← SQL cohort definitions (edit these)
  covariates/                 ← covariate CSV spec files (edit these)
  synthea/modules/            ← Synthea disease module + diagram
  portable/                   ← self-contained bundle for external sites
  internal_repo/              ← prebuilt OHDSI package binaries
  drivers/                    ← JDBC driver archive
  .github/                    ← Claude Code / AI assistant instructions
  output/                     ← analysis outputs (gitignored)
```

---

## Package Management

R packages are pinned in `renv.lock` (R 4.5.2, cloud.r-project.org). OHDSI packages not
available on CRAN ship as prebuilt binaries in `internal_repo/bin/` for offline
installation.

To add a new package:

```r
renv::install("package_name")
renv::snapshot()
```

Prebuilt bundle artifacts are maintained by the bundle packaging workflow in
`workflow/09_build_portable_analysis_bundle.sh` / `.ps1`.

---

## AI Assistant Integration

This repo ships coding convention files that work with any AI coding assistant
(GitHub Copilot, Claude Code, or others):

1. **Concept ID transparency** — every concept ID recommendation must be tagged `[vocab query]`
   (confirmed against live vocabulary) or `[pretraining]` (unverified, with explicit warning).
2. **HADES-first package selection** — use OHDSI HADES packages for all OHDSI methodology;
   fall back to tidyverse; all packages must be on the project CRAN mirror.
3. **Verbose comments** — all code follows OHDSI GitHub repository commenting conventions.

| File | Scope | Purpose |
|------|-------|---------|
| `CLAUDE.md` | Every session | Core coding conventions (concept IDs, packages, comments, architecture) |
| `.github/copilot-instructions.md` | GitHub Copilot | Points all assistants to `CLAUDE.md` |
| `.github/instructions/r-packages.instructions.md` | `*.R` files | HADES priority, CRAN mirror, renv workflow |
| `.github/instructions/omop-ohdsi.instructions.md` | `*.R` and `*.sql` | DatabaseConnector/SqlRender patterns, concept ID lookup, OMOP CDM conventions |

**Concept Lookup (terminal):**

```bash
Rscript scripts/concept_lookup.R "peripheral arterial disease" Condition
Rscript scripts/concept_lookup.R "cefazolin" Drug
Rscript scripts/concept_lookup.R "ankle brachial index" Measurement
```

Queries the live OMOP vocabulary in the connected SQL Server and returns ranked
candidate concepts with recommendation. Use this before writing any concept ID into
code or CSV files.

---

## Documentation

| Resource | Purpose | Audience |
|----------|---------|----------|
| **[../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md)** | Canonical step-by-step workflow from first-time setup to analysis and packaging | New users, first time setup |
| **[../docs/COMMANDS.md](../docs/COMMANDS.md)** | Canonical command index used by all operational docs | All users |
| **[docs/CITATION_TEMPLATE_METHODS.md](docs/CITATION_TEMPLATE_METHODS.md)** | Template-repo citation language and contributor list for methods sections | Manuscript authors |
| **[docs/CITATION_ANALYSIS_EXAMPLE.md](docs/CITATION_ANALYSIS_EXAMPLE.md)** | Copy-ready study-level citation example for analysis-specific code repositories | Study teams |
| **[../docs/ANALYST_PLAYBOOK.md](../docs/ANALYST_PLAYBOOK.md)** | Fast decision-tree guidance for common analyst tasks and escalation | Analysts, support triage |
| **[../docs/MAINTAINER_PLAYBOOK.md](../docs/MAINTAINER_PLAYBOOK.md)** | Governance and release-freeze checks for documentation consistency | Maintainers |
| **[../docs/SETUP.md](../docs/SETUP.md)** | Detailed Docker, SQL Server, Athena vocabulary, and dev container setup | Docker/infrastructure details |
| **[CHECKLIST.md](CHECKLIST.md)** | Quick visual reference for workflow phases and key commands | Quick reference during work |
| **[CLAUDE.md](CLAUDE.md)** | Coding conventions, package rules, comment style, architecture | Developers, AI assistants |
| **[../docs/CHANGELOG.md](../docs/CHANGELOG.md)** | Categorized docs-governance change history for high-signal review | Maintainers, reviewers |
| **[../infrastructure/setup/setup_docker_and_vocab.sh](../infrastructure/setup/setup_docker_and_vocab.sh)** | Automated Docker + vocabulary setup (macOS/Linux, workspace-level) | Automation-first users |
| **[../infrastructure/setup/setup_docker_and_vocab.ps1](../infrastructure/setup/setup_docker_and_vocab.ps1)** | Automated Docker + vocabulary setup (Windows PowerShell, workspace-level) | Windows users |
| **[Book of OHDSI](https://ohdsi.github.io/TheBookOfOhdsi/)** | OHDSI methodology reference (cohorts, phenotypes, causal inference) | OHDSI methods questions |
| **[OHDSI Forums](https://forums.ohdsi.org)** | Community Q&A and discussion | Troubleshooting, best practices |

---

## License, Copyleft, and Publication Expectations

This repository is licensed under **GNU GPL v3.0** (see [LICENSE](LICENSE)).

What that means in practice for studies built from this template:

1. If you modify this code and **convey/distribute** it to others (including collaborators,
  clients, or partner sites), you must provide the corresponding source code under GPL v3.0.
2. Modified versions must keep license/copyright notices, include a copy of GPL v3.0, and
  clearly indicate that changes were made.
3. You may run and modify code privately without distribution obligations until you convey it.
4. You may not apply additional restrictions that remove recipients' GPL rights.

Template project expectation for analyst workflows:

1. Maintain a GitHub repository for each study derived from this template.
2. Publish study code and workflow artifacts for reproducibility whenever institutionally and
  contractually permitted.
3. If public release is not allowed (for governance, legal, or contractual reasons), keep a
  private repository but still satisfy GPL v3.0 obligations when sharing code with recipients.

> This section is a practical summary for analysts and developers, not legal advice.
> For legal interpretation, consult your organization's counsel.

---

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible offline.
- `renv/library/` is intentionally not committed (restored from `renv.lock` on first run).
- `output/` is gitignored — commit outputs separately if needed for reproducibility.

---

## Funding

Research reported in this publication was supported by the National Center For Advancing Translational Sciences of the National Institutes of Health under Award Number K12TR005435. The content is solely the responsibility of the authors and does not necessarily represent the official views of the National Institutes of Health.
