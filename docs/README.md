# docs/

Supplementary project documentation that does not belong in the root README.

## Scope

- Owns: detailed procedural, troubleshooting, and operator references.
- Does not own: root-level repository orientation (see `README.md`).
- Canonical procedure source: `GETTING_STARTED.md`.
- Canonical commands source: `COMMANDS.md`.

## Files

| File | Description |
|------|-------------|
| `GETTING_STARTED.md` | **Start here.** Generating an analysis-specific synthetic dataset, from a ready charon workspace through registering the result. Machine setup (VS Code, Docker, vocabulary) is in the charon workspace docs. |
| `COMMANDS.md` | **Canonical command index.** Single source of truth for executable command snippets used across docs. |
| `PLAYBOOKS.md` | **Analyst and maintainer runbooks** for this repo. Decision-tree triage for analysts and governance checks for maintainers. |
| `omop_primer.md` | **OMOP CDM primer.** Practical introduction to OMOP concepts for analysts new to the data model. |
| `CITATION_TEMPLATE_METHODS.md` | **Template citation guidance.** Methods-ready citation text for citing this template in manuscripts. |
| `TOPIC_OWNERSHIP.csv` | **Topic ownership matrix.** Maps sensitive topic headings to canonical owner docs to reduce content cloning. |
| `workflow_steps.yaml` | **Machine-readable step map.** Canonical step labels/anchors used by docs validation guardrails. |

> Infrastructure setup, Git/GitHub auth, and vocabulary troubleshooting are covered in the workspace-level `docs/` folder (for example `docs/` in a [charon](https://github.com/Duke-Vascular-Informatics/charon)-based workspace).
