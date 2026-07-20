-- =============================================================================
-- cohorts/outcome_ed_visit.sql
-- OUTCOME COHORT — Emergency department (ED) visit after discharge following
-- major lower extremity amputation.
--
-- WHY A CUSTOM OUTCOME SQL
--   ED visits surface in two OMOP tables depending on how the source system
--   was ETL'd. This SQL uses both to maximise capture:
--
--   (1) visit_occurrence — visit_concept_id = 9203 (Emergency Room Visit).
--       This is the primary source for most CDMs.
--   (2) observation      — observation_concept_id = 4176269 (Emergency room
--       admission; SNOMED 50849002). Synthea ETL routes this event to the
--       observation table; some real-world ETLs do the same.
--
--   The two arms are UNIONed and de-duplicated; the earliest qualifying event
--   per person (regardless of source table) becomes the cohort index date.
--
-- PARAMETERS (injected via R/cohorts.R):
--   @cdm_database_schema      CDM schema
--   @target_database_schema   Results schema prefix
--   @target_cohort_table      Cohort table name
--   @outcome_cohort_id        Cohort definition ID (outcome.cohort_id)
--   @target_cohort_id         Target cohort ID — used to join discharge date
--   @study_start_date         Study start date
--   @study_end_date           Study end date
--   @prediction_window_days   Days post-discharge during which ED visit counts
--                             (set in study_params.yaml; default 90)
--
-- COHORT LOGIC:
--   INDEX EVENT  : earliest post-discharge ED event (from either source table)
--                  that falls within @prediction_window_days of discharge.
--   INDEX DATE   : event date (visit_start_date or observation_date).
--   COHORT EXIT  : event end date, or index date + 1 day if end date is NULL.
--   ONE ENTRY    : first qualifying event per person.
--
-- EVENT CONCEPTS:
--   9203     [vocab query] Emergency Room Visit  (visit_occurrence.visit_concept_id)
--   4176269  [vocab query] Emergency room admission  (observation.observation_concept_id;
--            SNOMED 50849002; domain = Observation in this vocab build)
--
-- TODO [OUTCOME SQL]: Confirm whether to add an observation_period guard
--   requiring the ED event to fall within an active observation_period.
--   Current implementation does not filter on observation_period.
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @outcome_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table (
  cohort_definition_id,
  subject_id,
  cohort_start_date,
  cohort_end_date
)
SELECT
  @outcome_cohort_id                  AS cohort_definition_id,
  ed.person_id                        AS subject_id,
  CAST(ed.event_date AS DATE)         AS cohort_start_date,
  CAST(
    ISNULL(ed.event_end_date, DATEADD(DAY, 1, ed.event_date))
    AS DATE
  )                                   AS cohort_end_date
FROM (
  SELECT
    person_id,
    event_date,
    event_end_date,
    ROW_NUMBER() OVER (
      PARTITION BY person_id
      ORDER BY event_date ASC
    ) AS rn
  FROM (

    -- Arm 1: visit_occurrence — Emergency Room Visit (visit_concept_id 9203)
    SELECT
      vo.person_id,
      vo.visit_start_date  AS event_date,
      vo.visit_end_date    AS event_end_date
    FROM @cdm_database_schema.visit_occurrence vo
    INNER JOIN @target_database_schema.@target_cohort_table tc
      ON  tc.subject_id           = vo.person_id
      AND tc.cohort_definition_id = @target_cohort_id
    WHERE
      vo.visit_concept_id = 9203  -- [vocab query] Emergency Room Visit
      AND vo.visit_start_date >  tc.cohort_end_date
      AND vo.visit_start_date <= DATEADD(DAY, @prediction_window_days, tc.cohort_end_date)
      AND vo.visit_start_date >= CAST('@study_start_date' AS DATE)
      AND vo.visit_start_date <= CAST('@study_end_date'   AS DATE)

    UNION

    -- Arm 2: observation — Emergency room admission (observation_concept_id 4176269)
    -- SNOMED 50849002 maps to the Observation domain in this vocab build; Synthea
    -- ETL routes this event here rather than to visit_occurrence.
    SELECT
      o.person_id,
      o.observation_date          AS event_date,
      o.observation_date          AS event_end_date  -- observation has no end date; end = start
    FROM @cdm_database_schema.observation o
    INNER JOIN @target_database_schema.@target_cohort_table tc
      ON  tc.subject_id           = o.person_id
      AND tc.cohort_definition_id = @target_cohort_id
    WHERE
      o.observation_concept_id = 4176269  -- [vocab query] Emergency room admission (SNOMED 50849002)
      AND o.observation_date >  tc.cohort_end_date
      AND o.observation_date <= DATEADD(DAY, @prediction_window_days, tc.cohort_end_date)
      AND o.observation_date >= CAST('@study_start_date' AS DATE)
      AND o.observation_date <= CAST('@study_end_date'   AS DATE)

  ) combined_ed

) ed
WHERE ed.rn = 1;
