-- =============================================================================
-- cohorts/target_amputation.sql
-- TARGET / EXPOSURE COHORT — Major lower extremity amputation with a
-- PAD / diabetes / wound indication (study-specific to pad-amp-nhd-val).
--
-- WHY A STUDY-SPECIFIC TARGET FILE
--   The shared parameterized template (target_surgery.sql) supports a single
--   washout (NOT EXISTS) clause but no positive inclusion-condition (OR-EXISTS)
--   clause. This study's eligibility requires the patient to have at least ONE
--   of three indication condition groups documented in the prior-observation
--   window before the index amputation. The indication concept IDs are
--   hardcoded below rather than threaded through study_params.yaml + R/cohorts.R
--   to avoid extending shared infrastructure for a single study's need.
--
-- PARAMETERS (injected from study_params.yaml via R/cohorts.R):
--   @cdm_database_schema      CDM schema
--   @target_database_schema   Results schema prefix
--   @target_cohort_table      Cohort table name
--   @target_cohort_id         Cohort definition ID (target.cohort_id)
--   @study_start_date         Study start date
--   @study_end_date           Study end date
--   @visit_concept_ids        Visit type filter (target.visit_concept_ids; 9201 = inpatient)
--   @min_age                  Minimum age at index in years (0 = no filter)
--   @index_concept_ids        Ancestor concept IDs for the amputation procedure
--                             (target.index_event.ancestor_concept_ids).
--   @washout_concept_ids      Empty string in this study — disabled.
--   @washout_lookback_days    Unused when washout disabled.
--
-- COHORT LOGIC:
--   INDEX EVENT    : qualifying inpatient visit during which a major LE
--                    amputation procedure occurred, within the study window.
--   INDEX DATE     : visit_start_date of the qualifying visit.
--   COHORT EXIT    : visit_end_date (or visit_start_date + 1 day if null).
--   ONE ENTRY      : first qualifying visit per person (incident / new-user).
--   AGE FILTER     : >= @min_age at index.
--   INDICATION     : patient must have AT LEAST ONE of the three indication
--                    condition groups below documented at any time on or before
--                    the index date (no minimum lookback required).
--
-- INDICATION CONCEPT GROUPS (all [vocab query] verified 2026-05-14):
--   Group A — Peripheral arterial disease:
--     317309   Peripheral arterial occlusive disease  (SNOMED 399957001, descendants on)
--   Group B — Diabetes mellitus:
--     201820   Diabetes mellitus                       (SNOMED 73211009, descendants on;
--                                                       captures type 1 / type 2 / secondary DM)
--   Group C — Lower-extremity wound (broad — 25 ancestors):
--     Broad dysvascular / diabetic / infectious LE wound definition. Includes
--     ulcers, open wounds, gangrene (multiple parallel trees), soft-tissue +
--     bone infections, and diabetic foot. Burns of LE are intentionally
--     excluded — burn-driven amputations have a different etiology and
--     risk-factor structure.
--     The OMOP gangrene hierarchy is fragmented across many parallel
--     ancestors (peripheral, ischemic, gas, DM-related, atherosclerotic,
--     Raynaud-related, presenile, acral, cutaneous), so each is listed.
--     Descendant counts shown for each (standard concepts only).
--       Ulcers / open wounds (large overlap via concept_ancestor):
--         197304   Ulcer of lower extremity                            (320 desc)
--         4097962  Open wound of lower limb                            (887 desc)
--         4054067  Open wound of foot                                  (320 desc)
--       Gangrene umbrellas (broad ancestors):
--         4108371  Peripheral gangrene                                  (24 desc; pulls in
--                                                                       limb gangrene d/t
--                                                                       atherosclerosis tree,
--                                                                       gangrene of foot/toe/
--                                                                       finger/hand)
--         433696   Gas gangrene                                         (20 desc; clostridial
--                                                                       gas gangrene of limb,
--                                                                       foot, thigh, lower leg,
--                                                                       etc.)
--         4226354  Gangrene due to diabetes mellitus                     (4 desc; wet gangrene
--                                                                       of foot d/t DM, T1/T2
--                                                                       DM gangrene)
--       Gangrene specific concepts (separate trees / orphan parents):
--         4263116  Gangrene (generic)                                    (5 desc)
--         4291464  Ischemic gangrene                                     (1 desc)
--         4112159  Gangrene of foot                                      (7 desc)
--         4111843  Gangrene of toe                                       (4 desc)
--         317577   Arteriosclerotic gangrene                             (1 desc)
--         4256119  Acral gangrene                                        (1 desc)
--         4111732  Presenile gangrene                                    (1 desc)
--         40480503 Progressive cutaneous gangrene                        (1 desc)
--         46273172 Gangrene due to arterial insufficiency                (1 desc)
--         46273522 Gangrene due to Raynaud disease                       (1 desc)
--         46270361 Gangrene due to secondary Raynaud phenomenon          (1 desc)
--       Soft-tissue / skin infection:
--         42709838 Cellulitis of lower limb                             (62 desc)
--         4028237  Cellulitis of foot                                   (29 desc)
--         4320944  Cellulitis of toe                                    (22 desc)
--         133566   Necrotizing fasciitis                                 (7 desc)
--       Bone infection (osteomyelitis):
--         133853   Osteomyelitis of ankle AND/OR foot                   (40 desc)
--         1246044  Osteomyelitis of foot                                (20 desc)
--       Diabetic foot:
--         4087682  Diabetic foot                                         (3 desc)
--         4159742  Diabetic foot ulcer                                  (31 desc; overlaps 197304)
--
-- RATIONALE FOR INCLUDING ALL THREE GROUPS
--   The Iannuzzi 2020 risk score and the Subramaniam mFI-5 were developed in
--   surgical cohorts dominated by dysvascular/diabetic/wound amputations rather
--   than traumatic or oncologic amputations. Restricting the validation cohort
--   to patients with ANY of these three indications excludes purely traumatic
--   and oncologic amputations (which would not be expected to follow the same
--   risk-factor structure) while keeping the cohort large and clinically
--   coherent.
-- =============================================================================

