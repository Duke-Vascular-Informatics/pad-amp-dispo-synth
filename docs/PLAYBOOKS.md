# Playbooks

Operational guides for analysts and maintainers using this study template.

- **Analyst playbook** — study execution and triage flow.
- **Maintainer playbook** — repo governance, docs guardrails, release checks.

For full procedural detail see `docs/GETTING_STARTED.md`. For canonical command snippets see `docs/COMMANDS.md`.

---

## Analyst Playbook

### Decision Tree

1. New machine or no charon workspace yet?
   - Complete the charon workspace setup first (charon Getting Started Steps 1–9), including matching R/Java/Python to your secure environment (charon Step 6.0). Then start at Step 2 here.

2. Workspace ready, new dataset?
   - Start at Step 2 in `docs/GETTING_STARTED.md` (check the registry first: another dataset may already fit).

3. Unsure what is missing?

```bash
Rscript scripts/check_setup.R
```

4. Need concept IDs?

```bash
Rscript scripts/concept_lookup.R "<clinical term>" <Domain>
```

5. Stuck after one fix attempt?

```bash
Rscript scripts/create_support_bundle.R
```

### One-Click Tasks (VS Code)

Use `Terminal -> Run Task`:

- Analyst: Install Git Hooks
- Analyst: Check Setup
- Analyst: Concept Lookup
- Analyst: Validate Step 2 Artifacts
- Analyst: Create Support Bundle

### Common Paths

**Generate a synthetic dataset** (this repo's only documented path)
- Define and validate cohorts and covariates (`workflow/02`).
- Run `workflow/03`–`06` for module validation, Synthea generation, ETL, and QC.
- Register the result in `synthetic_data/registry.yaml` at the workspace root.

Analysis against this (or any) dataset happens in a separate repo built from
`strategus-study-template`, not here.

### Hooks for Local Guardrails

Install local git hooks once per clone:

```bash
bash scripts/hooks/install_git_hooks.sh
```

What they do:
- `pre-commit` — runs setup checks when study-definition files are staged.
- `pre-push` — validates docs commands and runs tests (if `testthat` is installed).

To bypass once:

```bash
SKIP_ANALYST_HOOKS=1 git commit -m "message"
```

### Escalation Bundle

When requesting support, attach the archive path printed by:

```bash
Rscript scripts/create_support_bundle.R
```

Bundle contents include: redacted `study_params.yaml`, setup check report, git branch/status/history, recent log snippets.

---

## Maintainer Playbook

### Scope

- Owns: governance operations for documentation consistency and release readiness.
- Does not own: analyst workflow instructions (see Analyst Playbook above).

### Daily Maintainer Checks

1. Validate docs consistency:

```bash
Rscript scripts/maintainer/validate_docs_commands.R
```

2. Verify checklist step index is synchronized:

```bash
Rscript scripts/maintainer/generate_checklist_step_index.R --check
```

3. If step titles changed, regenerate checklist index:

```bash
Rscript scripts/maintainer/generate_checklist_step_index.R
```

### Canonical Source Rules

1. Workflow step names and order are owned by `docs/workflow_steps.yaml`.
2. Step-by-step execution is owned by `docs/GETTING_STARTED.md`.
3. Command snippets are owned by `docs/COMMANDS.md`.
4. Topic ownership is declared in `docs/TOPIC_OWNERSHIP.csv`.

### Release Docs Freeze

Run strict docs checks before tagging or high-impact merges:

```bash
DOCS_STRICT=1 Rscript scripts/maintainer/validate_docs_commands.R
Rscript scripts/maintainer/generate_checklist_step_index.R --check
```

Strict mode enforces:
- no broken local markdown links
- no unresolved local anchors
- no deprecated command/path references
- no topic ownership warnings
- checklist step index synchronized with step map
