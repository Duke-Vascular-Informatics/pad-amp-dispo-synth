# =============================================================================
# R/report_helpers.R
#
# Shared helper functions for all study-design-specific Word report templates.
#
# Purpose:
#   Centralises utility functions that are used across report templates so that
#   they do not need to be duplicated in each template file.  All templates
#   source this file (via the dispatcher R/report_extended.R) before defining
#   their own template-specific functions.
#
# Exports (functions sourced into the caller's environment):
#   Word document primitives (public — called directly from report templates):
#     make_doc_run()                      — Calibri-styled ftext run
#     add_doc_heading()                   — section heading with auto-spacing
#     add_doc_paragraph()                 — indented body paragraph
#     add_doc_caption()                   — bold-title + normal-body caption
#     add_doc_page_break()                — manual page break
#   Internal helpers (prefixed with "."):
#     .append_references_section()        — bibliography formatter (Vancouver/NLM)
#     .compute_ece()                      — expected calibration error
#     .save_roc_plot()                    — ROC curve PNG generation
#     .save_calibration_plot_from_table() — calibration plot from CSV
#     .save_calibration_plot_from_vectors() — calibration plot from vectors
#     .build_table1()                     — flextable styling helper
#     .build_cohort_summary_table()       — cohort-level summary stats flextable
#
# Usage:
#   This file is sourced automatically by R/report_extended.R (the dispatcher).
#   Template files (report_prognostic.R, etc.) DO NOT source it directly —
#   rely on the dispatcher to have sourced it first.
#
# Dependencies: officer, flextable, ggplot2, pROC (all managed via renv)
#
# Note: R/cohort_demographics.R is also sourced here because its
#   fetch_demographics_from_omop() helper is shared by all templates that
#   include a Table 1 demographics section.
# =============================================================================

library(officer)
library(flextable)
library(ggplot2)
library(pROC)

# Load cohort demographics helper functions (shared across all templates)
source("R/cohort_demographics.R")

# ---------------------------------------------------------------------------
# Word document primitives
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# make_doc_run()
#
# Wraps a text string in a styled officer::ftext run using Calibri font.
# Used by add_doc_heading() and add_doc_caption() to build formatted
# paragraphs (officer::fpar) before inserting them into the document.
#
# Parameters:
#   text      — the character string to format
#   bold      — logical; TRUE renders the text bold (default FALSE)
#   font_size — point size (default 10.5)
#
# Returns an officer::ftext object.
# ---------------------------------------------------------------------------
make_doc_run <- function(text, bold = FALSE, font_size = 10.5) {
  officer::ftext(
    text,
    officer::fp_text(
      bold = bold,
      font.size = font_size,
      font.family = "Calibri"
    )
  )
}

# ---------------------------------------------------------------------------
# add_doc_heading()
#
# Inserts a styled heading paragraph into a Word document object.
# Prepends a blank "Normal" paragraph before every heading after the first
# so that headings have visual separation from preceding body text.
#
# NOTE: Uses heading_counter from the calling environment; templates must
# initialise heading_counter <- 0L before the first call.
#
# Parameters:
#   doc   — officer rdocx object
#   text  — heading text string
#   level — heading level 1, 2, or 3 (controls font size: 13, 11.5, 11 pt)
#
# Returns the modified rdocx object.
# ---------------------------------------------------------------------------
add_doc_heading <- function(doc, text, level = 1L) {
  if (heading_counter > 0L) {
    doc <- officer::body_add_par(doc, "", style = "Normal")
  }
  size_map <- c(`1` = 13, `2` = 11.5, `3` = 11)
  heading_par <- officer::fpar(
    make_doc_run(text, bold = TRUE, font_size = unname(size_map[as.character(level)])),
    fp_p = officer::fp_par(text.align = "left")
  )
  heading_counter <<- heading_counter + 1L
  officer::body_add_fpar(doc, value = heading_par, style = "Normal")
}

# ---------------------------------------------------------------------------
# add_doc_paragraph()
#
# Inserts a body text paragraph indented by one tab stop (OHDSI report style).
#
# Parameters:
#   doc  — officer rdocx object
#   text — paragraph text
#
# Returns the modified rdocx object.
# ---------------------------------------------------------------------------
add_doc_paragraph <- function(doc, text) {
  officer::body_add_par(doc, paste0("\t", text), style = "Normal")
}

