---
description: "Use when writing R or SQL code that queries or processes OMOP CDM data, defines cohorts, uses OHDSI packages (DatabaseConnector, SqlRender, PatientLevelPrediction, FeatureExtraction, CohortGenerator), or works with concept IDs, domain tables, or cohort logic."
applyTo: ["**/*.R", "**/*.sql"]
---

# OMOP CDM and OHDSI Coding Conventions

## Database Connection

Always use `DatabaseConnector` — never raw JDBC, `DBI`, or `odbc` directly:

```r
# Load config first — it holds all connection parameters
config      <- get_validation_config()

# Create a ConnectionDetails object (no open connection yet)
connDetails <- DatabaseConnector::createConnectionDetails(
  dbms         = config$dbms,
  server       = paste0(config$server, "/", config$database),
  port         = config$sql_server_port,
  pathToDriver = config$path_to_driver
)

# Open a connection, always with an on.exit guard to prevent leaks
conn <- DatabaseConnector::connect(connDetails)
on.exit(DatabaseConnector::disconnect(conn))
```

## SQL Authoring (SqlRender)

All SQL must be written as SqlRender-parameterized templates, then rendered and translated.
Never concatenate user-supplied values or config values directly into SQL strings.

```r
# Write parameterized SQL using @parameter syntax
sql <- SqlRender::render(
  "SELECT * FROM @cdm_schema.person WHERE year_of_birth > @min_year",
  cdm_schema = config$cdm_schema,   # substituted at render time — no injection risk
  min_year   = 1920L
)

# Translate to the target dialect AFTER rendering
sql    <- SqlRender::translate(sql, targetDialect = config$dbms)
result <- DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = TRUE)
```

Rules:
- Use `@parameter` syntax for all schema, table, and value substitutions.
- Target dialect is always `"sql server"` for this project.
- Do not use source-vocabulary concept codes (ICD-10, NDC) in SQL — map to standard OMOP
  concept IDs first (see Concept ID Lookup section below).

## OMOP CDM Structure (v5.4)

Key tables in `config$cdm_schema`:

| Domain | Table | Key columns |
|--------|-------|-------------|
| Person | `person` | `person_id`, `gender_concept_id`, `year_of_birth` |
| Visit | `visit_occurrence` | `person_id`, `visit_start_date`, `visit_end_date`, `visit_concept_id` |
| Condition | `condition_occurrence` | `person_id`, `condition_concept_id`, `condition_start_date` |
| Drug | `drug_exposure` | `person_id`, `drug_concept_id`, `drug_exposure_start_date` |
| Procedure | `procedure_occurrence` | `person_id`, `procedure_concept_id`, `procedure_date` |
| Measurement | `measurement` | `person_id`, `measurement_concept_id`, `measurement_date`, `value_as_number` |
| Observation | `observation` | `person_id`, `observation_concept_id`, `observation_date` |
| Concept | `concept` | `concept_id`, `concept_name`, `domain_id`, `vocabulary_id`, `standard_concept` |
| Concept ancestor | `concept_ancestor` | `ancestor_concept_id`, `descendant_concept_id` |

Rules:
- Always use **standard concept IDs** (`standard_concept = 'S'`), not source codes.
- Use `concept_relationship` to map source/non-standard concepts to standard concepts.
- Join via `concept_ancestor` when descendant expansion is needed (e.g., all subtypes of a drug class).
- Confirm `invalid_reason IS NULL` before committing any concept ID.

## Cohorts

A `-synth` repo defines and instantiates no cohorts of its own. The cohorts that matter are
those of the Strategus studies listed in `consumers.yaml`: `workflow/02` lists them,
`workflow/03` checks the Synthea module can produce them, and `workflow/06` instantiates them
into scratch tables (`qc_consumer_*`, dropped afterwards) to count people. Cohorts follow the
standard OHDSI structure (`cohort_definition_id`, `subject_id`, `cohort_start_date`,
`cohort_end_date`); never hardcode `cohort_definition_id` values here.

## Concept ID Lookup — MANDATORY RULE

**AI source transparency:** Every OMOP concept ID recommendation must carry one of two tags:

- **[pretraining]** — derived from AI training data only. Treat as a starting hypothesis.
  Must be accompanied by: *"This ID has not been verified against the live vocabulary.
  Run a vocabulary query before using it in code or CSV."*
- **[vocab query]** — confirmed by a live query against `omop_vocab` in this SQL Server
  instance. Safe to use for this vocabulary version.

**Hard rule:** Never write a concept ID into code, SQL, or a CSV file without first running
a live vocabulary query and tagging it **[vocab query]**. Pretraining concept IDs are
vocabulary-version-dependent and have been observed to map to completely wrong concepts
in this project.

### Vocabulary lookup workflow (three-table check)

