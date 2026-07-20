# =============================================================================
# scripts/analysis/descriptive_ed_analysis.R
#
# PURPOSE
#   Custom descriptive analysis for the pad-amp-ed-desc study:
#     A) Table 1 — cohort demographics (incl. tobacco, LOS, non-home discharge,
#        stratified by ED visit), indication, race, amputation characteristics
#     B) Outcome description — ED visit rate/timing (30d + 90d), inpatient
#        readmission (30d/90d, discharge-anchored), mortality (30d/90d/1y,
#        index-anchored), plus diagnoses linked via visit_occurrence_id to the
#        specific ED encounter (not merely dated the same calendar day)
#     C) Timing of ED visit — histogram by days from hospital discharge
#     D) VA-FI component prevalence by ED visit status + associations (OR table + forest plot)
#     E) VA-FI score discrimination and calibration for ED visit outcome
#     F) Supplemental — index procedure CPT4/HCPCS crosswalk + VA-FI ICD-10-CM
#        crosswalk (all codes per component), both cohort-restricted
#
# INPUTS
#   connection_details  — DatabaseConnector ConnectionDetails object
#   config              — list from get_validation_config()
#
# OUTPUTS  (all written to config$output_folder/descriptive/)
#   table1.csv                       — Table 1 (machine-readable)
#   table1.docx                      — Table 1 (Word, flextable)
#   outcomes_summary.csv             — ED visit rate (30d/90d) + days-to-ED,
#                                       inpatient readmission (30d/90d), and
#                                       mortality (30d/90d/1y)
#   ed_visit_diagnoses.csv           — diagnoses linked via visit_occurrence_id to the
#                                       ED encounter, tallied and categorized (Amputation complication /
#                                       VA-FI component / Other); full per-diagnosis
#                                       detail for the "Other" category backs
#                                       Supplemental Table S4
#   ed_visit_diagnosis_category_totals.csv — distinct-patient count per category
#                                       (used to collapse "Other" to a single row
#                                       in Table 2b)
#   ed_visit_diagnosis_filter_mode.csv — "primary_only" if condition_status_concept_id
#                                       identified a primary diagnosis in this CDM
#                                       build (restricting the diagnosis pull above),
#                                       else "all_diagnoses" (Synthea builds; the field
#                                       is unpopulated)
#   ed_visit_timing_histogram.png    — histogram of days from discharge to ED visit
#   vafi_component_associations.csv  — prevalence by ED status + OR per VA-FI deficit
#   vafi_forest_plot.png             — forest plot of ORs
#   split_info.csv                    — temporal train/test split date and sizes
#   vafi_discrimination.csv          — AUROC, AUPRC, Brier, ECE, calibration
#                                       intercept/slope (test set only), each
#                                       with bootstrap 95% CI
#   vafi_calibration_plot.png        — calibration plot (deciles, test set only)
#   amputation_procedure_codes.csv   — index procedure CPT4/HCPCS crosswalk, cohort-restricted counts
#   vafi_icd_crosswalk.csv           — one representative (highest-level) ICD-10-CM code
#                                       per underlying standard concept per VA-FI component,
#                                       cohort-restricted counts
#
# CALLED FROM
#   workflow/08_run_analysis_and_manuscript_report.R
#   when config$run_descriptive_ed_analysis is TRUE.
#
# ASSUMPTIONS
#   - Cohorts already built in config$results_schema (run build_cohorts first).
#   - covariate_concepts.csv provides concept IDs for all VA-FI deficits.
#   - pROC, PRROC, ggplot2, flextable, officer, scales are installed.
# =============================================================================

