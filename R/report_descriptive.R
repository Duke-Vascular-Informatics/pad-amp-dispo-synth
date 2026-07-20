# =============================================================================
# R/report_descriptive.R
#
# Word manuscript report template for study_design = "descriptive".
#
# Reads the CSV/PNG artifacts written by
# scripts/analysis/descriptive_ed_analysis.R (output_dir/descriptive/) and
# assembles a single cohesive .docx report at output_dir/<project>_report_<date>.docx,
# following the same conventions as R/report_prognostic.R (Calibri styling,
# dark-blue/gray flextable theme, dated filename with automatic archiving of
# prior reports to output_dir/archive/).
#
# Entry point: .report_descriptive(output_dir, connection_details, config)
#
# Sections:
#   1. Executive summary
#   2. Methods (study population, outcome definition, VA-FI, statistics,
#      predicted-probability derivation, temporal train/test split)
#   3. Table 1 — cohort characteristics (demographics incl. tobacco; indication;
#      race; amputation characteristics incl. index LOS/non-home discharge
#      stratified by ED visit; VA-FI score summary only — individual deficits
#      are in Table 3)
#   4. Table 2a / Table 2b — ED visit rate/timing summary + diagnoses
#      associated with the ED visit, grouped into "Amputation complication",
#      per-VA-FI-component categories, and a single collapsed "Other" row
#      (full "Other" detail is in Supplemental Table S4); restricted to
#      primary-status diagnoses when condition_status_concept_id supports it
#      in the connected CDM, otherwise every linked diagnosis is tallied
#      (captions state which mode applied)
#   5. Figure 1 — histogram of ED visit timing by days from hospital discharge
#   6. Table 3 / Figure 2 — VA-FI component prevalence by ED status + OR
#      table + forest plot
#   7. Table 4 / Figure 3 — VA-FI discrimination and calibration (temporal
#      test-set evaluation)
#   References (if citations supplied) — precedes Supplemental Material
#   8. Supplemental Material — dataset description (Table S1), index
#      procedure CPT4/HCPCS crosswalk (Table S2, cohort-restricted), VA-FI
#      ICD-10-CM crosswalk (Table S3, all codes per component, cohort-restricted),
#      full per-diagnosis breakdown of Table 2b's "Other" category (Table S4)
#
# Discrimination/calibration use a chronological (by index_date) train/test
# split, mirroring pad-amp-nhd-val/R/risk_score_pipeline.R: the recalibration
# model is fit on the earlier half and every reported metric is evaluated on
# the later, held-out half only.
#
# Small-cell suppression (applies throughout every table in this report):
# any displayed nonzero patient count below SMALL_CELL_THRESHOLD (5) is
# replaced with "<5" -- the percentage is dropped for "n (pct%)" cells so a
# reader can't back-solve the exact count from a known denominator. Zero is
# never suppressed. Whole-cohort/stratum denominators (Table 1's "N" row,
# Supplemental S1's Study/Training/Test Set N) are left unsuppressed by
# design, consistent with standard practice of suppressing sub-group
# breakdowns, not overall Ns. See suppress_count()/suppress_pct_cell() below.
#
# Author/affiliation line is generated dynamically from the workspace
# ../contributors.yaml registry, filtered to contributors assigned to this
# repo (or "*"). Data source description dynamically reflects config$cdm_*
# fields and the live-queried CDM/vocabulary version.
#
# Gracefully skips any section whose source CSV/PNG is missing rather than
# failing the whole report — a partial pipeline run still produces a usable
# document.
# =============================================================================