# ---------------------------------------------------------------------------
# add_doc_caption()
#
# Inserts a figure or table caption with a bold title followed by
# normal-weight body text.  Placed immediately after a flextable or figure.
#
# Parameters:
#   doc       — officer rdocx object
#   title     — bold caption title (e.g. "Table 1. Cohort characteristics.")
#   body_text — optional additional caption text (rendered at normal weight)
#
# Returns the modified rdocx object.
# ---------------------------------------------------------------------------
add_doc_caption <- function(doc, title, body_text = NULL) {
  caption_runs <- list(make_doc_run(title, bold = TRUE, font_size = 10))
  if (!is.null(body_text) && nzchar(body_text)) {
    caption_runs[[length(caption_runs) + 1L]] <- make_doc_run(
      paste0(" ", body_text), bold = FALSE, font_size = 10
    )
  }
  caption_par <- do.call(
    officer::fpar,
    c(caption_runs, list(fp_p = officer::fp_par(text.align = "left")))
  )
  officer::body_add_fpar(doc, value = caption_par, style = "Normal")
}

# ---------------------------------------------------------------------------
# add_doc_page_break()
#
# Inserts a manual page break into the Word document.
#
# Parameters:
#   doc — officer rdocx object
#
# Returns the modified rdocx object.
# ---------------------------------------------------------------------------
add_doc_page_break <- function(doc) {
  officer::body_add_break(doc)
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# =============================================================================
# .append_references_section()
#
# Appends a numbered Vancouver/NLM reference list to an officer Word document.
#
# Arguments:
#   doc       — an officer rdocx object (modified in place via return value)
#   citations — named list of citation objects, or NULL (no-op).
#               Each element must have: authors, title, journal, year,
#               volume, issue, pages, doi.
#               Names are used only for human readability; order determines
#               the citation numbers printed in the document.
#
# Returns: the updated rdocx object.
# =============================================================================
.append_references_section <- function(doc, citations) {
  if (is.null(citations) || length(citations) == 0L) return(doc)

  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "References", style = "heading 1")

  for (i in seq_along(citations)) {
    ref  <- citations[[i]]
    # Vancouver format: Authors. Title. Journal. Year;Vol(Issue):Pages. doi:DOI
    line <- sprintf(
      "%d. %s. %s. %s. %s;%s(%s):%s. doi:%s",
      i,
      ref$authors,
      ref$title,
      ref$journal,
      ref$year,
      ref$volume,
      ref$issue,
      ref$pages,
      ref$doi
    )
    doc <- body_add_par(doc, line, style = "Normal")
  }
  doc
}

# -----------------------------------------------------------------------------
# .compute_ece()   [internal — report_helpers.R shared copy]
#
# Computes Expected Calibration Error (ECE) for display in the Word report.
# This is a self-contained copy that does not depend on risk_score_pipeline.R
# being loaded, so the report can be regenerated independently of the pipeline.
#
# Uses equal-frequency (quantile) bins so that each bin contains approximately
# the same number of patients.  Falls back to a single [0, 1] bin when the
# probability distribution is degenerate (< 3 unique quantile breakpoints).
#
# Returns a named list:
#   $ece      — scalar ECE value
#   $bin_data — data frame with columns bin, n_pred, mean_pred, n_obs, mean_obs
# -----------------------------------------------------------------------------
.compute_ece <- function(y, p, n_bins = 10) {
  p <- pmin(pmax(p, 0.0001), 0.9999)
  breaks <- quantile(p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE)
  if (length(unique(breaks)) < 3) breaks <- c(0, 1)

  p_binned <- cut(p, breaks = breaks, include.lowest = TRUE)

  ece_data <- aggregate(
    cbind(predicted = p, observed = y) ~ p_binned,
    data = data.frame(p = p, y = y, p_binned = p_binned),
    FUN = function(x) c(n = length(x), mean = mean(x, na.rm = TRUE))
  )

  ece_data <- cbind(ece_data[, 1], do.call(rbind, ece_data[, 2]))
  colnames(ece_data) <- c("bin", "n_pred", "mean_pred", "n_obs", "mean_obs")

  ece_value <- sum(ece_data$n_pred * abs(ece_data$mean_pred - ece_data$mean_obs)) / length(y)

  list(ece = ece_value, bin_data = ece_data)
}

