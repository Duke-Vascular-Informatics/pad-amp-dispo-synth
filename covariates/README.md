# covariates/

CSV specification files that define the covariates (patient features) used in your study.
These files are validated by Step 2 and consumed by whichever analysis pipeline you wire
up in `workflow/08`.

They support any study design — prognostic models, causal inference, cohort characterization —
wherever you need a structured, version-controlled covariate specification rather than
defining covariates inline in R code.

## Files

| File | Description |
|------|-------------|
| `covariates.csv` | One row per covariate. Defines the name, OMOP domain, lookback window, and minimum event count. |
| `covariate_concepts.csv` | OMOP concept ID mappings for each covariate. Supports `include_descendants = TRUE` for ancestor rollup via `concept_ancestor`. |

## When to use these files

**Use this CSV approach when:**
- You have a pre-specified covariate list (e.g. from a published protocol or risk model).
- You want to version-control the exact concepts used and keep them reviewable as plain text.
- You need per-covariate control over lookback windows or concept expansion.

**Use `FeatureExtraction::createCovariateSettings()` instead when:**
- You want automated, data-driven covariate extraction across all OMOP domains.
- You are running PatientLevelPrediction or CohortMethod with a broad feature set.

Set both file paths to `NULL` in workflow/08 to skip this CSV pipeline and pass a
`FeatureExtraction` settings object directly.

---

## covariates.csv — column definitions

| Column | Description |
|--------|-------------|
| `covariate_id` | Short unique identifier. Lowercase, letters/numbers/underscores only. Must match `covariate_id` values in `covariate_concepts.csv`. Examples: `female`, `diabetes`, `prior_hosp` |
| `covariate_name` | Human-readable label used in reports and output tables. |
| `domain` | OMOP CDM domain: `condition` → `condition_occurrence`, `procedure` → `procedure_occurrence`, `drug` → `drug_exposure`, `measurement` → `measurement`, `observation` → `observation` |
| `lookback_start_day` | Start of lookback window relative to index date (negative = before index). Examples: `-365`, `-3650`, `-30` |
| `lookback_end_day` | End of lookback window. `-1` = day before index (strictly prior). `0` = include index date. |
| `min_count` | Minimum qualifying records to count the covariate as present. Almost always `1`. |
| `points` | **Integer risk score pipeline only.** Point value assigned when present. Positive = risk factor, negative = protective. Set to `1` for simple binary presence/absence. Ignored by FeatureExtraction-based analyses. |
| `missing_is_negative` | `TRUE` = absence means covariate is absent (default). `FALSE` = for derived covariates where missing ≠ absent (e.g. BMI from weight/height). |

**Notes:**
- Mutually exclusive categories (e.g. overweight vs. obese) should be separate rows with distinct `covariate_id`s.
- For multi-concept OR covariates, add multiple rows in `covariate_concepts.csv` with the same `covariate_id` — the covariate is flagged if **any** row matches.

---

## covariate_concepts.csv — column definitions

| Column | Description |
|--------|-------------|
| `covariate_id` | Must exactly match a `covariate_id` in `covariates.csv`. |
| `concept_id` | Standard OMOP concept ID (`standard_concept = 'S'`). Exception: ATC drug class ancestors use `standard_concept = 'C'`. Use `0` as a placeholder — Step 2 warns when `0`s remain. |
| `include_descendants` | `TRUE` = use `concept_ancestor` rollup (matches concept and all descendants). Recommended for most clinical concepts. `FALSE` = exact match only. Use for gender, specific LOINC codes, or when descendants include unrelated concepts. |
| `concept_role` | Optional. Tag for the concept's role within the covariate. Leave blank for simple presence/absence. Used for measurement sub-types (`bmi_direct`, `weight`, `height`) or to group multi-domain concepts. |
| `value_concept_ids` | Optional. Semicolon-separated `value_as_concept_id` values for observation-table lookups where the concept alone is insufficient. Leave blank for condition, procedure, drug, and most measurement rows. |

### Special covariate types

**Gender / sex** (queries `person.gender_concept_id` directly — use `include_descendants = FALSE`):
```
female,8532,FALSE,,
```

**BMI from weight + height** (when direct BMI measurement is absent):
Use `concept_role` to tag each measurement type (`bmi_direct`, `weight`, `height`). The pipeline
resolves BMI in priority order: direct measurement first, then weight + height calculation.

**Operative time / duration** (derived from procedure timestamps):
The pipeline computes `DATEDIFF(MINUTE, procedure_datetime, procedure_end_datetime)` for
procedures descended from the listed ancestor concept IDs. No `value_concept_ids` needed.

---

## Concept lookup

Before writing any concept ID, verify it against the live vocabulary. Use the
`/concept-lookup` slash command in Claude Code:

```
/concept-lookup diabetes mellitus condition
/concept-lookup cefazolin drug
/concept-lookup ankle brachial index measurement
```

Or run directly:

```sql
-- Find candidate standard concepts
SELECT concept_id, concept_name, vocabulary_id, domain_id
FROM omop_vocab.concept
WHERE concept_name LIKE '%your covariate name%'
  AND standard_concept = 'S'
  AND invalid_reason IS NULL
  AND domain_id IN ('Condition', 'Procedure', 'Drug', 'Measurement', 'Observation');

-- Check descendants of a candidate ancestor
SELECT c.concept_id, c.concept_name, ca.min_levels_of_separation
FROM omop_vocab.concept_ancestor ca
INNER JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = <candidate_concept_id>
ORDER BY ca.min_levels_of_separation;

-- Find ATC drug class ancestors
SELECT concept_id, concept_name, vocabulary_id
FROM omop_vocab.concept
WHERE vocabulary_id = 'ATC'
  AND standard_concept = 'C'
  AND concept_name LIKE '%antibiotic%';
```
