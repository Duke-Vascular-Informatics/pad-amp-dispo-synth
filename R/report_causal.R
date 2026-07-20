# =============================================================================
# R/report_causal.R
#
# Placeholder for the causal inference (CohortMethod) report template.
#
# Entry point: .report_causal(output_dir, connection_details, config)
#
# To implement:
#   1. Source R/report_helpers.R for shared helper functions.
#   2. Define .report_causal() with the body below replaced by real logic.
#   3. Uncomment source("R/report_causal.R") in R/report_extended.R.
#
# Typical sections for a causal inference report:
#   - Title page
#   - Methods (data source, cohort definitions, propensity score model, estimator)
#   - Table 1: Covariate balance before / after PS matching
#   - Primary effect estimate with 95% CI (HR, RR, or RD)
#   - Subgroup heterogeneity forest plot
#   - Negative control calibration
#
# TODO [TEMPLATE]: implement for study_design = "causal_inference"
# =============================================================================

# .report_causal()
#
# Not yet implemented — fires an informative error when called.
.report_causal <- function(output_dir,
                           connection_details = NULL,
                           config             = NULL) {
  stop(
    "Causal inference report template is not yet implemented.\n",
    "  Implement .report_causal() in R/report_causal.R to enable this path.\n",
    "  See the file header for guidance."
  )
}