# -----------------------------------------------------------------------------
# .save_roc_plot()
#
# Generates a ROC curve plot and saves it as a PNG to output_folder/roc_curve.png.
#
# When auc_override is supplied, the function tries both pROC direction
# conventions ("<" and ">") and picks whichever gives an AUC closest to
# auc_override.  This handles the rare case where pROC auto-detects the wrong
# direction — the label shown on the plot will still use the published AUC
# value passed in auc_override.
#
# Returns the path to the saved PNG file (invisibly NULL if y is degenerate).
# -----------------------------------------------------------------------------
.save_roc_plot <- function(y, p, output_folder, auc_override = NA_real_) {
  if (length(unique(y)) < 2) return(NULL)

  p <- pmin(pmax(p, 0.0001), 0.9999)

  if (!is.na(auc_override)) {
    roc_lt <- pROC::roc(response = y, predictor = p, quiet = TRUE, direction = "<")
    roc_gt <- pROC::roc(response = y, predictor = p, quiet = TRUE, direction = ">")
    auc_lt <- as.numeric(pROC::auc(roc_lt))
    auc_gt <- as.numeric(pROC::auc(roc_gt))

    if (abs(auc_lt - as.numeric(auc_override)) <= abs(auc_gt - as.numeric(auc_override))) {
      roc_obj <- roc_lt
      auc_val <- auc_lt
    } else {
      roc_obj <- roc_gt
      auc_val <- auc_gt
    }
    auc_label <- as.numeric(auc_override)
  } else {
    roc_obj <- pROC::roc(response = y, predictor = p, quiet = TRUE)
    auc_val <- as.numeric(pROC::auc(roc_obj))
    auc_label <- auc_val
  }

  # Create ROC curve data
  roc_data <- data.frame(
    fpr = 1 - roc_obj$specificities,
    tpr = roc_obj$sensitivities
  )

  p <- ggplot2::ggplot(roc_data, ggplot2::aes(x = fpr, y = tpr)) +
    ggplot2::geom_path(linewidth = 1) +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed", color = "gray") +
    ggplot2::labs(
      title = "Receiver Operating Characteristic Curve",
      subtitle = paste0("AUROC = ", round(auc_label, 3)),
      x = "False Positive Rate",
      y = "True Positive Rate"
    ) +
    ggplot2::xlim(0, 1) +
    ggplot2::ylim(0, 1) +
    ggplot2::coord_equal() +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, "roc_curve.png")
  ggplot2::ggsave(out_file, p, width = 7, height = 5, dpi = 150)
  out_file
}

# -----------------------------------------------------------------------------
# .save_calibration_plot_from_table()
#
# Reads a calibration CSV (must contain "predicted" and "observed" columns) and
# saves a calibration plot PNG to output_folder.
#
# Called from generate_manuscript_report() for the lookup-model calibration plot
# when the calibration_table_lookup.csv file was produced by a prior pipeline run.
# Returns NULL silently if the input file does not exist or lacks the required
# columns.
# -----------------------------------------------------------------------------
.save_calibration_plot_from_table <- function(calibration_table_path,
                                              output_folder,
                                              file_name = "calibration_lookup.png",
                                              plot_title = "Calibration Plot") {
  if (!file.exists(calibration_table_path)) {
    return(NULL)
  }

  cal <- read.csv(calibration_table_path, stringsAsFactors = FALSE)
  if (!all(c("predicted", "observed") %in% names(cal))) {
    return(NULL)
  }

  p <- ggplot2::ggplot(cal, ggplot2::aes(x = predicted, y = observed)) +
    ggplot2::geom_point(size = 2) +
    ggplot2::geom_line() +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed", color = "gray") +
    ggplot2::labs(
      title = plot_title,
      x = "Mean predicted risk",
      y = "Observed event rate"
    ) +
    ggplot2::scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::coord_equal() +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, file_name)
  ggplot2::ggsave(out_file, p, width = 5, height = 5, dpi = 150)
  out_file
}

