# scripts/synthea/

Utilities for Synthea synthetic data generation and module visualization.

## Files

| File | Description | Called by |
|------|-------------|-----------|
| `run_synthea.ps1` | Invokes Synthea with the study module enabled. Configures population size, age range, US state, and module name. Requires Java and the Synthea checkout under `external/synthea`. | `workflow/04_generate_synthea_csv.ps1` |
| `generate_synthea_mermaid.R` | Parses `synthea/modules/study_template.json` and generates a Mermaid state-diagram rendering of the module logic, saved as `synthea/modules/study_template.diagram.html`. | `workflow/03_generate_synthea_module_artifacts.R` |

## Synthea configuration

Key parameters in `run_synthea.ps1` that may need adjustment per environment:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-SyntheaHome` | Path to the Synthea checkout directory | `$env:SYNTHEA_HOME` or `external/synthea` |
| `-Population` | Number of synthetic patients to generate | 1000 |
| `-ModuleName` | Basename of the study module JSON (without `.json`) | `study_template` |
| `-AgeRange` | Min-max age for generated patients | `18-100` |
| `-State` | US state for simulated demographics | `North Carolina` |

Output CSVs are written to the Synthea default output directory
(`external/synthea/output/csv/`) and picked up by Step 05.