-- Guard: fires when index concept IDs still contain the placeholder value 0.
{@index_concept_ids == "0"} ? {
  RAISERROR(
    'SETUP REQUIRED - target_amputation.sql: index_concept_ids = 0 placeholder '
    'has not been replaced. Set target.index_event.ancestor_concept_ids in '
    'study_params.yaml and re-run.',
    16, 1
  );
  RETURN;
}

DELETE FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table (
  cohort_definition_id,
  subject_id,
  cohort_start_date,
  cohort_end_date
)
SELECT
  @target_cohort_id                  AS cohort_definition_id,
  qualifying_event.person_id         AS subject_id,
  qualifying_event.index_date        AS cohort_start_date,
  qualifying_event.cohort_end_date   AS cohort_end_date
FROM (
  SELECT
    vo.person_id,
    CAST(vo.visit_start_date AS DATE) AS index_date,
    CAST(
      ISNULL(vo.visit_end_date, DATEADD(DAY, 1, vo.visit_start_date))
      AS DATE
    ) AS cohort_end_date,
    -- Keep first qualifying visit per person (incident design).
    ROW_NUMBER() OVER (
      PARTITION BY vo.person_id
      ORDER BY vo.visit_start_date ASC
    ) AS rn

  FROM @cdm_database_schema.visit_occurrence  vo
  INNER JOIN @cdm_database_schema.person       p
    ON p.person_id = vo.person_id

  WHERE
    1 = 1

    -- Visit type filter (inpatient only by default — set in study_params.yaml).
    {@visit_concept_ids != ""} ? {
    AND vo.visit_concept_id IN (@visit_concept_ids)
    }

    -- Study date window.
    AND vo.visit_start_date >= CAST('@study_start_date' AS DATE)
    AND vo.visit_start_date <= CAST('@study_end_date'   AS DATE)

    -- Age filter.
    {@min_age != "0"} ? {
    AND DATEDIFF(
          YEAR,
          DATEFROMPARTS(
            p.year_of_birth,
            ISNULL(p.month_of_birth, 7),
            ISNULL(p.day_of_birth,   1)
          ),
          vo.visit_start_date
        ) >= @min_age
    }

    -- Index event: major LE amputation during the inpatient visit.
    -- Concept IDs (ancestors) set via target.index_event.ancestor_concept_ids
    -- in study_params.yaml; descendants captured via concept_ancestor rollup.
    AND EXISTS (
      SELECT 1
      FROM @cdm_database_schema.procedure_occurrence po
      INNER JOIN @cdm_database_schema.concept_ancestor ca
        ON ca.descendant_concept_id = po.procedure_concept_id
      WHERE ca.ancestor_concept_id IN (@index_concept_ids)
        AND po.person_id      = vo.person_id
        AND po.procedure_date BETWEEN vo.visit_start_date
                                  AND ISNULL(vo.visit_end_date, vo.visit_start_date)
    )

    -- Indication eligibility: patient must have ANY of PAD, DM, or LE wound
    -- documented at any point on or before the index date. Three OR-EXISTS
    -- subqueries — equivalent to a single EXISTS over a UNIONed ancestor set
    -- but kept separate for readability and so each indication can be
    -- enabled/disabled independently in future revisions.
    AND (
      -- Group A: Peripheral arterial disease (SNOMED 399957001 + descendants).
      EXISTS (
        SELECT 1
        FROM @cdm_database_schema.condition_occurrence co_pad
        INNER JOIN @cdm_database_schema.concept_ancestor ca_pad
          ON ca_pad.descendant_concept_id = co_pad.condition_concept_id
        WHERE ca_pad.ancestor_concept_id = 317309  -- [vocab query] PAD
          AND co_pad.person_id            = vo.person_id
          AND co_pad.condition_start_date <= vo.visit_start_date
      )
      OR
      -- Group B: Diabetes mellitus (SNOMED 73211009 + descendants).
      EXISTS (
        SELECT 1
        FROM @cdm_database_schema.condition_occurrence co_dm
        INNER JOIN @cdm_database_schema.concept_ancestor ca_dm
          ON ca_dm.descendant_concept_id = co_dm.condition_concept_id
        WHERE ca_dm.ancestor_concept_id = 201820   -- [vocab query] Diabetes mellitus
          AND co_dm.person_id            = vo.person_id
          AND co_dm.condition_start_date <= vo.visit_start_date
      )
      OR
      -- Group C: LE wound — broad. Twenty-five SNOMED ancestors covering
      -- ulcers, open wounds, gangrene (eleven parallel trees / orphan
      -- parents), soft-tissue infection, osteomyelitis, and diabetic foot.
      -- Burns are intentionally excluded. See the file header for descendant
      -- counts and clinical mapping for each ancestor.
      EXISTS (
        SELECT 1
        FROM @cdm_database_schema.condition_occurrence co_wnd
        INNER JOIN @cdm_database_schema.concept_ancestor ca_wnd
          ON ca_wnd.descendant_concept_id = co_wnd.condition_concept_id
        WHERE ca_wnd.ancestor_concept_id IN (
                197304,    -- Ulcer of lower extremity
                4097962,   -- Open wound of lower limb
                4054067,   -- Open wound of foot
                -- Gangrene umbrellas
                4108371,   -- Peripheral gangrene
                433696,    -- Gas gangrene
                4226354,   -- Gangrene due to diabetes mellitus
                -- Gangrene specific / orphan parents
                4263116,   -- Gangrene (generic)
                4291464,   -- Ischemic gangrene
                4112159,   -- Gangrene of foot
                4111843,   -- Gangrene of toe
                317577,    -- Arteriosclerotic gangrene
                4256119,   -- Acral gangrene
                4111732,   -- Presenile gangrene
                40480503,  -- Progressive cutaneous gangrene
                46273172,  -- Gangrene due to arterial insufficiency
                46273522,  -- Gangrene due to Raynaud disease
                46270361,  -- Gangrene due to secondary Raynaud phenomenon
                -- Soft-tissue / skin infection
                42709838,  -- Cellulitis of lower limb
                4028237,   -- Cellulitis of foot
                4320944,   -- Cellulitis of toe
                133566,    -- Necrotizing fasciitis
                -- Bone infection
                133853,    -- Osteomyelitis of ankle AND/OR foot
                1246044,   -- Osteomyelitis of foot
                -- Diabetic foot
                4087682,   -- Diabetic foot
                4159742    -- Diabetic foot ulcer
              )
          AND co_wnd.person_id             = vo.person_id
          AND co_wnd.condition_start_date <= vo.visit_start_date
      )
    )

    -- Washout (disabled in this study). Kept for parameter-template parity.
    {@washout_concept_ids != ""} ? {
    AND NOT EXISTS (
      SELECT 1
      FROM @cdm_database_schema.condition_occurrence  prior_event
      INNER JOIN @cdm_database_schema.concept_ancestor ca
        ON ca.descendant_concept_id = prior_event.condition_concept_id
      WHERE
        ca.ancestor_concept_id IN (@washout_concept_ids)
        AND prior_event.person_id = vo.person_id
        AND prior_event.condition_start_date
              BETWEEN DATEADD(DAY, -@washout_lookback_days, vo.visit_start_date)
                  AND DATEADD(DAY,   -1, vo.visit_start_date)
    )
    }

) qualifying_event
WHERE qualifying_event.rn = 1;
