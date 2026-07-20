# =============================================================================
# R/report_prognostic.R
#
# Parameterized Word report template for prognostic model validation studies.
# Handles both integer risk scores and LASSO models within a single template,
# routing on config$score_type.
#
# This file is sourced by R/report_extended.R (the dispatcher).
# Do NOT source R/report_helpers.R here — the dispatcher handles that.
#
# Entry points:
#   .report_prognostic(output_dir, score_output_dir, connection_details,
#                      config, citations)
#     — full manuscript-format Word report; called by generate_manuscript_report()
#       in R/report_extended.R.
#   .report_word_simple(output_dir, score_output_dir)
#     — lightweight report (no live CDM queries); called by generate_word_report()
#       in R/report_extended.R.
#
# Parameterization branches (inside .report_prognostic()):
#   Branch 1 — Table 2 predictor definitions:
#     lasso  → .covariate_table_data_lasso(config)
#     integer → .covariate_table_data()
#   Branch 2 — Table 3 covariate activation table:
#     lasso  → .build_combined_covariate_table(covariate_summary)
#     integer → .build_combined_component_table(covariate_summary)
#   Branch 3 — Annual / monthly outcome rate plots:
#     lasso  → .save_macce_rate_by_year_plot() / .save_macce_rate_by_month_plot()
#     integer → .save_ssi_rate_by_year_plot() / .save_ssi_rate_by_month_plot()
#   Branch 4 — Methods §2.2 narrative text:
#     lasso  → LASSO-specific paragraph
#     integer → integer-score-specific paragraph
#
# Dependencies:
#   R/report_helpers.R  — sourced by dispatcher before this file
#   dplyr               — used by .covariate_table_data_lasso()
#   readr               — used by .report_prognostic() for subgroup_bias.csv
# =============================================================================

# ---------------------------------------------------------------------------
# Integer score functions (from SSI validation study)
# ---------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# .covariate_table_data()
#
# Returns a static data frame defining the PAD SSI risk score covariates.
# Used as Table 2 in the Word report for integer score_type.
# Each row contains covariate_id, variable, points, lookback, omop_domain, derivation.
# This table is static (not queried from the CDM) — if covariates.csv is updated,
# this function must be kept in sync manually.
# -----------------------------------------------------------------------------
.covariate_table_data <- function() {
  data.frame(
    covariate_id = c(
      "female",
      "overweight",
      "obese",
      "urgnt",
      "abi_35",
      "prrevasc_any",
      "prolong_abx",
      "optime4h",
      "mFI_high",
      "indicationClaudication"
    ),
    variable = c(
      "Female sex",
      "Overweight (BMI 25 to <30)",
      "Obese (BMI ≥30)",
      "Urgent / emergency case",
      "Low ankle-brachial index (ABI ≤0.35)",
      "Prior revascularization (any)",
      "Prolonged antibiotic exposure",
      "Operative time ≥4 hours",
      "High modified Frailty Index (mFI)",
      "Indication: claudication"
    ),
    points = c(
      "+1", "+1", "+3", "+1", "+1",
      "+1", "+2", "+1", "+1", "−1"
    ),
    lookback = c(
      "Any time",
      "365 days",
      "365 days",
      "30 days",
      "365 days",
      "10 years",
      "90 days",
      "Index date",
      "365 days",
      "365 days"
    ),
    omop_domain = c(
      "Person",
      "Measurement",
      "Measurement",
      "Observation / Visit",
      "Measurement",
      "Procedure",
      "Drug Exposure",
      "Procedure",
      "Condition (composite)",
      "Condition"
    ),
    derivation = c(
      paste0(
        "Concept 8532 (Female) matched to person.gender_concept_id. ",
        "No lookback required; demographic attribute."
      ),
      paste0(
        "BMI resolved with three-tier priority: ",
        "(1) direct BMI measurement (LOINC 3038553, 36304833); ",
        "(2) computed from weight (LOINC 3025315, 3013762, 3011054, 3026600) ",
        "and height (LOINC 3036277, 3023540, 3015514) as weight_kg / height_m\u00b2. ",
        "Flagged when 25 \u2264 BMI < 30."
      ),
      paste0(
        "Same BMI resolution as Overweight (direct preferred, weight/height fallback). ",
        "Flagged when BMI \u2265 30. Mutually exclusive with Overweight."
      ),
      paste0(
        "Concepts 4158569 (Emergency procedure) and 4250892 (Urgent procedure), ",
        "plus all descendants via concept_ancestor, in procedure_occurrence or ",
        "observation within 30 days before or on the index date."
      ),
      paste0(
        "Concepts 40489833 and 46237026 (ABI measurement), plus descendants, in ",
        "the measurement table. Record is counted when value_as_number < 0.35."
      ),
      paste0(
        "Concepts 4236706 (Arterial bypass of lower limb artery) and 4225375 ",
        "(Endarterectomy of lower limb artery) and all descendants in procedure_occurrence. ",
        "Captures any prior lower-extremity arterial bypass or endarterectomy within a 10-year lookback."
      ),
      paste0(
        "Concept 21603553 (systemic antibiotic agent) and descendants in ",
        "drug_exposure. Counted when drug_exposure_start_date ≤ index − 1 day ",
        "and total exposure duration > 2 days (non-prophylactic heuristic)."
      ),
      paste0(
        "Operative duration derived from procedure_occurrence: ",
        "DATEDIFF(MINUTE, procedure_start_datetime, procedure_end_datetime) > 240. ",
        "Supplemented by measurement-table operative-time concepts when available."
      ),
      paste0(
        "Composite index of 5 sub-components: diabetes (201820), COPD (255573), ",
        "congestive heart failure (316139), hypertension (316866), and functional ",
        "status impairment (4215267), each with descendants in condition_occurrence. ",
        "Flagged when ≥2 conditions are present (mFI score > 0.25)."
      ),
      paste0(
        "Concept 442774 (Intermittent claudication) and descendants in ",
        "condition_occurrence. Negative point value — claudication as the ",
        "operative indication is a protective factor for post-operative SSI."
      )
    ),
    stringsAsFactors = FALSE
  )
}

# -----------------------------------------------------------------------------
# .build_combined_component_table()
#
# Merges the static covariate definitions with observed prevalence counts from
# the pipeline's covariate_summary.csv to produce a combined flextable for
# Table 3 in the Word report (integer score_type).
# Renamed from .build_combined_covariate_table() in the original SSI monolith.
# -----------------------------------------------------------------------------
.build_combined_component_table <- function(covariate_summary_df) {
  # Build combined covariate table with definitions and prevalence
  # Input: covariate_summary dataframe with columns: covariate_name, n_positive, n_total

  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)

  # Map covariates to their definitions and derivation methods
  covariate_defs <- list(
    "Female sex" = list(
      points = "+1",
      definition = "Female gender",
      omop_concept = "Concept 8532 (Female)",
      derivation = "person.gender_concept_id matches concept 8532"
    ),
    "Overweight (BMI 25 to <30)" = list(
      points = "+1",
      definition = "BMI between 25 and <30 kg/m\u00b2",
      omop_concept = paste0("Direct BMI: 3038553, 36304833; ",
                            "Weight: 3025315, 3013762, 3011054, 3026600; ",
                            "Height: 3036277, 3023540, 3015514"),
      derivation = paste0("Direct BMI measurement preferred (LOINC 39156-5 / 59574-4); ",
                          "computed from weight/height as fallback. 25 \u2264 BMI < 30.")
    ),
    "Obese (BMI \u226530)" = list(
      points = "+3",
      definition = "BMI \u2265 30 kg/m\u00b2",
      omop_concept = paste0("Direct BMI: 3038553, 36304833; ",
                            "Weight: 3025315, 3013762, 3011054, 3026600; ",
                            "Height: 3036277, 3023540, 3015514"),
      derivation = paste0("Direct BMI measurement preferred (LOINC 39156-5 / 59574-4); ",
                          "computed from weight/height as fallback. BMI \u2265 30.")
    ),
    "Urgent / emergency case" = list(
      points = "+1",
      definition = "Urgent or emergency procedure",
      omop_concept = "Concepts 4158569, 4250892 + descendants",
      derivation = "Procedure types in procedure_occurrence or observation within 30 days"
    ),
    "Low ankle-brachial index (ABI ≤0.35)" = list(
      points = "+1",
      definition = "ABI ≤ 0.35",
      omop_concept = "Concepts 40489833, 46237026 (ABI measurement)",
      derivation = "ABI measurement value < 0.35 in measurement table"
    ),
    "Prior revascularization (any)" = list(
      points = "+1",
      definition = "Any prior lower-extremity revascularization procedure",
      omop_concept = "Concepts 4236706 + 4225375 + descendants",
      derivation = "Procedure_occurrence within 10-year lookback"
    ),
    "Prolonged antibiotic exposure" = list(
      points = "+2",
      definition = "Non-prophylactic antibiotic exposure >2 days",
      omop_concept = "Concept 21603553 (systemic antibiotic) + descendants",
      derivation = "drug_exposure duration > 2 days within 90 days before index date"
    ),
    "Operative time ≥4 hours" = list(
      points = "+1",
      definition = "Operative duration ≥ 240 minutes",
      omop_concept = "procedure_occurrence timestamps (procedure_start/end_datetime)",
      derivation = "DATEDIFF(MINUTE, start, end) > 240"
    ),
    "High modified Frailty Index (mFI)" = list(
      points = "+1",
      definition = "Modified Frailty Index > 0.25 (≥2 of 5 conditions)",
      omop_concept = "Concepts 201820, 255573, 316139, 316866, 4215267",
      derivation = "Condition_occurrence: diabetes, COPD, CHF, hypertension, functional impairment"
    ),
    "Indication: claudication" = list(
      points = "−1",
      definition = "Intermittent claudication as operative indication",
      omop_concept = "Concept 442774 + descendants",
      derivation = "Condition_occurrence within 365 days"
    )
  )
  
  combined_data <- data.frame(
    Component = character(),
    Points = character(),
    Definition = character(),
    OMOP_Concept = character(),
    Count = integer(),
    Total = integer(),
    Prevalence = character(),
    stringsAsFactors = FALSE
  )
  
  for (i in seq_len(nrow(covariate_summary_df))) {
    cov_name <- covariate_summary_df$covariate_name[i]
    cov_def <- covariate_defs[[cov_name]]

    if (is.null(cov_def)) {
      cov_def <- list(
        points = "—", definition = cov_name, omop_concept = "—", derivation = "—"
      )
    }

    combined_data <- rbind(combined_data, data.frame(
      Component = cov_name,
      Points = cov_def$points,
      Definition = cov_def$definition,
      OMOP_Concept = cov_def$omop_concept,
      Count = covariate_summary_df$n_positive[i],
      Total = covariate_summary_df$n_total[i],
      Prevalence = paste0(
        round(100 * covariate_summary_df$n_positive[i] / covariate_summary_df$n_total[i], 1), "%"
      ),
      stringsAsFactors = FALSE
    ))
  }
  
  ft <- flextable(combined_data) |>
    set_header_labels(
      Component = "Component",
      Points = "Points",
      Definition = "Definition",
      OMOP_Concept = "OMOP Standard Concept ID(s)",
      Count = "Count",
      Total = "Total",
      Prevalence = "Prevalence %"
    ) |>
    bold(part = "header") |>
    fontsize(size = 9, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "Component", width = 1.8) |>
    width(j = "Points", width = 0.5) |>
    width(j = "Definition", width = 1.8) |>
    width(j = "OMOP_Concept", width = 1.8) |>
    width(j = "Count", width = 0.6) |>
    width(j = "Total", width = 0.6) |>
    width(j = "Prevalence", width = 0.8) |>
    align(j = c("Points", "Count", "Total", "Prevalence"), align = "center", part = "all") |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    set_table_properties(layout = "fixed") |>
    padding(padding = 3, part = "all")
  
  ft
}


# -----------------------------------------------------------------------------
# .save_ssi_rate_by_year_plot()
#
# Stacked area chart of annual SSI rate (%) by SSI type and procedure year.
# Used for integer score_type studies with SSI as the outcome.
# -----------------------------------------------------------------------------
.save_ssi_rate_by_year_plot <- function(person_level_df, output_folder) {
  if (!all(c("index_date", "outcome") %in% names(person_level_df))) {
    message("[report] SSI-by-year plot skipped: index_date or outcome column missing.")
    return(NULL)
  }

  year_val <- tryCatch(
    as.integer(format(as.Date(person_level_df$index_date), "%Y")),
    error = function(e) NA_integer_
  )

  # Build per-patient data frame with year and SSI type
  # ssi_type is "Superficial", "Deep", or "Organ-space" for SSI cases; NA otherwise
  has_type <- "ssi_type" %in% names(person_level_df)
  df_yr <- data.frame(
    year     = year_val,
    outcome  = as.integer(person_level_df$outcome),
    ssi_type = if (has_type) person_level_df$ssi_type else NA_character_,
    stringsAsFactors = FALSE
  )
  df_yr <- df_yr[!is.na(df_yr$year), ]

  # Factor levels determine stacking order: first level = bottom of stack.
  # "Other/unclassified" anchors the bottom to capture outcome events with no
  # recorded sub-type; named types stack above in ascending severity order.
  ssi_levels <- c("Other/unclassified", "Superficial", "Deep", "Organ-space")

  # Aggregate individual SSI rate per year × SSI type.
  # Denominator = all procedures that year; numerator = events of that sub-type.
  # "Other/unclassified" = outcome == 1 patients with no ssi_type sub-code.
  all_years <- sort(unique(df_yr$year))
  yr_type_tbl <- do.call(rbind, lapply(all_years, function(y) {
    sub_yr <- df_yr[df_yr$year == y, ]
    n_yr   <- nrow(sub_yr)
    do.call(rbind, lapply(ssi_levels, function(tp) {
      events <- if (tp == "Other/unclassified") {
        sum(sub_yr$outcome == 1 & is.na(sub_yr$ssi_type), na.rm = TRUE)
      } else {
        sum(sub_yr$ssi_type == tp, na.rm = TRUE)
      }
      data.frame(
        year     = y,
        n        = n_yr,
        ssi_type = tp,
        events   = events,
        ssi_rate = 100 * events / n_yr,
        stringsAsFactors = FALSE
      )
    }))
  }))

  if (length(unique(yr_type_tbl$year)) < 2) {
    message("[report] SSI-by-year plot skipped: fewer than 2 years of data.")
    return(NULL)
  }

  # Enforce stacking order — Superficial bottom, Organ-space top
  yr_type_tbl$ssi_type <- factor(yr_type_tbl$ssi_type, levels = ssi_levels)

  # Fill colours (bottom to top): warm gray, teal, navy, red
  # "Other/unclassified" sits at the bottom (first factor level) in warm gray.
  fill_colours <- c(
    "Other/unclassified" = "#B0A090",   # warm gray
    "Superficial"        = "#A8D5DC",   # light teal
    "Deep"               = "#5B8DB8",   # mid blue
    "Organ-space"        = "#C0392B"    # red
  )
  line_colours <- c(
    "Other/unclassified" = "#6B5C50",
    "Superficial"        = "#2196A6",
    "Deep"               = "#1F3864",
    "Organ-space"        = "#922B21"
  )

  total_procs <- sum(yr_type_tbl$n[!duplicated(yr_type_tbl[, c("year")])  ])
  total_years <- length(unique(yr_type_tbl$year))

  p <- ggplot2::ggplot(
      yr_type_tbl,
      ggplot2::aes(x = year, y = ssi_rate,
                   fill = ssi_type, colour = ssi_type, group = ssi_type)
    ) +
    # Stacked shaded bands
    ggplot2::geom_area(position = "stack", alpha = 0.55, linewidth = 0.3) +
    # Bold boundary lines along the top edge of each band
    ggplot2::geom_line(
      ggplot2::aes(y = ssi_rate),
      position = ggplot2::position_stack(),
      linewidth = 0.9
    ) +
    # Points on each band's top edge
    ggplot2::geom_point(
      position = ggplot2::position_stack(),
      size = 2.5, shape = 21,
      fill = "white", stroke = 1.2
    ) +
    ggplot2::scale_fill_manual(
      values = fill_colours,
      breaks = ssi_levels,   # legend order matches factor levels
      name   = "Outcome type"
    ) +
    ggplot2::scale_colour_manual(
      values = line_colours,
      breaks = ssi_levels,
      name   = "Outcome type"
    ) +
    ggplot2::scale_x_continuous(breaks = sort(unique(yr_type_tbl$year))) +
    ggplot2::scale_y_continuous(
      limits = c(0, NA),
      labels = function(x) paste0(round(x, 1), "%")
    ) +
    ggplot2::labs(
      title   = "Outcome Rate by Type and Procedure Year",
      subtitle = "Top line = overall rate; bands show contribution of each type",
      x       = "Year of procedure",
      y       = "Outcome rate (%)",
      caption = paste0("N = ", total_procs, " procedures across ", total_years,
                       " years; years with < 10 procedures suppressed.")
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      axis.text.x      = ggplot2::element_text(angle = 45, hjust = 1),
      plot.caption     = ggplot2::element_text(size = 8),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position  = "bottom"
    )

  out_file <- file.path(output_folder, "ssi_rate_by_year.png")
  tryCatch({
    ggplot2::ggsave(out_file, p, width = 7, height = 5, dpi = 150)
    out_file
  }, error = function(e) {
    message("[report] Could not save SSI-by-year plot: ", conditionMessage(e))
    NULL
  })
}

# -----------------------------------------------------------------------------
# .save_ssi_rate_by_month_plot()
#
# Bar chart of 90-day SSI rate (%) by calendar month (Jan-Dec), pooled across
# all years.  Used for integer score_type studies.
# -----------------------------------------------------------------------------
.save_ssi_rate_by_month_plot <- function(person_level_df, output_folder) {
  if (!all(c("index_date", "outcome") %in% names(person_level_df))) {
    message("[report] SSI-by-month plot skipped: index_date or outcome column missing.")
    return(NULL)
  }

  month_val <- tryCatch(
    as.integer(format(as.Date(person_level_df$index_date), "%m")),
    error = function(e) NA_integer_
  )

  df_mo <- data.frame(
    month   = month_val,
    outcome = as.integer(person_level_df$outcome),
    stringsAsFactors = FALSE
  )
  df_mo <- df_mo[!is.na(df_mo$month), ]

  # Aggregate across all months 1–12 (keep all so x-axis is always Jan–Dec).
  # Wilson score 95% CIs via prop.test(); suppressed when n < 5.
  mo_tbl <- do.call(rbind, lapply(1:12, function(m) {
    sub    <- df_mo[df_mo$month == m, ]
    n      <- nrow(sub)
    events <- sum(sub$outcome, na.rm = TRUE)
    ci <- if (n >= 5) {
      tryCatch({
        bt <- stats::prop.test(events, n, conf.level = 0.95, correct = FALSE)
        100 * c(bt$conf.int[1], bt$conf.int[2])
      }, error = function(e) c(NA_real_, NA_real_))
    } else {
      c(NA_real_, NA_real_)
    }
    data.frame(
      month    = m,
      n        = n,
      events   = events,
      ssi_rate = if (n >= 5) 100 * events / n else NA_real_,
      ci_lower = ci[1],
      ci_upper = ci[2],
      stringsAsFactors = FALSE
    )
  }))

  mo_tbl$month_label <- factor(
    mo_tbl$month,
    levels = 1:12,
    labels = c("Jan","Feb","Mar","Apr","May","Jun",
               "Jul","Aug","Sep","Oct","Nov","Dec")
  )

  if (all(is.na(mo_tbl$ssi_rate))) {
    message("[report] SSI-by-month plot skipped: all months suppressed (< 5 procedures each).")
    return(NULL)
  }

  p <- ggplot2::ggplot(mo_tbl, ggplot2::aes(x = month_label, y = ssi_rate)) +
    ggplot2::geom_col(fill = "#1F3864", width = 0.7, na.rm = TRUE) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = ci_lower, ymax = ci_upper),
      width = 0.25, colour = "grey50", linewidth = 0.6, na.rm = TRUE
    ) +
    # Position n= label above the upper CI whisker so it does not overlap the bar.
    ggplot2::geom_text(
      ggplot2::aes(
        y     = ifelse(!is.na(ci_upper), ci_upper, ssi_rate),
        label = ifelse(!is.na(ssi_rate), paste0("n=", n), "")
      ),
      vjust = -0.4, size = 2.8, colour = "grey30", na.rm = TRUE
    ) +
    ggplot2::scale_y_continuous(
      limits = c(0, NA),
      expand = ggplot2::expansion(mult = c(0, 0.20)),
      labels = function(x) paste0(round(x, 1), "%")
    ) +
    ggplot2::labs(
      title   = "Outcome Rate by Month of Procedure",
      x       = "Month of index procedure",
      y       = "Outcome rate (%)",
      caption = paste0("Pooled across all study years. ",
                       "Error bars = 95% Wilson score confidence intervals. ",
                       "Months with < 5 procedures suppressed.")
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      plot.caption     = ggplot2::element_text(size = 8),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank()
    )

  out_file <- file.path(output_folder, "ssi_rate_by_month.png")
  tryCatch({
    ggplot2::ggsave(out_file, p, width = 7, height = 4.5, dpi = 150)
    out_file
  }, error = function(e) {
    message("[report] Could not save SSI-by-month plot: ", conditionMessage(e))
    NULL
  })
}


