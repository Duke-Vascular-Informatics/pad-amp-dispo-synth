# Workspace Instructions

This analysis folder inherits shared AI coding instructions from:

- [charon's `CLAUDE.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/CLAUDE.md)

Use the workspace-level file as canonical guidance for Claude Code and other assistants.

## Local Overrides

**This repo is data-generation-only — not a real study.** It exists to produce a
synthetic OMOP CDM (patients undergoing major lower extremity amputation for
dysvascular / diabetic / wound indications, with a modeled 90-day post-discharge
ED-visit outcome and a VA-Frailty-Index comorbidity burden) for the `pad-amp-ed-desc`
Strategus pipeline and the other studies listed in `consumers.yaml`. It has no IRB scope,
no real patient data, and no OSF protocol.

### Scope: Steps 1-6 only

Run **Steps 1-6 only** (module authoring, Synthea generation, ETL, QC). There is no analysis,
report or bundle code in this repo (the old `workflow/07`/`08` and the analysis R code were removed);
analysis lives in the consuming study repos.

### The Synthea module

- The single authored module is `synthea/modules/pad_amp_dispo.json` (PAD → major
  amputation → 90-day post-discharge ED-visit pathway, ~30 VA-FI comorbidity states,
  and a fixed ED-visit probability gate). `study_template.json` is the generic stub and
  is auto-skipped by Steps 3/4.
- This repo defines **no cohorts, outcomes or covariates of its own** (the local `cohorts/` and
  `covariates/` were removed). What the dataset must contain is defined by the studies listed in
  `consumers.yaml`, whose own cohort definitions (`inst/Cohorts.csv`, `inst/cohorts/*.json`) are read
  directly: `workflow/02` lists them, `workflow/03` checks the Synthea module (custom + built-in) can
  produce them before generation (`--enforce_coverage=true` to stop on a gap), and `workflow/06` checks
  the final data (`--enforce_thresholds=true`). Declare cohorts a consumer knows are empty on synthetic
  data under `expected_empty`; set `discharge_disposition_check: true` for a consumer whose analysis
  depends on discharge disposition. Keep `consumers.yaml` in step with `used_by` in the registry.
- The QC scripts default to the schema in `study_params.yaml` (`omop_synth_pad_amp_dispo`); for dataset
  v2 pass `--cdm_schema=omop_synth_pad_amp_v2`.

### Schema naming (important)

`cdm_schema` is pinned to **`omop_synth_pad_amp_dispo`** (NOT `..._synth`) even though
this repo is `pad-amp-dispo-synth`. That physical schema is registered in
the workspace's `synthetic_data/registry.yaml` (format: [charon's synthetic_data README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)) (dataset `id: pad_amp`) and is consumed by the studies listed in
`consumers.yaml` through view-overlays — through an overlay schema, never the bare name
directly, which is what made the 2026-07-31
rename (`pad-amp-ed-synth`/`pad_amp_ed`/`omop_synth_pad_amp_ed_desc` → `pad-amp-dispo-synth`/
`pad_amp_dispo`/`omop_synth_pad_amp_dispo`) low-risk: rebuild each consumer's overlay
after any regeneration, but do not change the pinned name again without checking the
consumers' overlay targets first. (The registry corrected on 2026-08-06 that `pad-oler-aki-desc`
is not a consumer of this dataset.)

### After a Step 5/6 run

Register/update the dataset entry in the workspace's `synthetic_data/registry.yaml` (format: [charon's synthetic_data README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)) (`id: pad_amp_dispo`)
per that file's README — fill in `generation_params` and `last_generated.qc_summary`.
A consumer points its `OMOP_CDM_SCHEMA_OVERRIDE` view-overlay at this schema via
`Rscript synthetic_data/scripts/generate_overlay_schema.R`.

### Version Control Routing

This repo is **not** a submodule — it is an independent repository with its own GitHub
remote, created from the `synthea-omop-template` lineage (bootstrapped from
`pad-amp-ed-desc`'s data-generation half).

| Remote | URL | What to push |
|--------|-----|--------------|
| `origin` | `https://github.com/Duke-Vascular-Informatics/pad-amp-dispo-synth.git` | Full repository |

```bash
BRANCH=$(gh api user --jq .login)
git push origin "$BRANCH"   # then open a PR into main
```

Register this repo in the workspace root's `studies.yaml` (category: `data-generation`,
not a real study) so `/sync-template` and `/check-alignment` pick it up.
