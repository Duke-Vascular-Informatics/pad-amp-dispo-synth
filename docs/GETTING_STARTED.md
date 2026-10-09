# Getting Started: From Zero to a Synthetic Dataset

This guide takes you from a working charon workspace to a **reusable,
analysis-specific synthetic OMOP CDM dataset**: author a Synthea module,
generate patients, load them into OMOP CDM v5.4, quality-check them, and
register the result so other repos can use it.

## What this repo is, and is not

This template is **only** for generating synthetic data. It contains no
analysis, no report and no deployment bundle:

| Where | What happens there |
|---|---|
| **A `-synth` repo (this template)** | Synthea module → generation → ETL → QC (`workflow/01–06`). Ends at registering the dataset. |
| A `<study>` analysis-core repo ([`strategus-study-template`](https://github.com/Duke-Vascular-Informatics/strategus-study-template)) | **All of the analysis**: cohorts, analytic strategy, result extraction. |
| A `<study>-report` repo ([`omop-report-template`](https://github.com/Duke-Vascular-Informatics/omop-report-template)) | The manuscript tables, figures and narrative, from the analysis's aggregate outputs. |

**Why a study needs synthetic data at all.** The analysis is written and
tested against synthetic patients, so the team can build the cohorts, choose
the analytic strategy, and produce publication-ready tables and figures
*before* anyone sees a real result. That keeps the analysis hypothesis-driven
and limits the opportunity for p-hacking. The finished, reviewed code is then
run once in the secure environment. So the synthetic data must contain the
patients, exposures, outcomes and covariates the analysis will need.

**Who this guide is for.** You know OMOP/OHDSI basics, can read R and Python,
and know roughly what Java is for. You have read the
[charon README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/README.md).

Related references (these live in the charon workspace, not in this repo):
- Workspace setup and troubleshooting: [charon `docs/GETTING_STARTED.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md), [`docs/SETUP.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/SETUP.md)
- Vocabulary load problems: [`docs/TROUBLESHOOTING_VOCAB_LOAD.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_VOCAB_LOAD.md)
- Git/GitHub auth: [`docs/GIT_GITHUB_AUTH.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GIT_GITHUB_AUTH.md)
- ETL problems: [`TROUBLESHOOTING_ETL.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_ETL.md)
- Commands: [COMMANDS.md](COMMANDS.md)

**Time:** ~2 hours for a first dataset once the workspace exists; the Synthea
module design is the variable part.

---

## Step 1: Complete the Workspace Setup (one-time per machine)

A `-synth` repo does not set up its own Docker, SQL Server or vocabulary. It
lives inside a charon workspace that provides them. If this machine does not
yet have one, complete **Steps 1–9** of the charon
[Getting Started guide](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md) first. That gives you:

- the dev container (R, Java, Python) and the shared SQL Server (`mssql_dev`);
- the OMOP vocabulary loaded into the `omop_vocab` schema of `omop_synth`;
- your `.env`, GitHub token, and git identity.

**Match the toolchain to your secure environment before the first build.** The
container's R, Java and Python versions must match those of the secure
analytics environment where the analysis will eventually run, because the
synthetic data is used to develop code for that environment. See
[charon Step 6.0](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md#60-match-the-container-to-your-secure-environment-before-the-first-build).

Skip this step if the workspace is already set up. You can confirm with:

```bash
echo $IN_DEV_CONTAINER          # true, when your terminal is inside the container
echo $MSSQL_HOST                # mssql_dev
```

---

## Step 2: Check Whether a Dataset Already Exists (5 minutes)

Generating data takes time. Before creating a repo, check whether the
workspace's registry already has a dataset that fits (same disease,
procedure and outcome):

```bash
# From the workspace root
Rscript synthetic_data/scripts/lookup_dataset.R --disease "<clinical term>"
```

If one fits, **reuse it instead** (same-machine schema, regenerate from its
module, or download its clinical tables). See
[`synthetic_data/README.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md). Only continue
here if nothing fits.

---

## Step 3: Create Your Synth Repository from Template (5 minutes)

1. On GitHub, open this template → **Use this template** → **Create a new
   repository**.
2. Name it `<study>-synth`; the `-synth` suffix is the workspace convention for
   a data-generation-only repo.
3. Set visibility to **Private**.
4. In the container terminal, clone it **inside the workspace root** as a
   sibling of your other study repos, and create your working branch:

```bash
cd /workspace
git clone https://github.com/<your-org>/<study>-synth.git
cd <study>-synth
BRANCH=$(gh api user --jq .login)
git checkout -b "$BRANCH"
git push -u origin "$BRANCH"
```

Add the folder to the workspace `.gitignore` and register it in the
workspace `studies.yaml` (`pipeline_role: synth`). Work only on your own
branch; changes reach `main` through a pull request.

```
/workspace/
├── <study>/            ← analysis-core (strategus-study-template)
├── <study>-report/     ← report (omop-report-template)
└── <study>-synth/      ← this repo: data generation only
```

---

## Step 4: Open in the Dev Container and Bootstrap (10 minutes)

Work from the container terminal, inside `/workspace/<study>-synth`. Run the
per-repo bootstrap once. It restores packages, provisions the JDBC driver and
tests the database connection:

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R
```

If the connection test reports `localhost:1433` refused, see the "Connection
refused" section of the
[charon guide](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md#connection-refused-on-localhost1433).

---

## Step 5: Declare the Studies Your Data Must Support (15 minutes)

A `-synth` repo defines **no cohorts, outcomes or covariates of its own**. What the
dataset must contain is defined by the studies that will use it, so you declare those
studies and their own cohort definitions are used directly. Nothing is copied into this
repo, so nothing can drift out of sync.

In a Strategus study, the target cohort, the outcome cohorts, and every other cohort in
`inst/Cohorts.csv` (the covariate cohorts) are what the dataset must support. The same
list drives three checks: `workflow/02` lists the cohorts (this step), `workflow/03` checks
that the Synthea module can produce them (Step 6), and `workflow/06` checks the final data
(Step 7).

### 5.1 Review what still needs input

```bash
Rscript scripts/check_setup.R       # [OK] / [WARN] / [FAIL] per item; no database needed
```

### 5.2 Edit `study_params.yaml`

Set the study identity (`study_name`), the CDM schema (`cdm_schema`), optionally
`results_schema` and `output_folder`, and the database description. That file holds
no cohort, outcome or concept settings. Generation parameters (population size, age
range, state) are arguments to `workflow/04` in Step 7; record the ones you used in the
registry entry (Step 8).

### 5.3 List the studies that will use this dataset

Add every Strategus study that uses this dataset to `consumers.yaml`:

```yaml
dataset_id: my_study_synth_dataset      # this dataset's id in synthetic_data/registry.yaml
consumers:
  - study: my-study-desc                # the study repo, cloned beside this one
    min_target_subjects: 100            # people required in the target cohort
    min_outcome_subjects: 10            # outcome people who are also in the target
    min_covariate_subjects: 1           # people required in each covariate cohort
    expected_empty: [9100104]           # cohorts the study knows are empty on synthetic data
not_checked: [some-retired-study]       # in the registry's used_by, deliberately not QC'd
```

**If a study's analysis depends on discharge disposition** (for example a non-home discharge
outcome), also set `discharge_disposition_check: true` on it. Such a cohort is hand-authored SQL that
Strategus never runs, so the cohort check cannot see whether the dataset carries dispositions at
all. This opt-in check reads `visit_occurrence` and verifies discharge dispositions were loaded,
mapped to concepts, and include both home (NUBC 01) and non-home discharge. `workflow/02` and
`check_setup` warn when a consumer's own cohort SQL reads `discharged_to_*` but the check is not
set. Optional thresholds: `min_discharge_visits`, `min_non_home_visits`, `min_discharge_mapped_pct`.

The target and outcome ids are read from `CreateStrategusAnalysisSpecification.R` (or set
`target_id` / `outcome_ids` yourself; the script cannot read ids a spec builds
programmatically, and says so). Mark outcomes that Synthea cannot generate as
`expected_empty` so they are reported rather than failed. Each study must also appear in
the registry's `used_by` for this dataset (Step 8); QC warns if they disagree. The
producer repo itself is ignored, and studies you list under `not_checked` (retired, or not
a Strategus repo) are too.

The consuming study's cohorts must exist before they can be checked: if the study is still
being designed, define its cohorts in **its** repo first. The dataset follows the study's
definitions, not the other way round.

### 5.4 See what the module must cover

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

It prints, for each consuming study, its target, outcome and covariate cohorts, and warns
about anything that would stop the later checks (a study repo not cloned, a missing
manifest or cohort JSON, an unresolvable target or outcome id). No database is needed.

### 5.5 Concept IDs

This repo contains no concept IDs. A concept a consuming cohort needs is added to that
study's own cohort definition, following Rule 1 (check the OHDSI Phenotype Library, your
lab's ATLAS definitions, the local catalog, then a live vocabulary query; tag each ID
`[vocab query]`). The live query is
`Rscript scripts/concept_lookup.R "<clinical term>" <Domain>`. In the Synthea module you
use source codes (SNOMED-CT, RxNorm, LOINC) that map to those concepts; Step 6 checks that
they do.

---

## Step 6: Design the Analysis-Specific Synthea Module (30 minutes)

Synthea simulates patients from **modules**: JSON state machines that decide
which conditions, procedures and medications each patient gets. This step
shapes the dataset to the analysis.

1. Open the default module in `synthea/modules/` (for example
   `surgical_site_infection_study.json`) to see the structure.
2. Edit it so the population contains what the studies in Step 5 require: the
   index event, the outcomes at plausible rates, and the comorbidities and
   exposures used as covariates (prevalence, procedure rates, medication
   patterns). Step 5.4 lists the cohorts to cover.
3. Validate it, regenerate its diagram, and check coverage:

```bash
Rscript workflow/03_generate_synthea_module_artifacts.R
Rscript workflow/03_generate_synthea_module_artifacts.R --enforce_coverage=true   # stop if a study's cohort cannot be produced
```

**Coverage check.** Workflow 03 also runs `scripts/module_coverage_check.R`, before you
spend time generating data. For every study in `consumers.yaml` it reads the study's cohort
definitions and checks that the Synthea modules that will run can emit the concepts they need:
the entry-event concept sets, plus any inclusion criterion that requires an event. It
considers your custom module **and** Synthea's built-in modules, because workflow 04 runs
them all (without an `-m` flag), so common comorbidities are often supplied by the built-ins.
The module's codes are mapped to standard OMOP concepts through the loaded vocabulary and
matched with `concept_ancestor`, so a concept set that includes descendants is matched by
its child concepts. Each cohort is reported `COVERED` (with whether the custom module,
the built-ins, or both supply it), `NOT_COVERED`, `NOT_EVALUABLE` (an entry criterion has no
concept set) or `EXPECTED_EMPTY` (listed in `expected_empty`). Results go to
`output/qc/module_coverage.csv`.

`COVERED` means the module **can** emit the concept; age, sex, probabilities and the ETL can
still make it rare or empty, so the final counts are judged by consumer-study QC in Step 7.
Two things are deliberately not judged. Visit entry events (for example "Inpatient Visit"): Synthea never
emits a visit concept through a code, the ETL derives it from the encounter class, so the cohort is judged on
its other required criteria, and a cohort that is *only* a visit criterion (such as a discharge-disposition
outcome) is `NOT_EVALUABLE`. For those, use `discharge_disposition_check` (Step 5.3) and consumer QC on the
final data. Inclusion criteria are judged when they are "at least one" criteria in an ALL group, or an ANY
group made only of such criteria (satisfied by any one of its concept sets).
On a real dataset this check named exactly the three outcomes that later had no people.
It needs the vocabulary (a database connection); skip it with `--skip_coverage_check=true`.

Realism matters for testing the pipeline (event rates, timing, coding), but
remember the data is synthetic: it shows that the analysis plan works, not
what the real effect will be.

---

## Step 7: Generate Synthetic Data, Run ETL, and Check Quality (60 minutes)

```bash
bash workflow/04_generate_synthea_csv.sh           # Synthea (Java) writes synthetic patient CSVs
Rscript workflow/05_etl_csv_to_omop.R              # CSV -> OMOP CDM v5.4 in config$cdm_schema
Rscript workflow/06_quality_check_defined_phenotypes.R   # data quality + phenotype validation
```

On Windows run
`powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1`
for the first command. Never run `.sh`/`.ps1` files with `Rscript`.

The ETL links to the shared `omop_vocab` schema rather than reloading it. The
generic QC checks the dataset in general: people, visits, procedures and conditions,
the share of conditions mapped to standard concepts, the era tables and age
distribution (thresholds and flags are in `workflow/README.md`; pass
`--enforce_thresholds=true` to make a shortfall fail the step). It holds no study
concepts; what a study needs is checked by the consumer-study QC below.

**Consumer-study QC.** After the generic checks, workflow 06 also runs
`scripts/consumer_cohort_qc.R`: for every study in `consumers.yaml` it renders that
study's cohorts from their circe JSON (as Strategus does), instantiates them against
the synthetic CDM, and reports subjects per cohort and, for outcomes, subjects who are
also in the target. A cohort below its minimum is a FAIL. Output goes to
`output/qc/consumer_cohort_qc.csv`.

```bash
Rscript workflow/06_quality_check_defined_phenotypes.R --enforce_thresholds=true
# or only the consumer check:
Rscript scripts/consumer_cohort_qc.R --enforce_thresholds=true
```

Run it with `--enforce_thresholds=true` before you regenerate or change a dataset that
other studies already use, so you do not break their links. It checks that the cohorts are
populated at the subject level; it does not re-run time-at-risk windows. Skip it with
`--skip_consumer_qc=true`. If a step fails, use the
[ETL troubleshooting guide](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_ETL.md).

---

## Step 8: Register Your Synthetic Dataset (10 minutes)

The dataset is generated, loaded and checked. This repo's job ends here.

1. Add an entry to `synthetic_data/registry.yaml` in the workspace
   root: the disease/procedure covered, the outcomes present, `source_repo`
   (this repo), `producer_role: synth`, and the schema name. The file's header
   comment lists every field. List every consuming study under `used_by`; it
   must match `consumers.yaml` (and `consumes_dataset` in the workspace
   `studies.yaml`). **Never** include vocabulary tables in anything you export
   or share.
2. Commit this repo's changes on your branch and open a PR into `main`:

```bash
git add synthea/modules/ study_params.yaml consumers.yaml
git commit -m "feat: synthetic dataset for <disease/procedure/outcome>"
git push
```

Your analysis-core repo can now point at the registered dataset (see
[`synthetic_data/README.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)). Analysis and the
manuscript happen there and in the report repo.

---

## Troubleshooting

- Workspace, container, Docker, vocabulary: the charon guides linked above
- Synthea generation and ETL: [charon `TROUBLESHOOTING_ETL.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_ETL.md)
- Concept lookup and coding rules: [CLAUDE.md](../CLAUDE.md)

## Getting Help

- **OHDSI Community**: [forums.ohdsi.org](https://forums.ohdsi.org)
- **Book of OHDSI**: [ohdsi.github.io/TheBookOfOhdsi](https://ohdsi.github.io/TheBookOfOhdsi)
- **Your coding assistant**: ask it to explain any step or help debug errors

## Key Files to Know

| File | Purpose |
|---|---|
| `config.R` | Infrastructure settings (do not edit) |
| `study_params.yaml` | Identity, schemas, database description (edit) |
| `synthea/modules/*.json` | The Synthea disease/procedure module (edit; the main work) |
| `consumers.yaml` | The Strategus studies that use this dataset; QC checks their cohorts (edit) |
| `workflow/01–06` | The generation pipeline (do not edit) |
| `output/` | Generation logs and QC output (gitignored) |

## Version Info

- **R / Java / Python:** the versions chosen for your workspace to match your secure analytics environment (charon `.env`: `R_VERSION`, `JAVA_VERSION`, `PYTHON_VERSION`)
- **SQL Server:** Azure SQL Edge (ARM64) or SQL Server 2022 (AMD64)
- **OMOP CDM:** v5.4
