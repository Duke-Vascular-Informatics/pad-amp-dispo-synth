## Summary

Describe what changed and why.

## Handoff Notes

For Claude Code–assisted PRs: include the same handoff summary you would otherwise send by
email. At minimum, cover:

- **What was done**: cohorts, covariates, SQL, or analysis code touched this session.
- **Concept ID status**: any new concept IDs added, with lookup tier used
  (`[pretraining]` / `[vocab query]`) per Rule 1 — flag anything still `[pretraining]` as
  unverified.
- **What was tested / validated**: scripts run, checks passed (e.g. `check_setup.R`),
  what was *not* tested.
- **Open questions or TODOs**: anything the reviewer should decide on or that's blocked
  pending input.

## Source-of-Truth Checks

- [ ] If workflow step text changed, I updated docs/GETTING_STARTED.md first.
- [ ] If a command changed, I updated docs/COMMANDS.md.
- [ ] If checklist step labels changed, I confirmed alignment with docs/workflow_steps.yaml.
- [ ] I avoided duplicating procedural instructions that already exist in canonical docs.

## Validation

- [ ] I ran: `Rscript scripts/validate_docs_commands.R`
- [ ] I ran relevant tests or noted why they were skipped.

## Notes

Anything reviewers should verify manually.