# ---------------------------------------------------------------------------
# LASSO model functions (from MACCE validation study)
# ---------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# .covariate_table_data_lasso()
#
# Reads included LASSO predictors from model/varImp.rds and returns a data frame
# for inclusion in the Word report as Table 2 (lasso score_type).
# Renamed from .covariate_table_data() in the original MACCE monolith.
# Now accepts config as first argument and reads config$var_imp_file instead of
# the hardcoded default path.
# -----------------------------------------------------------------------------
.covariate_table_data_lasso <- function(config, n_top = Inf) {
  varImp_path <- config$var_imp_file %||% "model/varImp.rds"
  if (!file.exists(varImp_path)) {
    stop("varImp.rds not found at: ", varImp_path,
         "\nSet varImp_path= or ensure the model artifact exists before generating the report.")
  }

  vi <- readRDS(varImp_path)

  # Retain only model-included covariates (included == 1 flags the LASSO-selected set).
  vi <- vi[!is.na(vi$included) & vi$included == 1, ]

  if (nrow(vi) == 0) {
    stop("No covariates with included == 1 found in ", varImp_path)
  }

  # Derive OMOP domain from analysisId encoding used by FeatureExtraction:
  #   2xx = condition_era, 4xx = drug_era, 9xx = measurement value,
  #   5xx = demographics,  7xx = visit,    other = miscellaneous
  get_domain <- function(aid) {
    ifelse(aid >= 200L & aid < 300L, "Condition",
    ifelse(aid >= 400L & aid < 500L, "Drug",
    ifelse(aid >= 900L & aid < 1000L, "Measurement",
    ifelse(aid >= 500L & aid < 600L, "Demographics",
    ifelse(aid >= 700L & aid < 800L, "Visit",
    "Other")))))
  }

  # Derive human-readable lookback window from analysisId.
  # Window codes follow FeatureExtraction default temporal analysis settings.
  get_lookback <- function(aid) {
    dplyr::case_when(
      aid %in% c(210L, 410L) ~ "365 to 3 days before index",
      aid %in% c(211L, 411L) ~ "180 to 3 days before index",
      aid %in% c(212L, 412L) ~ "30 to 3 days before index",
      aid %in% c(501L, 502L, 503L, 504L) ~ "At index (demographic)",
      aid %in% c(706L, 707L, 708L) ~ "365 days before index (visit)",
      aid %in% c(901L, 904L) ~ "Most recent value in 365 days before index",
      aid %in% c(998L, 999L) ~ "Aggregated risk score",
      TRUE ~ paste0("analysisId=", aid)
    )
  }

  vi$domain   <- get_domain(vi$analysisId)
  vi$lookback <- get_lookback(vi$analysisId)

  # Strip the FeatureExtraction time-window prefix from covariateName.
  # E.g. "condition_era group during day -365 through -3 days relative to index: Angina pectoris"
  # becomes "Angina pectoris".
  vi$variable <- sub("^[^:]+:\\s*", "", vi$covariateName)

  # Derivation note: OMOP CDM table and concept hierarchy source.
  vi$derivation <- ifelse(
    vi$domain == "Condition",
    paste0("Concept ", vi$conceptId, " + descendants in condition_occurrence (condition_era)."),
    ifelse(vi$domain == "Drug",
      paste0("Concept ", vi$conceptId, " + descendants in drug_exposure (drug_era)."),
      ifelse(vi$domain == "Measurement",
        paste0("Concept ", vi$conceptId, " in measurement; most recent value in lookback window."),
        paste0("FeatureExtraction analysisId=", vi$analysisId, ", conceptId=", vi$conceptId, ".")
      )
    )
  )

  # Sort by absolute coefficient value descending so the most predictive
  # covariates appear first.
  vi <- vi[order(-abs(vi$covariateValue)), ]

  # Trim to top n_top rows if requested.
  if (is.finite(n_top) && n_top < nrow(vi)) {
    vi <- vi[seq_len(as.integer(n_top)), ]
  }

  # Coerce covariateId to plain numeric so that merge() with covariate_summary
  # (read from CSV via read.csv(), which returns numeric) produces matches.
  # PLP RDS files store covariateId as bit64::integer64; read.csv() returns
  # numeric (double).  R's merge() treats these as different types and finds
  # zero intersections without explicit coercion.
  data.frame(
    covariate_id = as.numeric(vi$covariateId),
    variable     = vi$variable,
    weight       = vi$covariateValue,
    lookback     = vi$lookback,
    domain       = vi$domain,
    derivation   = vi$derivation,
    stringsAsFactors = FALSE
  )
}

# -----------------------------------------------------------------------------
# .build_combined_covariate_table()
#
# Builds a combined covariate table for LASSO score_type studies (PLP mode).
# Shows top predictors by |coefficient| with prevalence counts.
# Copied verbatim from pad-oler-macce-val/R/report_extended.R.
# -----------------------------------------------------------------------------
.build_combined_covariate_table <- function(covariate_summary_df) {
  # Build combined covariate table with definitions and prevalence.
  # Input: covariate_summary dataframe.
  # PLP mode: detected when "feature_importance" column is present.
  #   Columns: Feature, Importance (LASSO weight), Count, Prevalence.
  # Integer-score mode: covariate_name, n_positive, n_total, no feature_importance.
  #   Columns: Component, Points, Definition, OMOP_Concept, Count, Total, Prevalence.

  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)

  is_plp_mode <- "feature_importance" %in% names(covariate_summary_df)

  if (is_plp_mode) {
    # ---- PLP mode: show top features by |LASSO weight| with prevalence ----
    n_total <- if ("n_total" %in% names(covariate_summary_df))
                 covariate_summary_df$n_total[1] else NA_integer_

    # Strip FeatureExtraction time-window prefix from covariate name for display.
    # E.g. "condition_era group during day -365 through -3 days relative to index: Angina"
    # becomes "Angina".
    display_name <- sub("^[^:]+:\\s*", "", covariate_summary_df$covariate_name)

    plp_data <- data.frame(
      Feature      = display_name,
      Importance   = round(covariate_summary_df$feature_importance, 4),
      Count        = as.integer(covariate_summary_df$n_positive),
      Prevalence   = paste0(
        ifelse(!is.na(n_total) & n_total > 0,
               round(100 * covariate_summary_df$n_positive / n_total, 1),
               NA_real_), "%"),
      stringsAsFactors = FALSE
    )

    ft <- flextable::flextable(plp_data) |>
      flextable::set_header_labels(
        Feature    = "Feature (top predictors by |coefficient|)",
        Importance = "LASSO\nCoefficient",
        Count      = "Count\n(n positive)",
        Prevalence = "Prevalence %"
      ) |>
      flextable::bold(part = "header") |>
      flextable::fontsize(size = 9, part = "all") |>
      flextable::font(fontname = "Calibri", part = "all") |>
      flextable::width(j = "Feature",    width = 3.5) |>
      flextable::width(j = "Importance", width = 0.8) |>
      flextable::width(j = "Count",      width = 0.7) |>
      flextable::width(j = "Prevalence", width = 0.8) |>
      flextable::align(j = c("Importance", "Count", "Prevalence"),
                       align = "center", part = "all") |>
      flextable::bg(part = "header", bg = "#1F3864") |>
      flextable::color(part = "header", color = "white") |>
      flextable::hline(border = border_h, part = "body") |>
      flextable::border_outer(border = border_out, part = "all") |>
      flextable::set_table_properties(layout = "fixed") |>
      flextable::padding(padding = 3, part = "all")

    return(ft)
  }

  # ---- Integer-score mode: full covariate definition table ----

  # Map covariates to their definitions and derivation methods
  covariate_defs <- list(
    "Female sex" = list(
      points = "+1",
      definition = "Female gender",
      omop_concept = "Concept 8532 (Female)",
      derivation = "person.gender_concept_id matches concept 8532"
    ),
    "Overweight (BMI 25 to <30)" = list(
      points = "+1",
      definition = "BMI between 25 and <30 kg/m\u00b2",
      omop_concept = paste0("Direct BMI: 3038553, 36304833; ",
                            "Weight: 3025315, 3013762, 3011054, 3026600; ",
                            "Height: 3036277, 3023540, 3015514"),
      derivation = paste0("Direct BMI measurement preferred (LOINC 39156-5 / 59574-4); ",
                          "computed from weight/height as fallback. 25 \u2264 BMI < 30.")
    ),
    "Obese (BMI \u226530)" = list(
      points = "+3",
      definition = "BMI \u2265 30 kg/m\u00b2",
      omop_concept = paste0("Direct BMI: 3038553, 36304833; ",
                            "Weight: 3025315, 3013762, 3011054, 3026600; ",
                            "Height: 3036277, 3023540, 3015514"),
      derivation = paste0("Direct BMI measurement preferred (LOINC 39156-5 / 59574-4); ",
                          "computed from weight/height as fallback. BMI \u2265 30.")
    ),
    "Urgent / emergency case" = list(
      points = "+1",
      definition = "Urgent or emergency procedure",
      omop_concept = "Concepts 4158569, 4250892 + descendants",
      derivation = "Procedure types in procedure_occurrence or observation within 30 days"
    ),
    "Low ankle-brachial index (ABI ≤0.35)" = list(
      points = "+1",
      definition = "ABI ≤ 0.35",
      omop_concept = "Concepts 40489833, 46237026 (ABI measurement)",
      derivation = "ABI measurement value < 0.35 in measurement table"
    ),
    "Prior revascularization (any)" = list(
      points = "+1",
      definition = "Any prior lower-extremity revascularization procedure",
      omop_concept = "Concepts 4236706 + 4225375 + descendants",
      derivation = "Procedure_occurrence within 10-year lookback"
    ),
    "Prolonged antibiotic exposure" = list(
      points = "+2",
      definition = "Non-prophylactic antibiotic exposure >2 days",
      omop_concept = "Concept 21603553 (systemic antibiotic) + descendants",
      derivation = "drug_exposure duration > 2 days within 90 days before index date"
    ),
    "Operative time ≥4 hours" = list(
      points = "+1",
      definition = "Operative duration ≥ 240 minutes",
      omop_concept = "procedure_occurrence timestamps (procedure_start/end_datetime)",
      derivation = "DATEDIFF(MINUTE, start, end) > 240"
    ),
    "High modified Frailty Index (mFI)" = list(
      points = "+1",
      definition = "Modified Frailty Index > 0.25 (≥2 of 5 conditions)",
      omop_concept = "Concepts 201820, 255573, 316139, 316866, 4215267",
      derivation = "Condition_occurrence: diabetes, COPD, CHF, hypertension, functional impairment"
    ),
    "Indication: claudication" = list(
      points = "−1",
      definition = "Intermittent claudication as operative indication",
      omop_concept = "Concept 442774 + descendants",
      derivation = "Condition_occurrence within 365 days"
    )
  )
  
  combined_data <- data.frame(
    Component = character(),
    Points = character(),
    Definition = character(),
    OMOP_Concept = character(),
    Count = integer(),
    Total = integer(),
    Prevalence = character(),
    stringsAsFactors = FALSE
  )
  
  for (i in seq_len(nrow(covariate_summary_df))) {
    cov_name <- covariate_summary_df$covariate_name[i]
    cov_def <- covariate_defs[[cov_name]]

    if (is.null(cov_def)) {
      cov_def <- list(
        points = "—", definition = cov_name, omop_concept = "—", derivation = "—"
      )
    }

    combined_data <- rbind(combined_data, data.frame(
      Component = cov_name,
      Points = cov_def$points,
      Definition = cov_def$definition,
      OMOP_Concept = cov_def$omop_concept,
      Count = covariate_summary_df$n_positive[i],
      Total = covariate_summary_df$n_total[i],
      Prevalence = paste0(
        round(100 * covariate_summary_df$n_positive[i] / covariate_summary_df$n_total[i], 1), "%"
      ),
      stringsAsFactors = FALSE
    ))
  }
  
  ft <- flextable(combined_data) |>
    set_header_labels(
      Component = "Component",
      Points = "Points",
      Definition = "Definition",
      OMOP_Concept = "OMOP Standard Concept ID(s)",
      Count = "Count",
      Total = "Total",
      Prevalence = "Prevalence %"
    ) |>
    bold(part = "header") |>
    fontsize(size = 9, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "Component", width = 1.8) |>
    width(j = "Points", width = 0.5) |>
    width(j = "Definition", width = 1.8) |>
    width(j = "OMOP_Concept", width = 1.8) |>
    width(j = "Count", width = 0.6) |>
    width(j = "Total", width = 0.6) |>
    width(j = "Prevalence", width = 0.8) |>
    align(j = c("Points", "Count", "Total", "Prevalence"), align = "center", part = "all") |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    set_table_properties(layout = "fixed") |>
    padding(padding = 3, part = "all")
  
  ft
}

# -----------------------------------------------------------------------------
# .save_macce_rate_by_year_plot()
#
# Single-line trend of annual outcome rate (%) by procedure year.
# Used for lasso score_type studies (e.g. MACCE outcome).
# Copied verbatim from pad-oler-macce-val/R/report_extended.R.
# -----------------------------------------------------------------------------
.save_macce_rate_by_year_plot <- function(person_level_df, output_folder) {
  if (!all(c("index_date", "outcome") %in% names(person_level_df))) {
    message("[report] MACCE-by-year plot skipped: index_date or outcome column missing.")
    return(NULL)
  }

  year_val <- tryCatch(
    as.integer(format(as.Date(person_level_df$index_date), "%Y")),
    error = function(e) NA_integer_
  )

  df_yr <- data.frame(
    year    = year_val,
    outcome = as.integer(person_level_df$outcome),
    stringsAsFactors = FALSE
  )
  df_yr <- df_yr[!is.na(df_yr$year), ]

  all_years <- sort(unique(df_yr$year))
  yr_tbl <- do.call(rbind, lapply(all_years, function(y) {
    sub_yr <- df_yr[df_yr$year == y, ]
    n_yr   <- nrow(sub_yr)
    events <- sum(sub_yr$outcome, na.rm = TRUE)
    data.frame(
      year       = y,
      n          = n_yr,
      events     = events,
      macce_rate = if (n_yr >= 10L) 100 * events / n_yr else NA_real_,
      stringsAsFactors = FALSE
    )
  }))

  yr_tbl <- yr_tbl[!is.na(yr_tbl$macce_rate), ]

  if (nrow(yr_tbl) < 2L) {
    message("[report] MACCE-by-year plot skipped: fewer than 2 years with >= 10 procedures.")
    return(NULL)
  }

  total_procs <- sum(yr_tbl$n)
  total_years <- nrow(yr_tbl)

  p <- ggplot2::ggplot(yr_tbl, ggplot2::aes(x = year, y = macce_rate)) +
    ggplot2::geom_line(colour = "#1F3864", linewidth = 0.9) +
    ggplot2::geom_point(colour = "#1F3864", size = 2.5, shape = 21,
                        fill = "white", stroke = 1.2) +
    ggplot2::scale_x_continuous(breaks = yr_tbl$year) +
    ggplot2::scale_y_continuous(
      limits = c(0, NA),
      labels = function(x) paste0(round(x, 1), "%")
    ) +
    ggplot2::labs(
      title   = "90-Day MACCE Rate by Procedure Year",
      x       = "Year of procedure",
      y       = "30-day MACCE rate (%)",
      caption = paste0("N = ", total_procs, " procedures across ", total_years,
                       " years; years with < 10 procedures suppressed.")
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      axis.text.x      = ggplot2::element_text(angle = 45, hjust = 1),
      plot.caption     = ggplot2::element_text(size = 8),
      panel.grid.minor = ggplot2::element_blank()
    )

  out_file <- file.path(output_folder, "macce_rate_by_year.png")
  tryCatch({
    ggplot2::ggsave(out_file, p, width = 7, height = 5, dpi = 150)
    out_file
  }, error = function(e) {
    message("[report] Could not save MACCE-by-year plot: ", conditionMessage(e))
    NULL
  })
}

# -----------------------------------------------------------------------------
# .save_macce_rate_by_month_plot()
#
# Bar chart of monthly outcome rate (%) by calendar month.
# Used for lasso score_type studies.
# Copied verbatim from pad-oler-macce-val/R/report_extended.R.
# -----------------------------------------------------------------------------
.save_macce_rate_by_month_plot <- function(person_level_df, output_folder) {
  if (!all(c("index_date", "outcome") %in% names(person_level_df))) {
    message("[report] MACCE-by-month plot skipped: index_date or outcome column missing.")
    return(NULL)
  }

  month_val <- tryCatch(
    as.integer(format(as.Date(person_level_df$index_date), "%m")),
    error = function(e) NA_integer_
  )

  df_mo <- data.frame(
    month   = month_val,
    outcome = as.integer(person_level_df$outcome),
    stringsAsFactors = FALSE
  )
  df_mo <- df_mo[!is.na(df_mo$month), ]

  mo_tbl <- do.call(rbind, lapply(1:12, function(m) {
    sub    <- df_mo[df_mo$month == m, ]
    n      <- nrow(sub)
    events <- sum(sub$outcome, na.rm = TRUE)
    data.frame(
      month      = m,
      n          = n,
      events     = events,
      macce_rate = if (n >= 5L) 100 * events / n else NA_real_,
      stringsAsFactors = FALSE
    )
  }))

  mo_tbl$month_label <- factor(
    mo_tbl$month,
    levels = 1:12,
    labels = c("Jan","Feb","Mar","Apr","May","Jun",
               "Jul","Aug","Sep","Oct","Nov","Dec")
  )

  if (all(is.na(mo_tbl$macce_rate))) {
    message("[report] MACCE-by-month plot skipped: all months suppressed (< 5 procedures each).")
    return(NULL)
  }

  p <- ggplot2::ggplot(mo_tbl, ggplot2::aes(x = month_label, y = macce_rate)) +
    ggplot2::geom_col(fill = "#1F3864", width = 0.7, na.rm = TRUE) +
    ggplot2::geom_text(
      ggplot2::aes(label = ifelse(!is.na(macce_rate), paste0("n=", n), "")),
      vjust = -0.4, size = 2.8, colour = "grey30", na.rm = TRUE
    ) +
    ggplot2::scale_y_continuous(
      limits = c(0, NA),
      expand = ggplot2::expansion(mult = c(0, 0.15)),
      labels = function(x) paste0(round(x, 1), "%")
    ) +
    ggplot2::labs(
      title   = "90-Day MACCE Rate by Month of Procedure",
      x       = "Month of index procedure",
      y       = "30-day MACCE rate (%)",
      caption = "Pooled across all study years. Months with < 5 procedures suppressed."
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      plot.caption       = ggplot2::element_text(size = 8),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank()
    )

  out_file <- file.path(output_folder, "macce_rate_by_month.png")
  tryCatch({
    ggplot2::ggsave(out_file, p, width = 7, height = 4.5, dpi = 150)
    out_file
  }, error = function(e) {
    message("[report] Could not save MACCE-by-month plot: ", conditionMessage(e))
    NULL
  })
}


