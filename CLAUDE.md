# Workspace Instructions

This analysis folder inherits shared AI coding instructions from:

- `../CLAUDE.md`

Use the workspace-level file as canonical guidance for Claude Code and other assistants.

## Local Overrides

**This repo is data-generation-only — not a real study.** It exists to produce a
synthetic OMOP CDM (patients undergoing major lower extremity amputation for
dysvascular / diabetic / wound indications, with a modeled 90-day post-discharge
ED-visit outcome and a VA-Frailty-Index comorbidity burden) for the `pad-amp-ed-desc`
Strategus pipeline (and, via a view-overlay, `pad-oler-aki-desc`). It has no IRB scope,
no real patient data, and no OSF protocol.

### Scope: Steps 1-6 only

Run **Steps 1-6 only** (module authoring, Synthea generation, ETL, QC). Steps 7-8
(`workflow/07`/`08`, analysis + Word report) are **never** used — every flag under
`analyses:` in `study_params.yaml` stays `false`. The analysis/report R code carried in
`R/` is dormant template leftovers; do not run it here.

### The Synthea module

- The single authored module is `synthea/modules/pad_amp_dispo.json` (PAD → major
  amputation → 90-day post-discharge ED-visit pathway, ~30 VA-FI comorbidity states,
  and a fixed ED-visit probability gate). `study_template.json` is the generic stub and
  is auto-skipped by Steps 3/4.
- The authoritative cohort, outcome, and covariate **definitions** live in the analysis
  repo `pad-amp-ed-desc/` (`inst/` cohorts + `covariates/`). This repo's `cohorts/*.sql`
  are kept only for Step 6 QC phenotype sanity checks; `covariates/*.csv` are emptied to
  headers on purpose.

### Schema naming (important)

`cdm_schema` is pinned to **`omop_synth_pad_amp_dispo`** (NOT `..._synth`) even though
this repo is `pad-amp-dispo-synth`. That physical schema is registered in
`../synthetic_data/registry.yaml` (`id: pad_amp_dispo`) and is consumed by both
`pad-amp-ed-desc` and `pad-oler-aki-desc` via view-overlays — both consume it through
an overlay schema, never the bare name directly, which is what made the 2026-07-31
rename (`pad-amp-ed-synth`/`pad_amp_ed`/`omop_synth_pad_amp_ed_desc` → `pad-amp-dispo-synth`/
`pad_amp_dispo`/`omop_synth_pad_amp_dispo`) low-risk: rebuild each consumer's overlay
after any regeneration, but do not change the pinned name again without checking both
consumers' overlay targets first.

### After a Step 5/6 run

Register/update the dataset entry in `../synthetic_data/registry.yaml` (`id: pad_amp_dispo`)
per that file's README — fill in `generation_params` and `last_generated.qc_summary`.
A consumer points its `OMOP_CDM_SCHEMA_OVERRIDE` view-overlay at this schema via
`Rscript synthetic_data/scripts/generate_overlay_schema.R`.

### Version Control Routing

This repo is **not** a submodule — it is an independent repository with its own GitHub
remote, created from the `synthea-omop-template` lineage (bootstrapped from
`pad-amp-ed-desc`'s data-generation half).

| Remote | URL | What to push |
|--------|-----|--------------|
| `origin` | `https://github.com/adam-mdmph/pad-amp-dispo-synth.git` | Full repository |

```bash
BRANCH=$(gh api user --jq .login)
git push origin "$BRANCH"   # then open a PR into main
```

Register this repo in the workspace root's `studies.yaml` (category: `data-generation`,
not a real study) so `/sync-template` and `/check-alignment` pick it up.
