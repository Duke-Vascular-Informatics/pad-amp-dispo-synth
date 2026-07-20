# scripts/hooks/

Local git hook helpers for analyst guardrails.

## Files

| File | Purpose |
|------|---------|
| `install_git_hooks.sh` | Configures `core.hooksPath=.githooks` and marks hooks executable. |

## Install

```bash
bash scripts/hooks/install_git_hooks.sh
```

## Installed hooks

- `.githooks/pre-commit`
  - Runs `scripts/check_setup.R` when study-definition files are staged.
  - Runs `scripts/find_todos.R` as a non-blocking reminder.
- `.githooks/pre-push`
  - Runs `scripts/validate_docs_commands.R`.
  - Runs unit tests when `testthat` is installed.

## Bypass (one command)

```bash
SKIP_ANALYST_HOOKS=1 git commit -m "message"
```