```sql
-- 1. Find candidate standard concepts
SELECT concept_id, concept_name, domain_id, vocabulary_id, standard_concept, invalid_reason
FROM omop_vocab.concept
WHERE concept_name LIKE '%your term%'
  AND standard_concept = 'S'
  AND invalid_reason IS NULL
ORDER BY concept_name;

-- 2. Verify source-to-standard mapping if starting from a source code
SELECT c.concept_id, c.concept_name, cr.relationship_id
FROM omop_vocab.concept_relationship cr
JOIN omop_vocab.concept c ON c.concept_id = cr.concept_id_2
WHERE cr.concept_id_1 = <source_concept_id>
  AND cr.relationship_id = 'Maps to'
  AND c.standard_concept = 'S'
  AND c.invalid_reason IS NULL;

-- 3. Expand descendants for concept set definition
SELECT c.concept_id, c.concept_name, c.domain_id
FROM omop_vocab.concept_ancestor ca
JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = <your_chosen_ancestor_id>
  AND c.standard_concept = 'S'
  AND c.invalid_reason IS NULL;
```

Use the standalone R script to run vocabulary lookups interactively from terminal:

```bash
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
```

Examples:
```bash
Rscript scripts/concept_lookup.R "peripheral arterial disease" Condition
Rscript scripts/concept_lookup.R "cefazolin" Drug
Rscript scripts/concept_lookup.R "ankle brachial index" Measurement
```

**Note:** Claude Code users can also use the `/concept-lookup` slash command for interactive queries.

### Inline comment convention for concept IDs

Every concept ID that appears in code, SQL, or CSV must have a trailing comment:

```r
procedure_concept_id = 4301351  # [vocab query] SNOMED: Coronary artery bypass graft
ancestor_concept_id  = 0        # [REPLACE] TODO [CONFIG]: insert verified ancestor ID
```

```sql
WHERE ca.ancestor_concept_id = 4058703  -- [vocab query] SNOMED: Surgical site infection
  AND co.condition_concept_id != 0      -- [REPLACE] TODO: verify exclusion concept ID
```

## Methodology Reference

When implementing OHDSI methodology, consult the **Book of OHDSI** first:

  https://ohdsi.github.io/TheBookOfOhdsi/

Key chapters by task:

| Task | Chapter |
|------|---------|
| Cohort definition | Chapter 11 — Cohorts |
| Feature extraction / characterization | Chapter 12 — Characterization |
| Patient-level prediction | Chapter 13 — Patient-Level Prediction |
| Population-level estimation | Chapter 14 — Population-Level Estimation |
| Data quality | Chapter 15 — Data Quality |

Use **HADES packages** as the canonical implementation for each study design:

| Study design | Primary HADES packages |
|---|---|
| Cohort characterization | `FeatureExtraction`, `CohortDiagnostics` |
| Prognostic modelling | `PatientLevelPrediction`, `FeatureExtraction` |
| Causal inference | `CohortMethod`, `FeatureExtraction`, `EvidenceSynthesis` |
| SCCS | `SelfControlledCaseSeries`, `EmpiricalCalibration` |
| Data quality | `DataQualityDashboard` |

Only reach for non-HADES packages (e.g., `pROC`, `ggplot2`) for tasks not covered by
HADES (model diagnostics, visualization). All non-HADES packages must be available on
the project-configured CRAN mirror (see `CRAN_MIRROR` in `.env`).

## Verbose Comment Requirements (OHDSI GitHub Style)

All R and SQL code must include verbose inline comments following OHDSI repository conventions:

- **File headers**: identify purpose, inputs, outputs, prerequisites.
- **Section banners**: `# ============` separators for major logical blocks.
- **Function documentation**: describe parameters, return value, and side effects above each function.
- **Non-obvious logic**: explain the *why* behind SQL joins, window functions, and HADES
  configuration choices — not just what the code does.
- **Concept IDs**: always comment with concept name and `[vocab query]` / `[pretraining]` tag.
- **TODO blocks**: use `# TODO [LABEL]:` format for findability.

Do not write code with unexplained concept IDs, unexplained numeric thresholds, or unexplained
HADES argument values. A reader unfamiliar with OHDSI should be able to understand what each
block does from the comments alone.

## Anti-patterns

- Do not hardcode schema or table names — always use `@cdm_schema`, `@results_schema`, etc.
- Do not use `dbplyr` or remote `dplyr` tables — use explicit SqlRender SQL.
- Do not use source-vocabulary concept codes (ICD-10, NDC) — map to standard OMOP concept IDs.
- Do not write a concept ID without a `[vocab query]` tag and an inline name comment.
- Do not suggest packages outside the project CRAN mirror or OHDSI `internal_repo/bin/`.
