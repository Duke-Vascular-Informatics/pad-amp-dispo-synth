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
| `GETTING_STARTED.md` | **Start here for new users.** Complete end-to-end workflow from VS Code setup through analysis. Includes post-clone workflow with skip gates for repeat users. |
| `COMMANDS.md` | **Canonical command index.** Single source of truth for executable command snippets used across docs. |
| `PLAYBOOKS.md` | **Analyst and maintainer runbooks.** Decision-tree triage for analysts and governance checks for maintainers. |
| `omop_primer.md` | **OMOP CDM primer.** Practical introduction to OMOP concepts for analysts new to the data model. |
| `CITATION_TEMPLATE_METHODS.md` | **Template citation guidance.** Methods-ready citation text for citing this template in manuscripts. |
| `CITATION_ANALYSIS_EXAMPLE.md` | **Study citation guidance.** How to create analysis-specific citation metadata for derived study repositories. |
| `CITATION_ANALYSIS_EXAMPLE.cff` | **Study citation starter file.** Copy-and-edit CFF template for study-specific analysis repositories. |
| `TOPIC_OWNERSHIP.csv` | **Topic ownership matrix.** Maps sensitive topic headings to canonical owner docs to reduce content cloning. |
| `workflow_steps.yaml` | **Machine-readable step map.** Canonical step labels/anchors used by docs validation guardrails. |

> Infrastructure setup, Git/GitHub auth, and vocabulary troubleshooting are covered in the workspace-level `docs/` folder (`omop-dev-workspace/docs/`).