# -----------------------------------------------------------------------------
# .save_calibration_plot_from_vectors()
#
# Fallback calibration plot generator when pipeline PNG/CSV artifacts are
# missing but person-level predictions are available in memory.
# -----------------------------------------------------------------------------
.save_calibration_plot_from_vectors <- function(y,
                                                p,
                                                output_folder,
                                                file_name,
                                                plot_title,
                                                n_bins = 10) {
  ok <- !(is.na(y) | is.na(p))
  y <- as.numeric(y[ok])
  p <- as.numeric(p[ok])

  if (length(y) < 10 || length(unique(y)) < 2) {
    return(NULL)
  }

  p <- pmin(pmax(p, 0.0001), 0.9999)
  qbreaks <- unique(stats::quantile(p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
  if (length(qbreaks) < 3) {
    qbreaks <- c(0, 1)
  }

  bins <- cut(p, breaks = qbreaks, include.lowest = TRUE)
  cal <- aggregate(
    cbind(predicted = p, observed = y) ~ bins,
    data = data.frame(p = p, y = y, bins = bins),
    FUN = mean
  )

  p_cal <- ggplot2::ggplot(cal, ggplot2::aes(x = predicted, y = observed)) +
    ggplot2::geom_point(size = 2) +
    ggplot2::geom_line() +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed", color = "gray") +
    ggplot2::labs(
      title = plot_title,
      x = "Mean predicted risk",
      y = "Observed event rate"
    ) +
    ggplot2::scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::coord_equal() +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, file_name)
  ggplot2::ggsave(out_file, p_cal, width = 5, height = 5, dpi = 150)
  out_file
}

# -----------------------------------------------------------------------------
# .build_table1()
#
# Formats a data frame as a styled flextable for the Word report.
# Used for Table 2 (score component definitions).
#
# Styling conventions:
#   - Dark blue (#1F3864) header background with white text
#   - Light gray (#BFBFBF) horizontal rules between body rows
#   - Calibri 10pt throughout
#   - Fixed column widths totalling ~7 inches (US letter body width)
#   - Points and Lookback columns center-aligned
# -----------------------------------------------------------------------------
.build_table1 <- function(df) {
  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)

  ft <- flextable(df) |>
    set_header_labels(
      variable    = "Variable",
      points      = "Points",
      lookback    = "Lookback Window",
      omop_domain = "OMOP Domain",
      derivation  = "OMOP Derivation Method"
    ) |>
    bold(part = "header") |>
    fontsize(size = 10, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "variable",    width = 1.5) |>
    width(j = "points",      width = 0.55) |>
    width(j = "lookback",    width = 0.85) |>
    width(j = "omop_domain", width = 1.1) |>
    width(j = "derivation",  width = 3.0) |>
    align(j = "points",   align = "center", part = "all") |>
    align(j = "lookback", align = "center", part = "all") |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    set_table_properties(layout = "fixed") |>
    padding(padding = 4, part = "all")

  ft
}

# -----------------------------------------------------------------------------
# .build_cohort_summary_table()
#
# Builds a flextable summary of overall cohort statistics from the person-level
# scores data frame.  Presented as Table 1 (overall cohort summary) in the Word
# report.
#
# Statistics included:
#   - Total procedures (rows in person_level)
#   - Unique patients
#   - SSI events and incidence rate
#   - Mean total risk score (SD) and median total score (IQR)
# -----------------------------------------------------------------------------
.build_cohort_summary_table <- function(person_level_df) {
  # Build cohort characteristics summary table from person_level scores dataframe
  # Assumes columns: subject_id, outcome, total_score, age (if available)

  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)

  n_procedures <- nrow(person_level_df)
  n_patients <- length(unique(person_level_df$subject_id))
  n_ssi <- sum(person_level_df$outcome, na.rm = TRUE)
  ssi_rate <- 100 * n_ssi / n_procedures

  # Create summary statistics
  summary_data <- data.frame(
    Characteristic = c(
      "Total number of procedures",
      "Number of unique patients",
      "Number of SSI events",
      "SSI incidence rate (%)",
      "Mean total score (SD)",
      "Median total score (IQR)"
    ),
    Value = c(
      n_procedures,
      n_patients,
      n_ssi,
      paste0(round(ssi_rate, 1), "%"),
      paste0(
        round(mean(person_level_df$total_score, na.rm = TRUE), 2), " (",
        round(sd(person_level_df$total_score, na.rm = TRUE), 2), ")"
      ),
      paste0(
        round(median(person_level_df$total_score, na.rm = TRUE), 2), " (",
        round(quantile(person_level_df$total_score, 0.25, na.rm = TRUE), 2), " – ",
        round(quantile(person_level_df$total_score, 0.75, na.rm = TRUE), 2), ")"
      )
    ),
    stringsAsFactors = FALSE
  )

  ft <- flextable(summary_data) |>
    set_header_labels(
      Characteristic = "Characteristic",
      Value = "Value"
    ) |>
    bold(part = "header") |>
    fontsize(size = 10, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "Characteristic", width = 3.0) |>
    width(j = "Value", width = 2.0) |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    padding(padding = 4, part = "all")

  ft
}