run_descriptive_ed_analysis <- function(connection_details, config) {

  library(DatabaseConnector)
  library(dplyr)
  library(ggplot2)
  library(pROC)
  library(PRROC)
  library(flextable)
  library(officer)
  library(scales)

  out_dir <- file.path(config$output_folder, "descriptive")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  cdm     <- config$cdm_schema
  res     <- config$results_schema
  ctable  <- config$cohort_table
  tid     <- config$target_cohort_id
  oid     <- config$outcome_cohort_id
  win     <- as.integer(config$prediction_window_days %||% 90L)
  # Vocabulary schema — configurable via config$vocab_schema (site-specific;
  # e.g. Duke DHE / VA VINCI may not name it "omop_vocab"). Never hardcode
  # the literal schema name in SQL below.
  vocab   <- config$vocab_schema %||% "omop_vocab"

  message("[descriptive] Connected. output_dir = ", out_dir)


  # ===========================================================================
  # 0. Build person-level analysis dataset
  # ===========================================================================
  # Pull: demographics, index/discharge dates, outcome flag, LOS,
  # discharge disposition, and all VA-FI covariate flags.
  # Each covariate is pulled from covariate_concepts.csv using concept_ancestor
  # joins so that all standard descendants count.
  # ===========================================================================

  # ---- Read covariate concept definitions ------------------------------------
  cov_concepts <- read.csv(
    "covariates/covariate_concepts.csv",
    comment.char = "#",
    stringsAsFactors = FALSE,
    na.strings = c("", "NA")
  )
  # Keep only rows with a verified concept_id (non-zero)
  cov_concepts <- cov_concepts[!is.na(cov_concepts$concept_id) &
                                  cov_concepts$concept_id > 0, ]

  # Map covariate_id → concept_id(s); one covariate may have multiple concept rows
  cov_map <- split(cov_concepts$concept_id, cov_concepts$covariate_id)

  # ---- Helper: fetch presence of a concept set per person -------------------
  # Returns a 0/1 integer vector aligned to person_ids.
  get_cov_flag <- function(person_ids, concept_ids, domain) {
    if (length(concept_ids) == 0 || length(person_ids) == 0) return(rep(0L, length(person_ids)))
    id_csv <- paste(concept_ids, collapse = ", ")
    # Choose source table by domain
    if (domain == "condition") {
      sql <- sprintf(
        "SELECT DISTINCT co.person_id
         FROM %s.condition_occurrence co
         JOIN %s.concept_ancestor ca
           ON ca.descendant_concept_id = co.condition_concept_id
         WHERE ca.ancestor_concept_id IN (%s)
           AND co.person_id IN (%s)",
        cdm, vocab, id_csv, paste(person_ids, collapse = ", "))
    } else if (domain == "observation") {
      sql <- sprintf(
        "SELECT DISTINCT o.person_id
         FROM %s.observation o
         JOIN %s.concept_ancestor ca
           ON ca.descendant_concept_id = o.observation_concept_id
         WHERE ca.ancestor_concept_id IN (%s)
           AND o.person_id IN (%s)",
        cdm, vocab, id_csv, paste(person_ids, collapse = ", "))
    } else if (domain == "procedure") {
      sql <- sprintf(
        "SELECT DISTINCT po.person_id
         FROM %s.procedure_occurrence po
         JOIN %s.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
         WHERE ca.ancestor_concept_id IN (%s)
           AND po.person_id IN (%s)",
        cdm, vocab, id_csv, paste(person_ids, collapse = ", "))
    } else {
      return(rep(NA_integer_, length(person_ids)))
    }
    rows <- tryCatch(
      DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = FALSE),
      error = function(e) { warning("cov flag query failed: ", e$message); data.frame(person_id = integer(0)) }
    )
    names(rows) <- tolower(names(rows))
    as.integer(person_ids %in% rows$person_id)
  }

  # ---- Core cohort + demographic query ---------------------------------------
  message("[descriptive] Fetching cohort demographics ...")
  demo_sql <- sprintf("
    SELECT
      tc.subject_id                               AS person_id,
      tc.cohort_start_date                        AS index_date,
      tc.cohort_end_date                          AS discharge_date,
      DATEDIFF(day, tc.cohort_start_date, tc.cohort_end_date) AS los_days,
      CASE WHEN oc.subject_id IS NOT NULL THEN 1 ELSE 0 END    AS ed_visit,
      oc.cohort_start_date                        AS ed_date,
      DATEDIFF(day, tc.cohort_end_date,
               oc.cohort_start_date)              AS days_to_ed,
      DATEDIFF(year, p.birth_datetime,
               tc.cohort_start_date)              AS age_at_index,
      p.gender_concept_id,
      p.race_concept_id,
      -- Discharge disposition from the index inpatient visit (closest before/on discharge)
      vo.discharged_to_concept_id,
      vc.concept_name                             AS discharged_to_name,
      -- Additional Table 2a outcomes. Mortality is anchored to the index/
      -- operative date (tc.cohort_start_date) per surgical convention, so a
      -- perioperative in-hospital death still counts toward 30-day mortality.
      -- Readmission is anchored to hospital discharge (tc.cohort_end_date),
      -- consistent with the discharge-anchored ED outcome.
      dth.death_date,
      DATEDIFF(day, tc.cohort_start_date, dth.death_date)          AS days_to_death,
      readmit.visit_start_date                    AS readmit_date,
      DATEDIFF(day, tc.cohort_end_date, readmit.visit_start_date)  AS days_to_readmit
    FROM %s.%s tc
    JOIN %s.person p
      ON p.person_id = tc.subject_id
    LEFT JOIN %s.%s oc
      ON oc.subject_id           = tc.subject_id
     AND oc.cohort_definition_id = %d
    -- Index inpatient visit: latest inpatient visit ending on or before discharge date
    LEFT JOIN (
      SELECT person_id,
             visit_start_date,
             visit_end_date,
             discharged_to_concept_id,
             ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY visit_start_date DESC) rn
      FROM %s.visit_occurrence
      WHERE visit_concept_id = 9201  -- [vocab query] Inpatient Visit
    ) vo ON vo.person_id = tc.subject_id AND vo.rn = 1
    LEFT JOIN %s.concept vc
      ON vc.concept_id = vo.discharged_to_concept_id
    -- Death (OMOP death table). One row per person; days_to_death is negative
    -- only for the (nonsensical) case of a death before the index date, which
    -- the R-side event flags exclude via a days >= 0 guard.
    LEFT JOIN %s.death dth
      ON dth.person_id = tc.subject_id
    -- Earliest inpatient readmission STRICTLY AFTER index discharge. The
    -- subquery re-joins the target cohort to obtain each person's discharge
    -- date so it can exclude the index admission itself (visit_start_date must
    -- fall after cohort_end_date). visit_concept_id 9201 = [vocab query]
    -- Inpatient Visit.
    LEFT JOIN (
      SELECT vo2.person_id,
             vo2.visit_start_date,
             ROW_NUMBER() OVER (PARTITION BY vo2.person_id
                                ORDER BY vo2.visit_start_date ASC) rn
      FROM %s.visit_occurrence vo2
      JOIN %s.%s tc2
        ON tc2.subject_id          = vo2.person_id
       AND tc2.cohort_definition_id = %d
      WHERE vo2.visit_concept_id = 9201
        AND vo2.visit_start_date > tc2.cohort_end_date
    ) readmit
      ON readmit.person_id = tc.subject_id AND readmit.rn = 1
    WHERE tc.cohort_definition_id = %d
  ", res, ctable,
     cdm,
     res, ctable, oid,
     cdm,
     vocab,
     cdm,
     cdm, res, ctable, tid,
     tid)

  demo <- DatabaseConnector::querySql(conn, demo_sql, snakeCaseToCamelCase = FALSE)
  names(demo) <- tolower(names(demo))
  n_total <- nrow(demo)
  message(sprintf("[descriptive] Cohort n = %d  |  ED outcome n = %d (%.1f%%)",
                  n_total, sum(demo$ed_visit), mean(demo$ed_visit) * 100))


  # ---- Sex and race labels (look up concept names once) ----------------------
  gender_sql <- sprintf(
    "SELECT concept_id, concept_name FROM %s.concept
     WHERE concept_id IN (%s)",
    vocab,
    paste(unique(c(demo$gender_concept_id, demo$race_concept_id)), collapse = ", "))
  labels <- DatabaseConnector::querySql(conn, gender_sql, snakeCaseToCamelCase = FALSE)
  names(labels) <- tolower(names(labels))
  demo$sex  <- labels$concept_name[match(demo$gender_concept_id, labels$concept_id)]
  demo$race <- labels$concept_name[match(demo$race_concept_id,   labels$concept_id)]
  # concept_id 0 ("No matching concept") is OMOP's placeholder for a source
  # value that failed vocabulary mapping -- relabel for a clearer Table 1 row.
  demo$race[demo$race == "No matching concept"] <- "Unknown / not mapped"


  # ---- Pull VA-FI covariate flags for all persons ----------------------------
  message("[descriptive] Pulling VA-FI covariate flags ...")
  pid <- demo$person_id

  # VA-FI deficits with their domain and any supplement covariate that ORs in
  vafi_defs <- list(
    # Cardiovascular / Metabolic
    vafi_afib             = list(id = "vafi_afib",             domain = "condition",  supplement = NULL),
    vafi_cad              = list(id = "vafi_cad",              domain = "condition",  supplement = NULL),
    vafi_heart_failure    = list(id = "vafi_heart_failure",    domain = "condition",  supplement = NULL),
    vafi_hypertension     = list(id = "vafi_hypertension",     domain = "condition",  supplement = NULL),
    vafi_diabetes         = list(id = "vafi_diabetes",         domain = "condition",  supplement = NULL),
    vafi_ckd              = list(id = "vafi_ckd",              domain = "condition",  supplement = "vafi_kidney_procedure"),
    vafi_stroke           = list(id = "vafi_stroke",           domain = "condition",  supplement = NULL),
    vafi_pvd              = list(id = "vafi_pvd",              domain = "condition",  supplement = NULL),
    vafi_cancer           = list(id = "vafi_cancer",           domain = "condition",  supplement = NULL),
    vafi_liver            = list(id = "vafi_liver",            domain = "condition",  supplement = NULL),
    # Pulmonary / Musculoskeletal
    vafi_chronic_lung     = list(id = "vafi_chronic_lung",     domain = "condition",  supplement = NULL),
    vafi_arthritis        = list(id = "vafi_arthritis",        domain = "condition",  supplement = NULL),
    vafi_osteoporosis     = list(id = "vafi_osteoporosis",     domain = "condition",  supplement = NULL),
    vafi_gait_abnormality = list(id = "vafi_gait_abnormality", domain = "observation",supplement = "vafi_gait_ataxia"),
    vafi_falls            = list(id = "vafi_falls",            domain = "observation",supplement = "vafi_fall_injury"),
    vafi_peripheral_neuropathy = list(id = "vafi_peripheral_neuropathy", domain = "condition", supplement = NULL),
    # Neurological / Mental Health
    vafi_dementia         = list(id = "vafi_dementia",         domain = "condition",  supplement = NULL),
    vafi_depression       = list(id = "vafi_depression",       domain = "condition",  supplement = NULL),
    vafi_anxiety          = list(id = "vafi_anxiety",          domain = "condition",  supplement = NULL),
    vafi_parkinsons       = list(id = "vafi_parkinsons",       domain = "condition",  supplement = NULL),
    # General Health / Functional
    vafi_anemia           = list(id = "vafi_anemia",           domain = "condition",  supplement = NULL),
    vafi_thyroid          = list(id = "vafi_thyroid",          domain = "condition",  supplement = NULL),
    vafi_incontinence     = list(id = "vafi_incontinence",     domain = "condition",  supplement = NULL),
    vafi_muscle_wasting   = list(id = "vafi_muscle_wasting",   domain = "condition",  supplement = NULL),
    vafi_vision_impairment= list(id = "vafi_vision_impairment",domain = "condition",  supplement = NULL),
    vafi_hearing_loss     = list(id = "vafi_hearing_loss",     domain = "condition",  supplement = NULL),
    vafi_weight_loss      = list(id = "vafi_weight_loss",      domain = "observation",supplement = NULL),
    vafi_chronic_pain     = list(id = "vafi_chronic_pain",     domain = "condition",  supplement = NULL),
    vafi_failure_to_thrive= list(id = "vafi_failure_to_thrive",domain = "condition",  supplement = NULL),
    vafi_fatigue          = list(id = "vafi_fatigue",          domain = "observation",supplement = NULL)
  )

  # Supplement covariate domains (for the OR'd supplements)
  supplement_domains <- list(
    vafi_kidney_procedure = "procedure",
    vafi_gait_ataxia      = "condition",
    vafi_fall_injury      = "condition"
  )

  # Pull flags for each deficit (with OR supplement)
  cov_flags <- data.frame(person_id = pid)
  for (def in names(vafi_defs)) {
    d <- vafi_defs[[def]]
    ids <- cov_map[[d$id]]
    if (is.null(ids)) { cov_flags[[def]] <- 0L; next }
    flag <- get_cov_flag(pid, ids, d$domain)
    if (!is.null(d$supplement)) {
      sup_ids <- cov_map[[d$supplement]]
      if (!is.null(sup_ids)) {
        sup_domain <- supplement_domains[[d$supplement]] %||% "condition"
        flag <- pmax(flag, get_cov_flag(pid, sup_ids, sup_domain))
      }
    }
    cov_flags[[def]] <- flag
    message(sprintf("  %-30s n=%d (%.0f%%)", def, sum(flag), mean(flag)*100))
  }

  # Pull study-specific covariates for Table 1
  for (cid in c("amp_toe_foot", "amp_ankle_bka", "amp_aka", "amp_urgent", "tobacco_use")) {
    ids <- cov_map[[cid]]
    dom <- if (cid == "tobacco_use") "condition" else "procedure"
    cov_flags[[cid]] <- if (!is.null(ids)) get_cov_flag(pid, ids, dom) else 0L
  }

  # Merge everything
  dat <- merge(demo, cov_flags, by = "person_id", all.x = TRUE)

  # VA-FI score = count of 30 deficit flags / 30
  vafi_cols <- names(vafi_defs)
  dat$vafi_score <- rowSums(dat[, vafi_cols], na.rm = TRUE) / 30

  # Cohort-entry indication category — derived from the VA-FI PVD/diabetes
  # deficit flags (3-year lookback) rather than an exact condition_start_date
  # match to the index date. PVD/diabetes are typically pre-existing chronic
  # diagnoses whose condition_start_date long precedes the index amputation,
  # so an exact-date match against the index date returns nothing; a lookback
  # window reflects clinical presence of the indication instead.
  dat$indication <- with(dat, ifelse(
    vafi_pvd == 1 & vafi_diabetes == 1, "PVD + Diabetes",
    ifelse(vafi_pvd == 1, "PVD only",
    ifelse(vafi_diabetes == 1, "Diabetes only", "Unknown"))
  ))

  # Discharge type: home vs non-home
  # Concept IDs for "home" discharge: 8536 (Home), 8717 (Patient self-discharge),
  # 4161979 (Discharge to home), 0 (unknown/NULL).
  # Anything else is considered non-home (SNF, rehab, LTAC, hospice, etc.)
  home_concept_ids <- c(8536L, 8717L, 4161979L, 0L)
  dat$non_home_discharge <- as.integer(
    !is.na(dat$discharged_to_concept_id) &
      !(dat$discharged_to_concept_id %in% home_concept_ids)
  )

  # ---------------------------------------------------------------------------
  # Amputation anatomic level — collapse to a single mutually exclusive level
  # ---------------------------------------------------------------------------
  # amp_aka / amp_ankle_bka / amp_toe_foot are independent presence flags: a
  # single patient can trip more than one within the index window (bilateral
  # amputation, or a distal amputation revised to a more proximal level during
  # the same encounter). Reported as raw flags they overlap, so the subtype
  # percentages can sum to >100%. For Table 1 we partition the cohort by
  # assigning each patient to their MOST PROXIMAL (highest) recorded level:
  #   Above-knee (AKA)  >  Below-knee / ankle (BKA)  >  Toe / foot
  # The original overlapping flags are left untouched; the mutually exclusive
  # versions carry an "_excl" suffix and are what the amputation-subtype rows
  # below report. amp_urgent is a separate procedure attribute (not an anatomic
  # level) and stays an independent, non-exclusive flag.
  dat$amp_aka       <- ifelse(is.na(dat$amp_aka),       0L, dat$amp_aka)
  dat$amp_ankle_bka <- ifelse(is.na(dat$amp_ankle_bka), 0L, dat$amp_ankle_bka)
  dat$amp_toe_foot  <- ifelse(is.na(dat$amp_toe_foot),  0L, dat$amp_toe_foot)
  dat$amp_level <- factor(
    ifelse(dat$amp_aka == 1,       "Above-knee",
    ifelse(dat$amp_ankle_bka == 1, "Below-knee / ankle",
    ifelse(dat$amp_toe_foot == 1,  "Toe / foot", "None recorded"))),
    levels = c("Above-knee", "Below-knee / ankle", "Toe / foot", "None recorded")
  )
  dat$amp_aka_excl       <- as.integer(dat$amp_level == "Above-knee")
  dat$amp_ankle_bka_excl <- as.integer(dat$amp_level == "Below-knee / ankle")
  dat$amp_toe_foot_excl  <- as.integer(dat$amp_level == "Toe / foot")
  n_amp_unclassified <- sum(dat$amp_level == "None recorded")
  if (n_amp_unclassified > 0) {
    message(sprintf(
      "[descriptive] %d patient(s) had no AKA/BKA/toe-foot procedure code in the index window; excluded from the mutually exclusive amputation-subtype rows.",
      n_amp_unclassified))
  }


  # ===========================================================================
  # A. TABLE 1
  # ===========================================================================
  message("[descriptive] Building Table 1 ...")

  fmt_pct <- function(n, total) sprintf("%d (%.1f%%)", n, n / total * 100)
  fmt_med <- function(x) {
    q <- quantile(x, c(0.25, 0.5, 0.75), na.rm = TRUE)
    sprintf("%.0f [%.0f–%.0f]", q[2], q[1], q[3])
  }
  # For proportions like vafi_score (deficit count / 30, range 0-1) — %.0f
  # rounds nearly all values to 0, so a 2-decimal formatter is needed instead.
  fmt_med_dec <- function(x) {
    q <- quantile(x, c(0.25, 0.5, 0.75), na.rm = TRUE)
    sprintf("%.2f [%.2f–%.2f]", q[2], q[1], q[3])
  }

  n_ed  <- sum(dat$ed_visit)
  n_no  <- sum(!dat$ed_visit)

  # Helper: compute row for a binary covariate
  tbl_row <- function(label, col, grp = dat$ed_visit) {
    x_all <- dat[[col]]
    data.frame(
      Variable     = label,
      Overall      = fmt_pct(sum(x_all,   na.rm = TRUE), n_total),
      ED_yes       = fmt_pct(sum(x_all[grp == 1], na.rm = TRUE), n_ed),
      ED_no        = fmt_pct(sum(x_all[grp == 0], na.rm = TRUE), n_no),
      stringsAsFactors = FALSE
    )
  }

  # Age
  age_row <- data.frame(
    Variable = "Age at index, median [IQR]",
    Overall  = fmt_med(dat$age_at_index),
    ED_yes   = fmt_med(dat$age_at_index[dat$ed_visit == 1]),
    ED_no    = fmt_med(dat$age_at_index[dat$ed_visit == 0]),
    stringsAsFactors = FALSE
  )

  # Sex
  sex_row <- tbl_row("Female sex, n (%)",
                     "gender_concept_id") # will be wrong; use label
  sex_row$Overall <- fmt_pct(sum(dat$sex %in% c("FEMALE", "Female"), na.rm = TRUE), n_total)
  sex_row$ED_yes  <- fmt_pct(sum(dat$sex[dat$ed_visit == 1] %in% c("FEMALE", "Female"), na.rm = TRUE), n_ed)
  sex_row$ED_no   <- fmt_pct(sum(dat$sex[dat$ed_visit == 0] %in% c("FEMALE", "Female"), na.rm = TRUE), n_no)

  # Tobacco use (moved from Amputation characteristics — a patient-level
  # demographic/risk-factor characteristic, not a property of the procedure).
  tobacco_row <- tbl_row("Tobacco use", "tobacco_use")

  # Index admission LOS and non-home discharge (moved from the outcomes
  # summary — Table 2 — so they can be stratified by ED visit status here).
  los_row <- data.frame(
    Variable = "Index admission LOS, days, median [IQR]",
    Overall  = fmt_med(dat$los_days),
    ED_yes   = fmt_med(dat$los_days[dat$ed_visit == 1]),
    ED_no    = fmt_med(dat$los_days[dat$ed_visit == 0]),
    stringsAsFactors = FALSE
  )
  nhd_row <- tbl_row("Non-home discharge", "non_home_discharge")

  # VA-FI score (summary only — individual components are reported in Table 3)
  vafi_row <- data.frame(
    Variable = "VA-FI score, median [IQR]",
    Overall  = fmt_med_dec(dat$vafi_score),
    ED_yes   = fmt_med_dec(dat$vafi_score[dat$ed_visit == 1]),
    ED_no    = fmt_med_dec(dat$vafi_score[dat$ed_visit == 0]),
    stringsAsFactors = FALSE
  )

  # Amputation subtype — mutually exclusive anatomic levels (highest wins; see
  # the amp_level derivation above). Ordered most-proximal to most-distal.
  # These three rows now partition the cohort and sum to <=100% (the shortfall,
  # if any, is patients with no AKA/BKA/toe-foot code in the index window).
  # Urgent / emergency is a separate procedure attribute, not a level, so it
  # remains an independent flag and is not part of the partition.
  amp_rows <- rbind(
    tbl_row("Above-knee amputation",          "amp_aka_excl"),
    tbl_row("Below-knee / ankle amputation",  "amp_ankle_bka_excl"),
    tbl_row("Toe / foot amputation",          "amp_toe_foot_excl"),
    tbl_row("Urgent / emergency procedure",   "amp_urgent")
  )

  # Cohort-entry indication (mutually exclusive categories)
  indication_levels <- c("PVD only", "PVD + Diabetes", "Diabetes only")
  indication_rows <- do.call(rbind, lapply(indication_levels, function(lvl) {
    x_all <- as.integer(dat$indication == lvl)
    data.frame(
      Variable = lvl,
      Overall  = fmt_pct(sum(x_all), n_total),
      ED_yes   = fmt_pct(sum(x_all[dat$ed_visit == 1]), n_ed),
      ED_no    = fmt_pct(sum(x_all[dat$ed_visit == 0]), n_no),
      stringsAsFactors = FALSE
    )
  }))

  # Race distribution (one row per observed race category)
  race_levels <- sort(unique(dat$race))
  race_rows <- do.call(rbind, lapply(race_levels, function(lvl) {
    x_all <- as.integer(dat$race == lvl)
    data.frame(
      Variable = lvl,
      Overall  = fmt_pct(sum(x_all, na.rm = TRUE), n_total),
      ED_yes   = fmt_pct(sum(x_all[dat$ed_visit == 1], na.rm = TRUE), n_ed),
      ED_no    = fmt_pct(sum(x_all[dat$ed_visit == 0], na.rm = TRUE), n_no),
      stringsAsFactors = FALSE
    )
  }))

  # VA-FI component rows
  vafi_labels <- c(
    vafi_afib              = "Atrial fibrillation",
    vafi_cad               = "Coronary artery disease",
    vafi_heart_failure     = "Heart failure",
    vafi_hypertension      = "Hypertension",
    vafi_diabetes          = "Diabetes mellitus",
    vafi_ckd               = "Chronic kidney disease / dialysis",
    vafi_stroke            = "Cerebrovascular disease / stroke",
    vafi_pvd               = "Peripheral vascular disease",
    vafi_cancer            = "Malignant neoplasm",
    vafi_liver             = "Liver disease",
    vafi_chronic_lung      = "Chronic lung disease",
    vafi_arthritis         = "Arthritis",
    vafi_osteoporosis      = "Osteoporosis",
    vafi_gait_abnormality  = "Gait abnormality / ataxia",
    vafi_falls             = "Falls / fall-related injury",
    vafi_peripheral_neuropathy = "Peripheral neuropathy",
    vafi_dementia          = "Dementia",
    vafi_depression        = "Depression",
    vafi_anxiety           = "Anxiety disorder",
    vafi_parkinsons        = "Parkinson's disease",
    vafi_anemia            = "Anemia",
    vafi_thyroid           = "Thyroid disease",
    vafi_incontinence      = "Urinary / fecal incontinence",
    vafi_muscle_wasting    = "Muscle wasting / cachexia",
    vafi_vision_impairment = "Vision impairment",
    vafi_hearing_loss      = "Hearing loss",
    vafi_weight_loss       = "Unintentional weight loss",
    vafi_chronic_pain      = "Chronic pain",
    vafi_failure_to_thrive = "Failure to thrive",
    vafi_fatigue           = "Fatigue / malaise"
  )

  # Header rows
  hdr <- function(label) data.frame(Variable = label, Overall = "", ED_yes = "", ED_no = "",
                                    stringsAsFactors = FALSE)

  table1 <- rbind(
    data.frame(Variable = "N", Overall = as.character(n_total),
               ED_yes = as.character(n_ed), ED_no = as.character(n_no),
               stringsAsFactors = FALSE),
    hdr("Demographics"),
    age_row, sex_row, race_rows, tobacco_row,
    hdr("Cohort-entry indication"),
    indication_rows,
    hdr("Amputation characteristics"),
    amp_rows, los_row, nhd_row,
    hdr("Frailty"),
    vafi_row
  )
  # Column names are kept human-readable (spaces/parens) in the CSV; downstream
  # readers (report_descriptive.R) must use read.csv(check.names = FALSE) to
  # preserve them verbatim — otherwise R mangles them (e.g. "ED visit (n=53)"
  # becomes "ED.visit..n.53..").
  names(table1) <- c("Variable", "Overall",
                     sprintf("ED visit (n=%d)", n_ed),
                     sprintf("No ED visit (n=%d)", n_no))

  write.csv(table1, file.path(out_dir, "table1.csv"), row.names = FALSE)

  # Word version
  ft <- flextable::flextable(table1) |>
    flextable::bold(part = "header") |>
    flextable::autofit()
  doc <- officer::read_docx() |>
    officer::body_add_par("Table 1. Cohort characteristics", style = "heading 1") |>
    flextable::body_add_flextable(ft)
  print(doc, target = file.path(out_dir, "table1.docx"))
  message("[descriptive] Table 1 written.")


  # ===========================================================================
  # B. OUTCOME DESCRIPTION
  # ===========================================================================
  message("[descriptive] Building outcome summary ...")

  # ---- Time-anchored outcome event flags (Table 2a) --------------------------
  # ED (30d) and readmission (30d/90d) are anchored to hospital discharge;
  # mortality (30d/90d/1y) is anchored to the index/operative date (see the
  # demo_sql DATEDIFF definitions above). A missing days_to_* value means the
  # event never occurred and is scored as a non-event. Readmission requires
  # days_to_readmit >= 1 (strictly after discharge; the SQL already enforces
  # visit_start_date > cohort_end_date). Death on the index date itself
  # (days_to_death = 0) counts toward 30-day mortality.
  ev <- function(days, lo, hi) as.integer(!is.na(days) & days >= lo & days <= hi)
  dat$ed_30      <- as.integer(dat$ed_visit == 1 & !is.na(dat$days_to_ed) &
                                 dat$days_to_ed >= 0 & dat$days_to_ed <= 30)
  dat$readmit_30 <- ev(dat$days_to_readmit, 1, 30)
  dat$readmit_90 <- ev(dat$days_to_readmit, 1, 90)
  dat$death_30   <- ev(dat$days_to_death, 0, 30)
  dat$death_90   <- ev(dat$days_to_death, 0, 90)
  dat$death_365  <- ev(dat$days_to_death, 0, 365)

  outcomes_summary <- rbind(
    data.frame(metric = "ED visit within 90 days",
               value  = fmt_pct(n_ed, n_total), stringsAsFactors = FALSE),
    data.frame(metric = "ED visit within 30 days",
               value  = fmt_pct(sum(dat$ed_30), n_total), stringsAsFactors = FALSE),
    data.frame(metric = "Days to ED visit (among ED+), median [IQR]",
               value  = fmt_med(dat$days_to_ed[dat$ed_visit == 1]),
               stringsAsFactors = FALSE),
    data.frame(metric = "Inpatient readmission within 30 days",
               value  = fmt_pct(sum(dat$readmit_30), n_total), stringsAsFactors = FALSE),
    data.frame(metric = "Inpatient readmission within 90 days",
               value  = fmt_pct(sum(dat$readmit_90), n_total), stringsAsFactors = FALSE),
    data.frame(metric = "Mortality within 30 days (from index)",
               value  = fmt_pct(sum(dat$death_30), n_total), stringsAsFactors = FALSE),
    data.frame(metric = "Mortality within 90 days (from index)",
               value  = fmt_pct(sum(dat$death_90), n_total), stringsAsFactors = FALSE),
    data.frame(metric = "Mortality within 1 year (from index)",
               value  = fmt_pct(sum(dat$death_365), n_total), stringsAsFactors = FALSE)
  )
  write.csv(outcomes_summary, file.path(out_dir, "outcomes_summary.csv"), row.names = FALSE)
  message("[descriptive] Outcome summary written.")

  # ---- Diagnoses associated with the ED visit, categorized --------------------
  # For each ED-visit patient, pull condition_occurrence records linked via
  # visit_occurrence_id to the specific ED encounter (not merely dated the
  # same calendar day, which could also pick up an unrelated encounter on
  # that date, or miss a condition coded with a different date on the correct
  # visit). The ED encounter's visit_occurrence_id is re-derived here with the
  # same two-arm logic as cohorts/outcome_ed_visit.sql:
  #   Arm 1: visit_occurrence.visit_concept_id = 9203 (Emergency Room Visit),
  #          matched by visit_start_date = the cohort's index date.
  #   Arm 2: observation.observation_concept_id = 4176269 (Emergency room
  #          admission, SNOMED 50849002) -- the route Synthea's ETL uses --
  #          matched by observation_date = the cohort's index date, using
  #          the observation row's own visit_occurrence_id (confirmed
  #          populated in this CDM build via a direct query).
  # There is no reliable OMOP-standard "primary diagnosis" flag in
  # Synthea-derived data, so every condition linked to that visit_occurrence
  # is tallied.
  #
  # Each distinct diagnosis concept is categorized into one of:
  #   "Amputation complication" — descends from any of the concepts below
  #     (broadened 2026-07 to capture any code associated with amputation
  #     or residual-limb pain, not just the narrow stump-infection rollup):
  #       4345680 Disorder of amputation stump (infection/hematoma/
  #         dehiscence/necrosis/neuroma/contracture/edema/bony prominence/
  #         poorly shaped stump), [vocab query]
  #       4105631 Phantom limb (with pain / without pain / supernumerary),
  #         [vocab query]
  #       4082797 Limb stump pain (leaf concept), [vocab query]
  #       602328  Pain of amputation stump of right lower limb, [vocab query]
  #       608437  Pain of amputation stump of left upper limb, [vocab query]
  #       608438  Pain of amputation stump of left lower limb, [vocab query]
  #       608439  Pain of amputation stump of right upper limb, [vocab query]
  #         (the four laterality "pain of stump" concepts above are NOT
  #         descendants of 4082797/4345680 in this vocabulary build --
  #         verified via concept_ancestor; their bilateral counterparts,
  #         "Bilateral amputation stump pain of lower/upper limbs", are
  #         descendants of these four so are captured automatically)
  #       4008245 Stump neuralgia (leaf concept), [vocab query]
  #       37167032 Jumpy stump syndrome (leaf concept), [vocab query]
  #     Broadened further 2026-07-10 after reviewing a real Supplemental
  #     Table S4 "Other" list: generic post-surgical complication codes with
  #     no stump-specific qualifier were falling to "Other" even though, in
  #     this post-amputation ED cohort, they are overwhelmingly likely to be
  #     about the amputation surgical site. Added (all [vocab query]):
  #       442019   Complication of procedure
  #       4300243  Postoperative complication
  #       439981   Wound dehiscence (Condition domain)
  #       36712827 Dehiscence of external surgical incision wound
  #       4334801  Surgical site infection
  #       440303   Postoperative seroma
  #       4115171  Pain in right lower limb
  #       4117695  Pain in left lower limb
  #         (these two generic limb-pain concepts are the ANCESTORS of
  #         602328/608438 above, not descendants -- i.e. the code a
  #         clinician actually charts for stump pain is often this generic
  #         one, not the amputation-stump-specific code; verified via
  #         concept_ancestor. Added directly since concept_ancestor rollup
  #         only reaches descendants, not ancestors, of a defining concept)
  #       4150125  Persistent pain following procedure, [vocab query]
  #     NOT added (left in "Other" as too nonspecific / ambiguous to
  #     attribute to the amputation without over-claiming): Disorder of
  #     skin and/or subcutaneous tissue, Localized infection of skin AND/OR
  #     subcutaneous tissue, Cellulitis of buttock/toe, Mechanical
  #     complication of vascular device, Infection AND/OR inflammatory
  #     reaction due to internal prosthetic device/implant/graft, Pain in
  #     right arm/foot (foot pain post-BKA/AKA is likely the contralateral
  #     limb, i.e. PAD-related, not the stump).
  #   <VA-FI component label> — descends from any concept in that component's
  #     definition (covariates/covariate_concepts.csv); first matching
  #     component wins if a concept is shared across components.
  #   "Other" — neither of the above.
  # Category assignment happens per DISTINCT diagnosis concept (not per
  # person-diagnosis pair) via two scoped concept_ancestor queries, then
  # merged back onto the person-level diagnosis pull in R.
  amp_complication_ancestors <- c(4345680L, 4105631L, 4082797L,
                                  602328L, 608437L, 608438L, 608439L,
                                  4008245L, 37167032L,
                                  442019L, 4300243L, 439981L, 36712827L,
                                  4334801L, 440303L, 4115171L, 4117695L,
                                  4150125L)

  # ---- Check whether condition_status_concept_id can identify a primary diagnosis ----
  # OMOP's condition_status_concept_id (vocabulary_id = 'Condition Status') is the
  # field meant to carry primary/secondary/admission/discharge diagnosis status.
  # It is 0 (unpopulated) for every condition_occurrence row in Synthea-derived
  # builds -- verified directly -- so no primary-diagnosis distinction is possible
  # there. On source systems whose ETL captures a principal-diagnosis flag from
  # claims data (e.g. Duke OMOP / VA VINCI, if their UB-04/837 institutional claims
  # ETL populates this field), it may be usable. A quick check here decides whether
  # to restrict the diagnosis pull below to primary-status records only, or (the
  # fallback, and current behavior on Synthea data) tally every diagnosis linked
  # to the visit with equal weight.
  primary_status_ids <- c(32901L, 32902L, 32903L, 32904L)
  #  32901 Primary admission diagnosis, [vocab query]
  #  32902 Primary diagnosis, [vocab query]
  #  32903 Primary discharge diagnosis, [vocab query]
  #  32904 Primary referral diagnosis, [vocab query]
  primary_status_check_sql <- sprintf("
    SELECT COUNT(*) AS n
    FROM %s.condition_occurrence
    WHERE condition_status_concept_id IN (%s)
  ", cdm, paste(primary_status_ids, collapse = ", "))
  primary_status_n <- DatabaseConnector::querySql(conn, primary_status_check_sql, snakeCaseToCamelCase = FALSE)
  names(primary_status_n) <- tolower(names(primary_status_n))
  primary_dx_available <- isTRUE(primary_status_n$n[1] > 0)
  message(sprintf(
    "[descriptive]   condition_status_concept_id primary-diagnosis flag %s in this CDM build (%d matching record(s) overall)",
    if (primary_dx_available) "AVAILABLE -- restricting ED-visit diagnoses to primary status" else "NOT populated -- tallying all diagnoses linked to the visit",
    primary_status_n$n[1]
  ))
  write.csv(
    data.frame(mode = if (primary_dx_available) "primary_only" else "all_diagnoses"),
    file.path(out_dir, "ed_visit_diagnosis_filter_mode.csv"), row.names = FALSE
  )

  ed_person_ids <- dat$person_id[dat$ed_visit == 1 & !is.na(dat$ed_date)]
  if (length(ed_person_ids) > 0) {
    primary_status_filter_sql <- if (primary_dx_available) {
      sprintf(" AND co.condition_status_concept_id IN (%s)", paste(primary_status_ids, collapse = ", "))
    } else {
      ""
    }
    ed_dx_raw_sql <- sprintf("
      SELECT co.person_id, co.condition_concept_id, c.concept_name AS diagnosis
      FROM %s.condition_occurrence co
      JOIN %s.concept c ON c.concept_id = co.condition_concept_id
      JOIN (
        -- Arm 1: visit_occurrence-sourced ED visit
        SELECT tc.subject_id AS person_id, vo.visit_occurrence_id
        FROM %s.%s tc
        JOIN %s.%s oc
          ON oc.subject_id = tc.subject_id AND oc.cohort_definition_id = %d
        JOIN %s.visit_occurrence vo
          ON vo.person_id = tc.subject_id
         AND vo.visit_concept_id = 9203
         AND vo.visit_start_date = oc.cohort_start_date
        WHERE tc.cohort_definition_id = %d

        UNION

        -- Arm 2: observation-sourced ED visit (Synthea ETL route)
        SELECT tc.subject_id AS person_id, ob.visit_occurrence_id
        FROM %s.%s tc
        JOIN %s.%s oc
          ON oc.subject_id = tc.subject_id AND oc.cohort_definition_id = %d
        JOIN %s.observation ob
          ON ob.person_id = tc.subject_id
         AND ob.observation_concept_id = 4176269
         AND ob.observation_date = oc.cohort_start_date
        WHERE tc.cohort_definition_id = %d
      ) ed ON ed.person_id = co.person_id
          AND co.visit_occurrence_id = ed.visit_occurrence_id
      WHERE ed.visit_occurrence_id IS NOT NULL%s
    ", cdm, vocab,
       res, ctable, res, ctable, oid, cdm, tid,
       res, ctable, res, ctable, oid, cdm, tid,
       primary_status_filter_sql)
    ed_dx_raw <- DatabaseConnector::querySql(conn, ed_dx_raw_sql, snakeCaseToCamelCase = FALSE)
    names(ed_dx_raw) <- tolower(names(ed_dx_raw))
  } else {
    ed_dx_raw <- data.frame(person_id = integer(0), condition_concept_id = integer(0),
                            diagnosis = character(0))
  }

  if (nrow(ed_dx_raw) > 0) {
    distinct_concepts <- unique(ed_dx_raw$condition_concept_id)

    # Amputation-complication membership per distinct diagnosis concept.
    amp_flag_sql <- sprintf("
      SELECT DISTINCT ca.descendant_concept_id AS condition_concept_id
      FROM %s.concept_ancestor ca
      WHERE ca.ancestor_concept_id IN (%s)
        AND ca.descendant_concept_id IN (%s)
    ", vocab, paste(amp_complication_ancestors, collapse = ", "),
       paste(distinct_concepts, collapse = ", "))
    amp_flagged <- DatabaseConnector::querySql(conn, amp_flag_sql, snakeCaseToCamelCase = FALSE)
    names(amp_flagged) <- tolower(names(amp_flagged))

    # VA-FI component membership per distinct diagnosis concept (first
    # matching component per concept via MIN() on a component sort key).
    vafi_ancestor_map <- do.call(rbind, lapply(names(vafi_labels), function(id) {
      ids <- cov_map[[vafi_defs[[id]]$id]]
      if (is.null(ids)) return(NULL)
      data.frame(covariate_id = id, ancestor_concept_id = as.integer(ids), stringsAsFactors = FALSE)
    }))
    vafi_flag_sql <- sprintf("
      SELECT ca.descendant_concept_id AS condition_concept_id, ca.ancestor_concept_id
      FROM %s.concept_ancestor ca
      WHERE ca.ancestor_concept_id IN (%s)
        AND ca.descendant_concept_id IN (%s)
    ", vocab, paste(unique(vafi_ancestor_map$ancestor_concept_id), collapse = ", "),
       paste(distinct_concepts, collapse = ", "))
    vafi_flagged <- DatabaseConnector::querySql(conn, vafi_flag_sql, snakeCaseToCamelCase = FALSE)
    names(vafi_flagged) <- tolower(names(vafi_flagged))
    vafi_flagged <- merge(vafi_flagged, vafi_ancestor_map, by = "ancestor_concept_id")
    # One row per concept: first matching component (alphabetical covariate_id
    # as a stable tiebreak) when a concept is shared across components.
    vafi_flagged <- vafi_flagged[order(vafi_flagged$condition_concept_id, vafi_flagged$covariate_id), ]
    vafi_first_match <- vafi_flagged[!duplicated(vafi_flagged$condition_concept_id),
                                     c("condition_concept_id", "covariate_id")]

    concept_category <- data.frame(condition_concept_id = distinct_concepts, stringsAsFactors = FALSE)
    concept_category$category <- "Other"
    concept_category$category[concept_category$condition_concept_id %in% vafi_first_match$condition_concept_id] <-
      vafi_labels[vafi_first_match$covariate_id[match(
        concept_category$condition_concept_id[concept_category$condition_concept_id %in% vafi_first_match$condition_concept_id],
        vafi_first_match$condition_concept_id
      )]]
    concept_category$category[concept_category$condition_concept_id %in% amp_flagged$condition_concept_id] <- "Amputation complication"

    ed_dx_raw <- merge(ed_dx_raw, concept_category, by = "condition_concept_id")
    ed_dx_df <- aggregate(person_id ~ category + diagnosis, data = ed_dx_raw,
                          FUN = function(x) length(unique(x)))
    names(ed_dx_df)[names(ed_dx_df) == "person_id"] <- "n"
    # Sort: "Amputation complication" first, "Other" last, VA-FI components
    # alphabetically in between; descending count within category.
    cat_rank <- ifelse(ed_dx_df$category == "Amputation complication", 0,
                       ifelse(ed_dx_df$category == "Other", 2, 1))
    ed_dx_df <- ed_dx_df[order(cat_rank, ed_dx_df$category, -ed_dx_df$n), ]

    # Per-category distinct-patient totals (not a simple sum of the
    # per-diagnosis counts above, since one patient can contribute more than
    # one diagnosis within a category). Table 2b shows the "Other" category
    # as a single collapsed row using this total; the per-diagnosis detail
    # behind that row is written separately for Supplemental Table S4.
    ed_dx_category_totals <- aggregate(person_id ~ category, data = ed_dx_raw,
                                       FUN = function(x) length(unique(x)))
    names(ed_dx_category_totals)[names(ed_dx_category_totals) == "person_id"] <- "n"
  } else {
    ed_dx_df <- data.frame(category = character(0), diagnosis = character(0), n = integer(0))
    ed_dx_category_totals <- data.frame(category = character(0), n = integer(0))
  }
  write.csv(ed_dx_df[, c("category", "diagnosis", "n")],
           file.path(out_dir, "ed_visit_diagnoses.csv"), row.names = FALSE)
  write.csv(ed_dx_category_totals, file.path(out_dir, "ed_visit_diagnosis_category_totals.csv"), row.names = FALSE)
  message("[descriptive] ED visit diagnosis breakdown written.")


  # ===========================================================================
  # C. TIMING OF ED VISIT — HISTOGRAM BY DAYS FROM DISCHARGE
  # ===========================================================================
  # The outcome window (config$prediction_window_days = 90) is defined and
  # enforced relative to hospital DISCHARGE (see cohorts/outcome_ed_visit.sql:
  # visit/observation date must fall within 90 days of cohort_end_date), not
  # relative to the index operative date. days_to_ed is therefore guaranteed
  # to fall in [1, 90] by cohort construction and is the correct x-axis for
  # this figure.
  #
  # pod_of_ed (post-operative day, measured from the index procedure date) is
  # NOT used here: because index admission length of stay varies (median 14
  # days in this cohort), an ED visit on day 90 post-discharge can be well
  # past post-operative day 90, which looked like an out-of-window data bug
  # but was actually pod_of_ed being the wrong reference date for a
  # discharge-anchored outcome window.
  message("[descriptive] Plotting ED visit timing histogram ...")

  ed_timing_df <- dat[dat$ed_visit == 1 & !is.na(dat$days_to_ed), c("person_id", "days_to_ed")]

  p_hist <- ggplot2::ggplot(ed_timing_df, ggplot2::aes(x = days_to_ed)) +
    ggplot2::geom_histogram(binwidth = 5, boundary = 0,
                            fill = "#1B5E8E", colour = "white") +
    ggplot2::scale_x_continuous(limits = c(0, win), breaks = seq(0, win, by = 10)) +
    ggplot2::scale_y_continuous(breaks = scales::breaks_pretty()) +
    ggplot2::labs(
      title    = "Timing of emergency department visit after discharge",
      subtitle = sprintf("n = %d ED visits (of %d total patients); days from hospital discharge",
                         nrow(ed_timing_df), n_total),
      x        = "Days from hospital discharge to ED visit",
      y        = "Count of ED visits"
    ) +
    ggplot2::theme_bw(base_size = 12)

  ggplot2::ggsave(
    file.path(out_dir, "ed_visit_timing_histogram.png"),
    p_hist, width = 7, height = 5, dpi = 300
  )
  message("[descriptive] ED visit timing histogram written.")


  # ===========================================================================
  # D. VA-FI COMPONENT ASSOCIATIONS WITH ED VISIT
  # ===========================================================================
  message("[descriptive] Computing VA-FI component ORs ...")

  or_rows <- lapply(names(vafi_labels), function(col) {
    label <- vafi_labels[[col]]
    x     <- dat[[col]]
    y     <- dat$ed_visit

    n_ed_yes  <- sum(x[y == 1], na.rm = TRUE)
    n_ed_no   <- sum(x[y == 0], na.rm = TRUE)
    pct_ed_yes <- round(n_ed_yes / n_ed * 100, 1)
    pct_ed_no  <- round(n_ed_no  / n_no * 100, 1)

    base_row <- function(or = NA_real_, ci_lo = NA_real_, ci_hi = NA_real_, p_value = NA_real_) {
      data.frame(
        deficit    = label,
        n_ed_yes   = n_ed_yes,   pct_ed_yes = pct_ed_yes,
        n_ed_no    = n_ed_no,    pct_ed_no  = pct_ed_no,
        or = or, ci_lo = ci_lo, ci_hi = ci_hi, p_value = p_value,
        stringsAsFactors = FALSE
      )
    }

    # Skip OR estimation when any of the four 2x2 cells (deficit x ED status)
    # has fewer than 5 observations. This covers both low-count deficits and
    # quasi-complete separation (e.g. diabetes mellitus, present in ~99% of
    # this cohort by cohort-entry design, leaves a near-empty "no diabetes"
    # cell that otherwise produces an unstable OR with an astronomically wide
    # CI from glm()).
    cell_counts <- c(n_ed_yes, n_ed - n_ed_yes, n_ed_no, n_no - n_ed_no)
    if (any(cell_counts < 5)) return(base_row())

    fit <- tryCatch(glm(y ~ x, family = binomial(), data = dat), error = function(e) NULL)
    if (is.null(fit)) return(base_row())

    ci  <- tryCatch(confint(fit, level = 0.95), error = function(e) matrix(NA, 2, 2))
    est <- coef(fit)[["x"]]
    base_row(
      or      = round(exp(est), 2),
      ci_lo   = round(exp(ci[2, 1]), 2),
      ci_hi   = round(exp(ci[2, 2]), 2),
      p_value = round(summary(fit)$coefficients["x", "Pr(>|z|)"], 4)
    )
  })
  or_df <- do.call(rbind, or_rows)
  or_df <- or_df[order(or_df$or, decreasing = TRUE, na.last = TRUE), ]
  write.csv(or_df, file.path(out_dir, "vafi_component_associations.csv"), row.names = FALSE)

  # Forest plot
  fp_df <- or_df[!is.na(or_df$or), ]
  fp_df$deficit <- factor(fp_df$deficit, levels = fp_df$deficit)

  p_forest <- ggplot2::ggplot(
    fp_df,
    ggplot2::aes(x = or, y = deficit, xmin = ci_lo, xmax = ci_hi)
  ) +
    ggplot2::geom_vline(xintercept = 1, linetype = "dashed", colour = "grey50") +
    ggplot2::geom_errorbarh(height = 0.3, colour = "#444444") +
    ggplot2::geom_point(size = 2.5, colour = "#1B5E8E") +
    ggplot2::scale_x_log10(breaks = c(0.25, 0.5, 1, 2, 4, 8)) +
    ggplot2::labs(
      title = "VA-FI component associations with post-discharge ED visit",
      x     = "Odds ratio (95% CI, log scale)",
      y     = NULL
    ) +
    ggplot2::theme_bw(base_size = 11) +
    ggplot2::theme(panel.grid.major.y = ggplot2::element_blank())

  ggplot2::ggsave(
    file.path(out_dir, "vafi_forest_plot.png"),
    p_forest, width = 8, height = 9, dpi = 300
  )
  message("[descriptive] VA-FI OR table and forest plot written.")


  # ===========================================================================
  # E. VA-FI DISCRIMINATION AND CALIBRATION (TEMPORAL SPLIT RECALIBRATION)
  # ===========================================================================
  # "Predicted" probability is the fitted value from a univariable logistic
  # regression model: glm(ed_visit ~ vafi_score, family = binomial()). The
  # VA-FI score itself is not a probability, so a link function is needed to
  # map it onto (0, 1) before discrimination/calibration metrics can be computed.
  #
  # TEMPORAL TRAIN / TEST SPLIT (mirrors pad-amp-nhd-val/R/risk_score_pipeline.R
  # evaluate_integer_risk_score()): rows are sorted chronologically by
  # index_date; the earlier half becomes the training set used only to fit the
  # recalibration model (glm(ed_visit ~ vafi_score) on train), and the later
  # half becomes the test set used for every reported discrimination and
  # calibration metric. Evaluating on held-out future data approximates how
  # the VA-FI score would perform when recalibrated to an earlier local
  # population and then applied prospectively -- avoiding the optimistic bias
  # of fitting and evaluating the recalibration model on the same rows.
  #
  # Metric set and computation approach mirror pad-amp-nhd-val/R/risk_score_pipeline.R
  # (probability_metrics() / compute_bootstrap_cis()) for cross-study consistency:
  #   AUROC                — area under the ROC curve (pROC, direction = "<")
  #   AUPRC                — area under the precision-recall curve (PRROC)
  #   Brier                — mean squared prediction error
  #   ECE                  — expected calibration error, 10 equal-frequency bins
  #   CalibrationIntercept — glm(y ~ 1 + offset(logit(p))); ideal value = 0
  #   CalibrationSlope     — glm(y ~ logit(p)); ideal value = 1
  # 95% CIs are bootstrap percentile intervals (B = 500 resamples of *test-set*
  # rows, holding the fitted pred_prob fixed per resample — i.e. treating
  # pred_prob as a fixed "lookup" model being evaluated, not refit per resample).
  # ===========================================================================
  message("[descriptive] VA-FI discrimination and calibration (temporal split) ...")

  dat <- dat[order(dat$index_date), ]
  n_train <- floor(n_total / 2L)
  n_test  <- n_total - n_train
  split_date <- as.character(dat$index_date[n_train])
  dat$split_set <- c(rep("train", n_train), rep("test", n_test))
  message(sprintf(
    "[descriptive] Temporal split: train n=%d (through %s), test n=%d (after %s)",
    n_train, split_date, n_test, split_date
  ))

  # Fit the recalibration model on train only; score all rows so pred_prob is
  # available cohort-wide for the calibration plot and any downstream export.
  fit_vafi <- glm(ed_visit ~ vafi_score, family = binomial(),
                  data = dat[dat$split_set == "train", ])
  dat$pred_prob <- predict(fit_vafi, newdata = dat, type = "response")

  write.csv(
    data.frame(split_date = split_date, n_train = n_train, n_test = n_test),
    file.path(out_dir, "split_info.csv"), row.names = FALSE
  )

  clamp_probability <- function(p, eps = 1e-6) pmin(pmax(p, eps), 1 - eps)

  compute_ece <- function(y, p, n_bins = 10) {
    p <- clamp_probability(p)
    d <- data.frame(y = as.numeric(y), p = as.numeric(p))
    probs <- unique(stats::quantile(d$p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
    if (length(probs) < 3) probs <- c(0, 1)
    d$bin <- cut(d$p, breaks = probs, include.lowest = TRUE)
    predicted_mean <- tapply(d$p, d$bin, mean, na.rm = TRUE)
    observed_mean  <- tapply(d$y, d$bin, mean, na.rm = TRUE)
    bin_size       <- tapply(d$y, d$bin, length)
    abs_diff <- abs(predicted_mean - observed_mean)
    as.numeric(sum(abs_diff * bin_size, na.rm = TRUE) / sum(bin_size, na.rm = TRUE))
  }

  compute_bootstrap_cis <- function(y, p, B = 500, seed = 42) {
    set.seed(seed)
    n <- length(y)
    y <- as.numeric(y)
    p <- clamp_probability(p)

    boot_vals <- lapply(seq_len(B), function(i) {
      idx <- sample.int(n, replace = TRUE)
      yi  <- y[idx]
      pi  <- clamp_probability(p[idx])
      lpi <- qlogis(pi)
      if (length(unique(yi)) < 2) return(NULL)

      auroc_i <- tryCatch(
        as.numeric(pROC::auc(pROC::roc(yi, pi, quiet = TRUE, direction = "<"))),
        error = function(e) NA_real_
      )
      auprc_i <- tryCatch(
        PRROC::pr.curve(scores.class0 = pi[yi == 1], scores.class1 = pi[yi == 0],
                        curve = FALSE)$auc.integral,
        error = function(e) NA_real_
      )
      brier_i     <- mean((pi - yi)^2)
      ece_i       <- tryCatch(compute_ece(yi, pi), error = function(e) NA_real_)
      cal_int_i   <- tryCatch(unname(coef(glm(yi ~ 1 + offset(lpi), family = binomial()))[1]),
                              error = function(e) NA_real_)
      cal_slope_i <- tryCatch(unname(coef(glm(yi ~ lpi, family = binomial()))[2]),
                              error = function(e) NA_real_)

      data.frame(auroc = auroc_i, auprc = auprc_i, brier = brier_i,
                ece = ece_i, cal_int = cal_int_i, cal_slope = cal_slope_i,
                stringsAsFactors = FALSE)
    })

    mat <- do.call(rbind, Filter(Negate(is.null), boot_vals))
    pct_ci <- function(col) {
      v <- mat[[col]]
      as.numeric(quantile(v[!is.na(v)], probs = c(0.025, 0.975), names = FALSE))
    }
    list(
      auroc = pct_ci("auroc"), auprc = pct_ci("auprc"), brier = pct_ci("brier"),
      ece   = pct_ci("ece"),   cal_int = pct_ci("cal_int"), cal_slope = pct_ci("cal_slope")
    )
  }

  # All metrics are evaluated on the held-out test set only.
  test_idx <- dat$split_set == "test"
  y <- dat$ed_visit[test_idx]
  p <- clamp_probability(dat$pred_prob[test_idx])
  lp <- qlogis(p)

  roc_obj  <- pROC::roc(y, p, quiet = TRUE, direction = "<")
  auroc    <- as.numeric(pROC::auc(roc_obj))
  auprc    <- PRROC::pr.curve(scores.class0 = p[y == 1], scores.class1 = p[y == 0],
                              curve = FALSE)$auc.integral
  brier    <- mean((p - y)^2)
  ece      <- compute_ece(y, p)
  cal_int  <- unname(coef(glm(y ~ 1 + offset(lp), family = binomial()))[1])
  cal_slope <- unname(coef(glm(y ~ lp, family = binomial()))[2])

  cis <- compute_bootstrap_cis(y, p, B = 500)

  disc_df <- data.frame(
    metric   = c("AUROC", "AUPRC", "Brier", "ECE", "CalibrationIntercept", "CalibrationSlope"),
    value    = round(c(auroc, auprc, brier, ece, cal_int, cal_slope), 4),
    ci_lower = round(c(cis$auroc[1], cis$auprc[1], cis$brier[1],
                       cis$ece[1],   cis$cal_int[1], cis$cal_slope[1]), 4),
    ci_upper = round(c(cis$auroc[2], cis$auprc[2], cis$brier[2],
                       cis$ece[2],   cis$cal_int[2], cis$cal_slope[2]), 4),
    stringsAsFactors = FALSE
  )
  write.csv(disc_df, file.path(out_dir, "vafi_discrimination.csv"), row.names = FALSE)
  message(sprintf("[descriptive] AUROC = %.3f (%.3f-%.3f)  ECE = %.3f",
                  auroc, cis$auroc[1], cis$auroc[2], ece))

  # Calibration plot — test set only, rank-based (dplyr::ntile) decile binning
  # rather than cut() on quantile breaks, because VA-FI score is a discrete
  # count/30 and frequently produces tied predicted probabilities that
  # collapse quantile breakpoints (cut() errors on non-unique breaks).
  test_dat <- dat[test_idx, ]
  test_dat$decile <- dplyr::ntile(test_dat$pred_prob, 10)
  cal_df <- test_dat %>%
    dplyr::group_by(decile) %>%
    dplyr::summarise(
      n          = dplyr::n(),
      mean_pred  = mean(pred_prob, na.rm = TRUE),
      obs_rate   = mean(ed_visit,  na.rm = TRUE),
      .groups    = "drop"
    )

  p_cal <- ggplot2::ggplot(cal_df, ggplot2::aes(x = mean_pred, y = obs_rate)) +
    ggplot2::geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey50") +
    ggplot2::geom_point(size = 3, colour = "#1B5E8E") +
    ggplot2::geom_line(colour = "#1B5E8E") +
    ggplot2::scale_x_continuous(
      labels = scales::percent_format(accuracy = 1), limits = c(0, 1)
    ) +
    ggplot2::scale_y_continuous(
      labels = scales::percent_format(accuracy = 1), limits = c(0, 1)
    ) +
    ggplot2::labs(
      title    = "Calibration of VA Frailty Index for ED visit prediction",
      subtitle = sprintf("Test set (n=%d, after %s) | AUROC = %.3f (%.3f-%.3f) | ECE = %.3f",
                         n_test, split_date, auroc, cis$auroc[1], cis$auroc[2], ece),
      x        = "Predicted probability (mean per decile)",
      y        = "Observed event rate"
    ) +
    ggplot2::theme_bw(base_size = 11)

  ggplot2::ggsave(
    file.path(out_dir, "vafi_calibration_plot.png"),
    p_cal, width = 6, height = 6, dpi = 300
  )
  message("[descriptive] Calibration plot written.")


  # ===========================================================================
  # F. SUPPLEMENTAL: PROCEDURE CPT CROSSWALK AND VA-FI ICD-10-CM CROSSWALK
  # ===========================================================================
  # This synthetic (Synthea-derived) CDM records both standard and source
  # concepts in SNOMED for procedures and conditions -- there is no native
  # CPT4/ICD10CM source coding in this build. Both crosswalks below use
  # concept_relationship ('Maps to') to translate each cohort member's actual
  # standard SNOMED concept to the CPT4/HCPCS or ICD-10-CM code(s) that would
  # represent the same clinical fact in claims data (Duke OMOP / VA OMOP).
  # Counts are restricted to this cohort's actual patients (JOIN to the
  # target cohort table) -- NOT a database-wide count of the procedure code.
  # ===========================================================================
  message("[descriptive] Building supplemental procedure/ICD reference ...")

  # ---- Index procedure CPT4/HCPCS crosswalk (cohort-restricted) --------------
  # cohort_procs = each cohort member's actual index-procedure standard
  # concept(s) (from target.index_event.ancestor_concept_ids in
  # study_params.yaml, not hardcoded to one amputation subtype), restricted to
  # this target cohort's patients only.
  index_concept_ids <- as.integer(config$target_index_concept_ids)
  proc_sql <- sprintf("
    WITH cohort_procs AS (
      SELECT DISTINCT po.person_id, po.procedure_concept_id
      FROM %s.procedure_occurrence po
      JOIN %s.%s tc
        ON tc.subject_id = po.person_id AND tc.cohort_definition_id = %d
      WHERE po.procedure_concept_id IN (%s)
    )
    SELECT c.vocabulary_id, c.concept_code, c.concept_name,
           spc.concept_name AS standard_procedure_name,
           COUNT(DISTINCT cp.person_id) n
    FROM cohort_procs cp
    JOIN %s.concept_relationship cr
      ON cr.concept_id_2 = cp.procedure_concept_id
     AND cr.relationship_id = 'Maps to'
     AND cr.invalid_reason IS NULL
    JOIN %s.concept c
      ON c.concept_id = cr.concept_id_1
     AND c.vocabulary_id IN ('CPT4', 'HCPCS')
    JOIN %s.concept spc ON spc.concept_id = cp.procedure_concept_id
    GROUP BY c.vocabulary_id, c.concept_code, c.concept_name, spc.concept_name
    ORDER BY n DESC, c.concept_code
  ", cdm, res, ctable, tid, paste(index_concept_ids, collapse = ", "), vocab, vocab, vocab)
  proc_codes <- DatabaseConnector::querySql(conn, proc_sql, snakeCaseToCamelCase = FALSE)
  names(proc_codes) <- tolower(names(proc_codes))
  write.csv(proc_codes, file.path(out_dir, "amputation_procedure_codes.csv"), row.names = FALSE)
  message(sprintf("[descriptive]   CPT/HCPCS crosswalk: %d candidate code(s) found for %d index concept(s)",
                  nrow(proc_codes), length(index_concept_ids)))

  # ---- VA-FI component ICD-10-CM crosswalk (one code per concept, cohort-restricted) ----
  # Unlike the earlier "one representative code per component" version, this
  # lists one code per underlying standard concept mapped from ANY of a
  # component's ancestor concepts (the full cov_map list, not just the
  # first/primary concept), each with its own cohort-scoped prevalence count.
  # Within a given standard concept, ICD-10-CM sub-codes (e.g. D64, D64.8,
  # D64.89, D64.9) all carry an IDENTICAL count -- concept_ancestor does not
  # capture ICD-10-CM's own internal code hierarchy, so the count is per
  # ancestor_concept_id, not per specific code -- so only the highest-level
  # (shortest/most general) code in each such family is kept; see the
  # deduplication step below for the verification behind this. Supplement
  # covariates (e.g. vafi_kidney_procedure) are excluded -- this table covers
  # the 30 primary VA-FI component definitions only. All counts use the same
  # 3-year lookback as the standard VA-FI deficits; the kidney/dialysis
  # component's lifetime lookback (used elsewhere for vafi_ckd's OR'd
  # supplement) is not reflected here for comparability across components.
  component_concepts <- do.call(rbind, lapply(names(vafi_labels), function(id) {
    ids <- cov_map[[vafi_defs[[id]]$id]]
    if (is.null(ids)) return(NULL)
    data.frame(covariate_id = id, label = unname(vafi_labels[[id]]),
              ancestor_concept_id = as.integer(ids), stringsAsFactors = FALSE)
  }))
  all_ancestor_ids <- unique(component_concepts$ancestor_concept_id)

  icd_sql <- sprintf("
    SELECT cr.concept_id_2 AS ancestor_concept_id,
           c.concept_code  AS icd10cm_code,
           c.concept_name  AS icd10cm_name
    FROM %s.concept_relationship cr
    JOIN %s.concept c ON c.concept_id = cr.concept_id_1
    WHERE cr.concept_id_2 IN (%s)
      AND cr.relationship_id = 'Maps to'
      AND c.vocabulary_id = 'ICD10CM'
      AND cr.invalid_reason IS NULL
  ", vocab, vocab, paste(all_ancestor_ids, collapse = ", "))
  icd_map <- DatabaseConnector::querySql(conn, icd_sql, snakeCaseToCamelCase = FALSE)
  names(icd_map) <- tolower(names(icd_map))

  # Cohort-scoped prevalence per ancestor concept (3-year lookback), computed
  # in one batched query rather than one round trip per component.
  prev_sql <- sprintf("
    SELECT ca.ancestor_concept_id, COUNT(DISTINCT co.person_id) n
    FROM %s.condition_occurrence co
    JOIN %s.concept_ancestor ca ON ca.descendant_concept_id = co.condition_concept_id
    JOIN %s.%s tc
      ON tc.subject_id = co.person_id AND tc.cohort_definition_id = %d
    WHERE ca.ancestor_concept_id IN (%s)
      AND co.condition_start_date BETWEEN DATEADD(day, -1095, tc.cohort_start_date)
                                       AND tc.cohort_start_date
    GROUP BY ca.ancestor_concept_id
  ", cdm, vocab, res, ctable, tid, paste(all_ancestor_ids, collapse = ", "))
  prev_by_ancestor <- DatabaseConnector::querySql(conn, prev_sql, snakeCaseToCamelCase = FALSE)
  names(prev_by_ancestor) <- tolower(names(prev_by_ancestor))

  icd_df <- merge(component_concepts, icd_map, by = "ancestor_concept_id")
  icd_df <- merge(icd_df, prev_by_ancestor, by = "ancestor_concept_id", all.x = TRUE)
  icd_df$n[is.na(icd_df$n)] <- 0L

  # Collapse to one representative (highest-level, i.e. shortest/most general)
  # ICD-10-CM code per underlying standard concept. concept_ancestor does NOT
  # capture ICD-10-CM's own internal code hierarchy (verified directly: e.g.
  # D64 / D64.8 / D64.89 / D64.9 all "Maps to" the SAME single standard
  # concept 439777 "Anemia", with zero concept_ancestor rows relating them to
  # each other), so every code within such a family carries an IDENTICAL
  # patient count (n is computed per ancestor_concept_id, not per specific
  # ICD code). Listing every sub-code alongside its parent therefore adds
  # duplicate rows with no new information; keep only the shortest code
  # (the most general member of the family) per (label, ancestor_concept_id).
  icd_df <- icd_df[order(icd_df$label, icd_df$ancestor_concept_id, nchar(icd_df$icd10cm_code), icd_df$icd10cm_code), ]
  icd_df <- icd_df[!duplicated(icd_df[, c("label", "ancestor_concept_id")]), ]
  icd_df <- icd_df[order(icd_df$label, -icd_df$n, icd_df$icd10cm_code), ]

  write.csv(icd_df[, c("label", "ancestor_concept_id", "icd10cm_code", "icd10cm_name", "n")],
           file.path(out_dir, "vafi_icd_crosswalk.csv"), row.names = FALSE)
  message(sprintf("[descriptive]   ICD-10-CM crosswalk: %d code(s) across %d component(s)",
                  nrow(icd_df), length(unique(icd_df$covariate_id))))
  message("[descriptive] Supplemental procedure/ICD reference written.")

  message("[descriptive] Analysis complete. Outputs in: ", out_dir)
  invisible(list(
    table1             = table1,
    outcomes_summary   = outcomes_summary,
    or_table           = or_df,
    discrimination     = disc_df,
    calibration        = cal_df
  ))
}