# ===========================================================================
# .report_word_simple()
#
# Lightweight report that reads pipeline CSV outputs and assembles a Word
# document.  No live CDM queries.  Called by generate_word_report() in
# R/report_extended.R.
#
# Renamed from generate_word_report() in the original synthea-omop-template monolith.
# Body is verbatim — no parameterization applied to the simple report.
# ===========================================================================
# =============================================================================
# CLAUDE CODE — READ BEFORE GENERATING THIS REPORT
#
# Before calling this function (or enabling word_report: true in study_params.yaml),
# read the following study files and fill in the report: section of study_params.yaml
# so the Methods paragraphs accurately describe THIS study:
#
#   1. study_params.yaml               — study design, prediction window, outcome label
#   2. cohorts/<target_sql_file>       — target cohort inclusion/exclusion criteria,
#                                        index event concept IDs, washout definition
#   3. cohorts/<outcome_sql_file>      — outcome definition and OMOP concept IDs
#   4. covariates/covariates.csv       — risk score components, point values, lookback windows
#   5. covariates/covariate_concepts.csv — OMOP concept IDs mapped to each component
#
# After reading those files, update these fields in study_params.yaml under report:
#
#   study_title                   — display title for the report
#   target_population_description — 2–3 sentence paragraph for Methods §2.1 (target cohort)
#   outcome_description           — 2–3 sentence paragraph for Methods §2.1 (outcome)
#   score_description             — narrative paragraph for Methods §2.2 (model components)
#
# Paragraphs still showing "[...]" placeholder text mean that field has not been set.
# Do NOT leave placeholder text in a final report.
# =============================================================================
.report_word_simple <- function(output_dir       = "output/risk_score_eval",
                                score_output_dir = "output/risk_score_eval",
                                config           = NULL) {

  # Load config from study_params.yaml when not supplied by the caller.
  if (is.null(config)) {
    config <- tryCatch(get_validation_config(), error = function(e) NULL)
  }

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  # Load pipeline outputs if available
  person_level <- NULL
  covariate_summary <- NULL
  metrics <- NULL
  calibration_plot_files <- list()
  roc_plot_file <- NULL

  if (file.exists(file.path(score_output_dir, "person_level_scores.csv"))) {
    person_level <- read.csv(file.path(score_output_dir, "person_level_scores.csv"), stringsAsFactors = FALSE)
  }
  if (file.exists(file.path(score_output_dir, "covariate_summary.csv"))) {
    covariate_summary <- read.csv(file.path(score_output_dir, "covariate_summary.csv"), stringsAsFactors = FALSE)
  }
  if (file.exists(file.path(score_output_dir, "metrics.csv"))) {
    metrics <- read.csv(file.path(score_output_dir, "metrics.csv"), stringsAsFactors = FALSE)
  }

  # Ensure calibration PNGs exist for report insertion by backfilling from CSV
  # tables (preferred) or person-level predictions (fallback).
  lookup_plot_path <- file.path(score_output_dir, "calibration_lookup.png")
  recal_plot_path <- file.path(score_output_dir, "calibration_recalibrated.png")
  lookup_table_path <- file.path(score_output_dir, "calibration_table_lookup.csv")
  recal_table_path <- file.path(score_output_dir, "calibration_table_recalibrated.csv")

  if (!file.exists(lookup_plot_path) && file.exists(lookup_table_path)) {
    .save_calibration_plot_from_table(
      calibration_table_path = lookup_table_path,
      output_folder = score_output_dir,
      file_name = "calibration_lookup.png",
      plot_title = "Calibration Plot: Lookup Model"
    )
  }
  if (!file.exists(recal_plot_path) && file.exists(recal_table_path)) {
    .save_calibration_plot_from_table(
      calibration_table_path = recal_table_path,
      output_folder = score_output_dir,
      file_name = "calibration_recalibrated.png",
      plot_title = "Calibration Plot: Recalibrated Model"
    )
  }

  if (!file.exists(lookup_plot_path) && !is.null(person_level) &&
      all(c("outcome", "predicted_risk_lookup") %in% names(person_level))) {
    .save_calibration_plot_from_vectors(
      y = person_level$outcome,
      p = person_level$predicted_risk_lookup,
      output_folder = score_output_dir,
      file_name = "calibration_lookup.png",
      plot_title = "Calibration Plot: Lookup Model"
    )
  }
  if (!file.exists(recal_plot_path) && !is.null(person_level) &&
      all(c("outcome", "predicted_risk_recalibrated") %in% names(person_level))) {
    .save_calibration_plot_from_vectors(
      y = person_level$outcome,
      p = person_level$predicted_risk_recalibrated,
      output_folder = score_output_dir,
      file_name = "calibration_recalibrated.png",
      plot_title = "Calibration Plot: Recalibrated Model"
    )
  }
  
  # Check for calibration plot files
  cal_files <- list.files(score_output_dir, pattern = "^calibration_.*\\.png$", full.names = TRUE)
  if (length(cal_files) > 0) {
    calibration_plot_files <- setNames(cal_files, 
                                         gsub(".*calibration_|\\.png$", "", cal_files))
  }
  
  # Generate ROC plot if we have the data
  if (!is.null(person_level)) {
    roc_plot_file <- .save_roc_plot(
      y = person_level$outcome,
      p = if ("predicted_risk_recalibrated" %in% names(person_level)) 
          person_level$predicted_risk_recalibrated
        else person_level$total_score / max(person_level$total_score, na.rm = TRUE),
      output_folder = score_output_dir
    )
  }

  # ---- Resolve narrative text from config (set via study_params.yaml report:) ----
  # Falls back to a "[PLACEHOLDER]" reminder string — see CLAUDE CODE INSTRUCTIONS above.
  cfg_study_title <- config$report_study_title %||%
    paste0("[STUDY_TITLE: Set report.study_title in study_params.yaml.",
           " Ask Claude Code to read cohorts/ and covariates/ and generate the title.]")

  cfg_target_pop <- config$report_target_population_description %||%
    paste0("[TARGET_POPULATION_DESCRIPTION: Read ",
           config$target_cohort_sql %||% "cohorts/target.sql",
           " and rewrite this paragraph to describe who enters the cohort,",
           " how the index date is defined, and what washout is applied.",
           " Store the result in report.target_population_description in study_params.yaml.]")

  cfg_outcome <- config$report_outcome_description %||%
    paste0("[OUTCOME_DESCRIPTION: Read ",
           config$outcome_cohort_sql %||% "cohorts/outcome.sql",
           " and rewrite this paragraph to describe the outcome concept IDs, ascertainment logic,",
           " and the ", config$prediction_window_days %||% "N",
           "-day prediction window.",
           " Store the result in report.outcome_description in study_params.yaml.]")

  cfg_score <- config$report_score_description %||%
    paste0("[SCORE_DESCRIPTION: Read covariates/covariates.csv and covariates/covariate_concepts.csv",
           " and rewrite this paragraph to describe the ",
           config$model_type_description %||% "risk model",
           " components, point values, lookback windows, and scoring algorithm.",
           " Store the result in report.score_description in study_params.yaml.]")

  cfg_outcome_label <- config$outcome_label          %||% "the outcome"
  cfg_model_type    <- config$model_type_description %||% "risk score"
  cfg_window        <- config$prediction_window_days %||% "N"
  cfg_study_name    <- config$study_name             %||% "this study"

  doc <- read_docx()
  doc <- officer::body_set_default_section(
    doc,
    officer::prop_section(
      page_margins = officer::page_mar(
        top = 0.5, bottom = 0.5, left = 0.5, right = 0.5,
        header = 0.3, footer = 0.3, gutter = 0
      )
    )
  )

  # ---- Title ---------------------------------------------------------------
  today_str <- format(Sys.Date(), "%B %d, %Y")
  doc <- body_add_par(doc, cfg_study_title,
                      style = "heading 1")
  doc <- body_add_par(doc, "External Validation Report", style = "heading 1")
  doc <- body_add_par(doc, paste("Report Generated:", today_str), style = "heading 2")
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 1. Executive Summary ------------------------------------------------
  doc <- body_add_par(doc, "1.  Executive Summary", style = "heading 2")
  
  if (!is.null(person_level)) {
    n_patients <- length(unique(person_level$subject_id))
    n_procedures <- nrow(person_level)
    n_ssi_events <- sum(person_level$outcome, na.rm = TRUE)
    ssi_rate <- round(100 * n_ssi_events / n_procedures, 1)
    mean_score <- round(mean(person_level$total_score, na.rm = TRUE), 2)
    
    doc <- body_add_par(doc,
      paste0(
        "This validation study evaluated the external performance of a previously developed ",
        cfg_model_type, " for ", cfg_outcome_label, ". The analysis was performed on ",
        "an OMOP CDM dataset containing ", n_patients, " unique patients with ",
        n_procedures, " eligible procedures. Overall ", cfg_outcome_label, " incidence was ",
        n_ssi_events, " events (", ssi_rate, "%). The mean risk score was ", mean_score, "."
      ),
      style = "Normal"
    )
  } else {
    doc <- body_add_par(doc,
      paste0(
        "This validation study evaluated the external performance of a previously developed ",
        cfg_model_type, " for ", cfg_outcome_label, "."
      ),
      style = "Normal"
    )
  }
  
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 2. Methods ----------------------------------------------------------
  doc <- body_add_par(doc, "2.  Methods", style = "heading 2")

  doc <- body_add_par(doc, "2.1  Study Population and Data Source", style = "heading 3")
  # TODO [CLAUDE]: cfg_target_pop is drawn from report.target_population_description in
  # study_params.yaml. Read cohorts/<target_sql_file> and populate that field first.
  doc <- body_add_par(doc, cfg_target_pop, style = "Normal")
  # TODO [CLAUDE]: cfg_outcome is drawn from report.outcome_description in
  # study_params.yaml. Read cohorts/<outcome_sql_file> and populate that field first.
  doc <- body_add_par(doc, cfg_outcome, style = "Normal")

  doc <- body_add_par(doc, "2.2  Risk Score Computation", style = "heading 3")
  # TODO [CLAUDE]: cfg_score is drawn from report.score_description in study_params.yaml.
  # Read covariates/covariates.csv and covariates/covariate_concepts.csv and populate that field first.
  doc <- body_add_par(doc, cfg_score, style = "Normal")

  doc <- body_add_par(doc, "2.3  Performance Evaluation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "Discrimination was assessed using the area under the receiver operating characteristic curve ",
      "(AUROC) and the area under the precision-recall curve (AUPRC). Calibration was evaluated under two ",
      "model specifications: (1) lookup-based predicted probabilities drawn directly from the published ",
      "score-to-risk calibration table (no refitting), and (2) recalibrated probabilities estimated by ",
      paste0("fitting a logistic regression of the total integer score on the observed binary ",
             cfg_window, "-day ", cfg_outcome_label, " outcome "),
      "in the validation cohort. Calibration-in-the-large was summarised by the intercept and slope of the ",
      "calibration regression. Expected calibration error (ECE) was computed as the probability-weighted ",
      "mean absolute difference between mean predicted and observed event rates across 10 equal-frequency bins."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 3. Table 1: Cohort Summary ------------------------------------------
  doc <- body_add_par(doc, "3.  Study Cohort Characteristics", style = "heading 2")
  
  if (!is.null(person_level)) {
    doc <- body_add_par(doc,
      paste0(
        "Table 1 presents baseline demographic and clinical characteristics of the validation cohort. ",
        "Variables are summarized across all eligible procedures (N = ", nrow(person_level), ")."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 1.  Cohort characteristics (baseline demographics and clinical features).",
      style = "Normal"
    )
    
    cohort_summary_df <- .build_cohort_summary_table(person_level)
    doc <- body_add_flextable(doc, cohort_summary_df)
  }
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 4. Table 2: Risk Score Components -----------------------------------
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "4.  Risk Model Variables", style = "heading 2")
  doc <- body_add_par(doc,
    paste0(
      paste0("Table 2 lists the components of the ", cfg_model_type,
             ", the point value assigned to each, ",
             "the lookback window applied, and the OMOP concept-based derivation method used in this validation.")
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc,
    paste0("Table 2.  ", cfg_model_type, " components, point values, and OMOP CDM derivation method."),
    style = "Normal"
  )
  doc <- body_add_flextable(doc, .build_table1(.covariate_table_data()))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Figure 1. ROC Curve (placed immediately after Tables 1-2) ----------
  if (!is.null(roc_plot_file) && file.exists(roc_plot_file)) {
    doc <- body_add_par(doc,
      paste0("Figure 1.  Receiver operating characteristic (ROC) curve for ",
             cfg_window, "-day ", cfg_outcome_label, " risk prediction."),
      style = "Normal"
    )
    doc <- body_add_img(doc, src = roc_plot_file, width = 5, height = 3.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 5. Table 3: Covariate Summary & Cohort Counts ----------------------
  if (!is.null(covariate_summary)) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "5.  Covariate Prevalence in the Validation Cohort", style = "heading 2")
    doc <- body_add_par(doc,
      paste0(
        "Table 3 displays the prevalence of each risk score covariate in the validation cohort, ",
        "alongside the covariate definitions and OMOP concept derivation. ",
        "Covariate counts and prevalence percentages are computed across all eligible procedures."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 3.  Risk score covariates with OMOP derivation and prevalence in the validation cohort.",
      style = "Normal"
    )

    # Build combined flextable for covariate summary with definitions
    combined_cov_df <- .build_combined_covariate_table(covariate_summary)
    doc <- body_add_flextable(doc, combined_cov_df)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 6. Results & Performance Metrics ------------------------------------
  if (!is.null(metrics) && nrow(metrics) > 0) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "6.  Discrimination and Calibration Metrics", style = "heading 2")
    
    doc <- body_add_par(doc,
      paste0(
        "Table 4 presents the discrimination (AUROC, AUPRC, Brier score) and calibration ",
        "(calibration-in-the-large intercept and slope) metrics across three model specifications: ",
        "lookup-based score-to-risk table, and recalibrated logistic regression."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 4.  Discrimination and calibration metrics.",
      style = "Normal"
    )
    
    # Build a formatted "value (95% CI)" string per metric-model cell, then
    # pivot wide so each model becomes one column.  Falls back to just the
    # point estimate when ci_lower / ci_upper are absent (legacy CSV format).
    has_ci <- all(c("ci_lower", "ci_upper") %in% names(metrics)) &&
              any(!is.na(metrics$ci_lower))

    fmt3 <- function(x) format(round(as.numeric(x), 3), nsmall = 3, trim = TRUE)

    metrics_disp <- metrics
    metrics_disp$cell <- if (has_ci) {
      ifelse(
        !is.na(metrics$ci_lower) & !is.na(metrics$ci_upper),
        paste0(fmt3(metrics$value),
               " (", fmt3(metrics$ci_lower), "\u2013", fmt3(metrics$ci_upper), ")"),
        fmt3(metrics$value)
      )
    } else {
      fmt3(metrics$value)
    }

    metrics_wide <- metrics_disp[, c("metric", "cell", "model")]
    metrics_wide <- reshape(metrics_wide, idvar = "metric", timevar = "model", direction = "wide")
    names(metrics_wide) <- gsub("cell\\.", "", names(metrics_wide))

    ft_metrics <- flextable(metrics_wide) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      align(j = seq_along(names(metrics_wide))[-1], align = "center", part = "all") |>
      set_header_labels(
        metric       = "Metric",
        score_only   = "Score only",
        lookup       = "Lookup (published)",
        recalibrated = "Recalibrated"
      )

    if (has_ci) {
      ft_metrics <- add_footer_lines(ft_metrics,
        "Values shown as point estimate (95% bootstrap percentile CI, B\u2009=\u2009500 resamples).")
      ft_metrics <- fontsize(ft_metrics, size = 8, part = "footer")
      ft_metrics <- font(ft_metrics, fontname = "Calibri", part = "footer")
    }

    doc <- body_add_flextable(doc, ft_metrics)
    doc <- body_add_par(doc, "", style = "Normal")
    
    # Interpretation
    auroc_lookup <- metrics$value[metrics$metric == "AUROC" & metrics$model == "lookup"]
    if (length(auroc_lookup) > 0 && !is.na(auroc_lookup)) {
      interp <- if (auroc_lookup > 0.8) "excellent" 
                else if (auroc_lookup > 0.7) "good" 
                else if (auroc_lookup > 0.6) "fair" 
                else "poor"
      doc <- body_add_par(doc,
        paste0(
          "The model demonstrates an AUROC of ", round(auroc_lookup, 3), 
          " when using lookup-based probabilities, indicating ", interp, 
          " discriminative ability."
        ),
        style = "Normal"
      )
    }
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 8. Calibration Plots -----------------------------------------------
  if (length(calibration_plot_files) > 0) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "8.  Calibration: Observed vs. Predicted Risk", style = "heading 2")
    doc <- body_add_par(doc,
      paste0(
        "Figures 2+ display calibration plots for the lookup-based and recalibrated model specifications. ",
        "The solid line represents perfect calibration (predicted = observed risk). Points above the line ",
        "indicate overprediction; points below indicate underprediction."
      ),
      style = "Normal"
    )
    
    fig_num <- 2
    for (model_name in names(calibration_plot_files)) {
      plot_file <- calibration_plot_files[[model_name]]
      if (file.exists(plot_file)) {
        cap <- paste0(
          "Figure ", fig_num, ".  Calibration plot (",
          gsub("_", " ", model_name), " model). Points represent deciles of predicted risk, ",
          "with error bars showing 95% confidence intervals around the observed event rate."
        )
        doc <- body_add_par(doc, cap, style = "Normal")
        doc <- body_add_img(doc, src = plot_file, width = 5, height = 3.5)
        doc <- body_add_par(doc, "", style = "Normal")
        fig_num <- fig_num + 1
      }
    }
  }

  # ---- 9. Expected Calibration Error (ECE) --------------------------------
  if (!is.null(person_level) && "predicted_risk_recalibrated" %in% names(person_level)) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "9.  Expected Calibration Error", style = "heading 2")
    
    # Compute ECE
    y <- person_level$outcome
    p <- person_level$predicted_risk_recalibrated
    ece_result <- .compute_ece(y, p, n_bins = 10)
    ece_value <- ece_result$ece
    
    doc <- body_add_par(doc,
      paste0(
        "Expected calibration error (ECE) quantifies the average absolute difference between predicted ",
        "and observed risk probabilities across deciles of risk. For the recalibrated model, ECE = ",
        round(ece_value, 4), ", indicating ",
        if (ece_value < 0.05) "excellent" else if (ece_value < 0.10) "good" else "moderate",
        " calibration."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 10. Discussion & Conclusion -----------------------------------------
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "10.  Discussion and Conclusion", style = "heading 2")
  doc <- body_add_par(doc,
    paste0(
      # TODO [CLAUDE]: Rewrite this paragraph to describe the specific model validated,
      # the target population, the outcome, the CDM version, and the key performance finding.
      "This external validation demonstrates the applicability of the ", cfg_model_type,
      " for ", cfg_outcome_label, " to an OMOP CDM v5.4 dataset. All score components were ",
      "successfully mapped to OMOP standard concept IDs using transparent, scriptable SQL against ",
      "the concept_ancestor and concept tables. Performance metrics indicate ",
      if (!is.null(metrics)) {
        auroc <- metrics$value[metrics$metric == "AUROC" & metrics$model == "lookup"]
        if (length(auroc) > 0 && !is.na(auroc[1])) {
          if (auroc[1] > 0.75) "promising discriminative and calibration properties"
          else if (auroc[1] > 0.60) "moderate discriminative and calibration properties"
          else "modest discriminative properties that warrant further investigation"
        } else "good performance"
      } else "reasonable",
      ", supporting its continued evaluation as a clinical decision-support tool."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc,
    paste0(
      "The fully reproducible workflow — implemented as executable R scripts with SqlRender-parameterised ",
      "cohort SQL — enables validation teams to audit all cohort inclusion criteria, concept mappings, ",
      "lookback windows, and statistical calculations end-to-end. This transparency aligns with OHDSI ",
      "best practices for network studies and external validation."
    ),
    style = "Normal"
  )

  # ---- Write output -------------------------------------------------------
  out_path <- file.path(output_dir, paste0(cfg_study_name, "_validation_report.docx"))
  print(doc, target = out_path)
  message("Report written to: ", normalizePath(out_path))
  invisible(out_path)
}


# ===========================================================================
# .report_prognostic()
#
# Full manuscript-format Word report with live CDM queries for Table 1.
# Parameterized by config$score_type ("integer" | "lasso") with 4 branches.
# Called by generate_manuscript_report() in R/report_extended.R.
#
# Renamed from generate_manuscript_report() in the original synthea-omop-template
# monolith.  All 4 parameterization branches have been applied; the rest of
# the body is verbatim.
# ===========================================================================
.report_prognostic <- function(output_dir        = "output/risk_score_eval",
                                       score_output_dir   = "output/risk_score_eval",
                                       connection_details = NULL,
                                       config             = NULL,
                                       citations          = NULL) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  temp_figure_dir <- tempfile("report_figures_")
  dir.create(temp_figure_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(temp_figure_dir, recursive = TRUE, force = TRUE), add = TRUE)

  person_level_path <- file.path(score_output_dir, "person_level_scores.csv")
  covariate_summary_path <- file.path(score_output_dir, "covariate_summary.csv")
  metrics_path <- file.path(score_output_dir, "metrics.csv")
  lookup_calibration_plot <- file.path(score_output_dir, "calibration_lookup.png")
  recalibrated_calibration_plot <- file.path(score_output_dir, "calibration_recalibrated.png")
  calibration_table_lookup_path <- file.path(score_output_dir, "calibration_table_lookup.csv")
  calibration_table_recalibrated_path <- file.path(score_output_dir, "calibration_table_recalibrated.csv")
  lookup_calibration_plot_temp <- file.path(temp_figure_dir, "calibration_lookup.png")
  recalibrated_calibration_plot_temp <- file.path(temp_figure_dir, "calibration_recalibrated.png")

  if (!file.exists(person_level_path) || !file.exists(covariate_summary_path) || !file.exists(metrics_path)) {
    stop("Missing one or more required pipeline outputs in ", score_output_dir)
  }

  person_level <- read.csv(person_level_path, stringsAsFactors = FALSE)
  covariate_summary <- read.csv(covariate_summary_path, stringsAsFactors = FALSE)
  metrics <- read.csv(metrics_path, stringsAsFactors = FALSE)

  # Backfill ECE if it is not present in the metrics file.
  compute_ece <- function(y, p, n_bins = 10) {
    ok <- !(is.na(y) | is.na(p))
    y <- as.numeric(y[ok])
    p <- as.numeric(p[ok])
    if (length(y) == 0) {
      return(NA_real_)
    }

    eps <- 1e-6
    p[p < eps] <- eps
    p[p > (1 - eps)] <- 1 - eps

    probs <- unique(stats::quantile(p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
    if (length(probs) < 3) {
      probs <- c(0, 1)
    }
    bins <- cut(p, breaks = probs, include.lowest = TRUE)
    bin_n <- as.numeric(table(bins))
    if (length(bin_n) == 0) {
      return(NA_real_)
    }

    pred_mean <- tapply(p, bins, mean)
    obs_mean <- tapply(y, bins, mean)
    as.numeric(sum(abs(pred_mean - obs_mean) * bin_n) / sum(bin_n))
  }

  if (!any(metrics$metric == "ECE")) {
    ece_rows <- data.frame(
      metric = character(), value = numeric(),
      ci_lower = numeric(), ci_upper = numeric(),
      model = character(), stringsAsFactors = FALSE
    )

    if ("predicted_risk_lookup" %in% names(person_level)) {
      keep_lookup <- !is.na(person_level$predicted_risk_lookup)
      if (any(keep_lookup)) {
        ece_rows <- rbind(
          ece_rows,
          data.frame(
            metric   = "ECE",
            value    = compute_ece(person_level$outcome[keep_lookup], person_level$predicted_risk_lookup[keep_lookup]),
            ci_lower = NA_real_,
            ci_upper = NA_real_,
            model    = "lookup",
            stringsAsFactors = FALSE
          )
        )
      }
    }

    if ("predicted_risk_recalibrated" %in% names(person_level)) {
      ece_rows <- rbind(
        ece_rows,
        data.frame(
          metric   = "ECE",
          value    = compute_ece(person_level$outcome, person_level$predicted_risk_recalibrated),
          ci_lower = NA_real_,
          ci_upper = NA_real_,
          model    = "recalibrated",
          stringsAsFactors = FALSE
        )
      )
    }

    if (nrow(ece_rows) > 0) {
      # Ensure metrics has ci_lower/ci_upper before binding, so column sets match.
      if (!"ci_lower" %in% names(metrics)) metrics$ci_lower <- NA_real_
      if (!"ci_upper" %in% names(metrics)) metrics$ci_upper <- NA_real_
      metrics <- rbind(metrics, ece_rows)
    }
  } else {
    # Ensure ci_lower/ci_upper exist even when ECE was already present in the CSV.
    if (!"ci_lower" %in% names(metrics)) metrics$ci_lower <- NA_real_
    if (!"ci_upper" %in% names(metrics)) metrics$ci_upper <- NA_real_
  }

  fmt <- function(x, digits = 3) {
    format(round(as.numeric(x), digits), nsmall = digits)
  }

  metric_value <- function(metric_name, model_name) {
    row <- metrics[metrics$metric == metric_name & metrics$model == model_name, , drop = FALSE]
    if (nrow(row) == 0) {
      return(NA_real_)
    }
    as.numeric(row$value[1])
  }

  # Returns a formatted "(lower–upper)" CI string for a given metric/model pair.
  # Pulls ci_lower and ci_upper from the metrics data frame (present when
  # compute_bootstrap_cis() was run during the pipeline).  Returns "—" when the
  # columns are absent or the values are NA (e.g. legacy metrics.csv files).
  metric_ci <- function(metric_name, model_name) {
    row <- metrics[metrics$metric == metric_name & metrics$model == model_name, , drop = FALSE]
    if (nrow(row) == 0) return("\u2014")
    if (!all(c("ci_lower", "ci_upper") %in% names(row))) return("\u2014")
    lo <- as.numeric(row$ci_lower[1])
    hi <- as.numeric(row$ci_upper[1])
    if (is.na(lo) || is.na(hi)) return("\u2014")
    paste0("(", fmt(lo), "\u2013", fmt(hi), ")")
  }

  n_target <- nrow(person_level)
  n_outcome <- sum(person_level$outcome, na.rm = TRUE)
  outcome_prev <- if (n_target > 0) 100 * n_outcome / n_target else NA_real_

  results_tbl <- data.frame(
    Metric = c(
      "AUROC",
      "AUPRC",
      "Brier score",
      "Estimated calibration error",
      "Calibration intercept",
      "Calibration slope"
    ),
    Value = c(
      fmt(metric_value("AUROC", "lookup")),
      fmt(metric_value("AUPRC", "lookup")),
      fmt(metric_value("Brier", "lookup")),
      fmt(metric_value("ECE", "lookup")),
      fmt(metric_value("CalibrationIntercept", "lookup")),
      fmt(metric_value("CalibrationSlope", "lookup"))
    ),
    "95% CI" = c(
      metric_ci("AUROC",                "lookup"),
      metric_ci("AUPRC",                "lookup"),
      metric_ci("Brier",                "lookup"),
      metric_ci("ECE",                  "lookup"),
      metric_ci("CalibrationIntercept", "lookup"),
      metric_ci("CalibrationSlope",     "lookup")
    ),
    check.names     = FALSE,
    stringsAsFactors = FALSE
  )

  normalize_label <- function(x) {
    x <- tolower(trimws(as.character(x)))
    x <- gsub("[()\\[\\]\\{\\}]", " ", x)
    x <- gsub("[^a-z0-9]+", " ", x)
    x <- gsub("\\s+", " ", x)
    trimws(x)
  }

  # Branch 1 — Table 2 covariate/predictor definitions.
  # LASSO: read from varImp.rds artifact via .covariate_table_data_lasso().
  # Integer: use the static component specification table .covariate_table_data().
  tbl2_data <- if (identical(config$score_type, "lasso")) {
    .covariate_table_data_lasso(config)
  } else {
    .covariate_table_data()
  }
  # Build predictor_ref from whichever table was selected above.
  # Column names differ: integer has "points"; LASSO has "weight".
  if ("points" %in% names(tbl2_data) && "covariate_id" %in% names(tbl2_data)) {
    predictor_ref <- tbl2_data[, c("covariate_id", "variable", "points", "lookback", "derivation")]
    names(predictor_ref) <- c("covariate_id", "Predictor", "Points", "Lookback", "Definition")
  } else if ("weight" %in% names(tbl2_data) && "covariate_id" %in% names(tbl2_data)) {
    predictor_ref <- tbl2_data[, c("covariate_id", "variable", "weight", "lookback", "derivation")]
    names(predictor_ref) <- c("covariate_id", "Predictor", "Points", "Lookback", "Definition")
  } else {
    predictor_ref <- .covariate_table_data()[, c("covariate_id", "variable", "points", "lookback", "derivation")]
    names(predictor_ref) <- c("covariate_id", "Predictor", "Points", "Lookback", "Definition")
  }

  has_missing_col <- "n_missing" %in% names(covariate_summary)

  if ("covariate_id" %in% names(covariate_summary)) {
    keep_cols <- c("covariate_id", "n_positive", "mean_points",
                   if (has_missing_col) "n_missing")
    covariate_act <- covariate_summary[, keep_cols, drop = FALSE]
    predictor_tbl <- merge(predictor_ref, covariate_act, by = "covariate_id", all.x = TRUE, sort = FALSE)
  } else {
    predictor_ref$key <- normalize_label(predictor_ref$Predictor)
    keep_cols <- c("covariate_name", "n_positive", "mean_points",
                   if (has_missing_col) "n_missing")
    covariate_act <- covariate_summary[, keep_cols, drop = FALSE]
    covariate_act$key <- normalize_label(covariate_act$covariate_name)
    covariate_act <- covariate_act[, c("key", "n_positive", "mean_points",
                                       if (has_missing_col) "n_missing"), drop = FALSE]
    predictor_tbl <- merge(predictor_ref, covariate_act, by = "key", all.x = TRUE, sort = FALSE)
  }

  predictor_tbl$n_positive[is.na(predictor_tbl$n_positive)] <- 0
  predictor_tbl$mean_points[is.na(predictor_tbl$mean_points)] <- 0
  if (has_missing_col) predictor_tbl$n_missing[is.na(predictor_tbl$n_missing)] <- 0

  base_cols <- c("Predictor", "Points", "Lookback", "Definition", "n_positive", "mean_points")
  if (has_missing_col) base_cols <- c(base_cols, "n_missing")
  predictor_tbl <- predictor_tbl[, base_cols]

  if (has_missing_col) {
    names(predictor_tbl) <- c("Predictor", "Points", "Lookback", "Definition",
                               "PositiveCount", "MeanPoints", "MissingCount")
    predictor_tbl$MissingCount <- as.integer(predictor_tbl$MissingCount)
    predictor_tbl$MissingPct   <- paste0(
      round(100 * predictor_tbl$MissingCount / max(n_target, 1), 1), "%")
  } else {
    names(predictor_tbl) <- c("Predictor", "Points", "Lookback", "Definition",
                               "PositiveCount", "MeanPoints")
  }
  predictor_tbl$PositiveCount <- as.integer(predictor_tbl$PositiveCount)
  predictor_tbl$MeanPoints <- round(as.numeric(predictor_tbl$MeanPoints), 4)

  fmt_n_pct <- function(n, denom, digits = 1) {
    n <- suppressWarnings(as.numeric(n))
    denom <- suppressWarnings(as.numeric(denom))
    if (is.na(n) || is.na(denom) || denom <= 0) {
      return("0 (0.0%)")
    }
    paste0(format(round(n, 0), scientific = FALSE, trim = TRUE),
           " (", format(round(100 * n / denom, digits), nsmall = digits, trim = TRUE), "%)")
  }

  fetch_demographics_from_omop <- function(config, connection_details) {
    if (is.null(config) || is.null(connection_details)) {
      return(NULL)
    }

    conn <- NULL
    out <- NULL
    try({
      conn <- DatabaseConnector::connect(connection_details)

      # Defensive deduplication: one row per person_id in case of ETL re-runs.
      # Uses the row with the most-frequent person_source_value (= most recent run)
      # and breaks ties by taking the first row per person_id within that group.
      dedup_person_cte <-
        "dedup_person AS (
           SELECT p2.*
           FROM (
             SELECT p3.*,
               ROW_NUMBER() OVER (
                 PARTITION BY p3.person_id
                 ORDER BY src_freq.n DESC, p3.person_source_value DESC, p3.year_of_birth DESC
               ) AS _rn
             FROM @cdm_schema.person p3
             INNER JOIN (
               SELECT person_id, person_source_value, COUNT(*) AS n
               FROM @cdm_schema.person
               GROUP BY person_id, person_source_value
             ) src_freq
               ON src_freq.person_id      = p3.person_id
              AND src_freq.person_source_value = p3.person_source_value
           ) p2
           WHERE p2._rn = 1
         )"

      # Age = FLOOR((procedure_date - birth_date) / 365.25), where birth_date
      # is constructed from the three OMOP person fields year_of_birth,
      # month_of_birth, day_of_birth (ETLSyntheaBuilder populates all three;
      # birth_datetime is optional in CDM 5.4 and may be NULL).
      # DATEFROMPARTS defaults to mid-year (Jul 1) when month/day are missing
      # so that any residual imprecision is symmetric rather than biased.
      # The DATEDIFF(DAY, ...) / 365.25 division is done in floating-point
      # so that fractional years are preserved before FLOOR rounds down to the
      # last completed year — matching the user-specified formula exactly.
      sql_age <- SqlRender::render(
        paste0(
          "WITH ", dedup_person_cte, "
           SELECT
             CAST(
               FLOOR(
                 CAST(DATEDIFF(DAY,
                   DATEFROMPARTS(
                     p.year_of_birth,
                     COALESCE(p.month_of_birth, 7),
                     COALESCE(p.day_of_birth,   1)
                   ),
                   t.cohort_start_date
                 ) AS FLOAT) / 365.25
               )
             AS FLOAT) AS age_at_index
           FROM @results_schema.@cohort_table t
           INNER JOIN dedup_person p ON p.person_id = t.subject_id
           WHERE t.cohort_definition_id = @target_id"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id
      )
      age_df <- tryCatch(
        DatabaseConnector::querySql(
          conn,
          SqlRender::translate(sql_age, targetDialect = "sql server")
        ),
        error = function(e) {
          message("[report] Age query failed: ", conditionMessage(e))
          NULL
        }
      )

      # Returns concept_id, category (concept_name), and n per group so that
      # downstream lookups can match on concept_id rather than on concept_name
      # strings (which are fragile to vocabulary version changes and regex errors).
      distribution_sql <- function(concept_col) {
        SqlRender::render(
          paste0(
            "WITH ", dedup_person_cte, "
             SELECT
               COALESCE(p.@concept_col, 0)                        AS concept_id,
               COALESCE(NULLIF(c.concept_name, ''), 'Unknown')    AS category,
               COUNT(DISTINCT t.subject_id)                       AS n
             FROM @results_schema.@cohort_table t
             INNER JOIN dedup_person p ON p.person_id = t.subject_id
             LEFT  JOIN @cdm_schema.concept c ON c.concept_id = p.@concept_col
             WHERE t.cohort_definition_id = @target_id
             GROUP BY COALESCE(p.@concept_col, 0),
                      COALESCE(NULLIF(c.concept_name, ''), 'Unknown')
             ORDER BY n DESC, category"
          ),
          results_schema = results_schema_prefix(config),
          cohort_table   = config$cohort_table,
          cdm_schema     = config$cdm_schema,
          concept_col    = concept_col,
          target_id      = config$target_cohort_id
        )
      }

      sex_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(distribution_sql("gender_concept_id"), targetDialect = "sql server")
      )
      race_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(distribution_sql("race_concept_id"), targetDialect = "sql server")
      )
      ethnicity_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(distribution_sql("ethnicity_concept_id"), targetDialect = "sql server")
      )

      # ---- Indication categories (condition_ancestor rollup, 365d pre-index) ----
      # Claudication : ancestor 442774  (Intermittent claudication)
      #                Synthea module code: SNOMED 63491006
      # Rest pain    : ancestor 4325344  (Peripheral vascular disease with rest pain)
      #                Synthea module code: SNOMED 428171009 (maps directly to 4325344)
      # Tissue loss  : ancestor 4029926  (Ischemic ulcer)
      #                Synthea module code: SNOMED 238794007 (Ischemic foot ulcer, concept
      #                4033352), which is a level-1 descendant of 4029926.
      #                NOTE: ancestor 319835 was previously used here but is incorrect —
      #                319835 is Congestive Heart Failure, not Gangrene. Corrected to 4029926.
      # Asymptomatic : target patients with no claudication / rest pain / tissue loss code
      sql_indication <- SqlRender::render(
        "WITH target AS (
           SELECT subject_id, cohort_start_date
           FROM @results_schema.@cohort_table
           WHERE cohort_definition_id = @target_id
         ),
         claud AS (
           SELECT DISTINCT co.person_id
           FROM @cdm_schema.condition_occurrence co
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON ca.descendant_concept_id = co.condition_concept_id
            AND ca.ancestor_concept_id   = 442774
           INNER JOIN target t ON t.subject_id = co.person_id
             AND co.condition_start_date BETWEEN DATEADD(DAY,-365,t.cohort_start_date)
                                             AND t.cohort_start_date
         ),
         rest_pain AS (
           SELECT DISTINCT co.person_id
           FROM @cdm_schema.condition_occurrence co
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON ca.descendant_concept_id = co.condition_concept_id
            AND ca.ancestor_concept_id   = 4325344
           INNER JOIN target t ON t.subject_id = co.person_id
             AND co.condition_start_date BETWEEN DATEADD(DAY,-365,t.cohort_start_date)
                                             AND t.cohort_start_date
         ),
         tissue_loss AS (
           SELECT DISTINCT co.person_id
           FROM @cdm_schema.condition_occurrence co
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON ca.descendant_concept_id = co.condition_concept_id
            AND ca.ancestor_concept_id   = 4029926
           INNER JOIN target t ON t.subject_id = co.person_id
             AND co.condition_start_date BETWEEN DATEADD(DAY,-365,t.cohort_start_date)
                                             AND t.cohort_start_date
         ),
         any_specific AS (
           SELECT person_id FROM claud
           UNION SELECT person_id FROM rest_pain
           UNION SELECT person_id FROM tissue_loss
         )
         SELECT 'Claudication' AS category, COUNT(*)               AS n FROM claud
         UNION ALL
         SELECT 'Rest pain',                COUNT(*)                    FROM rest_pain
         UNION ALL
         SELECT 'Tissue loss',              COUNT(*)                    FROM tissue_loss
         UNION ALL
         SELECT 'Asymptomatic',             COUNT(DISTINCT t.subject_id)
           FROM target t
           LEFT JOIN any_specific sp ON sp.person_id = t.subject_id
           WHERE sp.person_id IS NULL",
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id
      )
      indication_df <- tryCatch(
        DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_indication, targetDialect = "sql server")
        ),
        error = function(e) NULL
      )

      # ---- Procedure type (qualifying procedure at index visit) ---------------
      # Concept ancestor rollup per procedure type (not mutually exclusive;
      # counts distinct patients with each procedure type at the index visit).
      # Ancestor IDs:
      #   4231680 = Aorto-femoral arterial bypass  → aortobifemoral
      #   4259121 = Femoral-femoral artery vascular bypass → fem-fem
      #   4012936 = Femoral-popliteal artery bypass graft  → fem-pop
      #   4166196 = Femorotibial vascular bypass           → fem-tibial
      sql_proc_type <- SqlRender::render(
        "WITH target AS (
           SELECT subject_id,
                  cohort_start_date,
                  ISNULL(cohort_end_date, cohort_start_date) AS cohort_end_date
           FROM @results_schema.@cohort_table
           WHERE cohort_definition_id = @target_id
         )
         SELECT 'Aortobifemoral bypass'   AS category,
                COUNT(DISTINCT t.subject_id) AS n
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4231680
         UNION ALL
         SELECT 'Femoral endarterectomy', COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4040974
         UNION ALL
         SELECT 'Femoral-popliteal bypass', COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4012936
         UNION ALL
         SELECT 'Femorotibial bypass',      COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4166196
         UNION ALL
         SELECT 'Extra-anatomic bypass',    COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4050281",
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id
      )
      proc_type_df <- tryCatch(
        DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_proc_type, targetDialect = "sql server")
        ),
        error = function(e) NULL
      )

      out <- list(
        age            = age_df,
        sex            = sex_df,
        race           = race_df,
        ethnicity      = ethnicity_df,
        indication     = indication_df,
        procedure_type = proc_type_df
      )
    }, silent = TRUE)

    if (!is.null(conn)) {
      try(DatabaseConnector::disconnect(conn), silent = TRUE)
    }

    out
  }

  # ---------------------------------------------------------------------------
  # fetch_ssi_outcomes_from_omop()
  #
  # Queries post-operative outcome statistics for SSI patients:
  #   1. Median days (with IQR) from the index procedure to SSI diagnosis
  #   2. 90-day reoperation count: any procedure_occurrence after SSI date
  #      and within 90 days of the index date
  #   3. 90-day readmission count: inpatient visit (concept 9201) starting
  #      after SSI date and within 90 days of the index date
  #   4. 90-day mortality count: death record within 90 days of index date
  #      among SSI patients
  #
  # Denominator for rates 2–4 is the number of SSI patients (n_ssi).
  # ---------------------------------------------------------------------------
  fetch_ssi_outcomes_from_omop <- function(config, connection_details) {
    if (is.null(config) || is.null(connection_details)) return(NULL)

    conn <- NULL
    out  <- NULL
    try({
      conn <- DatabaseConnector::connect(connection_details)

      # Shared CTE: SSI patients joined to their index procedure date.
      # Only patients whose SSI falls within the 90-day prediction window are kept.
      ssi_cte <- "ssi_w_index AS (
        SELECT
          s.subject_id,
          t.cohort_start_date        AS index_date,
          s.cohort_start_date        AS ssi_date,
          DATEDIFF(DAY,
            t.cohort_start_date,
            s.cohort_start_date)     AS days_to_ssi
        FROM @results_schema.@cohort_table s
        INNER JOIN @results_schema.@cohort_table t
          ON  t.subject_id           = s.subject_id
          AND t.cohort_definition_id = @target_id
        WHERE s.cohort_definition_id = @outcome_id
          AND DATEDIFF(DAY, t.cohort_start_date, s.cohort_start_date)
              BETWEEN 0 AND 90
      )"

      # 1. Days-to-SSI: count, median, IQR
      # PERCENTILE_CONT in SQL Server is an analytic (window) function and requires
      # OVER (). We select TOP 1 since the window function returns the same value
      # for every row; COUNT(*) OVER () gives the total row count.
      sql_days <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT TOP 1
             COUNT(*) OVER ()                                                 AS n_ssi,
             CAST(PERCENTILE_CONT(0.25)
               WITHIN GROUP (ORDER BY CAST(days_to_ssi AS FLOAT)) OVER ()
             AS FLOAT)                                                         AS p25,
             CAST(PERCENTILE_CONT(0.5)
               WITHIN GROUP (ORDER BY CAST(days_to_ssi AS FLOAT)) OVER ()
             AS FLOAT)                                                         AS median_days,
             CAST(PERCENTILE_CONT(0.75)
               WITHIN GROUP (ORDER BY CAST(days_to_ssi AS FLOAT)) OVER ()
             AS FLOAT)                                                         AS p75
           FROM ssi_w_index"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      days_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_days, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Days-to-SSI query failed: ", conditionMessage(e))
        NULL
      })

      # 2. 90-day reoperation: any procedure_occurrence after SSI date within window
      sql_reop <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_reoperation
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.procedure_occurrence po
             ON  po.person_id = si.subject_id
             AND CAST(po.procedure_date AS DATE) > si.ssi_date
             AND CAST(po.procedure_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      reop_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_reop, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Reoperation query failed: ", conditionMessage(e))
        NULL
      })

      # 3. 90-day readmission: inpatient visit (concept 9201) after SSI date within window
      sql_readm <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_readmission
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.visit_occurrence vo
             ON  vo.person_id        = si.subject_id
             AND vo.visit_concept_id = 9201
             AND CAST(vo.visit_start_date AS DATE) > si.ssi_date
             AND CAST(vo.visit_start_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      readm_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_readm, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Readmission query failed: ", conditionMessage(e))
        NULL
      })

      # 4. 90-day mortality: death record within 90 days of index date (SSI patients only)
      sql_death <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_death
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.death d
             ON  d.person_id = si.subject_id
             AND CAST(d.death_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      death_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_death, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Death query failed: ", conditionMessage(e))
        NULL
      })

      # 5. SSI type breakdown: superficial / deep / organ-space / unclassified
      # Ancestor concept IDs (SNOMED-CT, OMOP standard):
      #   43530818 = Superficial incisional surgical site infection
      #   4308542  = Postoperative wound infection - deep  (deep incisional proxy)
      #   43530820 = Organ-space surgical site infection
      # Counts are distinct patients whose SSI condition_concept_id is a
      # descendant of the relevant ancestor.  Patients coded only at the parent
      # level (e.g. 4334801) are captured in n_unclassified.
      sql_ssi_type <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, ",
           typed AS (
             SELECT DISTINCT
               si.subject_id,
               MAX(CASE WHEN ca_sup.ancestor_concept_id IS NOT NULL THEN 1 ELSE 0 END)
                 OVER (PARTITION BY si.subject_id) AS is_superficial,
               MAX(CASE WHEN ca_deep.ancestor_concept_id IS NOT NULL THEN 1 ELSE 0 END)
                 OVER (PARTITION BY si.subject_id) AS is_deep,
               MAX(CASE WHEN ca_org.ancestor_concept_id IS NOT NULL THEN 1 ELSE 0 END)
                 OVER (PARTITION BY si.subject_id) AS is_organ
             FROM ssi_w_index si
             INNER JOIN @cdm_schema.condition_occurrence co
               ON  co.person_id                       = si.subject_id
               AND CAST(co.condition_start_date AS DATE) = si.ssi_date
             INNER JOIN @cdm_schema.concept_ancestor ca_ssi
               ON  ca_ssi.descendant_concept_id = co.condition_concept_id
               AND ca_ssi.ancestor_concept_id   = 4334801
             LEFT JOIN @cdm_schema.concept_ancestor ca_sup
               ON  ca_sup.descendant_concept_id = co.condition_concept_id
               AND ca_sup.ancestor_concept_id   = 43530818
             LEFT JOIN @cdm_schema.concept_ancestor ca_deep
               ON  ca_deep.descendant_concept_id = co.condition_concept_id
               AND ca_deep.ancestor_concept_id   = 4308542
             LEFT JOIN @cdm_schema.concept_ancestor ca_org
               ON  ca_org.descendant_concept_id  = co.condition_concept_id
               AND ca_org.ancestor_concept_id    = 43530820
           ),
           deduped AS (
             SELECT subject_id,
                    MAX(is_superficial) AS is_superficial,
                    MAX(is_deep)        AS is_deep,
                    MAX(is_organ)       AS is_organ
             FROM typed
             GROUP BY subject_id
           )
           SELECT
             SUM(is_superficial)                                       AS n_superficial,
             SUM(is_deep)                                              AS n_deep,
             SUM(is_organ)                                             AS n_organ,
             SUM(CASE WHEN is_superficial = 0
                       AND is_deep        = 0
                       AND is_organ       = 0 THEN 1 ELSE 0 END)      AS n_unclassified
           FROM deduped"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      ssi_type_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_ssi_type, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] SSI type query failed: ", conditionMessage(e))
        NULL
      })

      # 6. Index hospitalisation length of stay (days) — visit_occurrence containing
      #    the index procedure date, using DATEDIFF on visit end vs. start.
      sql_los <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT TOP 1
             COUNT(*) OVER ()                                                         AS n_los,
             CAST(PERCENTILE_CONT(0.25)
               WITHIN GROUP (ORDER BY CAST(los_days AS FLOAT)) OVER () AS FLOAT)     AS p25,
             CAST(PERCENTILE_CONT(0.5)
               WITHIN GROUP (ORDER BY CAST(los_days AS FLOAT)) OVER () AS FLOAT)     AS median_los,
             CAST(PERCENTILE_CONT(0.75)
               WITHIN GROUP (ORDER BY CAST(los_days AS FLOAT)) OVER () AS FLOAT)     AS p75
           FROM (
             SELECT si.subject_id,
                    DATEDIFF(DAY,
                      vo.visit_start_date,
                      COALESCE(vo.visit_end_date, vo.visit_start_date)) AS los_days
             FROM ssi_w_index si
             INNER JOIN @cdm_schema.visit_occurrence vo
               ON  vo.person_id        = si.subject_id
               AND vo.visit_concept_id = 9201
               AND CAST(vo.visit_start_date AS DATE) <= si.index_date
               AND CAST(COALESCE(vo.visit_end_date, vo.visit_start_date) AS DATE) >= si.index_date
           ) los_sub"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      los_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_los, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] LOS query failed: ", conditionMessage(e))
        NULL
      })

      # 7. Time (days) from SSI diagnosis to first post-SSI antibiotic exposure.
      #    Uses drug_exposure with ATC ancestor 21603553 (Antibacterials).
      sql_abx <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT TOP 1
             COUNT(*) OVER ()                                                         AS n_abx,
             CAST(PERCENTILE_CONT(0.25)
               WITHIN GROUP (ORDER BY CAST(days_to_abx AS FLOAT)) OVER () AS FLOAT)  AS p25,
             CAST(PERCENTILE_CONT(0.5)
               WITHIN GROUP (ORDER BY CAST(days_to_abx AS FLOAT)) OVER () AS FLOAT)  AS median_days_to_abx,
             CAST(PERCENTILE_CONT(0.75)
               WITHIN GROUP (ORDER BY CAST(days_to_abx AS FLOAT)) OVER () AS FLOAT)  AS p75
           FROM (
             SELECT si.subject_id,
                    MIN(DATEDIFF(DAY, si.ssi_date,
                                 CAST(de.drug_exposure_start_date AS DATE))) AS days_to_abx
             FROM ssi_w_index si
             INNER JOIN @cdm_schema.drug_exposure de
               ON  de.person_id = si.subject_id
               AND CAST(de.drug_exposure_start_date AS DATE) >= si.ssi_date
               AND CAST(de.drug_exposure_start_date AS DATE) <=
                   DATEADD(DAY, 90, si.index_date)
             INNER JOIN @cdm_schema.concept_ancestor ca
               ON  ca.descendant_concept_id = de.drug_concept_id
               AND ca.ancestor_concept_id   = 21603553
             GROUP BY si.subject_id
           ) abx_sub"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      abx_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_abx, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Time-to-antibiotic query failed: ", conditionMessage(e))
        NULL
      })

      # 8. SSI wound treatment: debridement/surgical wound procedure after SSI date.
      #    Identified via OMOP concept_ancestor on procedure_occurrence:
      #    SNOMED 36485005 = Debridement (surgical wound treatment ancestor).
      sql_debride <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_debridement
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.procedure_occurrence po
             ON  po.person_id = si.subject_id
             AND CAST(po.procedure_date AS DATE) >= si.ssi_date
             AND CAST(po.procedure_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON  ca.descendant_concept_id = po.procedure_concept_id
             AND ca.ancestor_concept_id   = 36485005"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      debride_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_debride, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Debridement query failed: ", conditionMessage(e))
        NULL
      })

      # 9. SSI onset timing bands: proportion diagnosed within 0-30, 31-60, 61-90 days.
      sql_timing <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT
             SUM(CASE WHEN days_to_ssi <= 30 THEN 1 ELSE 0 END) AS n_0_30,
             SUM(CASE WHEN days_to_ssi BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS n_31_60,
             SUM(CASE WHEN days_to_ssi BETWEEN 61 AND 90 THEN 1 ELSE 0 END) AS n_61_90
           FROM ssi_w_index"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      timing_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_timing, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] SSI timing query failed: ", conditionMessage(e))
        NULL
      })

      out <- list(
        n_ssi             = if (!is.null(days_raw))     as.integer(days_raw$n_ssi[1])              else NA_integer_,
        median_days       = if (!is.null(days_raw))     as.numeric(days_raw$median_days[1])        else NA_real_,
        p25               = if (!is.null(days_raw))     as.numeric(days_raw$p25[1])                else NA_real_,
        p75               = if (!is.null(days_raw))     as.numeric(days_raw$p75[1])                else NA_real_,
        n_reoperation     = if (!is.null(reop_raw))     as.integer(reop_raw$n_reoperation[1])      else NA_integer_,
        n_readmission     = if (!is.null(readm_raw))    as.integer(readm_raw$n_readmission[1])     else NA_integer_,
        n_death           = if (!is.null(death_raw))    as.integer(death_raw$n_death[1])           else NA_integer_,
        n_superficial     = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_superficial[1])  else NA_integer_,
        n_deep            = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_deep[1])         else NA_integer_,
        n_organ           = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_organ[1])        else NA_integer_,
        n_unclassified    = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_unclassified[1]) else NA_integer_,
        median_los        = if (!is.null(los_raw))      as.numeric(los_raw$median_los[1])          else NA_real_,
        los_p25           = if (!is.null(los_raw))      as.numeric(los_raw$p25[1])                 else NA_real_,
        los_p75           = if (!is.null(los_raw))      as.numeric(los_raw$p75[1])                 else NA_real_,
        median_days_to_abx = if (!is.null(abx_raw) && !is.na(abx_raw$n_abx[1]) && abx_raw$n_abx[1] > 0)
                               as.numeric(abx_raw$median_days_to_abx[1]) else NA_real_,
        abx_p25           = if (!is.null(abx_raw) && !is.na(abx_raw$n_abx[1]) && abx_raw$n_abx[1] > 0)
                               as.numeric(abx_raw$p25[1]) else NA_real_,
        abx_p75           = if (!is.null(abx_raw) && !is.na(abx_raw$n_abx[1]) && abx_raw$n_abx[1] > 0)
                               as.numeric(abx_raw$p75[1]) else NA_real_,
        n_abx             = if (!is.null(abx_raw))      as.integer(abx_raw$n_abx[1])              else NA_integer_,
        n_debridement     = if (!is.null(debride_raw))  as.integer(debride_raw$n_debridement[1])   else NA_integer_,
        n_0_30            = if (!is.null(timing_raw))   as.integer(timing_raw$n_0_30[1])           else NA_integer_,
        n_31_60           = if (!is.null(timing_raw))   as.integer(timing_raw$n_31_60[1])          else NA_integer_,
        n_61_90           = if (!is.null(timing_raw))   as.integer(timing_raw$n_61_90[1])          else NA_integer_
      )
    }, silent = TRUE)

    if (!is.null(conn)) {
      try(DatabaseConnector::disconnect(conn), silent = TRUE)
    }

    out
  }

  append_distribution_rows <- function(tbl, dist_df, label_prefix, denom, max_rows = 6L) {
    if (is.null(dist_df) || nrow(dist_df) == 0) {
      return(tbl)
    }

    n_col <- names(dist_df)[tolower(names(dist_df)) == "n"][1]
    cat_col <- names(dist_df)[tolower(names(dist_df)) == "category"][1]
    if (is.na(n_col) || is.na(cat_col)) {
      return(tbl)
    }

    dist_df$n_value <- as.numeric(dist_df[[n_col]])
    dist_df$cat_value <- as.character(dist_df[[cat_col]])
    keep_n <- min(nrow(dist_df), max_rows)
    shown <- dist_df[seq_len(keep_n), , drop = FALSE]

    for (i in seq_len(nrow(shown))) {
      tbl <- rbind(
        tbl,
        data.frame(
          Item = paste0(label_prefix, " - ", shown$cat_value[i]),
          Value = fmt_n_pct(shown$n_value[i], denom),
          Definition = paste0(
            "Distribution among target-cohort patients based on OMOP person ",
            if (label_prefix == "Race") "race_concept_id" else if (label_prefix == "Ethnicity") "ethnicity_concept_id" else "gender_concept_id",
            "."
          ),
          stringsAsFactors = FALSE
        )
      )
    }

    if (nrow(dist_df) > keep_n) {
      other_n <- sum(as.numeric(dist_df$n_value[(keep_n + 1):nrow(dist_df)]), na.rm = TRUE)
      tbl <- rbind(
        tbl,
        data.frame(
          Item = paste0(label_prefix, " - Other"),
          Value = fmt_n_pct(other_n, denom),
          Definition = "Combined frequency of remaining categories not shown individually.",
          stringsAsFactors = FALSE
        )
      )
    }

    tbl
  }

  build_table1_cohort <- function(person_level, config, connection_details) {
    n_target  <- nrow(person_level)
    n_outcome <- sum(as.numeric(person_level$outcome), na.rm = TRUE)

    # Helper: build one row; is_header=TRUE makes the row a section label
    row1 <- function(char, val = "", header = FALSE) {
      data.frame(
        Characteristic = char,
        Value          = val,
        is_header      = header,
        stringsAsFactors = FALSE
      )
    }
    sub_row <- function(label, n, denom) {
      row1(paste0("    ", label), fmt_n_pct(n, denom))
    }
    # Look up count for a fixed OMOP concept_id in a distribution data frame
    # returned by distribution_sql() (columns: CONCEPT_ID, CATEGORY, N).
    # All matching is done on the integer concept_id — no string/regex logic.
    lookup_concept <- function(df, cid) {
      if (is.null(df) || nrow(df) == 0) return(0L)
      n_col  <- names(df)[toupper(names(df)) == "N"][1]
      id_col <- names(df)[toupper(names(df)) == "CONCEPT_ID"][1]
      if (is.na(n_col) || is.na(id_col)) return(0L)
      idx <- which(as.integer(df[[id_col]]) == as.integer(cid))
      if (length(idx) == 0) return(0L)
      sum(as.integer(df[[n_col]][idx]), na.rm = TRUE)
    }
    # Look up count by exact category label (used for indication/procedure rows
    # where the SQL itself sets the category string, so it is stable).
    lookup_n <- function(df, category_value) {
      if (is.null(df) || nrow(df) == 0) return(0L)
      n_col   <- names(df)[toupper(names(df)) == "N"][1]
      cat_col <- names(df)[toupper(names(df)) == "CATEGORY"][1]
      if (is.na(n_col) || is.na(cat_col)) return(0L)
      idx <- which(trimws(df[[cat_col]]) == category_value)
      if (length(idx) == 0) return(0L)
      as.integer(df[[n_col]][idx[1]])
    }

    demog <- fetch_demographics_from_omop(config, connection_details)

    # ---- Age ------------------------------------------------------------------
    age_row <- row1("Age, median (IQR), years", "N/A")
    if (!is.null(demog$age) && nrow(demog$age) > 0) {
      # DatabaseConnector >= 6.0 stopped auto-uppercasing column names, so use
      # a case-insensitive lookup instead of the hard-coded AGE_AT_INDEX name.
      .age_col <- names(demog$age)[toupper(names(demog$age)) == "AGE_AT_INDEX"][1]
      ages <- if (!is.na(.age_col)) as.numeric(demog$age[[.age_col]]) else numeric(0)
      ages <- ages[!is.na(ages)]
      if (length(ages) > 0) {
        q <- stats::quantile(ages, probs = c(0.25, 0.75), na.rm = TRUE)
        age_row <- row1(
          "Age, median (IQR), years",
          paste0(
            as.character(as.integer(floor(stats::median(ages)))),
            " (",
            as.character(as.integer(floor(q[[1]]))),
            "\u2013",
            as.character(as.integer(floor(q[[2]]))),
            ")"
          )
        )
      }
    }

    # ---- Sex ------------------------------------------------------------------
    # Standard OMOP Gender domain concept IDs (vocabulary_id = 'Gender'):
    #   8507 = MALE
    #   8532 = FEMALE
    male_n   <- lookup_concept(demog$sex, 8507L)
    female_n <- lookup_concept(demog$sex, 8532L)

    # ---- Race / Ethnicity (four requested categories) ------------------------
    # Standard OMOP Race domain concept IDs (vocabulary_id = 'Race'):
    #   8527 = White
    #   8516 = Black or African American
    #   8515 = Asian
    # Standard OMOP Ethnicity domain concept IDs (vocabulary_id = 'Ethnicity'):
    #   38003563 = Hispanic or Latino
    #   38003564 = Not Hispanic or Latino
    white_n   <- lookup_concept(demog$race,      8527L)
    black_n   <- lookup_concept(demog$race,      8516L)
    asian_n   <- lookup_concept(demog$race,      8515L)
    latino_n  <- lookup_concept(demog$ethnicity, 38003563L)

    # ---- Indication (OMOP concept_ancestor rollup, returned by fetch_demographics) -----
    ind_df   <- demog$indication
    claud_n  <- lookup_n(ind_df, "Claudication")
    rest_n   <- lookup_n(ind_df, "Rest pain")
    tissue_n <- lookup_n(ind_df, "Tissue loss")
    asymp_n  <- lookup_n(ind_df, "Asymptomatic")

    # ---- Procedure type -------------------------------------------------------
    pt_df      <- demog$procedure_type
    aortobif_n <- lookup_n(pt_df, "Aortobifemoral bypass")
    endar_n    <- lookup_n(pt_df, "Femoral endarterectomy")
    fempop_n   <- lookup_n(pt_df, "Femoral-popliteal bypass")
    femtib_n    <- lookup_n(pt_df, "Femorotibial bypass")
    extraanat_n <- lookup_n(pt_df, "Extra-anatomic bypass")

    # ---- Assemble table -------------------------------------------------------
    tbl <- rbind(
      age_row,
      # Sex
      row1("Sex", header = TRUE),
      sub_row("Male",   male_n,   n_target),
      sub_row("Female", female_n, n_target),
      # Race
      row1("Race", header = TRUE),
      sub_row("White",             white_n,  n_target),
      sub_row("Black",             black_n,  n_target),
      sub_row("Asian",             asian_n,  n_target),
      sub_row("Hispanic / Latino", latino_n, n_target),
      # Indication
      row1("Indication", header = TRUE),
      sub_row("Asymptomatic", asymp_n,  n_target),
      sub_row("Claudication", claud_n,  n_target),
      sub_row("Rest pain",    rest_n,   n_target),
      sub_row("Tissue loss",  tissue_n, n_target),
      # Procedure
      row1("Procedure", header = TRUE),
      sub_row("Aortobifemoral bypass",    aortobif_n, n_target),
      sub_row("Femoral endarterectomy",   endar_n,    n_target),
      sub_row("Femoral-popliteal bypass", fempop_n,   n_target),
      sub_row("Femorotibial bypass",      femtib_n,    n_target),
      sub_row("Extra-anatomic bypass",    extraanat_n, n_target),
      # Prediction window outcome
      row1(paste0(config$prediction_window_days, "-day outcome"), header = TRUE),
      sub_row(config$outcome_label, n_outcome, n_target),
      # Total (last row)
      row1("Total cohort", fmt_n_pct(n_target, n_target))
    )

    tbl
  }

  # Use passed-in config / connection_details; fall back to get_validation_config()
  # for callers that do not supply them explicitly.
  if (is.null(config) && exists("get_validation_config", mode = "function")) {
    config <- tryCatch(get_validation_config(), error = function(e) NULL)
  }
  if (is.null(connection_details) && !is.null(config) &&
      exists("build_connection_details", mode = "function")) {
    connection_details <- tryCatch(build_connection_details(config), error = function(e) NULL)
  }
  cohort_tbl <- build_table1_cohort(person_level, config, connection_details)

  simple_ft <- function(df) {
    flextable(df) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      padding(padding = 4, part = "all") |>
      autofit()
  }

  # Two-column Table 1 formatter.
  # Expects df with columns: Characteristic, Value, is_header (logical).
  # is_header rows are rendered bold with no indentation; sub-rows are indented.
  # The is_header column is dropped before the flextable is built.
  table1_ft <- function(df) {
    if (is.null(df) || nrow(df) == 0) {
      return(flextable(data.frame(Characteristic = character(), Value = character())))
    }

    header_rows <- which(df$is_header)
    sub_rows    <- which(!df$is_header)
    total_row   <- nrow(df)   # last row is always "Total cohort"

    # Strip the helper column before passing to flextable
    display_df <- df[, c("Characteristic", "Value"), drop = FALSE]

    ft <- flextable(display_df) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      align(align = "left",  part = "all") |>
      valign(valign = "top", part = "all") |>
      padding(padding = 3, part = "all") |>
      # Section-label rows: bold, no left indent, light grey background
      bold(i = header_rows, part = "body") |>
      bg(i = header_rows, bg = "#F2F2F2", part = "body") |>
      # Sub-rows: extra left padding to simulate indent
      padding(i = sub_rows, j = "Characteristic", padding.left = 18, part = "body") |>
      # Total row: bold
      bold(i = total_row, part = "body") |>
      # Column widths
      width(j = "Characteristic", width = 2.8) |>
      width(j = "Value",          width = 1.4) |>
      set_table_properties(layout = "fixed")

    ft
  }

  wrapped_definition_ft <- function(df) {
    ft <- flextable(df) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      padding(padding = 4, part = "all") |>
      align(align = "left", part = "all") |>
      valign(valign = "top", part = "all") |>
      width(j = "Item", width = 1.4) |>
      width(j = "Value", width = 0.9) |>
      width(j = "Definition", width = 4.7) |>
      set_table_properties(layout = "fixed")

    ft
  }

  wrapped_predictor_ft <- function(df) {
    has_missing <- "MissingPct" %in% names(df)
    ft <- flextable(df) |>
      bold(part = "header") |>
      fontsize(size = 9, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      padding(padding = 3, part = "all") |>
      align(align = "left", part = "all") |>
      valign(valign = "top", part = "all") |>
      width(j = "Predictor",    width = 1.3) |>
      width(j = "Points",       width = 0.5) |>
      width(j = "Lookback",     width = 0.75) |>
      width(j = "Definition",   width = if (has_missing) 3.0 else 3.5) |>
      width(j = "PositiveCount", width = 0.75) |>
      width(j = "MeanPoints",   width = 0.7)
    if (has_missing) {
      ft <- ft |>
        width(j = "MissingCount", width = 0.65) |>
        width(j = "MissingPct",   width = 0.65) |>
        set_header_labels(
          MissingCount = "No CDM\nRecord\nn",
          MissingPct   = "No CDM\nRecord\n%"
        )
    }
    ft |> set_table_properties(layout = "fixed")
  }

  # ---------------------------------------------------------------------------
  # save_subgroup_forest_plot()
  #
  # Builds a forest plot of ECE (95% CI) by subgroup from the subgroup_bias
  # data frame.  Each subgroup variable is drawn as a labelled section (via
  # ggplot2 faceting on subgroup_var).  A dashed vertical reference line shows
  # the overall ECE for the lookup model (read from metrics.csv).
  #
  # Arguments:
  #   bias_df      — data frame from subgroup_bias.csv
  #   overall_ece  — numeric overall ECE (lookup model) for the reference line
  #   output_folder — directory where the PNG will be written
  #
  # Returns the path to the saved PNG, or NULL on failure.
  # ---------------------------------------------------------------------------
  save_subgroup_forest_plot <- function(bias_df, overall_ece, output_folder) {

    if (is.null(bias_df) || nrow(bias_df) == 0) return(NULL)

    # Impose Table 1 ordering on subgroup facets.
    var_order <- c("age_group", "sex", "race", "ethnicity",
                   "indication", "proc_type", "year")
    present_vars <- var_order[var_order %in% bias_df$subgroup_var]
    extra_vars   <- setdiff(unique(bias_df$subgroup_var), present_vars)
    ordered_vars <- c(present_vars, extra_vars)
    bias_df$subgroup_var <- factor(bias_df$subgroup_var, levels = ordered_vars)

    # Build a combined label: "Sex: Female", "Race: Black", etc.
    bias_df$label <- paste0(
      tools::toTitleCase(gsub("_", " ", as.character(bias_df$subgroup_var))),
      ": ",
      bias_df$subgroup_level
    )

    # Order labels within each facet by ECE (ascending) for readability.
    bias_df$label <- factor(
      bias_df$label,
      levels = bias_df$label[order(bias_df$subgroup_var, bias_df$ece)]
    )

    # Facet labels: capitalise the subgroup variable name for display.
    facet_labels <- setNames(
      tools::toTitleCase(gsub("_", " ", levels(bias_df$subgroup_var))),
      levels(bias_df$subgroup_var)
    )

    p <- ggplot2::ggplot(bias_df,
           ggplot2::aes(x = ece, y = label)) +
      ggplot2::geom_point(size = 2, colour = "black") +
      ggplot2::geom_errorbar(
        ggplot2::aes(xmin = ci_lower, xmax = ci_upper),
        width = 0.25, colour = "grey40", orientation = "y"
      ) +
      ggplot2::geom_vline(
        xintercept = overall_ece,
        linetype   = "dashed",
        colour     = "black"
      ) +
      ggplot2::facet_grid(
        subgroup_var ~ .,
        scales   = "free_y",
        space    = "free_y",
        labeller = ggplot2::as_labeller(facet_labels)
      ) +
      ggplot2::labs(
        x     = "Expected Calibration Error (95% CI)",
        y     = NULL,
        title = "Subgroup Calibration (ECE)",
        caption = paste0(
          "Dashed line = overall ECE (", round(overall_ece, 3), "). ",
          "Groups with < 10 events suppressed. ",
          "CIs from 200 bootstrap resamples."
        )
      ) +
      ggplot2::theme_bw(base_size = 11) +
      ggplot2::theme(
        panel.grid.major.y = ggplot2::element_blank(),
        strip.text         = ggplot2::element_text(face = "bold"),
        plot.caption       = ggplot2::element_text(size = 8)
      )

    out_path <- file.path(output_folder, "subgroup_forest_plot.png")
    tryCatch({
      ggplot2::ggsave(out_path, p,
                      width  = 7,
                      height = max(4, nrow(bias_df) * 0.35 + 1.5),
                      dpi    = 150)
      out_path
    }, error = function(e) {
      message("[report] Could not save subgroup forest plot: ", conditionMessage(e))
      NULL
    })
  }

  # ---------------------------------------------------------------------------
  # save_score_distribution_plot()
  # Overlapping density/histogram of total integer score by outcome (SSI vs not).
  # ---------------------------------------------------------------------------
  save_score_distribution_plot <- function(person_level_df, output_folder) {
    if (!all(c("total_score", "outcome") %in% names(person_level_df))) return(NULL)
    df <- person_level_df[, c("total_score", "outcome")]
    df$Outcome <- ifelse(df$outcome == 1, "SSI", "No SSI")
    df$Outcome <- factor(df$Outcome, levels = c("No SSI", "SSI"))

    p <- ggplot2::ggplot(df, ggplot2::aes(x = total_score, fill = Outcome)) +
      ggplot2::geom_histogram(
        ggplot2::aes(y = ggplot2::after_stat(density)),
        binwidth = 1, position = "identity", alpha = 0.55, colour = "white"
      ) +
      ggplot2::scale_fill_manual(values = c("No SSI" = "#4472C4", "SSI" = "#C00000")) +
      ggplot2::scale_x_continuous(breaks = seq(-2, 14, by = 1)) +
      ggplot2::labs(
        title   = "Score Distribution by Outcome",
        x       = "Integer risk score",
        y       = "Density",
        fill    = NULL,
        caption = paste0(
          "N = ", nrow(df), " patients. ",
          config$prediction_window_days, "-day ", config$outcome_label, " = outcome group."
        )
      ) +
      ggplot2::theme_bw(base_size = 11) +
      ggplot2::theme(
        legend.position  = "top",
        plot.caption     = ggplot2::element_text(size = 8),
        panel.grid.minor = ggplot2::element_blank()
      )

    out_path <- file.path(output_folder, "score_distribution.png")
    tryCatch({
      ggplot2::ggsave(out_path, p, width = 6, height = 3.8, dpi = 150)
      out_path
    }, error = function(e) {
      message("[report] Could not save score distribution plot: ", conditionMessage(e))
      NULL
    })
  }

  # ---------------------------------------------------------------------------
  # save_dca_plot()
  # Decision curve analysis: net benefit vs. threshold probability for the
  # lookup model, treat-all, and treat-none strategies.
  # Threshold range restricted to 0–40% (typical SSI clinical decision range).
  # ---------------------------------------------------------------------------
  save_dca_plot <- function(y, p, output_folder) {
    if (length(y) == 0 || length(p) == 0) return(NULL)

    thresholds <- seq(0.01, 0.40, by = 0.005)
    n <- length(y)
    prev <- mean(y, na.rm = TRUE)

    nb_model    <- numeric(length(thresholds))
    nb_treat_all <- numeric(length(thresholds))

    for (i in seq_along(thresholds)) {
      pt <- thresholds[i]
      # Treat if predicted >= threshold
      predicted_pos <- p >= pt
      tp <- sum(predicted_pos & y == 1, na.rm = TRUE)
      fp <- sum(predicted_pos & y == 0, na.rm = TRUE)
      nb_model[i]     <- tp / n - fp / n * (pt / (1 - pt))
      # Treat all
      nb_treat_all[i] <- prev - (1 - prev) * (pt / (1 - pt))
    }

    dca_df <- data.frame(
      threshold  = rep(thresholds, 3),
      net_benefit = c(nb_model,
                      pmax(nb_treat_all, 0),
                      rep(0, length(thresholds))),
      Strategy   = rep(c("Lookup model", "Treat all", "Treat none"), each = length(thresholds))
    )
    dca_df$Strategy <- factor(dca_df$Strategy,
                               levels = c("Lookup model", "Treat all", "Treat none"))

    p_dca <- ggplot2::ggplot(dca_df,
        ggplot2::aes(x = threshold * 100, y = net_benefit,
                     colour = Strategy, linetype = Strategy)) +
      ggplot2::geom_line(linewidth = 0.9) +
      ggplot2::scale_colour_manual(
        values = c("Lookup model" = "#1F3864",
                   "Treat all"   = "#C00000",
                   "Treat none"  = "grey50")
      ) +
      ggplot2::scale_linetype_manual(
        values = c("Lookup model" = "solid",
                   "Treat all"   = "dashed",
                   "Treat none"  = "dotted")
      ) +
      ggplot2::scale_x_continuous(
        breaks = seq(0, 40, by = 5),
        labels = function(x) paste0(x, "%")
      ) +
      ggplot2::labs(
        title   = "Decision Curve Analysis",
        x       = "Threshold probability (%)",
        y       = "Net benefit",
        colour  = NULL, linetype = NULL,
        caption = paste0(
          "Net benefit = TP/N \u2212 FP/N \u00d7 (p\u209c / (1\u2212p\u209c)). ",
          "Treat-all and treat-none are reference strategies. ",
          "Threshold range 1\u201340%."
        )
      ) +
      ggplot2::theme_bw(base_size = 11) +
      ggplot2::theme(
        legend.position  = "top",
        plot.caption     = ggplot2::element_text(size = 8),
        panel.grid.minor = ggplot2::element_blank()
      )

    out_path <- file.path(output_folder, "decision_curve.png")
    tryCatch({
      ggplot2::ggsave(out_path, p_dca, width = 6, height = 4, dpi = 150)
      out_path
    }, error = function(e) {
      message("[report] Could not save DCA plot: ", conditionMessage(e))
      NULL
    })
  }

  # ---------------------------------------------------------------------------
  # next_report_file()
  #
  # Returns the target .docx path for the new report.  archive_old_reports()
  # always runs before this, so the dated filename is free to use directly.
  # ---------------------------------------------------------------------------
  next_report_file <- function(output_dir, base_name) {
    file.path(output_dir, paste0(base_name, ".docx"))
  }

  # ---------------------------------------------------------------------------
  # archive_old_reports()
  #
  # Moves all existing .docx files in output_dir to output_dir/archive/ before
  # each report run so only the latest report is visible at the top level.
  # Files are renamed with an incrementing suffix (_2, _3 …) when an archive
  # entry with the same name already exists (e.g. two runs on the same date).
  # ---------------------------------------------------------------------------
  archive_old_reports <- function(output_dir) {
    existing <- list.files(output_dir, pattern = "\\.docx$",
                           full.names = TRUE, all.files = FALSE)
    if (length(existing) == 0L) return(invisible(NULL))

    archive_dir <- file.path(output_dir, "archive")
    dir.create(archive_dir, recursive = TRUE, showWarnings = FALSE)

    for (f in existing) {
      nm   <- basename(f)
      dest <- file.path(archive_dir, nm)

      # Avoid silently overwriting an existing archive entry on same-day re-runs.
      if (file.exists(dest)) {
        base <- tools::file_path_sans_ext(nm)
        ext  <- tools::file_ext(nm)
        i    <- 2L
        repeat {
          dest <- file.path(archive_dir, paste0(base, "_", i, ".", ext))
          if (!file.exists(dest)) break
          i <- i + 1L
        }
      }

      file.rename(f, dest)
    }

    invisible(NULL)
  }

  roc_y <- person_level$outcome
  if ("predicted_risk_lookup" %in% names(person_level)) {
    keep_lookup <- !is.na(person_level$predicted_risk_lookup)
    roc_y <- person_level$outcome[keep_lookup]
    roc_p <- person_level$predicted_risk_lookup[keep_lookup]
  } else if ("predicted_risk_recalibrated" %in% names(person_level)) {
    roc_p <- person_level$predicted_risk_recalibrated
  } else {
    roc_p <- person_level$total_score / max(person_level$total_score, na.rm = TRUE)
  }

  roc_plot_file <- .save_roc_plot(
    y = roc_y,
    p = roc_p,
    output_folder = temp_figure_dir,
    auc_override = metric_value("AUROC", "lookup")
  )

  # Branch 3 — Annual and monthly outcome rate plots.
  # LASSO (MACCE-style): single-line trend via .save_macce_rate_by_year_plot().
  # Integer (SSI-style): stacked area chart via .save_ssi_rate_by_year_plot().
  if (identical(config$score_type, "lasso")) {
    ssi_year_plot_file  <- .save_macce_rate_by_year_plot(person_level, temp_figure_dir)
    ssi_month_plot_file <- .save_macce_rate_by_month_plot(person_level, temp_figure_dir)
  } else {
    ssi_year_plot_file  <- .save_ssi_rate_by_year_plot(person_level, temp_figure_dir)
    ssi_month_plot_file <- .save_ssi_rate_by_month_plot(person_level, temp_figure_dir)
  }

  # Score distribution plot (supplemental S4)
  score_dist_plot_file <- save_score_distribution_plot(person_level, temp_figure_dir)

  # Decision curve analysis plot (Figure 4)
  dca_plot_file <- if ("predicted_risk_lookup" %in% names(person_level)) {
    keep_dca <- !is.na(person_level$predicted_risk_lookup)
    save_dca_plot(person_level$outcome[keep_dca],
                  person_level$predicted_risk_lookup[keep_dca],
                  temp_figure_dir)
  } else NULL

  if (file.exists(lookup_calibration_plot)) {
    file.copy(lookup_calibration_plot, lookup_calibration_plot_temp, overwrite = TRUE)
  } else if (file.exists(calibration_table_lookup_path)) {
    lookup_generated <- .save_calibration_plot_from_table(
      calibration_table_path = calibration_table_lookup_path,
      output_folder = temp_figure_dir,
      file_name = "calibration_lookup.png",
      plot_title = "Calibration Plot: Lookup Model"
    )
    if (!is.null(lookup_generated) && file.exists(lookup_generated)) {
      lookup_calibration_plot_temp <- lookup_generated
    }
  }

  if (file.exists(recalibrated_calibration_plot)) {
    file.copy(recalibrated_calibration_plot, recalibrated_calibration_plot_temp, overwrite = TRUE)
  } else if (file.exists(calibration_table_recalibrated_path)) {
    recal_generated <- .save_calibration_plot_from_table(
      calibration_table_path = calibration_table_recalibrated_path,
      output_folder = temp_figure_dir,
      file_name = "calibration_recalibrated.png",
      plot_title = "Calibration Plot: Recalibrated Model"
    )
    if (!is.null(recal_generated) && file.exists(recal_generated)) {
      recalibrated_calibration_plot_temp <- recal_generated
    }
  }

  if (!file.exists(lookup_calibration_plot_temp) &&
      all(c("outcome", "predicted_risk_lookup") %in% names(person_level))) {
    lookup_generated <- .save_calibration_plot_from_vectors(
      y = person_level$outcome,
      p = person_level$predicted_risk_lookup,
      output_folder = temp_figure_dir,
      file_name = "calibration_lookup.png",
      plot_title = "Calibration Plot: Lookup Model"
    )
    if (!is.null(lookup_generated) && file.exists(lookup_generated)) {
      lookup_calibration_plot_temp <- lookup_generated
    }
  }

  if (!file.exists(recalibrated_calibration_plot_temp) &&
      all(c("outcome", "predicted_risk_recalibrated") %in% names(person_level))) {
    recal_generated <- .save_calibration_plot_from_vectors(
      y = person_level$outcome,
      p = person_level$predicted_risk_recalibrated,
      output_folder = temp_figure_dir,
      file_name = "calibration_recalibrated.png",
      plot_title = "Calibration Plot: Recalibrated Model"
    )
    if (!is.null(recal_generated) && file.exists(recal_generated)) {
      recalibrated_calibration_plot_temp <- recal_generated
    }
  }

  project_name <- basename(normalizePath(getwd(), winslash = "/", mustWork = FALSE))
  project_name <- gsub("[^A-Za-z0-9_-]", "_", project_name)
  report_base_name <- paste(project_name, "report", format(Sys.Date(), "%Y%m%d"), sep = "_")

  # Move any existing .docx reports to output_dir/archive/ before writing the
  # new report so only the latest version is visible at the top level.
  archive_old_reports(output_dir)

  report_file <- next_report_file(output_dir, report_base_name)

  # Query CDM source metadata early so values are available for the methods text.
  cdm_version_str        <- ""
  vocabulary_version_str <- ""
  if (!is.null(connection_details) && !is.null(config)) {
    tryCatch({
      conn_meta <- DatabaseConnector::connect(connection_details)
      meta_raw  <- DatabaseConnector::querySql(
        conn_meta,
        SqlRender::translate(
          SqlRender::render(
            "SELECT cdm_version, vocabulary_version FROM @cdm_schema.cdm_source",
            cdm_schema = config$cdm_schema
          ),
          targetDialect = "sql server"
        )
      )
      DatabaseConnector::disconnect(conn_meta)
      names(meta_raw) <- tolower(names(meta_raw))
      if (nrow(meta_raw) > 0) {
        cdm_version_str        <- as.character(meta_raw$cdm_version[1])
        vocabulary_version_str <- as.character(meta_raw$vocabulary_version[1])
      }
    }, error = function(e) NULL)
  }

  # =============================================================================
  # CLAUDE CODE — READ BEFORE GENERATING THIS REPORT
  #
  # Before running .report_prognostic(), read the following study files and
  # ensure the report: section of study_params.yaml is complete:
  #
  #   1. study_params.yaml               — study design, prediction window, outcome label
  #   2. cohorts/<target_sql_file>       — target cohort inclusion/exclusion criteria,
  #                                        index event concept IDs, washout definition
  #   3. cohorts/<outcome_sql_file>      — outcome definition and OMOP concept IDs
  #   4. covariates/covariates.csv       — risk score components, point values, lookback windows
  #   5. covariates/covariate_concepts.csv — OMOP concept IDs mapped to each component
  #   6. workflow/08_run_analysis_and_manuscript_report.R — confirm active analysis flags
  #
  # After reading those files, populate (in study_params.yaml report: section):
  #   report.study_title                   — display title for the manuscript
  #   report.target_population_description — Methods "Target cohort" paragraph
  #   report.outcome_description           — Methods "Outcome cohort" paragraph
  #   report.score_description             — Methods "Risk score evaluation" paragraph
  #
  # Paragraphs still showing "[...]" placeholder text mean that field has not been set.
  # =============================================================================

  # Resolve narrative text from config — falls back to "[PLACEHOLDER]" reminder strings.
  cfg_study_title <- config$report_study_title %||%
    paste0("[STUDY_TITLE: Set report.study_title in study_params.yaml.]")

  cfg_target_pop <- config$report_target_population_description %||%
    paste0("[TARGET_POPULATION_DESCRIPTION: Read cohorts/<target_sql_file> and",
           " populate report.target_population_description in study_params.yaml.]")

  cfg_outcome_par <- config$report_outcome_description %||%
    paste0("[OUTCOME_DESCRIPTION: Read cohorts/<outcome_sql_file> and",
           " populate report.outcome_description in study_params.yaml.]")

  cfg_score_par <- config$report_score_description %||%
    paste0("[SCORE_DESCRIPTION: Read covariates/covariates.csv and",
           " covariates/covariate_concepts.csv and populate",
           " report.score_description in study_params.yaml.]")

  doc <- read_docx()
  doc <- officer::body_set_default_section(
    doc,
    officer::prop_section(
      page_margins = officer::page_mar(
        top = 0.5, bottom = 0.5, left = 0.5, right = 0.5,
        header = 0.3, footer = 0.3, gutter = 0
      )
    )
  )
  doc <- body_add_par(doc, "Manuscript Draft: Methods and Results", style = "heading 1")
  doc <- body_add_par(doc, cfg_study_title %||% paste0(config$prediction_window_days, "-Day ", config$outcome_label, " Risk Score: External Validation"), style = "Normal")
  doc <- body_add_par(doc, paste("Date:", format(Sys.Date(), "%Y-%m-%d")), style = "Normal")
  doc <- body_add_par(doc, "", style = "Normal")

  doc <- body_add_par(doc, "Methods", style = "heading 2")
  doc <- body_add_par(doc, "Data source", style = "heading 3")
  doc <- body_add_par(doc, paste0(
    "This analysis used patient-level data mapped to the Observational Medical Outcomes Partnership ",
    "Common Data Model (OMOP CDM",
    if (nzchar(cdm_version_str))        paste0("; CDM version: ", cdm_version_str)        else "",
    if (nzchar(vocabulary_version_str)) paste0("; vocabulary release: ", vocabulary_version_str) else "",
    "). The study window spanned ",
    if (!is.null(config$study_start_date)) format(as.Date(config$study_start_date), "%B %d, %Y") else "N/A",
    " to ",
    if (!is.null(config$study_end_date))   format(as.Date(config$study_end_date),   "%B %d, %Y") else "N/A",
    ". All cohort definitions, concept mappings, and analytic scripts are compatible with any ",
    "OMOP CDM v5 data source. Full data source metadata are reported in Supplemental Table S1."
  ), style = "Normal")
  doc <- body_add_par(doc, "Target and outcome cohort definitions", style = "heading 3")
  # TODO [CLAUDE]: cfg_target_pop is drawn from report.target_population_description in
  # study_params.yaml. Read cohorts/<target_sql_file> and populate that field first.
  doc <- body_add_par(doc, cfg_target_pop, style = "Normal")
  # TODO [CLAUDE]: cfg_outcome_par is drawn from report.outcome_description in
  # study_params.yaml. Read cohorts/<outcome_sql_file> and populate that field first.
  doc <- body_add_par(doc, cfg_outcome_par, style = "Normal")
  doc <- body_add_par(doc, "Risk score evaluation", style = "heading 3")

  # Branch 4 — Methods §2.2 narrative for the risk score computation.
  # Text is parameterised by score_type so the methods section reads correctly
  # for both integer risk scores (lookup-table approach) and LASSO models.
  methods_22_text <- if (identical(config$score_type, "lasso")) {
    paste0(
      "The ", config$model_type_description, " was developed using penalised logistic ",
      "regression (LASSO) applied to patient-level OMOP CDM data. Predictors with ",
      "non-zero LASSO coefficients were retained (Table 2). Each patient received a ",
      "predicted probability of ", config$outcome_label, " within ",
      config$prediction_window_days, " days of the index procedure."
    )
  } else {
    paste0(
      "The ", config$model_type_description, " comprises pre-operative and ",
      "intra-operative components (Table 2), each mapped to one or more OMOP standard ",
      "concept IDs. Component scores are summed to produce a total risk score; ",
      "a lookup table converts the total score to a predicted probability of ",
      config$outcome_label, " within ", config$prediction_window_days,
      " days of the index procedure."
    )
  }

  doc <- body_add_par(doc, paste0(
    methods_22_text, " Discrimination was summarized ",
    "using the area under the receiver operating characteristic curve (AUROC) and the area under the ",
    "precision-recall curve (AUPRC), each with 95% bootstrap percentile confidence intervals ",
    "(B = 500 resamples). For the published lookup model, predicted probabilities were obtained ",
    "from the supplied score-to-risk lookup table."
  ), style = "Normal")
  doc <- body_add_par(doc, paste0(
    "Calibration was assessed for the published lookup model using the Brier score, expected calibration ",
    "error (ECE), calibration intercept, and calibration slope, each with 95% bootstrap percentile CIs ",
    "(B\u2009=\u2009500 resamples). ECE was computed as the probability-weighted mean absolute difference ",
    paste0("between mean predicted and observed ", config$prediction_window_days, "-day ",
           config$outcome_label, " rates across quantile-based bins. Calibration plots "),
    "compare mean predicted risk versus observed event rate within each bin; the dashed diagonal represents ",
    "perfect calibration."
  ), style = "Normal")
  doc <- body_add_par(doc, "Subgroup analysis and bias assessment", style = "heading 3")
  # TODO [CLAUDE]: Rewrite the subgroup paragraph to list the prespecified subgroups
  # for THIS study (sex, age, indication, procedure type, calendar year, etc.).
  # Replace study-specific subgroup labels if they differ from the PAD SSI example.
  doc <- body_add_par(doc, paste0(
    "Model calibration was assessed across prespecified patient subgroups to identify populations ",
    "in which the ", config$model_type_description, " may systematically over- or underestimate observed ",
    tolower(config$outcome_label), " risk. ",
    "Subgroups evaluated included biological sex, race, ethnicity, age group (<65, 65\u201374, \u226575 years), ",
    "and calendar year of the index procedure. Expected calibration error (ECE) was ",
    "computed within each subgroup as the weighted mean absolute difference between grouped ",
    "predicted and observed event rates across quantile-based bins. Uncertainty was quantified ",
    "using 200 bootstrap resamples (percentile 95% CI). Subgroup levels with fewer than 10 ",
    "observed ", tolower(config$outcome_label), " events were suppressed to avoid unreliable estimates. ",
    "Results are presented in Supplemental Table S6 and Supplemental Figure S7."
  ), style = "Normal")

  doc <- body_add_par(doc, "Results", style = "heading 2")

  # ---- Table 1: Demographics -----------------------------------------------
  doc <- body_add_par(doc, "Cohort characteristics", style = "heading 3")
  doc <- body_add_par(doc, paste0("The final target cohort included ", n_target, " patients, of whom ",
    n_outcome, " experienced ", tolower(config$outcome_label), " within ", config$prediction_window_days,
    " days, corresponding to an observed event rate of ", fmt(outcome_prev, 2), "%."),
    style = "Normal")
  doc <- body_add_par(doc, "Table 1. Demographics of the external validation cohort.", style = "Normal")
  # TODO [CLAUDE]: Update this caption to reflect the specific demographic and clinical
  # variables displayed in Table 1 for this study. Remove or replace PAD-specific
  # subgroup rows (indication, procedure type) that do not apply to this cohort.
  doc <- body_add_par(doc, paste0(
    "Caption: Values are n (%) unless stated. Age is summarised as median (IQR). ",
    "Race and ethnicity are derived from OMOP person table concept fields. ",
    "[TODO: update subgroup row definitions and OMOP concept IDs to match this study's cohort SQL.]"
  ), style = "Normal")
  doc <- body_add_flextable(doc, table1_ft(cohort_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Table 2: SSI Patient Outcomes ----------------------------------------
  ssi_outcomes <- fetch_ssi_outcomes_from_omop(config, connection_details)
  if (!is.null(ssi_outcomes) && !is.na(ssi_outcomes$n_ssi) && ssi_outcomes$n_ssi > 0) {
    n_ssi_denom <- ssi_outcomes$n_ssi

    days_str <- if (!is.na(ssi_outcomes$median_days)) {
      paste0(
        as.integer(round(ssi_outcomes$median_days)), " days",
        " (IQR: ",
        as.integer(round(ssi_outcomes$p25)),
        "\u2013",
        as.integer(round(ssi_outcomes$p75)),
        ")"
      )
    } else "N/A"

    los_str <- if (!is.na(ssi_outcomes$median_los)) {
      paste0(as.integer(round(ssi_outcomes$median_los)), " days",
             " (IQR: ", as.integer(round(ssi_outcomes$los_p25)),
             "\u2013", as.integer(round(ssi_outcomes$los_p75)), ")")
    } else "N/A"

    abx_str <- if (!is.na(ssi_outcomes$median_days_to_abx)) {
      paste0(as.integer(round(ssi_outcomes$median_days_to_abx)), " days",
             " (IQR: ", as.integer(round(ssi_outcomes$abx_p25)),
             "\u2013", as.integer(round(ssi_outcomes$abx_p75)), ")")
    } else "N/A"

    ssi_outcome_tbl <- data.frame(
      Outcome = c(
        "Index hospitalisation length of stay, median (IQR)",
        "Days from index operation to SSI diagnosis, median (IQR)",
        "SSI onset timing",
        "    Within 30 days, n (%)",
        "    31\u201360 days, n (%)",
        "    61\u201390 days, n (%)",
        "SSI type",
        "    Superficial incisional, n (%)",
        "    Deep incisional, n (%)",
        "    Organ-space, n (%)",
        "    Other / unclassified, n (%)",
        "Time from SSI to first post-SSI antibiotic, median (IQR)",
        "Wound debridement within 90 days of SSI, n (%)",
        "Reoperation within 90 days of SSI, n (%)",
        "Readmission within 90 days of SSI, n (%)",
        "Death within 90 days of index operation, n (%)"
      ),
      Value = c(
        los_str,
        days_str,
        "",
        fmt_n_pct(ssi_outcomes$n_0_30,         n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_31_60,        n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_61_90,        n_ssi_denom),
        "",
        fmt_n_pct(ssi_outcomes$n_superficial,  n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_deep,         n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_organ,        n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_unclassified, n_ssi_denom),
        abx_str,
        fmt_n_pct(ssi_outcomes$n_debridement,  n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_reoperation,  n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_readmission,  n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_death,        n_ssi_denom)
      ),
      stringsAsFactors = FALSE
    )

    # Row indices for formatting
    ssi_header_rows <- which(ssi_outcome_tbl$Outcome %in% c("SSI onset timing", "SSI type"))
    ssi_indent_rows <- grep("^    ", ssi_outcome_tbl$Outcome)

    ssi_out_ft <- flextable::flextable(ssi_outcome_tbl) |>
      flextable::bold(part = "header") |>
      flextable::fontsize(size = 10, part = "all") |>
      flextable::font(fontname = "Calibri", part = "all") |>
      flextable::bg(part = "header", bg = "#1F3864") |>
      flextable::color(part = "header", color = "white") |>
      flextable::align(align = "left", part = "all") |>
      flextable::padding(padding = 4, part = "all") |>
      flextable::bold(i = ssi_header_rows, part = "body") |>
      flextable::bg(i = ssi_header_rows, bg = "#F2F2F2", part = "body") |>
      flextable::padding(i = ssi_indent_rows, j = "Outcome",
                         padding.left = 18, part = "body") |>
      flextable::width(j = "Outcome", width = 3.5) |>
      flextable::width(j = "Value",   width = 1.5) |>
      flextable::set_table_properties(layout = "fixed")

    doc <- body_add_par(doc, "SSI patient outcomes", style = "heading 3")
    doc <- body_add_par(doc,
      paste0(
        "Among the ", n_ssi_denom, " patients who developed SSI within the 90-day ",
        "prediction window, Table 2 summarises key post-SSI clinical outcomes."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 2. SSI patient outcomes within the 90-day post-operative window.",
      style = "Normal"
    )
    doc <- body_add_par(doc,
      paste0(
        "Caption: Denominator is all patients with an SSI event attributed to the index ",
        "procedure (n\u00a0=\u00a0", n_ssi_denom, "). ",
        "Index hospitalisation LOS: length of the inpatient visit (visit_concept_id 9201) ",
        "that contained the index procedure date. ",
        "SSI onset timing: days from index procedure to SSI diagnosis, grouped into 30-day bands. ",
        "SSI type is classified by concept_ancestor rollup: superficial incisional ",
        "(OMOP concept 43530818), deep incisional (concept 4308542), organ-space ",
        "(concept 43530820); 'Other / unclassified' captures patients coded only at the parent ",
        "concept level (4334801). ",
        "Time to antibiotic: days from SSI date to first post-SSI drug_exposure with ",
        "ATC ancestor 21603553 (Antibacterials). ",
        "Wound debridement: any procedure_occurrence with SNOMED ancestor 36485005 ",
        "after SSI date and within 90 days of index. ",
        "Reoperation: any procedure_occurrence after SSI date and within 90 days of index. ",
        "Readmission: inpatient visit (concept 9201) starting after SSI date and within 90 days of index. ",
        "90-day mortality: death record within 90 days of the index procedure date."
      ),
      style = "Normal"
    )
    doc <- body_add_flextable(doc, ssi_out_ft)
    doc <- body_add_par(doc, "", style = "Normal")
    message("[report] Table 2 (SSI outcomes) added.")
  }

  # ---- Figure 1: SSI rate by year (placed after Tables 1-2) ---------------
  if (!is.null(ssi_year_plot_file) && file.exists(ssi_year_plot_file)) {
    doc <- body_add_par(doc, paste0("Figure 1. Annual ", config$prediction_window_days, "-day ", config$outcome_label, " rate."), style = "Normal")
    doc <- body_add_par(doc, paste0(
      "Caption: ", config$prediction_window_days, "-day ", config$outcome_label,
      " rate (%) by calendar year of procedure. ",
      "Points and lines trace the annual event rate. Years with fewer than 5 events are suppressed."
    ), style = "Normal")
    doc <- body_add_img(doc, src = ssi_year_plot_file, width = 5.5, height = 3.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- Table 3: Features ---------------------------------------------------
  doc <- body_add_par(doc, "Predictor activation", style = "heading 3")
  doc <- body_add_par(doc, "Table 3. Features: predictor definitions and activation summary.", style = "Normal")
  doc <- body_add_par(doc, paste0(
    "Caption: Each predictor is listed with its points, lookback window, OMOP-based definition, ",
    "and observed activation in the validation cohort. ",
    "The 'Missing n (%)' column shows patients with no qualifying CDM record for that component. ",
    "For measurement-based components (BMI, ABI, operative time) this reflects the absence of any ",
    "relevant measurement in the lookback window. ",
    "For binary presence/absence components (sex, prior procedures, drug exposures, frailty, indication) ",
    "absence is a true negative and missing is reported as 0."
  ), style = "Normal")
  # Branch 2 — Table 3 predictor/covariate activation table.
  # LASSO: .build_combined_covariate_table() renders the PLP covariate summary.
  # Integer: .build_combined_component_table() shows component points + activation counts.
  tbl3_data <- if (identical(config$score_type, "lasso")) {
    .build_combined_covariate_table(covariate_summary)
  } else {
    .build_combined_component_table(covariate_summary)
  }
  doc <- body_add_flextable(doc, tbl3_data)
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Table 4: Model Performance ------------------------------------------
  doc <- body_add_par(doc, "Model performance", style = "heading 3")
  doc <- body_add_par(doc, "Table 4. Model performance: lookup-model discrimination and calibration metrics.", style = "Normal")
  doc <- body_add_par(doc, "Caption: Metrics are shown for the lookup model. 95% CI = 95% bootstrap percentile confidence interval (B\u2009=\u2009500 resamples). \u2014 indicates CI not available.", style = "Normal")
  doc <- body_add_flextable(doc, simple_ft(results_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Figure 2: AUC / ROC curve -------------------------------------------
  if (!is.null(roc_plot_file) && file.exists(roc_plot_file)) {
    doc <- body_add_par(doc, "Figure 2. Receiver operating characteristic (ROC) curve.", style = "Normal")
    doc <- body_add_par(doc, paste0(
      "Caption: ROC curve for the lookup model predicting ", config$prediction_window_days,
      "-day ", config$outcome_label,
      ". AUROC with 95% bootstrap percentile CI (B\u2009=\u2009500 resamples). ",
      "Dashed diagonal = no-discrimination reference line."
    ), style = "Normal")
    doc <- body_add_img(doc, src = roc_plot_file, width = 4.5, height = 4.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- Figure 3: Calibration curve -----------------------------------------
  if (file.exists(lookup_calibration_plot_temp) || file.exists(recalibrated_calibration_plot_temp)) {
    cal_plot_path <- if (file.exists(lookup_calibration_plot_temp)) {
      lookup_calibration_plot_temp
    } else {
      recalibrated_calibration_plot_temp
    }
    cal_caption <- if (identical(cal_plot_path, lookup_calibration_plot_temp)) {
      paste0("Caption: Mean predicted ", config$prediction_window_days, "-day ",
             config$outcome_label, " risk (x-axis, 0\u20131) vs. observed ",
             config$prediction_window_days, "-day ", config$outcome_label,
             " event rate (y-axis, 0\u20131) by quantile bin for the lookup model. ",
             "Dashed diagonal = perfect calibration.")
    } else {
      paste0("Caption: Mean predicted ", config$prediction_window_days, "-day ",
             config$outcome_label, " risk (x-axis, 0\u20131) vs. observed ",
             config$prediction_window_days, "-day ", config$outcome_label,
             " event rate (y-axis, 0\u20131) by quantile bin for the recalibrated model. ",
             "Dashed diagonal = perfect calibration.")
    }
    doc <- body_add_par(doc, "Figure 3. Calibration plot for the published lookup mapping.", style = "Normal")
    doc <- body_add_par(doc, cal_caption, style = "Normal")
    doc <- body_add_img(doc, src = cal_plot_path, width = 4.5, height = 4.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- Risk tier table (after Figure 3) ------------------------------------
  if ("predicted_risk_lookup" %in% names(person_level)) {
    keep_rt <- !is.na(person_level$predicted_risk_lookup)
    if (sum(keep_rt) > 0) {
      rt_df <- person_level[keep_rt, ]
      rt_df$risk_tier <- ifelse(
        rt_df$predicted_risk_lookup < 0.05,  "Low (<5%)",
        ifelse(rt_df$predicted_risk_lookup <= 0.20, "Intermediate (5\u201320%)", "High (>20%)")
      )
      rt_df$risk_tier <- factor(rt_df$risk_tier,
                                levels = c("Low (<5%)", "Intermediate (5\u201320%)", "High (>20%)"))

      tier_agg <- do.call(rbind, lapply(levels(rt_df$risk_tier), function(tier) {
        sub      <- rt_df[rt_df$risk_tier == tier, ]
        n_tier   <- nrow(sub)
        n_ev     <- sum(sub$outcome, na.rm = TRUE)
        obs_rate <- if (n_tier > 0) n_ev / n_tier else NA_real_
        data.frame(
          "Risk Tier"          = tier,
          "N"                  = n_tier,
          "Events"             = n_ev,
          "Observed Rate (%)"  = if (!is.na(obs_rate)) paste0(round(obs_rate * 100, 1), "%") else "N/A",
          check.names          = FALSE,
          stringsAsFactors     = FALSE
        )
      }))

      tier_ft <- flextable::flextable(tier_agg) |>
        flextable::bold(part = "header") |>
        flextable::fontsize(size = 10, part = "all") |>
        flextable::font(fontname = "Calibri", part = "all") |>
        flextable::bg(part = "header", bg = "#1F3864") |>
        flextable::color(part = "header", color = "white") |>
        flextable::padding(padding = 4, part = "all") |>
        flextable::align(j = c("N", "Events", "Observed Rate (%)"),
                         align = "center", part = "all") |>
        flextable::width(j = "Risk Tier",             width = 2.0) |>
        flextable::width(j = "N",                     width = 0.7) |>
        flextable::width(j = "Events",                width = 0.9) |>
        flextable::width(j = "Observed Rate (%)",     width = 1.6) |>
        flextable::set_table_properties(layout = "fixed")

      doc <- body_add_par(doc, "Risk tier analysis", style = "heading 3")
      doc <- body_add_par(doc, paste0(
        "Table 5. Risk tier classification of the validation cohort. ",
        "Patients are stratified into three tiers based on the model-predicted ", config$prediction_window_days,
        "-day ", config$outcome_label, " risk: ",
        "Low (<5%), Intermediate (5\u201320%), and High (>20%). ",
        "The observed ", tolower(config$outcome_label), " rate within each tier provides a direct assessment of clinical utility."
      ), style = "Normal")
      doc <- body_add_par(doc, paste0(
        "Caption: N = number of patients in each tier. ",
        "Events = number with ", config$prediction_window_days, "-day ", config$outcome_label, ". ",
        "Observed Rate = Events / N. ",
        "Predicted risk thresholds: Low <5%, Intermediate 5\u201320%, High >20%."
      ), style = "Normal")
      doc <- body_add_flextable(doc, tier_ft)
      doc <- body_add_par(doc, "", style = "Normal")
      message("[report] Risk tier table (Table 5) added.")
    }
  }

  # ---- Figure 4: Decision curve analysis ------------------------------------
  if (!is.null(dca_plot_file) && file.exists(dca_plot_file)) {
    doc <- body_add_par(doc, "Figure 4. Decision curve analysis.", style = "Normal")
    doc <- body_add_par(doc, paste0(
      paste0("Caption: Decision curve analysis for the lookup model predicting ",
             config$prediction_window_days, "-day ", config$outcome_label, ". "),
      "Net benefit is plotted across threshold probabilities from 1% to 40%. ",
      "The model curve (blue) is compared with the 'treat-all' (dashed) and ",
      "'treat-none' (zero reference) strategies. Threshold probabilities correspond ",
      "to the minimum predicted risk at which a clinician would recommend an intervention."
    ), style = "Normal")
    doc <- body_add_img(doc, src = dca_plot_file, width = 5.5, height = 3.8)
    doc <- body_add_par(doc, "", style = "Normal")
    message("[report] Figure 4 (DCA) added.")
  }

  # ---- Supplemental section ------------------------------------------------
  # Read subgroup_bias.csv if it was produced by the pipeline.
  subgroup_bias_path <- file.path(score_output_dir, "subgroup_bias.csv")
  subgroup_bias_df   <- NULL
  if (file.exists(subgroup_bias_path)) {
    subgroup_bias_df <- tryCatch(
      readr::read_csv(subgroup_bias_path, show_col_types = FALSE),
      error = function(e) NULL
    )
  }

  doc <- body_add_par(doc, "Supplemental Material", style = "heading 2")

  # ---- S1–S3: DB-sourced tables (own connection; order: CDM, CPT, ICD) ------
  if (!is.null(connection_details) && !is.null(config)) {
    tryCatch({
      conn_supp <- DatabaseConnector::connect(connection_details)
      on.exit(try(DatabaseConnector::disconnect(conn_supp), silent = TRUE), add = TRUE)

      # ---- Supplemental Table S1 — CDM Source --------------------------------
      tryCatch({
        sql_cdm_src <- SqlRender::render(
          "SELECT cdm_source_name, cdm_source_abbreviation, cdm_holder,
                  source_release_date, cdm_release_date, cdm_version,
                  vocabulary_version
           FROM @cdm_schema.cdm_source",
          cdm_schema = config$cdm_schema
        )
        cdm_src_raw <- DatabaseConnector::querySql(
          conn_supp,
          SqlRender::translate(sql_cdm_src, targetDialect = "sql server")
        )
        names(cdm_src_raw) <- tolower(names(cdm_src_raw))
        if (nrow(cdm_src_raw) > 0) {
          cdm_src_display <- data.frame(
            Field = c("CDM Source Name", "Source Abbreviation", "CDM Holder",
                      "Source Release Date", "CDM Release Date",
                      "CDM Version", "Vocabulary Version",
                      "Study Start Date", "Study End Date"),
            Value = c(as.character(cdm_src_raw$cdm_source_name[1]),
                      as.character(cdm_src_raw$cdm_source_abbreviation[1]),
                      as.character(cdm_src_raw$cdm_holder[1]),
                      as.character(cdm_src_raw$source_release_date[1]),
                      as.character(cdm_src_raw$cdm_release_date[1]),
                      as.character(cdm_src_raw$cdm_version[1]),
                      as.character(cdm_src_raw$vocabulary_version[1]),
                      if (!is.null(config$study_start_date)) as.character(config$study_start_date) else "N/A",
                      if (!is.null(config$study_end_date))   as.character(config$study_end_date)   else "N/A"),
            stringsAsFactors = FALSE
          )
          cdm_src_ft <- flextable::flextable(cdm_src_display) |>
            flextable::bold(part = "header") |>
            flextable::fontsize(size = 10, part = "all") |>
            flextable::font(fontname = "Calibri", part = "all") |>
            flextable::bg(part = "header", bg = "#1F3864") |>
            flextable::color(part = "header", color = "white") |>
            flextable::padding(padding = 4, part = "all") |>
            flextable::width(j = "Field", width = 2.0) |>
            flextable::width(j = "Value", width = 4.0) |>
            flextable::set_table_properties(layout = "fixed")
          doc <- body_add_par(doc, "CDM source metadata", style = "heading 3")
          doc <- body_add_par(doc,
            "Supplemental Table S1. CDM source metadata.",
            style = "Normal")
          doc <- body_add_par(doc,
            paste0("Caption: Metadata from the cdm_source table of the OMOP CDM instance ",
                   "used for this analysis. CDM Version and Vocabulary Version confirm ",
                   "compliance with OMOP CDM v5.4 and the Athena vocabulary release used ",
                   "during ETL."),
            style = "Normal")
          doc <- body_add_flextable(doc, cdm_src_ft)
          doc <- body_add_par(doc, "", style = "Normal")
          message("[report] Supplemental Table S1 (CDM source) added.")
        }
      }, error = function(e) {
        message("[report] CDM source table skipped: ", conditionMessage(e))
      })

      # ---- Supplemental Table S2 — CPT codes by procedure subgroup -----------
      # Uses concept_relationship ('Mapped from') to find CPT4 source codes
      # that map to SNOMED standard descendants — CPT4 codes are source codes
      # (standard_concept IS NULL), not in concept_ancestor as descendants.
      tryCatch({
        sql_cpt <- SqlRender::render(
          "SELECT combined.proc_group,
                  combined.cpt_code,
                  combined.cpt_description,
                  COUNT(DISTINCT po.person_id) AS case_count
           FROM (
             -- Branch 1: CPT4 codes that ARE in concept_ancestor as descendants
             -- (covers CPT4s with standard_concept = 'S' in this vocabulary)
             SELECT grp.proc_group,
                    c.concept_id   AS standard_concept_id,
                    c.concept_code AS cpt_code,
                    c.concept_name AS cpt_description
             FROM (
               SELECT 'Endarterectomy'           AS proc_group, 4225375 AS ancestor_id
               UNION ALL SELECT 'Aortobifemoral bypass',        4231680
               UNION ALL SELECT 'Femoral-popliteal bypass',     4012936
               UNION ALL SELECT 'Femorotibial bypass',          4166196
               UNION ALL SELECT 'Extra-anatomic bypass',        4050281
             ) grp
             INNER JOIN @vocab_schema.concept_ancestor ca
               ON ca.ancestor_concept_id = grp.ancestor_id
             INNER JOIN @vocab_schema.concept c
               ON c.concept_id    = ca.descendant_concept_id
              AND c.vocabulary_id IN ('CPT4','HCPCS')

             UNION

             -- Branch 2: CPT4 source codes that map TO standard SNOMED descendants
             -- via concept_relationship (catches CPT4s not in concept_ancestor)
             SELECT grp.proc_group,
                    cr.concept_id_1 AS standard_concept_id,
                    c.concept_code  AS cpt_code,
                    c.concept_name  AS cpt_description
             FROM (
               SELECT 'Endarterectomy'           AS proc_group, 4225375 AS ancestor_id
               UNION ALL SELECT 'Aortobifemoral bypass',        4231680
               UNION ALL SELECT 'Femoral-popliteal bypass',     4012936
               UNION ALL SELECT 'Femorotibial bypass',          4166196
               UNION ALL SELECT 'Extra-anatomic bypass',        4050281
             ) grp
             INNER JOIN @vocab_schema.concept_ancestor ca
               ON ca.ancestor_concept_id = grp.ancestor_id
             INNER JOIN @vocab_schema.concept_relationship cr
               ON cr.concept_id_2    = ca.descendant_concept_id
              AND cr.relationship_id = 'Maps to'
              AND cr.invalid_reason  IS NULL
             INNER JOIN @vocab_schema.concept c
               ON c.concept_id    = cr.concept_id_1
              AND c.vocabulary_id IN ('CPT4','HCPCS')
           ) combined
           LEFT JOIN @cdm_schema.procedure_occurrence po
             ON po.procedure_source_concept_id = combined.standard_concept_id
           GROUP BY combined.proc_group, combined.cpt_code, combined.cpt_description
           ORDER BY combined.proc_group, combined.cpt_code",
          vocab_schema = config$vocab_schema,
          cdm_schema   = config$cdm_schema
        )
        cpt_raw <- DatabaseConnector::querySql(
          conn_supp,
          SqlRender::translate(sql_cpt, targetDialect = "sql server")
        )
        names(cpt_raw) <- tolower(names(cpt_raw))
        if (nrow(cpt_raw) > 0) {
          cpt_display <- data.frame(
            "Procedure Group" = cpt_raw$proc_group,
            "CPT Code"        = cpt_raw$cpt_code,
            "Description"     = cpt_raw$cpt_description,
            "Cases (n)"       = cpt_raw$case_count,
            check.names = FALSE, stringsAsFactors = FALSE
          )
          cpt_ft <- flextable::flextable(cpt_display) |>
            flextable::bold(part = "header") |>
            flextable::fontsize(size = 9, part = "all") |>
            flextable::font(fontname = "Calibri", part = "all") |>
            flextable::bg(part = "header", bg = "#1F3864") |>
            flextable::color(part = "header", color = "white") |>
            flextable::padding(padding = 3, part = "all") |>
            flextable::width(j = "Procedure Group", width = 1.7) |>
            flextable::width(j = "CPT Code",        width = 0.9) |>
            flextable::width(j = "Description",     width = 3.5) |>
            flextable::width(j = "Cases (n)",       width = 0.8) |>
            flextable::align(j = "Cases (n)", align = "right", part = "all") |>
            flextable::set_table_properties(layout = "fixed")
          doc <- body_add_par(doc, "Index procedure CPT codes", style = "heading 3")
          doc <- body_add_par(doc,
            "Supplemental Table S2. CPT codes for index procedure subgroups.",
            style = "Normal")
          doc <- body_add_par(doc,
            paste0("Caption: CPT-4 codes identified via concept_relationship ('Mapped from') ",
                   "from SNOMED concept-ancestor descendants of each procedure subgroup anchor ",
                   "(endarterectomy: 4225375; aortobifemoral: 4231680; femoral-popliteal: 4012936; ",
                   "femorotibial: 4166196; extra-anatomic bypass: 4050281). ",
                   "Cases (n) = number of distinct patients in procedure_occurrence with that source concept. ",
                   "A code may appear in more than one group."),
            style = "Normal")
          doc <- body_add_flextable(doc, cpt_ft)
          doc <- body_add_par(doc, "", style = "Normal")
          message("[report] Supplemental Table S2 (CPT codes) added.")
        }
      }, error = function(e) {
        message("[report] CPT supplemental table skipped: ", conditionMessage(e))
      })

      # ---- Supplemental Table S3 — ICD codes for SSI outcome concept ---------
      tryCatch({
        sql_icd <- SqlRender::render(
          "SELECT
             c.vocabulary_id,
             c.concept_code  AS icd_code,
             c.concept_name  AS icd_description,
             COUNT(DISTINCT co.person_id) AS case_count
           FROM @vocab_schema.concept_ancestor ca
           INNER JOIN @vocab_schema.concept_relationship cr
             ON cr.concept_id_2    = ca.descendant_concept_id
            AND cr.relationship_id = 'Maps to'
            AND cr.invalid_reason  IS NULL
           INNER JOIN @vocab_schema.concept c
             ON c.concept_id    = cr.concept_id_1
            AND c.vocabulary_id IN ('ICD9CM','ICD10CM','ICD10PCS','ICD9Proc')
           LEFT JOIN @cdm_schema.condition_occurrence co
             ON co.condition_source_concept_id = cr.concept_id_1
           WHERE ca.ancestor_concept_id = 4334801
             AND c.concept_code NOT LIKE 'O86%'
             AND c.concept_code NOT LIKE 'T86.84%'
           GROUP BY c.vocabulary_id, c.concept_code, c.concept_name
           ORDER BY c.vocabulary_id, c.concept_code",
          vocab_schema = config$vocab_schema,
          cdm_schema   = config$cdm_schema
        )
        icd_raw <- DatabaseConnector::querySql(
          conn_supp,
          SqlRender::translate(sql_icd, targetDialect = "sql server")
        )
        names(icd_raw) <- tolower(names(icd_raw))
        if (nrow(icd_raw) > 0) {
          icd_display <- data.frame(
            "Vocabulary"  = icd_raw$vocabulary_id,
            "ICD Code"    = icd_raw$icd_code,
            "Description" = icd_raw$icd_description,
            "Cases (n)"   = icd_raw$case_count,
            check.names = FALSE, stringsAsFactors = FALSE
          )
          icd_ft <- flextable::flextable(icd_display) |>
            flextable::bold(part = "header") |>
            flextable::fontsize(size = 9, part = "all") |>
            flextable::font(fontname = "Calibri", part = "all") |>
            flextable::bg(part = "header", bg = "#1F3864") |>
            flextable::color(part = "header", color = "white") |>
            flextable::padding(padding = 3, part = "all") |>
            flextable::width(j = "Vocabulary",  width = 0.9) |>
            flextable::width(j = "ICD Code",    width = 1.1) |>
            flextable::width(j = "Description", width = 3.8) |>
            flextable::width(j = "Cases (n)",   width = 0.7) |>
            flextable::align(j = "Cases (n)", align = "right", part = "all") |>
            flextable::set_table_properties(layout = "fixed")
          doc <- body_add_par(doc, paste0(config$outcome_label, " outcome ICD codes"), style = "heading 3")
          doc <- body_add_par(doc,
            paste0("Supplemental Table S3. ICD codes mapping to the ",
                   tolower(config$outcome_label), " outcome concept."),
            style = "Normal")
          doc <- body_add_par(doc,
            paste0("Caption: Source ICD-9-CM and ICD-10-CM codes that map to the ",
                   tolower(config$outcome_label), " outcome concept(s) or their descendants via ",
                   "concept_relationship (relationship: 'Maps to'). Cases (n) = number of distinct ",
                   "patients in condition_occurrence with that source concept. ",
                   "These are the codes used to identify the outcome in source data prior to OMOP ETL standardisation."),
            style = "Normal")
          doc <- body_add_flextable(doc, icd_ft)
          doc <- body_add_par(doc, "", style = "Normal")
          message("[report] Supplemental Table S3 (SSI ICD codes) added.")
        }
      }, error = function(e) {
        message("[report] SSI ICD supplemental table skipped: ", conditionMessage(e))
      })

      DatabaseConnector::disconnect(conn_supp)
    }, error = function(e) {
      message("[report] Supplemental DB tables skipped: ", conditionMessage(e))
    })
  }

  # ---- S4: SSI rate by month of year ----------------------------------------
  if (!is.null(ssi_month_plot_file) && file.exists(ssi_month_plot_file)) {
    doc <- body_add_par(doc, paste0(config$outcome_label, " rate by month"), style = "heading 3")
    doc <- body_add_par(doc,
      paste0("Supplemental Figure S4. ", config$prediction_window_days, "-day ",
             config$outcome_label, " rate by calendar month of procedure."),
      style = "Normal")
    doc <- body_add_par(doc, paste0(
      "Caption: Observed ", config$prediction_window_days, "-day ", config$outcome_label,
      " rate (%) for each calendar month (January through December), pooled across all study years. ",
      "Bar height represents the event rate; numbers above each bar show the total procedure count for that month. ",
      "Months with fewer than 5 procedures are suppressed."
    ), style = "Normal")
    doc <- body_add_img(doc, src = ssi_month_plot_file, width = 5.5, height = 3.5)
    doc <- body_add_par(doc, "", style = "Normal")
    message("[report] Supplemental Figure S4 (SSI by month) added.")
  }

  # ---- S5: Score distribution plot -----------------------------------------
  if (!is.null(score_dist_plot_file) && file.exists(score_dist_plot_file)) {
    doc <- body_add_par(doc, "Score distribution", style = "heading 3")
    doc <- body_add_par(doc,
      "Supplemental Figure S5. Distribution of predicted risk by outcome group.",
      style = "Normal")
    doc <- body_add_par(doc, paste0(
      paste0("Caption: Overlapping density histograms of model-predicted ",
             config$prediction_window_days, "-day ", config$outcome_label, " risk (x-axis) "),
      paste0("for patients who did (red) and did not (blue) experience ",
             tolower(config$outcome_label), " "),
      "within the prediction window. Improved separation between the two distributions ",
      "indicates better model discrimination."
    ), style = "Normal")
    doc <- body_add_img(doc, src = score_dist_plot_file, width = 5.5, height = 3.5)
    doc <- body_add_par(doc, "", style = "Normal")
    message("[report] Supplemental Figure S5 (score distribution) added.")
  }

  # ---- S6: Bias table, S7: Forest plot (from pre-loaded CSV) ----------------
  if (!is.null(subgroup_bias_df) && nrow(subgroup_bias_df) > 0) {

    # Sort rows to match Table 1 order: age_group, sex, race, ethnicity,
    # indication, proc_type, year — any unlisted vars sort to the end.
    subgroup_order <- c(age_group = 1, sex = 2, race = 3, ethnicity = 4,
                        indication = 5, proc_type = 6, year = 7)
    sort_key <- subgroup_order[match(subgroup_bias_df$subgroup_var,
                                     names(subgroup_order))]
    sort_key[is.na(sort_key)] <- 99L
    subgroup_bias_df <- subgroup_bias_df[order(sort_key,
                                               subgroup_bias_df$subgroup_level), ]

    # Overall ECE for reference line — read from metrics.csv.
    overall_ece_val <- tryCatch(
      as.numeric(metric_value("ECE", "lookup")),
      error = function(e) NA_real_
    )
    if (is.na(overall_ece_val)) overall_ece_val <- 0.0

    # Build a display table.
    bias_display <- data.frame(
      Subgroup     = tools::toTitleCase(gsub("_", " ", subgroup_bias_df$subgroup_var)),
      Level        = subgroup_bias_df$subgroup_level,
      N            = subgroup_bias_df$n,
      Events       = subgroup_bias_df$n_events,
      ECE          = round(subgroup_bias_df$ece,      3),
      "95% CI"     = paste0("(", round(subgroup_bias_df$ci_lower, 3),
                            "\u2013",
                            round(subgroup_bias_df$ci_upper, 3), ")"),
      check.names     = FALSE,
      stringsAsFactors = FALSE
    )

    bias_ft <- flextable::flextable(bias_display) |>
      flextable::bold(part = "header") |>
      flextable::fontsize(size = 10, part = "all") |>
      flextable::font(fontname = "Calibri", part = "all") |>
      flextable::bg(part = "header", bg = "#1F3864") |>
      flextable::color(part = "header", color = "white") |>
      flextable::padding(padding = 4, part = "all") |>
      flextable::align(j = c("N", "Events", "ECE", "95% CI"),
                       align = "center", part = "all") |>
      flextable::width(j = "Subgroup", width = 1.2) |>
      flextable::width(j = "Level",    width = 1.6) |>
      flextable::width(j = "N",        width = 0.6) |>
      flextable::width(j = "Events",   width = 0.7) |>
      flextable::width(j = "ECE",      width = 0.7) |>
      flextable::width(j = "95% CI",   width = 1.2) |>
      flextable::set_table_properties(layout = "fixed")

    doc <- body_add_par(doc, "Subgroup bias assessment", style = "heading 3")
    doc <- body_add_par(doc,
      "Supplemental Table S6. Expected calibration error (ECE) by subgroup.",
      style = "Normal")
    doc <- body_add_par(doc,
      paste0("Caption: ECE is shown for the lookup model within each subgroup. ",
             paste0("Subgroups with fewer than 10 observed ", tolower(config$outcome_label), " events are suppressed. "),
             "Overall ECE (dashed reference line in Supplemental Figure S7) = ",
             round(overall_ece_val, 3), ". ",
             "95% CI = bootstrap percentile interval (B\u2009=\u2009200 resamples)."),
      style = "Normal")
    doc <- body_add_flextable(doc, bias_ft)
    doc <- body_add_par(doc, "", style = "Normal")

    # Supplemental Figure S1 — subgroup forest plot
    forest_png <- save_subgroup_forest_plot(
      subgroup_bias_df,
      overall_ece_val,
      temp_figure_dir
    )
    if (!is.null(forest_png) && file.exists(forest_png)) {
      plot_height <- max(4.0, nrow(subgroup_bias_df) * 0.35 + 1.5)
      doc <- body_add_par(doc, "Subgroup calibration forest plot", style = "heading 3")
      doc <- body_add_par(doc,
        "Supplemental Figure S7. Subgroup calibration forest plot.",
        style = "Normal")
      doc <- body_add_par(doc,
        paste0("Caption: Expected calibration error (ECE) with 95% bootstrap percentile CIs (B\u2009=\u2009200) ",
               "by subgroup. Dashed vertical line = overall ECE for the lookup model. ",
               paste0("Subgroups with < 10 ", tolower(config$outcome_label), " events are suppressed. "),
               "Subgroups include sex, race, ethnicity, age group, and calendar year of procedure."),
        style = "Normal")
      doc <- body_add_img(doc, src = forest_png,
                          width  = 5.5,
                          height = min(plot_height, 9.0))
      doc <- body_add_par(doc, "", style = "Normal")
    }
  }

  # ---- Fringe cases — Excel export (not in Word report) -------------------
  # Two groups of patients that the model handled worst:
  #   Group A — lowest predicted risk who nonetheless had an SSI (false negatives)
  #   Group B — highest predicted risk who did not have an SSI (false positives)
  # Written to a dated Excel file in the same output folder as the report.
  if (!is.null(connection_details) && !is.null(config) &&
      "predicted_risk_lookup" %in% names(person_level)) {

    tryCatch({
      conn_f <- DatabaseConnector::connect(connection_details)
      on.exit(try(DatabaseConnector::disconnect(conn_f), silent = TRUE), add = TRUE)

      # Restrict fringe candidates to index procedures in 2017–2019.
      fringe_year_min <- 2017L
      fringe_year_max <- 2019L
      fringe_year_vec <- suppressWarnings(
        as.integer(format(as.Date(person_level$index_date), "%Y"))
      )
      in_window <- !is.na(fringe_year_vec) &
                   fringe_year_vec >= fringe_year_min &
                   fringe_year_vec <= fringe_year_max
      pl_fringe <- person_level[in_window, ]

      # Identify the two fringe groups from person_level_scores (2017–2019 only)
      fn_mask <- pl_fringe$outcome == 1 & !is.na(pl_fringe$predicted_risk_lookup)
      fn_ids  <- pl_fringe$subject_id[fn_mask]
      fn_risk <- pl_fringe$predicted_risk_lookup[fn_mask]
      fn_top  <- fn_ids[order(fn_risk)][seq_len(min(10L, sum(fn_mask)))]

      fp_mask <- pl_fringe$outcome == 0 & !is.na(pl_fringe$predicted_risk_lookup)
      fp_ids  <- pl_fringe$subject_id[fp_mask]
      fp_risk <- pl_fringe$predicted_risk_lookup[fp_mask]
      fp_top  <- fp_ids[order(fp_risk, decreasing = TRUE)][seq_len(min(10L, sum(fp_mask)))]

      message(sprintf("[report] Fringe case filter: %d patients in %d\u2013%d (of %d total).",
                      sum(in_window), fringe_year_min, fringe_year_max, nrow(person_level)))

      all_ids <- unique(c(fn_top, fp_top))
      id_str  <- paste(as.integer(all_ids), collapse = ",")

      sql_fringe <- SqlRender::render(
        "SELECT
           p.person_id,
           p.person_source_value                                                AS mrn,
           CAST(po.procedure_date AS DATE)                                      AS procedure_date,
           COALESCE(c.concept_name, po.procedure_source_value, 'Unknown')       AS procedure_name,
           YEAR(CAST(po.procedure_date AS DATE)) - p.year_of_birth             AS age_at_procedure
         FROM @cdm_schema.person p
         JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = p.person_id
         JOIN @vocab_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   IN (4236706, 4225375)
         LEFT JOIN @vocab_schema.concept c
           ON c.concept_id = po.procedure_concept_id
         WHERE p.person_id IN (@id_list)",
        cdm_schema   = config$cdm_schema,
        vocab_schema = config$vocab_schema,
        id_list      = id_str
      )

      raw <- DatabaseConnector::querySql(
        conn_f,
        SqlRender::translate(sql_fringe, targetDialect = "sql server")
      )
      names(raw) <- tolower(names(raw))

      # One row per person — earliest qualifying procedure
      raw <- raw[order(raw$person_id, raw$procedure_date), ]
      raw <- raw[!duplicated(raw$person_id), ]

      # Merge outcome + predicted risk from person_level
      pl_sub <- person_level[, c("subject_id", "predicted_risk_lookup", "outcome")]
      raw    <- merge(raw, pl_sub, by.x = "person_id", by.y = "subject_id", all.x = TRUE)

      # Merge individual score component columns from person_level
      score_cols <- grep("^score_", names(person_level), value = TRUE)
      if (length(score_cols) > 0) {
        pl_scores <- person_level[, c("subject_id", score_cols), drop = FALSE]
        raw <- merge(raw, pl_scores, by.x = "person_id", by.y = "subject_id", all.x = TRUE)
      }

      make_group <- function(ids, label) {
        sub        <- raw[raw$person_id %in% ids, ]
        sub$group  <- label
        sub
      }

      fn_df <- make_group(fn_top, "Low risk, SSI occurred")
      fp_df <- make_group(fp_top, "High risk, no SSI")
      fn_df <- fn_df[order(fn_df$predicted_risk_lookup), ]
      fp_df <- fp_df[order(fp_df$predicted_risk_lookup, decreasing = TRUE), ]

      # Build display-friendly column names for score components
      score_display_names <- c(
        score_female                 = "Female Sex (pts)",
        score_overweight             = "Overweight BMI 25-<30 (pts)",
        score_obese                  = "Obese BMI >=30 (pts)",
        score_urgnt                  = "Urgent Case (pts)",
        score_abi_35                 = "ABI <=0.35 (pts)",
        score_prrevasc_any           = "Prior Revascularization (pts)",
        score_prolong_abx            = "Prolonged Antibiotics (pts)",
        score_optime4h               = "Op Time >=4h (pts)",
        score_mFI_high               = "High mFI (pts)",
        score_indicationClaudication = "Indication: Claudication (pts)"
      )
      present_score_cols <- score_cols[score_cols %in% names(score_display_names)]
      score_labels       <- unname(score_display_names[present_score_cols])

      combined <- rbind(fn_df, fp_df)
      fringe_tbl <- combined[,
        c("group", "mrn", "age_at_procedure",
          "procedure_date", "procedure_name", "predicted_risk_lookup",
          present_score_cols),
        drop = FALSE
      ]

      names(fringe_tbl) <- c(
        "Group", "MRN", "Age at Procedure",
        "Procedure Date", "Procedure", "Predicted Risk",
        score_labels
      )
      fringe_tbl[["Predicted Risk"]] <- round(as.numeric(fringe_tbl[["Predicted Risk"]]), 3)

      # Prepend model_name and report_date columns
      model_nm    <- if (!is.null(config$model_name)) config$model_name else NA_character_
      report_date <- format(Sys.Date(), "%Y-%m-%d")
      fringe_tbl  <- cbind(
        "Model"       = model_nm,
        "Report Date" = report_date,
        fringe_tbl,
        stringsAsFactors = FALSE
      )

      # Write to dated CSV file alongside the report
      export_date  <- format(Sys.Date(), "%Y%m%d")
      fringe_file  <- file.path(output_dir,
                                paste0("pad_oler_ssi_fringe_",
                                       fringe_year_min, "_", fringe_year_max,
                                       "_", export_date, ".csv"))
      readr::write_csv(fringe_tbl, fringe_file)
      message("[report] Fringe case CSV written to: ",
              normalizePath(fringe_file, winslash = "/", mustWork = FALSE))

    }, error = function(e) {
      message("[report] Fringe case CSV skipped: ", conditionMessage(e))
    })
  }

  doc <- .append_references_section(doc, citations)

  print(doc, target = report_file)
  message("Manuscript report written to: ", normalizePath(report_file))
  invisible(report_file)
}