.report_descriptive <- function(output_dir,
                                connection_details = NULL,
                                config             = NULL) {

  if (!exists("%||%", mode = "function")) `%||%` <- function(x, y) if (is.null(x)) y else x

  pipeline_dir <- file.path(output_dir, "descriptive")
  if (!dir.exists(pipeline_dir)) {
    stop(
      "[report_descriptive] No pipeline outputs found at '", pipeline_dir, "'.\n",
      "  Run the descriptive ED analysis (analyses.descriptive_ed_analysis: true ",
      "in study_params.yaml, Step 8) before generating the report."
    )
  }

  # ---- Read pipeline CSVs (each optional; section skipped if missing) --------
  # check.names = FALSE preserves human-readable headers exactly as written by
  # the pipeline (e.g. "ED visit (n=53)") -- the default check.names = TRUE
  # would mangle these into syntactic names like "ED.visit..n.53..".
  read_if_exists <- function(path) {
    if (file.exists(path)) read.csv(path, stringsAsFactors = FALSE, check.names = FALSE) else NULL
  }
  table1_df    <- read_if_exists(file.path(pipeline_dir, "table1.csv"))
  outcomes_df  <- read_if_exists(file.path(pipeline_dir, "outcomes_summary.csv"))
  ed_dx_df     <- read_if_exists(file.path(pipeline_dir, "ed_visit_diagnoses.csv"))
  ed_dx_category_totals_df <- read_if_exists(file.path(pipeline_dir, "ed_visit_diagnosis_category_totals.csv"))
  ed_dx_filter_mode_df <- read_if_exists(file.path(pipeline_dir, "ed_visit_diagnosis_filter_mode.csv"))
  ed_dx_primary_only <- !is.null(ed_dx_filter_mode_df) && nrow(ed_dx_filter_mode_df) > 0 &&
    identical(as.character(ed_dx_filter_mode_df$mode[1]), "primary_only")
  vafi_or_df   <- read_if_exists(file.path(pipeline_dir, "vafi_component_associations.csv"))
  vafi_disc_df <- read_if_exists(file.path(pipeline_dir, "vafi_discrimination.csv"))
  split_info_df <- read_if_exists(file.path(pipeline_dir, "split_info.csv"))
  icd_crosswalk_df <- read_if_exists(file.path(pipeline_dir, "vafi_icd_crosswalk.csv"))
  proc_codes_df    <- read_if_exists(file.path(pipeline_dir, "amputation_procedure_codes.csv"))

  hist_plot_path   <- file.path(pipeline_dir, "ed_visit_timing_histogram.png")
  forest_plot_path <- file.path(pipeline_dir, "vafi_forest_plot.png")
  cal_plot_path    <- file.path(pipeline_dir, "vafi_calibration_plot.png")

  # ---- Small-cell suppression -------------------------------------------------
  # Applied throughout this report to every displayed patient count: any
  # nonzero count below SMALL_CELL_THRESHOLD is replaced with "<N" rather
  # than shown exactly, to reduce re-identification risk. Zero is never
  # suppressed (it carries no identifying information). Scoped to actual
  # count cells only -- continuous summary rows (median [IQR]) are left
  # untouched, since suppress_pct_cell only matches the "n (pct%)" pattern
  # Table 1 uses for categorical rows.
  SMALL_CELL_THRESHOLD <- 5L

  # For a raw integer/numeric count vector (Table 2b, Supplemental S2-S4):
  suppress_count <- function(n, threshold = SMALL_CELL_THRESHOLD) {
    n_num <- suppressWarnings(as.numeric(n))
    out <- as.character(n)
    idx <- !is.na(n_num) & n_num > 0 & n_num < threshold
    out[idx] <- sprintf("<%d", threshold)
    out
  }

  # For a "n (pct%)" formatted cell (Table 1 categorical rows, Table 3
  # prevalence): drops the percentage when suppressing, since the pair could
  # otherwise let a reader back-solve the exact count from a known
  # denominator. Cells not matching this exact pattern (e.g. "median [IQR]"
  # rows, blank section headers, the "N" total row) pass through unchanged.
  suppress_pct_cell <- function(x, threshold = SMALL_CELL_THRESHOLD) {
    x <- as.character(x)
    is_pct_cell <- grepl("^[0-9]+\\s*\\([0-9.]+%\\)$", x)
    n <- suppressWarnings(as.integer(sub("^([0-9]+).*$", "\\1", x)))
    idx <- is_pct_cell & !is.na(n) & n > 0 & n < threshold
    out <- x
    out[idx] <- sprintf("<%d", threshold)
    out
  }

  # ---- Query CDM source metadata for the methods text ------------------------
  cdm_version_str        <- ""
  vocabulary_version_str <- ""
  if (!is.null(connection_details) && !is.null(config)) {
    tryCatch({
      conn_meta <- DatabaseConnector::connect(connection_details)
      on.exit(DatabaseConnector::disconnect(conn_meta), add = TRUE)
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
      names(meta_raw) <- tolower(names(meta_raw))
      if (nrow(meta_raw) > 0) {
        cdm_version_str        <- as.character(meta_raw$cdm_version[1])
        vocabulary_version_str <- as.character(meta_raw$vocabulary_version[1])
      }
    }, error = function(e) NULL)
  }

  # ---- Report filename + archiving (matches report_prognostic.R convention) --
  next_report_file <- function(output_dir, base_name) {
    file.path(output_dir, paste0(base_name, ".docx"))
  }
  archive_old_reports <- function(output_dir) {
    existing <- list.files(output_dir, pattern = "\\.docx$",
                           full.names = TRUE, all.files = FALSE)
    if (length(existing) == 0L) return(invisible(NULL))
    archive_dir <- file.path(output_dir, "archive")
    dir.create(archive_dir, recursive = TRUE, showWarnings = FALSE)
    for (f in existing) {
      nm   <- basename(f)
      dest <- file.path(archive_dir, nm)
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

  project_name <- basename(normalizePath(getwd(), winslash = "/", mustWork = FALSE))
  project_name <- gsub("[^A-Za-z0-9_-]", "_", project_name)
  report_base_name <- paste(project_name, "report", format(Sys.Date(), "%Y%m%d"), sep = "_")

  archive_old_reports(output_dir)
  report_file <- next_report_file(output_dir, report_base_name)

  # ---- Author / affiliation block (from workspace contributors.yaml) ---------
  # Filters the shared workspace contributor registry to entries assigned to
  # this repo (matched by directory name) or to "*" (all repos). Builds a
  # journal-style byline: each author's affiliations are collapsed to a
  # de-duplicated, ordered numbered list (first appearance order), and each
  # author record carries the superscript numbers pointing into that list.
  # Returns NULLs if contributors.yaml is unavailable so the report still
  # generates (e.g. a portable bundle without the workspace root).
  build_author_block <- function(project_dir_name) {
    contrib_path <- file.path("..", "contributors.yaml")
    if (!file.exists(contrib_path) || !requireNamespace("yaml", quietly = TRUE)) {
      return(list(authors = NULL, affiliations = NULL))
    }
    reg <- tryCatch(yaml::read_yaml(contrib_path), error = function(e) NULL)
    if (is.null(reg) || is.null(reg$contributors)) {
      return(list(authors = NULL, affiliations = NULL))
    }

    matched <- Filter(function(c) {
      repo_names <- vapply(c$repos %||% list(), function(r) r$repo %||% "", character(1))
      project_dir_name %in% repo_names || "*" %in% repo_names
    }, reg$contributors)

    if (length(matched) == 0L) return(list(authors = NULL, affiliations = NULL))

    affil_list <- character(0)
    affil_index <- function(aff_str) {
      idx <- match(aff_str, affil_list)
      if (is.na(idx)) {
        affil_list[[length(affil_list) + 1L]] <<- aff_str
        idx <- length(affil_list)
      }
      idx
    }

    authors <- lapply(matched, function(c) {
      nm <- trimws(paste(c$given_names %||% "", c$family_names %||% ""))
      suffix <- c$name_suffix %||% NULL
      if (!is.null(suffix) && nzchar(suffix)) nm <- paste0(nm, ", ", suffix)
      aff_strs <- vapply(c$affiliations %||% list(), function(a) {
        parts <- c(a$name %||% "", a$city %||% "", a$region %||% "")
        paste(parts[nzchar(parts)], collapse = ", ")
      }, character(1))
      list(name = nm, affil_nums = vapply(aff_strs, affil_index, integer(1)))
    })

    list(authors = authors, affiliations = affil_list)
  }
  author_block <- build_author_block(project_name)

  # ---- Data source characterization (dynamic; supports multi-site reuse) ----
  # This pipeline is designed to run unmodified against any OMOP CDM
  # v5.4-conformant instance. is_synthetic detects the current run's data
  # source from config so the report's disclaimers/caveats appear only when
  # they apply, rather than being hardcoded to one deployment.
  is_synthetic <- grepl("synth", config$cdm_schema %||% "", ignore.case = TRUE) ||
                  grepl("synth", config$cdm_database_name %||% "", ignore.case = TRUE)

  data_source_text <- sprintf(
    "Data were extracted from the \"%s\" OMOP Common Data Model (CDM) v%s instance (vocabulary version: %s).%s This analysis pipeline is designed to run unmodified against any OMOP CDM v5.4-conformant instance and is intended for eventual deployment within the protected research environments of Duke University Health System (Duke OMOP) and the Durham VA Medical Center (VA OMOP), evaluating the same cohort, outcome, and VA-FI definitions at each site.",
    config$cdm_database_name %||% project_name,
    if (nzchar(cdm_version_str)) cdm_version_str else "5.4",
    if (nzchar(vocabulary_version_str)) vocabulary_version_str else "unspecified",
    if (nzchar(config$cdm_database_description %||% "")) paste0(" ", config$cdm_database_description) else ""
  )

  synthetic_note <- if (is_synthetic) {
    "NOTE: This run was executed against a Synthea-derived synthetic OMOP CDM instance for pipeline validation prior to deployment against live site data. Effect estimates, discrimination, and calibration results reflect synthetic data generation parameters, not real-world clinical relationships, and should not be interpreted as clinical findings."
  } else {
    NULL
  }

  # ---- Generic flextable builder ----------------------------------------------
  # Renders any data frame with the shared dark-blue / gray-rule theme used
  # across all report templates. Unlike .build_table1() (report_helpers.R),
  # this does not assume fixed column names — column headers come from the
  # data frame's own names.
  build_generic_table <- function(df, col_widths = NULL) {
    border_h   <- officer::fp_border(color = "#BFBFBF", width = 0.5)
    border_out <- officer::fp_border(color = "#1F3864", width = 1.5)

    ft <- flextable::flextable(df) |>
      flextable::bold(part = "header") |>
      flextable::fontsize(size = 9.5, part = "all") |>
      flextable::font(fontname = "Calibri", part = "all") |>
      flextable::bg(part = "header", bg = "#1F3864") |>
      flextable::color(part = "header", color = "white") |>
      flextable::hline(border = border_h, part = "body") |>
      flextable::border_outer(border = border_out, part = "all") |>
      flextable::set_table_properties(layout = "fixed") |>
      flextable::padding(padding = 3, part = "all") |>
      flextable::align(align = "center", part = "header")

    if (!is.null(col_widths)) {
      for (nm in names(col_widths)) {
        if (nm %in% names(df)) ft <- flextable::width(ft, j = nm, width = col_widths[[nm]])
      }
    }
    ft
  }

  # Formats a numeric value with its 95% CI in parentheses, e.g. "0.515 (0.414-0.616)".
  # Rows without a CI (ci_lower/ci_upper NA, e.g. n, n_events) show the bare value.
  fmt_value_ci <- function(value, ci_lower, ci_upper) {
    ifelse(
      is.na(ci_lower) | is.na(ci_upper),
      ifelse(value == round(value), as.character(as.integer(round(value))), as.character(value)),
      sprintf("%.3f (%.3f-%.3f)", value, ci_lower, ci_upper)
    )
  }

  # =============================================================================
  # Assemble document
  # =============================================================================
  # Local redefinitions of the report_helpers.R document primitives: R's <<-
  # walks the *lexical* (defining) environment chain, not the caller's, so
  # add_doc_heading() must be defined here to close over this function's own
  # heading_counter rather than the copy in report_helpers.R's environment.
  # (Same pattern used in R/report_prognostic.R.)
  heading_counter <- 0L

  make_doc_run <- function(text, bold = FALSE, font_size = 10.5) {
    officer::ftext(
      text,
      officer::fp_text(bold = bold, font.size = font_size, font.family = "Calibri")
    )
  }

  add_doc_heading <- function(doc, text, level = 1L) {
    if (heading_counter > 0L) doc <- officer::body_add_par(doc, "", style = "Normal")
    size_map <- c(`1` = 13, `2` = 11.5, `3` = 11)
    heading_par <- officer::fpar(
      make_doc_run(text, bold = TRUE, font_size = unname(size_map[as.character(level)])),
      fp_p = officer::fp_par(text.align = "left")
    )
    heading_counter <<- heading_counter + 1L
    officer::body_add_fpar(doc, value = heading_par, style = "Normal")
  }

  add_doc_paragraph <- function(doc, text) {
    officer::body_add_par(doc, paste0("\t", text), style = "Normal")
  }

  add_doc_caption <- function(doc, title, body_text = NULL) {
    caption_runs <- list(make_doc_run(title, bold = TRUE, font_size = 10))
    if (!is.null(body_text) && nzchar(body_text)) {
      caption_runs[[length(caption_runs) + 1L]] <- make_doc_run(
        paste0(" ", body_text), bold = FALSE, font_size = 10
      )
    }
    caption_par <- do.call(officer::fpar,
      c(caption_runs, list(fp_p = officer::fp_par(text.align = "left"))))
    officer::body_add_fpar(doc, value = caption_par, style = "Normal")
  }

  doc <- officer::read_docx()

  # ---- Title -------------------------------------------------------------------
  # Full descriptive title only — no separate short study-tag line above it.
  title_par <- officer::fpar(
    make_doc_run(
      "Emergency Department Visits Following Major Lower Extremity Amputation: A Descriptive Analysis of VA Frailty Index Association",
      bold = TRUE, font_size = 15
    ),
    fp_p = officer::fp_par(text.align = "center")
  )
  doc <- officer::body_add_fpar(doc, title_par)
  doc <- officer::body_add_par(doc, "", style = "Normal")

  # ---- Authors (journal-style: name with superscript affiliation numbers) ----
  if (!is.null(author_block$authors)) {
    make_superscript_run <- function(text) {
      officer::ftext(
        text,
        officer::fp_text(font.size = 8, font.family = "Calibri", vertical.align = "superscript")
      )
    }
    author_runs <- list()
    for (i in seq_along(author_block$authors)) {
      a <- author_block$authors[[i]]
      author_runs[[length(author_runs) + 1L]] <- make_doc_run(a$name, bold = FALSE, font_size = 11)
      author_runs[[length(author_runs) + 1L]] <- make_superscript_run(paste(a$affil_nums, collapse = ","))
      if (i < length(author_block$authors)) {
        author_runs[[length(author_runs) + 1L]] <- make_doc_run(", ", bold = FALSE, font_size = 11)
      }
    }
    author_par <- do.call(officer::fpar,
      c(author_runs, list(fp_p = officer::fp_par(text.align = "center"))))
    doc <- officer::body_add_fpar(doc, author_par)
  }

  # ---- Numbered affiliation list ----------------------------------------------
  if (!is.null(author_block$affiliations)) {
    for (i in seq_along(author_block$affiliations)) {
      aff_par <- officer::fpar(
        make_doc_run(sprintf("%d. %s", i, author_block$affiliations[i]), bold = FALSE, font_size = 9),
        fp_p = officer::fp_par(text.align = "center")
      )
      doc <- officer::body_add_fpar(doc, aff_par)
    }
  }

  doc <- officer::body_add_par(doc, "", style = "Normal")
  date_par <- officer::fpar(
    make_doc_run(paste0("Report generated: ", format(Sys.Date(), "%B %d, %Y")),
                font_size = 10),
    fp_p = officer::fp_par(text.align = "center")
  )
  doc <- officer::body_add_fpar(doc, date_par)
  doc <- officer::body_add_par(doc, "", style = "Normal")

  n_total <- if (!is.null(table1_df)) as.integer(table1_df[[2]][table1_df$Variable == "N"][1]) else NA_integer_
  ed_pct  <- if (!is.null(outcomes_df)) suppress_pct_cell(outcomes_df$value[outcomes_df$metric == "ED visit within 90 days"][1]) else NA_character_

  # ---- 1. Executive summary -----------------------------------------------------
  doc <- add_doc_heading(doc, "1. Executive Summary", level = 1)
  doc <- add_doc_paragraph(doc, sprintf(
    "This report describes a cohort of %s patients undergoing major lower extremity amputation, characterizing 90-day emergency department (ED) utilization following hospital discharge and its association with the VA Frailty Index (VA-FI, 30-deficit accumulation model). %s of patients had at least one ED visit within 90 days of discharge. Individual VA-FI components were examined for association with post-discharge ED visit, and the composite VA-FI score was evaluated for discrimination and calibration as a predictor of this outcome.",
    if (is.na(n_total)) "N" else n_total,
    if (is.na(ed_pct))  "An undetermined proportion" else ed_pct
  ))
  if (!is.null(synthetic_note)) doc <- add_doc_paragraph(doc, synthetic_note)

  # ---- 2. Methods -----------------------------------------------------------------
  doc <- add_doc_heading(doc, "2. Methods", level = 1)

  doc <- add_doc_heading(doc, "2.1. Data Source", level = 2)
  doc <- add_doc_paragraph(doc, data_source_text)

  doc <- add_doc_heading(doc, "2.2. Study Population", level = 2)
  doc <- add_doc_paragraph(doc,
    "The target cohort comprised patients undergoing major lower extremity amputation (below-knee, above-knee, or knee-disarticulation) with an index inpatient encounter. Patients were categorized into three mutually exclusive indication groups based on presence of the peripheral vascular disease (PVD) and diabetes mellitus VA-FI deficits (3-year lookback from the index admission; see Section 2.4): PVD only, PVD with diabetes mellitus, and diabetes mellitus only."
  )

  doc <- add_doc_heading(doc, "2.3. Outcome Definition", level = 2)
  doc <- add_doc_paragraph(doc, sprintf(
    "The primary outcome was the first emergency department (ED) visit occurring after discharge from the index amputation admission and within %s days. ED visits were identified from two sources and combined: visit_occurrence records with visit_concept_id = 9203 (Emergency Room Visit), and observation records with observation_concept_id = 4176269 (Emergency room admission; SNOMED 50849002), the latter capturing ED events that some source ETLs (including this study's Synthea-based pipeline validation run) route to the Observation domain rather than visit_occurrence.",
    config$prediction_window_days %||% 90L
  ))

  doc <- add_doc_heading(doc, "2.4. VA Frailty Index (VA-FI)", level = 2)
  doc <- add_doc_paragraph(doc,
    "Frailty was quantified using the VA Frailty Index, a 30-deficit accumulation index adapted from Cheng et al. (J Gerontol A Biol Sci Med Sci, 2021) [1]. Each deficit was ascertained from condition, observation, or procedure records with a 3-year lookback from the index admission date (kidney transplant/dialysis used a lifetime lookback). The VA-FI score is the count of present deficits divided by 30."
  )

  doc <- add_doc_heading(doc, "2.5. Statistical Methods", level = 2)
  doc <- add_doc_paragraph(doc,
    "Cohort characteristics are summarized as counts and percentages for categorical variables and medians with interquartile ranges (IQR) for continuous variables, stratified by 90-day ED visit status. Timing of ED visits relative to hospital discharge (the outcome window's reference date, Section 2.3) is summarized graphically. Diagnoses recorded on the date of the ED visit are tallied to describe conditions associated with the visit. Associations between individual VA-FI deficits and ED visit were estimated via univariable logistic regression, reported as odds ratios (OR) with 95% Wald confidence intervals; components with fewer than 5 events in either exposure stratum were suppressed from OR estimation (prevalence is still reported, subject to the small-cell suppression below). Throughout this report, any displayed nonzero patient count below 5 is suppressed and shown as \"<5\" to reduce re-identification risk."
  )

  doc <- add_doc_heading(doc, "2.6. Predicted Probability, Discrimination, and Calibration", level = 2)
  split_sentence <- if (!is.null(split_info_df)) {
    sprintf(
      "Patients were sorted chronologically by index date and split into an earlier training set (n=%d, through %s) and a later, held-out test set (n=%d, after %s). ",
      split_info_df$n_train[1], split_info_df$split_date[1],
      split_info_df$n_test[1],  split_info_df$split_date[1]
    )
  } else {
    ""
  }
  doc <- add_doc_paragraph(doc, paste0(
    split_sentence,
    "The predicted probability of ED visit used for discrimination and calibration assessment was the fitted value from a univariable logistic regression model, fit on the training set only, regressing the binary 90-day ED visit outcome on the continuous VA-FI score (deficit count / 30): logit(P(ED visit)) = beta0 + beta1 x VA-FI score. This temporal split approximates how the VA-FI would perform if recalibrated to an earlier local population and then applied prospectively, avoiding the optimistic bias of fitting and evaluating the recalibration model on the same rows. All discrimination and calibration metrics below are computed on the test set only. Discrimination was assessed with the area under the receiver operating characteristic curve (AUROC) and the area under the precision-recall curve (AUPRC). Calibration was assessed with the Brier score (mean squared prediction error), the expected calibration error (ECE, 10 equal-frequency bins of predicted probability), and logistic calibration intercept and slope (intercept from a model with the log-odds of predicted probability as a fixed offset, ideal value 0; slope from a model regressing outcome on the log-odds of predicted probability, ideal value 1). All metrics are reported with 95% bootstrap percentile confidence intervals (500 resamples of test-set patients, holding the fitted predicted probabilities fixed per resample)."
  ))

  # ---- 3. Table 1 — Cohort characteristics ----------------------------------------
  if (!is.null(table1_df)) {
    doc <- add_doc_heading(doc, "3. Cohort Characteristics", level = 1)
    # Widen the Variable column (position 1) so labels like "Below-knee /
    # ankle amputation" don't wrap; the 3 count columns share the remainder.
    t1_names <- names(table1_df)
    # Small-cell suppression: applies to the count columns only (everything
    # after Variable), leaving continuous median [IQR] rows untouched (see
    # suppress_pct_cell above).
    for (col in t1_names[-1]) {
      table1_df[[col]] <- suppress_pct_cell(table1_df[[col]])
    }
    col_widths_t1 <- setNames(as.list(c(2.6, rep(1.3, length(t1_names) - 1))), t1_names)
    ft1 <- build_generic_table(table1_df, col_widths = col_widths_t1)
    # Section-header rows (e.g. "Demographics", "Frailty") are written by the
    # pipeline with blank Overall/ED_yes/ED_no values -- grey them to set them
    # apart from data rows.
    section_header_rows <- which(table1_df[[2]] == "")
    if (length(section_header_rows) > 0) {
      ft1 <- flextable::bg(ft1, i = section_header_rows, bg = "#D9D9D9", part = "body")
      ft1 <- flextable::bold(ft1, i = section_header_rows, part = "body")
    }
    doc <- flextable::body_add_flextable(doc, ft1)
    doc <- add_doc_caption(doc,
      "Table 1. Cohort characteristics stratified by 90-day emergency department visit status.",
      "Continuous variables reported as median [IQR]; categorical variables as n (%). VA-FI score is the summary composite (deficit count / 30); individual VA-FI deficits are reported in Table 3. Small-cell suppression: nonzero categorical counts below 5 are shown as \"<5\" (with the percentage dropped) to reduce re-identification risk."
    )
  }

  # ---- 4. Outcome description --------------------------------------------------
  if (!is.null(outcomes_df)) {
    doc <- add_doc_heading(doc, "4. Outcome Description", level = 1)
    names(outcomes_df) <- c("Metric", "Value")
    outcomes_df$Value <- suppress_pct_cell(outcomes_df$Value)
    ft2 <- build_generic_table(outcomes_df, col_widths = list(Metric = 4.0, Value = 2.0))
    doc <- flextable::body_add_flextable(doc, ft2)
    doc <- add_doc_caption(doc,
      "Table 2a. Summary of key post-amputation outcomes.",
      "Emergency department visits and inpatient readmissions are anchored to the hospital discharge date; mortality is anchored to the index (operative) date, so perioperative in-hospital deaths are captured in the 30-day figure. Index admission length of stay and non-home discharge are reported in Table 1, stratified by ED visit status. Small-cell suppression: a nonzero count below 5 is shown as \"<5\" (with the percentage dropped)."
    )

    # ---- Diagnoses associated with the ED visit, grouped by category ----------
    # "Other" stays as a single row in Table 2b (a category header row with no
    # further diagnosis rows beneath it, using the distinct-patient category
    # total rather than a sum of per-diagnosis counts, since one patient can
    # contribute more than one "Other" diagnosis). The full per-diagnosis
    # breakdown of everything that falls into "Other" is listed separately in
    # Supplemental Table S4 (Section 8).
    doc <- add_doc_paragraph(doc, "")
    if (!is.null(ed_dx_df) && nrow(ed_dx_df) > 0) {
      # Build a grouped display matching Table 1's style: a grey category
      # header row (blank diagnosis/count), followed by that category's
      # diagnosis rows. ed_dx_df is already sorted by the pipeline:
      # "Amputation complication" first, VA-FI components alphabetically,
      # "Other" last; descending count within category.
      cats <- unique(ed_dx_df$category)
      # Category total (distinct-patient count for the whole category, NOT a
      # sum of the per-diagnosis rows below it, since one patient can
      # contribute more than one diagnosis within a category) is shown in the
      # header row itself for every category. "Other" has no diagnosis rows
      # beneath it (collapsed; full detail is in Supplemental Table S4); all
      # other categories keep their per-diagnosis rows underneath the total.
      category_total <- function(cat) {
        if (is.null(ed_dx_category_totals_df)) return(NA_integer_)
        val <- ed_dx_category_totals_df$n[ed_dx_category_totals_df$category == cat]
        if (length(val) == 1) val else NA_integer_
      }
      grouped_rows <- do.call(rbind, lapply(cats, function(cat) {
        cat_n <- category_total(cat)
        cat_n_str <- if (!is.na(cat_n)) suppress_count(cat_n) else ""
        if (cat == "Other") {
          data.frame(Diagnosis = "Other", `Patients (n)` = cat_n_str,
                     check.names = FALSE, stringsAsFactors = FALSE)
        } else {
          rbind(
            data.frame(Diagnosis = cat, `Patients (n)` = cat_n_str, check.names = FALSE, stringsAsFactors = FALSE),
            data.frame(
              Diagnosis = paste0("    ", ed_dx_df$diagnosis[ed_dx_df$category == cat]),
              `Patients (n)` = suppress_count(ed_dx_df$n[ed_dx_df$category == cat]),
              check.names = FALSE, stringsAsFactors = FALSE
            )
          )
        }
      }))
      ft2b <- build_generic_table(grouped_rows, col_widths = list(Diagnosis = 4.5, `Patients (n)` = 1.5))
      category_header_rows <- which(grouped_rows$Diagnosis %in% c(cats, "Other") &
                                    !startsWith(grouped_rows$Diagnosis, "    "))
      if (length(category_header_rows) > 0) {
        ft2b <- flextable::bg(ft2b, i = category_header_rows, bg = "#D9D9D9", part = "body")
        ft2b <- flextable::bold(ft2b, i = category_header_rows, part = "body")
      }
      doc <- flextable::body_add_flextable(doc, ft2b)
      dx_scope_note <- if (ed_dx_primary_only) {
        "condition_status_concept_id identified a primary diagnosis in this data source, so this table is restricted to primary-status diagnoses (Primary diagnosis / Primary admission diagnosis / Primary discharge diagnosis / Primary referral diagnosis, [vocab query]) linked via visit_occurrence_id to the ED visit encounter"
      } else {
        "there is no OMOP-standard \"primary diagnosis\" flag in this data source (condition_status_concept_id is unpopulated), so every condition_occurrence record linked via visit_occurrence_id to the ED visit encounter is tallied with equal weight"
      }
      doc <- add_doc_caption(doc,
        "Table 2b. Diagnoses recorded on the date of the emergency department visit, grouped by category.",
        sprintf(
          "\"Amputation complication\" = descends from any of: Disorder of amputation stump, Phantom limb, Limb stump pain, Pain of amputation stump (each limb/laterality), Stump neuralgia, Jumpy stump syndrome, Pain in left/right lower limb, Persistent pain following procedure, or a generic post-surgical complication code (Complication of procedure, Postoperative complication, Wound dehiscence, Dehiscence of external surgical incision wound, Surgical site infection, Postoperative seroma) (concept_ancestor rollup, [vocab query]); VA-FI component categories = descends from that component's concept set (first matching component if shared across components; vafi_diabetes, vafi_ckd, vafi_falls, and vafi_vision_impairment were broadened 2026-07-10 to include commonly-charted related diagnoses -- e.g. \"Syncope and collapse\" for falls -- that are not concept_ancestor descendants of the original defining concept); \"Other\" = neither, shown as a single row with no diagnosis rows beneath it (full per-diagnosis breakdown is in Supplemental Table S4). Each category header row shows that category's total distinct-patient count, which is NOT a sum of the per-diagnosis rows beneath it (a patient contributing more than one diagnosis within the same category is only counted once in the header total). %s; a patient may contribute more than one diagnosis overall. Small-cell suppression: any nonzero count below 5 (category totals and per-diagnosis rows alike) is shown as \"<5\".",
          dx_scope_note
        )
      )
    } else {
      dx_omitted_note <- if (ed_dx_primary_only) {
        "condition_status_concept_id restricted this pull to primary-status diagnoses and none were found"
      } else {
        "no condition_occurrence records were found linked via visit_occurrence_id to the ED visit encounter for any patient in this cohort"
      }
      doc <- add_doc_paragraph(doc,
        sprintf(
          "Table 2b (diagnoses associated with the ED visit) is omitted: %s. This is a known limitation of the current Synthea module for this study -- the emergency department encounter state does not generate an associated diagnosis condition record. This table is expected to populate correctly when this pipeline is run against Duke OMOP / VA OMOP claims data, where ED encounters carry diagnosis coding.",
          dx_omitted_note
        )
      )
    }
  }

  # ---- 5. Figure 1 — Timing of ED visit -----------------------------------------
  if (file.exists(hist_plot_path)) {
    doc <- add_doc_heading(doc, "5. Timing of Emergency Department Visit", level = 1)
    doc <- officer::body_add_img(doc, src = hist_plot_path, width = 5.5, height = 3.9)
    doc <- add_doc_caption(doc,
      "Figure 1. Histogram of emergency department visits by days from hospital discharge.",
      "The 90-day outcome window is defined relative to discharge (Section 2.3), not the index operative date, so all visits fall within 0-90 days by construction; 5-day bins."
    )
  }

  # ---- 6. VA-FI component prevalence and associations -----------------------------
  if (!is.null(vafi_or_df) || file.exists(forest_plot_path)) {
    doc <- add_doc_heading(doc, "6. VA Frailty Index Component Prevalence and Associations", level = 1)

    if (!is.null(vafi_or_df)) {
      display_df <- data.frame(
        `VA-FI Deficit`      = vafi_or_df$deficit,
        `N (%) — ED visit`    = suppress_pct_cell(sprintf("%d (%.1f%%)", vafi_or_df$n_ed_yes, vafi_or_df$pct_ed_yes)),
        `N (%) — No ED visit` = suppress_pct_cell(sprintf("%d (%.1f%%)", vafi_or_df$n_ed_no,  vafi_or_df$pct_ed_no)),
        `OR (95% CI)`         = ifelse(is.na(vafi_or_df$or), "—",
                                      sprintf("%.2f (%.2f-%.2f)", vafi_or_df$or, vafi_or_df$ci_lo, vafi_or_df$ci_hi)),
        `P-value`             = ifelse(is.na(vafi_or_df$p_value), "—", sprintf("%.4f", vafi_or_df$p_value)),
        check.names = FALSE, stringsAsFactors = FALSE
      )
      ft4 <- build_generic_table(display_df, col_widths = list(
        `VA-FI Deficit`        = 2.3,
        `N (%) — ED visit`     = 1.2,
        `N (%) — No ED visit`  = 1.2,
        `OR (95% CI)`          = 1.6,
        `P-value`              = 0.8
      ))
      doc <- flextable::body_add_flextable(doc, ft4)
      doc <- add_doc_caption(doc,
        "Table 3. VA-FI component prevalence by 90-day ED visit status, with univariable odds ratios.",
        "Components with fewer than 5 observations in any of the four deficit-by-ED-status cells are reported with prevalence only (OR not estimable). Small-cell suppression: a nonzero N (%) cell below 5 is shown as \"<5\" (with the percentage dropped)."
      )
    }

    if (file.exists(forest_plot_path)) {
      n_deficits <- if (!is.null(vafi_or_df)) sum(!is.na(vafi_or_df$or)) else 25L
      plot_height <- min(max(4.0, n_deficits * 0.28 + 1.2), 9.5)
      doc <- officer::body_add_img(doc, src = forest_plot_path, width = 6.0, height = plot_height)
      doc <- add_doc_caption(doc,
        "Figure 2. Forest plot of VA-FI component odds ratios for 90-day ED visit.",
        "Dashed vertical line = null effect (OR = 1). Error bars = 95% confidence interval."
      )
    }
  }

  # ---- 7. VA-FI discrimination and calibration ------------------------------------
  if (!is.null(vafi_disc_df) || file.exists(cal_plot_path)) {
    doc <- add_doc_heading(doc, "7. VA Frailty Index Discrimination and Calibration", level = 1)

    auroc_line <- NULL
    if (!is.null(vafi_disc_df)) {
      display_disc <- data.frame(
        Metric = vafi_disc_df$metric,
        `Value (95% CI)` = fmt_value_ci(vafi_disc_df$value, vafi_disc_df$ci_lower, vafi_disc_df$ci_upper),
        check.names = FALSE,
        stringsAsFactors = FALSE
      )
      ft5 <- build_generic_table(display_disc, col_widths = list(Metric = 3.5, `Value (95% CI)` = 2.5))
      doc <- flextable::body_add_flextable(doc, ft5)
      test_set_note <- if (!is.null(split_info_df)) {
        sprintf("Evaluated on the held-out temporal test set (n=%d, after %s; see Section 2.6). ",
               split_info_df$n_test[1], split_info_df$split_date[1])
      } else {
        ""
      }
      doc <- add_doc_caption(doc,
        "Table 4. Discrimination and calibration of the composite VA-FI score for 90-day ED visit.",
        paste0(
          test_set_note,
          "AUROC = area under the receiver operating characteristic curve; AUPRC = area under the precision-recall curve; Brier = mean squared prediction error; ECE = expected calibration error (10 equal-frequency bins); calibration intercept/slope from logistic recalibration models (ideal values 0 and 1, respectively). 95% CIs are bootstrap percentile intervals (500 resamples). See Section 2.6 for how the predicted probability was derived."
        )
      )

      auroc_row <- vafi_disc_df[vafi_disc_df$metric == "AUROC", ]
      if (nrow(auroc_row) == 1) {
        auroc_line <- sprintf("AUROC = %.3f (%.3f-%.3f)",
                              auroc_row$value, auroc_row$ci_lower, auroc_row$ci_upper)
      }
    }

    if (file.exists(cal_plot_path)) {
      doc <- officer::body_add_img(doc, src = cal_plot_path, width = 4.5, height = 4.5)
      doc <- add_doc_caption(doc,
        "Figure 3. Calibration plot of the VA-FI score for 90-day ED visit (test set).",
        paste0(
          "Points show mean predicted probability vs. observed event rate within rank-based (ntile) deciles of predicted probability, computed on the held-out temporal test set only; dashed line = perfect calibration. ",
          "Predicted probability is the fitted value from a univariable logistic regression of ED visit on VA-FI score, fit on the training set and applied to the test set (Section 2.6).",
          if (!is.null(auroc_line)) paste0(" ", auroc_line, ".") else ""
        )
      )
    }
  }

  # ---- References ---------------------------------------------------------------
  citations <- list(
    cheng2021 = list(
      authors = "Cheng D, Shi Y, Wang X, et al",
      title   = "Development and validation of a Frailty Index using claims data among Veterans Affairs elderly patients",
      journal = "J Gerontol A Biol Sci Med Sci",
      year    = "2021",
      volume  = "76",
      issue   = "9",
      pages   = "1591-1598",
      doi     = "10.1093/gerona/glab071"
    )
  )
  doc <- .append_references_section(doc, citations)

  # ---- 8. Supplemental Material ----------------------------------------------------
  doc <- add_doc_heading(doc, "8. Supplemental Material", level = 1)

  # ---- Supplemental Table S1 — dataset description (CDM source metadata) ----------
  # Mirrors pad-amp-nhd-val/R/report_prognostic.R's Supplemental Table S1.
  if (!is.null(connection_details) && !is.null(config)) {
    tryCatch({
      conn_supp <- DatabaseConnector::connect(connection_details)
      on.exit(DatabaseConnector::disconnect(conn_supp), add = TRUE)
      cdm_src_raw <- DatabaseConnector::querySql(
        conn_supp,
        SqlRender::translate(
          SqlRender::render(
            "SELECT cdm_source_name, cdm_source_abbreviation, cdm_holder,
                    source_release_date, cdm_release_date, cdm_version,
                    vocabulary_version
             FROM @cdm_schema.cdm_source",
            cdm_schema = config$cdm_schema
          ),
          targetDialect = "sql server"
        )
      )
      names(cdm_src_raw) <- tolower(names(cdm_src_raw))
      if (nrow(cdm_src_raw) > 0) {
        cdm_src_display <- data.frame(
          Field = c("CDM Source Name", "Source Abbreviation", "CDM Holder",
                    "Source Release Date", "CDM Release Date",
                    "CDM Version", "Vocabulary Version",
                    "Study Cohort N", "ED Visit Outcome N",
                    "Temporal Split Date", "Training Set N", "Test Set N"),
          Value = c(
            as.character(cdm_src_raw$cdm_source_name[1]),
            as.character(cdm_src_raw$cdm_source_abbreviation[1]),
            as.character(cdm_src_raw$cdm_holder[1]),
            as.character(cdm_src_raw$source_release_date[1]),
            as.character(cdm_src_raw$cdm_release_date[1]),
            as.character(cdm_src_raw$cdm_version[1]),
            as.character(cdm_src_raw$vocabulary_version[1]),
            if (!is.na(n_total)) as.character(n_total) else "N/A",
            if (!is.na(ed_pct))  as.character(ed_pct)  else "N/A",
            if (!is.null(split_info_df)) as.character(split_info_df$split_date[1]) else "N/A",
            if (!is.null(split_info_df)) as.character(split_info_df$n_train[1])    else "N/A",
            if (!is.null(split_info_df)) as.character(split_info_df$n_test[1])     else "N/A"
          ),
          stringsAsFactors = FALSE
        )
        ft_s1 <- build_generic_table(cdm_src_display, col_widths = list(Field = 2.2, Value = 4.3))
        doc <- add_doc_heading(doc, "Dataset description", level = 2)
        doc <- flextable::body_add_flextable(doc, ft_s1)
        doc <- add_doc_caption(doc,
          "Supplemental Table S1. Dataset description.",
          "Metadata from the cdm_source table of the OMOP CDM instance used for this analysis, plus cohort and temporal-split sizes. CDM Version and Vocabulary Version confirm compliance with OMOP CDM v5.4 and the Athena vocabulary release used during ETL."
        )
      }
    }, error = function(e) {
      message("[report_descriptive] Supplemental Table S1 (dataset description) skipped: ", conditionMessage(e))
    })
  }

  # ---- Supplemental Table S2 — index procedure CPT4/HCPCS crosswalk -----------------
  if (!is.null(proc_codes_df) && nrow(proc_codes_df) > 0) {
    display_proc <- data.frame(
      Vocabulary  = proc_codes_df$vocabulary_id,
      # concept_code is character in the CSV, but read.csv infers numeric
      # since CPT/SNOMED codes are all-digit strings -- force character so
      # flextable doesn't render it with thousands separators (e.g. "88,312,006").
      Code        = as.character(proc_codes_df$concept_code),
      Description = proc_codes_df$concept_name,
      `Standard Procedure` = proc_codes_df$standard_procedure_name,
      `Patients (n)` = suppress_count(proc_codes_df$n),
      check.names = FALSE, stringsAsFactors = FALSE
    )
    ft_s2 <- build_generic_table(display_proc, col_widths = list(
      Vocabulary = 0.9, Code = 0.9, Description = 2.6, `Standard Procedure` = 2.0, `Patients (n)` = 0.9
    ))
    doc <- add_doc_heading(doc, "Index procedure CPT4/HCPCS crosswalk", level = 2)
    doc <- flextable::body_add_flextable(doc, ft_s2)
    doc <- add_doc_caption(doc,
      "Supplemental Table S2. CPT4/HCPCS crosswalk for the index amputation procedure, restricted to this cohort.",
      "This cohort's index procedures are recorded in SNOMED (the source vocabulary of this CDM build); Code/Description are CPT4/HCPCS codes that map to the same standard procedure concept via concept_relationship ('Maps to'), and Patients (n) is the count of this cohort's patients whose index procedure corresponds to that standard concept -- not a database-wide count. Multiple CPT4/HCPCS codes crosswalking to the same standard procedure will show identical counts, since the underlying records cannot be further distinguished by which of the equivalent codes would have been billed. Small-cell suppression: a nonzero Patients (n) below 5 is shown as \"<5\"."
    )
  } else {
    doc <- add_doc_heading(doc, "Index procedure CPT4/HCPCS crosswalk", level = 2)
    doc <- add_doc_paragraph(doc,
      "No CPT4/HCPCS 'Maps to' crosswalk was found for this cohort's index procedure concept(s) in the connected vocabulary."
    )
  }

  # ---- Supplemental Table S3 — VA-FI ICD-10-CM crosswalk (one code per concept) -----
  if (!is.null(icd_crosswalk_df) && nrow(icd_crosswalk_df) > 0) {
    display_icd <- data.frame(
      `VA-FI Deficit` = icd_crosswalk_df$label,
      `ICD-10-CM Code` = icd_crosswalk_df$icd10cm_code,
      `ICD-10-CM Description` = icd_crosswalk_df$icd10cm_name,
      `Patients (n)` = suppress_count(icd_crosswalk_df$n),
      check.names = FALSE, stringsAsFactors = FALSE
    )
    ft_s3 <- build_generic_table(display_icd, col_widths = list(
      `VA-FI Deficit` = 1.8, `ICD-10-CM Code` = 1.1, `ICD-10-CM Description` = 2.8, `Patients (n)` = 1.0
    ))
    doc <- add_doc_heading(doc, "VA-FI component ICD-10-CM crosswalk", level = 2)
    doc <- flextable::body_add_flextable(doc, ft_s3)
    doc <- add_doc_caption(doc,
      "Supplemental Table S3. ICD-10-CM codes mapping to each VA-FI component's concept set, restricted to this cohort.",
      sprintf(
        "%d codes across %d of 30 VA-FI components. One code per underlying standard concept (from concept_relationship 'Maps to', for any concept in a component's definition) is listed, not every code in this table's crosswalk; when multiple ICD-10-CM codes map to the same standard concept (e.g. an ICD-10-CM category header and its more specific sub-codes, such as D64 / D64.8 / D64.89 / D64.9 all mapping to a single \"Anemia\" concept), only the highest-level (shortest/most general) code is shown, since Patients (n) is computed per standard concept and would otherwise repeat identically across every sub-code with no added information; Patients (n) = this cohort's patient count for that specific underlying standard concept, using the same 3-year lookback as the standard VA-FI deficits (the kidney/dialysis supplement's lifetime lookback is not reflected here). Components with no listed rows have no ICD-10-CM 'Maps to' relationship in this vocabulary build for any of their concepts. Supplement covariates (e.g. the kidney transplant/dialysis OR added to vafi_ckd) are not included -- this table covers the 30 primary component definitions only. Small-cell suppression: a nonzero Patients (n) below 5 is shown as \"<5\".",
        nrow(icd_crosswalk_df), length(unique(icd_crosswalk_df$label))
      )
    )
  } else {
    doc <- add_doc_heading(doc, "VA-FI component ICD-10-CM crosswalk", level = 2)
    doc <- add_doc_paragraph(doc,
      "No ICD-10-CM 'Maps to' crosswalk was found for any VA-FI component concept in the connected vocabulary."
    )
  }

  # ---- Supplemental Table S4 — full breakdown of "Other" ED diagnoses ---------------
  # Table 2b collapses the "Other" category to a single row; this table lists
  # every individual diagnosis behind that row, so nothing from the ED-visit
  # diagnosis pull is lost from the report.
  ed_dx_other_df <- if (!is.null(ed_dx_df) && nrow(ed_dx_df) > 0) {
    ed_dx_df[ed_dx_df$category == "Other", ]
  } else {
    NULL
  }
  doc <- add_doc_heading(doc, "Diagnoses in the \"Other\" ED-visit category (all codes)", level = 2)
  if (!is.null(ed_dx_other_df) && nrow(ed_dx_other_df) > 0) {
    display_other <- data.frame(
      Diagnosis = ed_dx_other_df$diagnosis,
      `Patients (n)` = suppress_count(ed_dx_other_df$n),
      check.names = FALSE, stringsAsFactors = FALSE
    )
    ft_s4 <- build_generic_table(display_other, col_widths = list(Diagnosis = 4.5, `Patients (n)` = 1.5))
    doc <- flextable::body_add_flextable(doc, ft_s4)
    doc <- add_doc_caption(doc,
      "Supplemental Table S4. All diagnoses recorded on the date of the emergency department visit that did not match the \"Amputation complication\" or any VA-FI component category in Table 2b.",
      sprintf(
        "Same condition_occurrence pull as Table 2b (%s a patient may contribute more than one diagnosis); Patients (n) = distinct patients with that specific diagnosis concept. Small-cell suppression: a nonzero Patients (n) below 5 is shown as \"<5\".",
        if (ed_dx_primary_only) {
          "restricted to primary-status diagnoses (condition_status_concept_id, [vocab query]) linked via visit_occurrence_id to the ED visit encounter;"
        } else {
          "every record linked via visit_occurrence_id to the ED visit encounter is tallied;"
        }
      )
    )
  } else {
    doc <- add_doc_paragraph(doc,
      "No \"Other\" (uncategorized) ED-visit diagnoses were found for this cohort -- either Table 2b is empty (see Section 4) or every recorded diagnosis matched the \"Amputation complication\" or a VA-FI component category."
    )
  }

  print(doc, target = report_file)
  message("[report_descriptive] Report written to: ", report_file)
  invisible(report_file)
}
