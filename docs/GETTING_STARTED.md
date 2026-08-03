# Getting Started: From Zero to Analysis (Complete Workflow)

This guide walks you through the complete workflow from downloading VS Code to creating
a transportable analysis code packet. Each step is designed to work with any AI coding
assistant: GitHub Copilot, Claude Code, or any other supported tool.

This is the canonical procedural guide for this template. The root README is intentionally
kept concise and links here for full step-by-step execution.

Detailed command snippets are canonicalized in [COMMANDS.md](COMMANDS.md).
Focused deep dives are split into dedicated docs:
- GitHub auth details: [GIT_GITHUB_AUTH.md](GIT_GITHUB_AUTH.md)
- Vocabulary load troubleshooting: [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)
- ETL troubleshooting: [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)

**Total time:** ~2 hours first time (mostly Docker vocabulary loading)  
**Repeat-study time:** ~10-20 minutes when your machine is already set up  
**Requires:** ~35 GB disk space, 8 GB RAM (16 GB recommended), active internet

> **Using `omop-dev-workspace`?**  
> The [omop-dev-workspace](https://github.com/Duke-Vascular-Informatics/omop-dev-workspace) provides SQL Server,
> the OMOP vocabulary mount, and the dev container as shared infrastructure. If you are working
> inside that workspace, **skip Steps 4, 6, and 7** (machine setup is already done).
> Clone your study repo into the workspace folder, then jump to **Step 5** to create the repo
> and **Step 8** to open the dev container.

This guide prioritizes a post-clone workflow:
1. Install VS Code
2. Set up Git and understand version control basics
3. Install and sign in to your AI coding assistant in VS Code
4. Create `OMOP_Dev/` and clone the study repo *(skip if using omop-dev-workspace)*
5. Use the AI assistant to help install Docker Desktop and Dev Containers
6. Check shared setup and continue from there *(skip if using omop-dev-workspace)*

---

## Step 1: Install VS Code (5 minutes)

### 1.1 Download VS Code

- Go to [code.visualstudio.com](https://code.visualstudio.com)
- Download and install for your operating system (Windows, macOS, or Linux)
- Launch VS Code

### 1.2 Verify VS Code installation

```bash
# In your terminal / command prompt
code --version          # Should print: X.XX.X
```

---

## Step 2: Set Up Git and Version Control (10 minutes)

### 2.1 What version control is (and why you need it)

Version control (Git) tracks every meaningful change to your study code.

Use it to:
- Keep a complete history of cohort/covariate/analysis changes
- Collaborate safely across analysts
- Reproduce exactly what code produced reported results
- Roll back mistakes without losing work

In this workflow, treat Git commits as study milestones (setup, phenotype definition,
analysis runs, and bundle generation).

### 2.2 Install Git

- Go to [git-scm.com/downloads](https://git-scm.com/downloads)
- Install for your operating system
- On Windows, keep default options unless your organization requires specific settings

### 2.3 Configure your Git identity (one-time)

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@org.edu"
```

Optional but recommended default branch preference:

```bash
git config --global init.defaultBranch main
```

### 2.4 Verify Git setup

```bash
git --version
git config --global --get user.name
git config --global --get user.email
```

### 2.5 Link Git to your GitHub account

Choose one authentication method for `git clone`, `git push`, and `git pull`.

- Option A (recommended): SSH keys
- Option B: HTTPS + token-backed auth (`gh auth login` or your credential manager)

For complete setup and remote switching commands, use:
[GIT_GITHUB_AUTH.md](GIT_GITHUB_AUTH.md)

---

## Step 3: Install Your AI Coding Assistant (10 minutes)

### Option A: GitHub Copilot (Free Education Plan)

1. Go to [github.com/features/copilot](https://github.com/features/copilot)
2. Click **Get Copilot Free** (or **Sign up for free trial**)
3. Sign in with your GitHub account or create one
4. Inside VS Code:
   - Open Extensions (`Ctrl+Shift+X`)
   - Search for "GitHub Copilot"
   - Install the official extension by GitHub
   - Sign in with your GitHub account when prompted

### Option B: Claude Code (Free Trial or Subscription)

1. Go to [claude.ai](https://claude.ai) and sign in or create an account
2. Click on your profile → "API keys"
3. Create a new API key and save it securely
4. Inside VS Code:
   - Open Extensions (`Ctrl+Shift+X`)
   - Search for "Claude" (look for Anthropic extension)
   - Install and configure with your API key

### Option C: Other Coding Assistants

Follow the standard setup for your chosen tool and verify it works in VS Code before
proceeding to Step 4.

---

## Step 4: Create Your Parent Development Folder (5 minutes)

> **Skip this step if using `omop-dev-workspace`.** The workspace already provides the shared
> SQL Server container, vocabulary mount, and `.env` — clone your study repo directly into
> the workspace folder and proceed to Step 5.

All pieces (SQL Server, OMOP vocabulary, study repositories) live in a single parent folder
so the relative paths work correctly. Create this **once** and reuse it for every study.

### 4.1 Create the folder

```bash
# macOS / Linux
mkdir ~/OMOP_Dev
cd ~/OMOP_Dev

# Windows (PowerShell)
New-Item -ItemType Directory -Path $env:USERPROFILE/OMOP_Dev -Force
cd $env:USERPROFILE/OMOP_Dev
```

### 4.2 Create the .env file with SQL Server password

The `.env` file stores the SQL Server SA password. Keep it outside the study repo so
it's never committed to version control.

```bash
# macOS / Linux
echo 'MSSQL_SA_PASSWORD=YourStrong@Passw0rd' > .env

# Windows (PowerShell) — use backtick to escape special characters, or paste into editor
'MSSQL_SA_PASSWORD=YourStrong@Passw0rd' | Out-File -Encoding ascii .env
```

**Password requirements:**
- At least 8 characters
- Mix of upper, lower, digit, and special character (e.g., `@`, `#`, `$`, `%`)
- Do NOT use `!` (Bash history expansion will fail)

**Example strong passwords:**
- `SqlServer@2024`
- `Dev#OMOP$Vocab1`
- `MyStudy123%Pass`

### 4.3 Verify the folder structure

```bash
# Should see:
# .env                   ← your password file (do not commit)
# (other files added in next steps)

ls -la  # macOS / Linux
dir     # Windows Command Prompt
```

---

## Step 5: Create Your Study Repository from Template (5 minutes)

This is the recommended next step. Cloning only downloads the files. The thing that must
wait until Docker and the shared host resources exist is opening the repo in the dev container.

### 5.1 Use the GitHub template

1. Go to [github.com/ohdsi-studies/OMOP-Study-Template](https://github.com/ohdsi-studies/OMOP-Study-Template)
   *(or your organization's fork of it)*
2. Click **Use this template** → **Create a new repository**
3. Name it something descriptive (e.g., `colectomy-ssi-omop`, `hip-replace-vte`)
4. Choose **Private** (recommended for studies with PHI definitions)
5. Click **Create repository from template**

### 5.2 Clone inside OMOP_Dev/ (or omop-dev-workspace/)

```bash
# Standalone: clone into OMOP_Dev/
cd ~/OMOP_Dev

# OR if using omop-dev-workspace:
cd ~/path/to/omop-dev-workspace

# Replace <your-org> and <your-study> with your GitHub paths
# HTTPS
git clone https://github.com/<your-org>/<your-study>.git

# OR SSH (if you configured SSH keys in Step 2.5)
# git clone git@github.com:<your-org>/<your-study>.git

cd <your-study>
```

**Standalone:** The repo MUST be directly inside `OMOP_Dev/`. The relative paths in
the dev container depend on this structure:

```
OMOP_Dev/
  .env
  docker-compose.yml
  omop_vocab/
  infrastructure/
    setup/
      setup_docker_and_vocab.sh
      setup_docker_and_vocab.ps1
  <your-study>/          ← your repo is here
    config.R
    study_params.yaml
    ...
```

**omop-dev-workspace:** Clone the study repo directly into the workspace root. The workspace
already provides `.env`, `docker-compose.yml`, and `omop_vocab/`:

```
omop-dev-workspace/
  .env
  docker-compose.yml
  omop_vocab/
  <your-study>/          ← clone here
    config.R
    study_params.yaml
    ...
```

### 5.3 Install Docker Desktop and Dev Containers (with assistant help)

Now that your AI assistant is active in VS Code, use it to walk through local setup:

1. Install Docker Desktop from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
2. Start Docker Desktop and wait until it shows as running
3. In VS Code Extensions, install **Dev Containers** (Microsoft)

> **Apple Silicon (M1/M2/M3):** Docker Desktop runs natively on ARM64. No Rosetta needed.

Verify both tools before continuing:

```bash
docker --version        # Should print: Docker version XX.X.X
code --version          # Should print: X.XX.X
```

---

## Step 6: Check Whether Shared Local Setup Already Exists (2 minutes)

> **Skip this step if using `omop-dev-workspace`.** The workspace manages SQL Server and the
> vocabulary mount. Confirm the workspace dev container is running and proceed to Step 8.

Run these checks from `OMOP_Dev/`. If they all pass, skip Step 7 and go directly to Step 8.

### 6.1 Check host-side files and folders

```bash
# macOS / Linux
cd ~/OMOP_Dev
ls -la .env docker-compose.yml omop_vocab
ls omop_vocab/CONCEPT.csv

# Windows (PowerShell)
cd $env:USERPROFILE/OMOP_Dev
Get-ChildItem .env, docker-compose.yml, omop_vocab
Get-ChildItem omop_vocab/CONCEPT.csv
```

You should have:
- `.env`
- `docker-compose.yml`
- `omop_vocab/CONCEPT.csv`

### 6.2 Check Docker SQL Server status

```bash
cd ~/OMOP_Dev  # or $env:USERPROFILE/OMOP_Dev on Windows
docker compose ps
```

You should see `mssql_dev` with status `healthy`.

### 6.3 Decide whether to skip

Skip Step 7 if all of the following are true:
- `.env` exists
- `docker-compose.yml` exists
- `omop_vocab/CONCEPT.csv` exists
- `docker compose ps` shows `mssql_dev` as `healthy`

If any of those checks fail, continue to Step 7.

---

## Step 7: Complete Machine Setup If Needed (20-60 minutes)

> **Skip this step if using `omop-dev-workspace`.** Machine setup is managed by the workspace.

Do this only if Step 6 found missing shared setup. This is one-time per machine, not per study.

### Option A: Use the Automated Setup Script (Recommended)

The cloned repository includes a setup script that automates Docker configuration:

```bash
# From inside your study repo folder (OMOP_Dev/<your-study>)
cd ..  # Go to OMOP_Dev/

# macOS / Linux
bash infrastructure/setup/setup_docker_and_vocab.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File infrastructure\setup\setup_docker_and_vocab.ps1
```

This script:
1. Checks Docker is running
2. Creates `docker-compose.yml` in `OMOP_Dev/`
3. Starts the SQL Server container
4. Creates the `omop_synth` database
5. Guides you through Athena vocabulary download

After the script completes, continue to Step 8.

### Option B: Manual Docker setup

If you prefer not to use the script, create `docker-compose.yml` in `OMOP_Dev/`:

**File: `OMOP_Dev/docker-compose.yml`**

```yaml
version: '3.9'

services:
  mssql:
    # azure-sql-edge provides native linux/arm64 support for Apple Silicon.
    # Swap for mcr.microsoft.com/mssql/server:2022-latest on amd64 hardware only.
    image: mcr.microsoft.com/azure-sql-edge:latest
    container_name: mssql_dev
    restart: unless-stopped
    ports:
      - "${MSSQL_PORT:-1433}:1433"
    environment:
      ACCEPT_EULA: "1"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD}"
      # Performance tuning for vocabulary load (optional)
      # MSSQL_MEMORY_LIMIT_MB: "4096"
    volumes:
      - mssql_data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'cat /dev/null > /dev/tcp/localhost/1433' || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - omop_dev_network

volumes:
  mssql_data:
    name: mssql_dev_data

networks:
  omop_dev_network:
    name: omop_dev_network
```

Then start SQL Server and create the shared database:

```bash
cd ~/OMOP_Dev  # or $env:USERPROFILE/OMOP_Dev on Windows

# Start SQL Server
docker compose up -d

# Replace YourStrong@Passw0rd with your actual password from .env
docker exec mssql_dev \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U SA -P "YourStrong@Passw0rd" -C \
  -Q "IF DB_ID('omop_synth') IS NULL CREATE DATABASE omop_synth;"

# Verify
docker compose ps
```

### 7.1 Download OMOP vocabulary from Athena

The OMOP vocabulary is shared across all studies on this machine.

1. Go to [athena.ohdsi.org](https://athena.ohdsi.org)
2. Click **Download** → **Create new download**
3. Select these vocabulary bundles at minimum:

| Vocabulary | Required | Notes |
|------------|----------|-------|
| **SNOMED** | ✅ | Primary clinical vocabulary |
| **RxNorm** | ✅ | Drug ingredients |
| **RxNorm Extension** | ⭐ | Drugs not in RxNorm |
| **LOINC** | ✅ | Lab measurements |
| **ICD10CM** | ✅ | US diagnoses (US studies only) |
| **CPT4** | ⭐ | US procedures (requires UMLS key) |
| **HCPCS** | ⭐ | US outpatient procedures |
| **ICD10PCS** | ⭐ | US inpatient procedures |
| **Visit** | ✅ | Visit types |
| **Gender** / **Race** / **Ethnicity** | ✅ | Demographics |
| **UCUM** | ✅ | Units of measure |

4. Accept the license and click **Download**
5. Extract it into `OMOP_Dev/omop_vocab/` so `CONCEPT.csv` is directly inside that folder

```bash
mkdir -p OMOP_Dev/omop_vocab
unzip ~/Downloads/vocabulary_download_v5*.zip -d OMOP_Dev/omop_vocab/
ls OMOP_Dev/omop_vocab/CONCEPT.csv
```

### 7.2 Optional: Rebuild CPT-4 codes

If you did not include CPT-4 in the Athena download, you can skip this step for now.

```bash
cd OMOP_Dev/omop_vocab

# macOS / Linux
bash cpt.sh YOUR_UMLS_API_KEY

# Windows (Command Prompt, not PowerShell)
cpt.bat YOUR_UMLS_API_KEY
```

---

## Step 8: Open in Dev Container (10 minutes)

Now that SQL Server is running, you can safely open the dev container in VS Code.

### 8.1 Open in VS Code

1. Inside VS Code: **File** → **Open Folder**
2. Navigate to `OMOP_Dev/<your-study>/` and click **Open**
3. Open the workspace root folder and run the shared root-level dev container.
4. Continue once the container is running
   *(Or use `Cmd+Shift+P` → **Dev Containers: Reopen in Container**)*

### 8.2 Wait for container build (5–10 minutes first time)

The first build:
- Pulls the R + Java image (~1.5 GB)
- Installs system dependencies
- Activates renv environment

VS Code shows a progress indicator. When complete, the status bar shows the container name.

### 8.3 Verify the environment

Open a terminal in VS Code (`Ctrl+`` or `Cmd+`` `) and run:

```bash
# Should print: true
echo $IN_DEV_CONTAINER

# Should show R 4.5.x
R --version

# Should show: No errors
Rscript -e "library(DatabaseConnector); print('OK')"
```

---

## Step 9: Check Whether OMOP Vocabulary Is Already Loaded (2 minutes)

The vocabulary CSV files on disk are not enough by themselves. SQL Server also needs the
`omop_vocab` schema loaded once per machine.

### 9.1 Check whether the database is already populated

Inside the dev container, run:

```bash
Rscript -e "
  config <- get_validation_config()
  conn <- DatabaseConnector::connect(config$connection_details)
  result <- tryCatch(
    DatabaseConnector::querySql(conn, 'SELECT COUNT(*) AS n FROM omop_vocab.concept'),
    error = function(e) NULL
  )
  print(result)
  DatabaseConnector::disconnect(conn)
"
```

If this prints a row count for `omop_vocab.concept`, skip Step 10 and go to Step 11.
If it errors or returns no table, continue to Step 10.

---

## Step 10: Load OMOP Vocabulary into SQL Server (30–60 minutes)

Do this only if Step 9 showed the vocabulary is not already loaded.

### 10.1 Inside the dev container, run the vocabulary loader

```bash
# Run from the study root (inside the container)
Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template
```

This script:
1. Reads the CSV files from `/omop_vocab/` (mounted from `OMOP_Dev/omop_vocab/`)
2. Creates the `omop_vocab` schema in SQL Server
3. Loads all 9 vocabulary tables
4. Creates primary keys and indexes

**Expected output:**
```
Loading CONCEPT.csv...
Loading CONCEPT_ANCESTOR.csv...
...
✓ OMOP vocabulary schema loaded successfully
```

If you see errors, check:
- SQL Server is running: `docker compose ps` from outside the container
- `.env` password is correct
- Files exist: `ls -la /omop_vocab/`

If Step 10 fails or stalls, use the focused runbook:
[TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)

### 10.2 Verify vocabulary was loaded

```bash
# Still inside the container
Rscript -e "
  config <- get_validation_config()
  conn <- DatabaseConnector::connect(config$connection_details)
  result <- DatabaseConnector::querySql(conn, 'SELECT COUNT(*) FROM omop_vocab.concept')
  print(result)
  DatabaseConnector::disconnect(conn)
"

# Should print: ~2M rows (varies by vocabulary version)
```

---

## Step 11: Define Your Cohort, Outcome, and Covariates (30–60 minutes)

This is where you customize the template for your specific study.

### 11.1 Review the setup checklist

```bash
# Inside the dev container
Rscript scripts/check_setup.R

# or in your coding assistant (Claude Code only):
# /check-setup
```

This shows what still needs your input.

### 11.2 Edit study_params.yaml

Open `study_params.yaml` and fill in study-specific values:

```yaml
study_name: "my_study"              # ← Change this
study_design: "prognostic_model"    # ← Verify / change if different

cdm_schema: "cdm_my_study"          # ← Change to your CDM schema name
# results_schema, cohort_table, and output_folder default to
#   <study_name>_results, <study_name>_cohort, output/<study_name>
# Uncomment and override only if you need non-standard names:
# results_schema: "my_study_results"
# cohort_table:   "my_study_cohort"

target:
  cohort_id: 1
  index_event:
    ancestor_concept_ids: [0]       # ← Look these up!
  inclusion_criteria: []
  
outcome:
  cohort_id: 2
  ancestor_concept_ids: [0]         # ← Look these up!

prediction_window_days: 30

study_start_date: "2020-01-01"
study_end_date: "2022-12-31"

output_folder: "output/my_study"    # ← Change this

analyses:
  cohort_characterization: true     # ← Set to true for analyses you want
  propensity_score: false
  ...
```

### 11.3 Look up concept IDs

For every `[0]` placeholder, use your coding assistant to look up the correct concept ID:

```bash
# Inside the container
Rscript scripts/concept_lookup.R "your clinical term" Domain

# Examples:
Rscript scripts/concept_lookup.R "hip replacement" Procedure
Rscript scripts/concept_lookup.R "surgical site infection" Condition
```

**In your coding assistant:** Ask it to help you find and verify concept IDs. It should:
1. Run the lookup script
2. Show you the results
3. Help you document where each ID came from

### 11.4 Edit cohort SQL files

Open the files in `cohorts/`:
- `target_surgery.sql` — index event cohort definition
- `outcome_ssi.sql` — outcome cohort definition
- `comparator_cohort.sql` — (if doing causal inference)

Replace every `concept_id = 0` placeholder with verified concept IDs from Step 11.3.

Example:

```sql
-- BEFORE:
WHERE c.procedure_concept_id IN (0, 0, 0)  -- TODO: insert procedure concept IDs

-- AFTER:
WHERE c.procedure_concept_id IN (4301351, 4306895)  -- [vocab query] Total hip replacement and variants
```

### 11.5 Edit covariate files

Update the covariates your study needs:

- `covariates/covariates.csv` — define covariates (rows with `covariate_id`, `covariate_name`, etc.)
- `covariates/covariate_concepts.csv` — map each covariate to OMOP concept IDs

Example `covariates.csv`:
```csv
covariate_id,covariate_name,type
1,Age,demographic
2,Male,demographic
3,Diabetes,condition
```

Example `covariate_concepts.csv`:
```csv
covariate_id,concept_id
3,201820  # Type 2 diabetes mellitus
```

### 11.6 Validate your setup

```bash
Rscript scripts/check_setup.R

# Should show all [OK] or at least no [FAIL] items
```

---

## Step 12: Design Analysis-Specific Synthea Module (Optional, 30 minutes)

If you're using synthetic data (not a real CDM), customize the Synthea module to match
your study population.

### 12.1 Review the default module

Synthea generates synthetic patient data. The module controls which conditions, procedures,
and medications are simulated.

```bash
# Inside the container, see the default module:
cat synthea/modules/surgical_site_infection_study.json
```

### 12.2 Customize if needed

For your study population, edit the Synthea module JSON to adjust:
- Disease prevalence (comorbidities)
- Procedure rates
- Medication use patterns

This is optional; the default module is often sufficient for testing.

---

## Step 13: Generate Synthetic Data and Run ETL (60 minutes)

### 13.1 Generate Synthea synthetic patient records

```bash
# Inside the container
Rscript workflow/01_setup_synthea_etl_qc_env.R    # Install packages, verify DB
Rscript workflow/03_generate_synthea_module_artifacts.R
bash workflow/04_generate_synthea_csv.sh          # (Linux/macOS)
# OR (Windows PowerShell):
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1
```

This creates synthetic EHR data in CSV format.

### 13.2 Run ETL (Extract, Transform, Load)

```bash
# Load the CSV files into the CDM schema
Rscript workflow/05_etl_csv_to_omop.R
```

This:
1. Reads Synthea CSV files
2. Transforms to OMOP v5.4 format
3. Loads into `config$cdm_schema` in SQL Server

### 13.3 Run data quality checks

```bash
Rscript workflow/06_quality_check_defined_phenotypes.R
```

If Step 13 fails, use the focused runbook:
[TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)

---

## Step 14: Create and Test Analysis Code (30–60 minutes)

### 14.1 Build cohorts

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

This:
1. Validates your SQL cohort definitions
2. Instantiates target, outcome, and comparator cohorts in SQL Server
3. Checks that the cohorts are non-empty and reasonable

### 14.2 Run analyses

```bash
Rscript workflow/07_setup_analysis_env.R       # Install analysis packages
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

All analysis parameters are controlled by the `analyses:` flags in `study_params.yaml`.
No code editing needed — just set flags to `true` / `false`.

### 14.3 Review outputs

Outputs are written to `config$output_folder` (e.g., `output/my_study/`):

```bash
# Inside the container
ls -la output/my_study/

# View results in VS Code or your file explorer
# e.g., output/my_study/CharacterizationResults.csv
```

---

## Step 15: Create Transportable Code Packet (5 minutes)

Your analysis code is now ready to run in any environment (with SQL Server access).

### 15.1 Generate the transportable bundle

```bash
# Inside the container
bash workflow/09_build_portable_analysis_bundle.sh
# OR (Windows PowerShell):
powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1
```

This creates a self-contained folder `portable/transportable_bundle/` containing:
- All analysis R code
- Pinned R packages (`renv.lock`)
- JDBC driver (bundled)
- OHDSI packages (prebuilt binaries)
- Configuration templates

### 15.2 Share the packet

The `transportable_bundle/` can be:
1. **Shipped to a data partner** — they extract it, update config with their schema names, and run `Rscript run_analysis.R` locally
2. **Pushed to GitHub** — other researchers can clone and use it
3. **Archived** — long-term preservation of exact analysis code and package versions

---

## Troubleshooting

Use focused troubleshooting docs to reduce duplicated guidance and merge conflicts:

- Infrastructure and container setup: [SETUP.md](SETUP.md)
- Vocabulary loading failures: [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)
- Synthetic generation and ETL failures: [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)
- Concept lookup workflow and verification: [../CLAUDE.md](../CLAUDE.md)

---

## Next Steps

1. **Commit your study definition** to version control:
   ```bash
   git add study_params.yaml cohorts/ covariates/
   git commit -m "feat: Define <your study name> cohort, outcome, and covariates"
   git push
   ```

2. **Share your analysis** — push the transportable bundle or the study repo itself

3. **Document your phenotypes** — add README files explaining clinical rationale for each cohort

---

## Getting Help

- **OHDSI Community** — [forums.ohdsi.org](https://forums.ohdsi.org)
- **Book of OHDSI** — [ohdsi.github.io/TheBookOfOhdsi](https://ohdsi.github.io/TheBookOfOhdsi)
- **Your coding assistant** — ask it to explain any of these steps or help debug errors

---

## Key Files to Know

| File | Purpose |
|------|---------|
| `config.R` | Infrastructure settings (do not edit) |
| `study_params.yaml` | Your study's settings (edit this) |
| `cohorts/*.sql` | Cohort definitions (edit these) |
| `covariates/*.csv` | Covariate definitions (edit these) |
| `workflow/01–09` | Analysis pipeline (do not edit) |
| Workspace root container config | Shared development environment (do not edit from this study repo) |
| `output/` | Analysis results (gitignored) |
| `portable/` | Transportable bundle (for sharing) |

---

## Version Info

- **R version:** 4.5.x
- **Java:** 17 (Eclipse Adoptium)
- **SQL Server:** Azure SQL Edge (ARM64) or SQL Server 2022 (AMD64)
- **OHDSI packages:** Latest from [github.com/OHDSI](https://github.com/OHDSI)
- **OMOP CDM:** v5.4
