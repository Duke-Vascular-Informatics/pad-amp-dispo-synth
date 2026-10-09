---
description: "Look up OMOP standard concept IDs in the live omop_vocab vocabulary. Use before writing any concept_id into code or CSV files. Accepts a clinical term and optional domain (condition, drug, procedure, measurement, observation, visit)."
name: "OMOP Concept Lookup"
argument-hint: "<clinical term> [domain]"
agent: "agent"
tools: ["mssql_connect", "mssql_run_query", "mssql_disconnect", "mssql_get_connection_details"]
---

You are performing an OMOP vocabulary lookup against the live `omop_synth` database.

## Non-interactive alternative

For batch use or terminal workflows, run the standalone R script instead of this skill:

```bash
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
# Examples:
Rscript scripts/concept_lookup.R "total hip replacement" Procedure
Rscript scripts/concept_lookup.R "venous thromboembolism" Condition
Rscript scripts/concept_lookup.R "cefazolin"
```

The R script performs the same two-step query (name match + descendant expansion) and
prints results with the `[vocab query]` label. Use it when you need to look up many
terms without opening a chat session, or when running from a CI/shell environment.

## Connection

Connect using these parameters — do not prompt the user for credentials:
- Server: `localhost,1433`
- Database: `omop_synth`
- Use Windows authentication (trust server certificate)

If already connected, skip the connect step.

## Input

The user has provided: **${{input}}**

Parse this as:
- **term**: the clinical concept to search for (required)
- **domain**: optional filter — one of `Condition`, `Drug`, `Procedure`, `Measurement`,
  `Observation`, `Visit`. If not provided, search all domains.

## Queries to Run

### 1. Direct name match (primary)

```sql
SELECT TOP 20
    concept_id,
    concept_name,
    domain_id,
    vocabulary_id,
    concept_class_id,
    standard_concept,
    concept_code
FROM omop_vocab.concept
WHERE standard_concept = 'S'
  AND invalid_reason IS NULL
  AND LOWER(concept_name) LIKE LOWER('%<term>%')
  -- add: AND domain_id = '<domain>'  when domain is specified
ORDER BY
    CASE WHEN LOWER(concept_name) = LOWER('<term>') THEN 0 ELSE 1 END,
    LEN(concept_name),
    concept_name
```

### 2. Synonym / fuzzy match (run only if query 1 returns fewer than 3 results)

```sql
SELECT TOP 10
    c.concept_id,
    c.concept_name,
    c.domain_id,
    c.vocabulary_id,
    c.concept_class_id,
    cs.concept_synonym_name AS matched_synonym
FROM omop_vocab.concept c
JOIN omop_vocab.concept_synonym cs ON c.concept_id = cs.concept_id
WHERE c.standard_concept = 'S'
  AND c.invalid_reason IS NULL
  AND LOWER(cs.concept_synonym_name) LIKE LOWER('%<term>%')
  -- add: AND c.domain_id = '<domain>'  when domain is specified
ORDER BY LEN(cs.concept_synonym_name), c.concept_name
```

### 3. Descendant expansion (always run for the top-ranked concept from query 1 or 2)

```sql
SELECT TOP 10
    c.concept_id,
    c.concept_name,
    c.domain_id,
    c.vocabulary_id,
    ca.min_levels_of_separation AS levels_below
FROM omop_vocab.concept_ancestor ca
JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = <best_concept_id>
  AND c.standard_concept = 'S'
  AND c.invalid_reason IS NULL
  AND ca.min_levels_of_separation > 0
ORDER BY ca.min_levels_of_separation, c.concept_name
```

Substitute `<term>` / `<best_concept_id>` with actual values. When domain is given,
uncomment the `AND domain_id` filter in queries 1 and 2.

## Output Format

### Candidate concepts

Present results as a Markdown table with these columns:

| concept_id | concept_name | domain_id | vocabulary_id | concept_class_id |
|------------|-------------|-----------|---------------|-----------------|
| ...        | ...         | ...       | ...           | ...             |

### Descendant expansion

Present the top descendants table (from query 3) so the user can verify that
ancestor-based rollup captures the intended clinical scope. If no descendants exist,
state "leaf concept — no descendants".

### Recommendation

Provide a **Recommended concept_id** — the single best match — with a one-sentence
rationale (e.g., most specific standard concept, preferred vocabulary for this domain).

Always label the result explicitly:

> **[vocab query]** — confirmed against `omop_vocab` in this SQL Server instance.
> Safe to use in code and CSV files for this vocabulary version.

This label is required so the user knows the concept ID was verified by a live
database query, not inferred from AI training data. If you are ever unable to run
the query (e.g., no database connection), state:

> **[pretraining]** — not verified against the live vocabulary. Run `/concept-lookup`
> or `Rscript scripts/concept_lookup.R "<term>"` before using this concept ID in any
> code or CSV file.

If no standard concepts are found, state that clearly and suggest alternative search
terms or vocabulary (e.g., "Try searching for the ingredient name rather than the
brand name").

### Usage hint

After the recommendation, remind the user where the concept ID belongs. A `-synth` repo
holds no concept sets of its own: the ID goes into a concept set of a cohort definition in the
consuming Strategus repo (or the Synthea module as a source code), and into
`phenotype_library/catalog.yaml` so the next study can reuse it.

## Disconnect

Disconnect from the database after all queries are complete.
