# scripts/maintainer/

Template governance scripts for maintainers. These are not part of the
analyst study workflow — run them when updating the template itself.

| Script | Purpose |
|--------|---------|
| `validate_docs_commands.R` | Validates docs consistency: checks command snippets, local links, topic ownership, and (in strict mode) enforces no warnings before a release. |
| `generate_checklist_step_index.R` | Regenerates the step index block in `CHECKLIST.md` from `docs/workflow_steps.yaml`. Run after changing step titles or order. |

## When to run

After any change to `docs/GETTING_STARTED.md` step headings or `docs/COMMANDS.md`:

```bash
Rscript scripts/maintainer/generate_checklist_step_index.R
Rscript scripts/maintainer/validate_docs_commands.R
```

Before tagging a release:

```bash
DOCS_STRICT=1 Rscript scripts/maintainer/validate_docs_commands.R
Rscript scripts/maintainer/generate_checklist_step_index.R --check
```
