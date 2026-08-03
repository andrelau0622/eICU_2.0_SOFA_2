-- generated; do not edit

-- source: sql/00_preflight.sql
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';

CREATE SCHEMA IF NOT EXISTS eicu_sofa2;

DO $preflight$
DECLARE
    required_relation text;
BEGIN
    FOREACH required_relation IN ARRAY ARRAY[
        'eicu_icu.patient',
        'eicu_icu.infusiondrug',
        'eicu_icu.medication',
        'eicu_icu.microlab',
        'eicu_icu.treatment',
        'eicu_icu.intakeoutput',
        'eicu_icu.respiratorycare',
        'eicu_icu.respiratorycharting',
        'eicu_derived.pivoted_gcs',
        'eicu_derived.pivoted_bg',
        'eicu_derived.pivoted_lab',
        'eicu_derived.pivoted_vital',
        'eicu_derived.pivoted_infusion',
        'eicu_derived.pivoted_o2',
        'eicu_derived.pivoted_uo',
        'eicu_derived.pivoted_weight',
        'eicu_derived.ventilation_events'
    ] LOOP
        IF to_regclass(required_relation) IS NULL THEN
            RAISE EXCEPTION 'eICU preflight failed: missing relation %', required_relation;
        END IF;
    END LOOP;
END
$preflight$;

DROP TABLE IF EXISTS eicu_sofa2.data_quality_report;
DROP TABLE IF EXISTS eicu_sofa2.pipeline_metadata;
DROP TABLE IF EXISTS eicu_sofa2.infection_associated_sofa2_events_exploratory;
DROP TABLE IF EXISTS eicu_sofa2.infection_associated_sofa2_hourly_exploratory;
DROP TABLE IF EXISTS eicu_sofa2.sepsis3_sofa1_reference;
DROP TABLE IF EXISTS eicu_sofa2.suspicion_of_infection;
DROP VIEW IF EXISTS eicu_sofa2.sofa1_hourly_reference;
DROP TABLE IF EXISTS eicu_sofa2.first_day_sofa2;
DROP TABLE IF EXISTS eicu_sofa2.sofa2_daily;
DROP TABLE IF EXISTS eicu_sofa2.sofa2_hourly_rolling_experimental;
DROP TABLE IF EXISTS eicu_sofa2.sofa2_hourly_raw;
DROP TABLE IF EXISTS eicu_sofa2.hourly_features;
DROP TABLE IF EXISTS eicu_sofa2.respiratory_support_intervals;
DROP TABLE IF EXISTS eicu_sofa2.vasoactive_events;
DROP TABLE IF EXISTS eicu_sofa2.urine_hourly;
DROP TABLE IF EXISTS eicu_sofa2.oxygen_events;
DROP TABLE IF EXISTS eicu_sofa2.hour_grid;
DROP TABLE IF EXISTS eicu_sofa2.adult_stays;

-- source: sql/10_score_functions.sql
CREATE OR REPLACE FUNCTION eicu_sofa2.sofa2_brain(gcs double precision, motor_fallback integer, delirium_drug boolean)
RETURNS smallint LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE score integer;
BEGIN
    IF gcs IS NOT NULL THEN
        score := CASE WHEN gcs>=15 THEN 0 WHEN gcs>=13 THEN 1 WHEN gcs>=9 THEN 2 WHEN gcs>=6 THEN 3 ELSE 4 END;
    ELSIF motor_fallback IS NOT NULL THEN
        score := CASE WHEN motor_fallback>=6 THEN 0 WHEN motor_fallback=5 THEN 1 WHEN motor_fallback=4 THEN 2 WHEN motor_fallback=3 THEN 3 ELSE 4 END;
    END IF;
    IF COALESCE(delirium_drug,false) THEN score := GREATEST(COALESCE(score,0),1); END IF;
    RETURN score::smallint;
END $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa2_respiratory(pf_ratio double precision, sf_ratio double precision, advanced_support boolean, respiratory_ecmo boolean, support_unavailable boolean)
RETURNS smallint LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE supported boolean := COALESCE(advanced_support,false) OR COALESCE(support_unavailable,false);
BEGIN
    IF COALESCE(respiratory_ecmo,false) THEN RETURN 4; END IF;
    IF pf_ratio IS NOT NULL THEN
        RETURN CASE WHEN supported AND pf_ratio<=75 THEN 4 WHEN supported AND pf_ratio<=150 THEN 3 WHEN pf_ratio<=225 THEN 2 WHEN pf_ratio<=300 THEN 1 ELSE 0 END;
    ELSIF sf_ratio IS NOT NULL THEN
        RETURN CASE WHEN supported AND sf_ratio<=120 THEN 4 WHEN supported AND sf_ratio<=200 THEN 3 WHEN sf_ratio<=250 THEN 2 WHEN sf_ratio<=300 THEN 1 ELSE 0 END;
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa2_cardiovascular(map_value double precision, norepinephrine_base double precision, epinephrine double precision, other_agent boolean, dopamine double precision, mechanical_support boolean, drug_unavailable boolean)
RETURNS smallint LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    catecholamine double precision := COALESCE(norepinephrine_base,0)+COALESCE(epinephrine,0);
    dopamine_value double precision := COALESCE(dopamine,0);
    other_present boolean := COALESCE(other_agent,false) OR dopamine_value>0;
BEGIN
    IF COALESCE(mechanical_support,false) THEN RETURN 4; END IF;
    IF catecholamine>0.4 THEN RETURN 4; END IF;
    IF catecholamine>0.2 THEN RETURN CASE WHEN other_present THEN 4 ELSE 3 END; END IF;
    IF catecholamine>0 THEN RETURN CASE WHEN other_present THEN 3 ELSE 2 END; END IF;
    IF dopamine_value>40 THEN RETURN 4; END IF;
    IF dopamine_value>20 THEN RETURN 3; END IF;
    IF dopamine_value>0 OR COALESCE(other_agent,false) THEN RETURN 2; END IF;
    IF map_value IS NULL THEN RETURN NULL; END IF;
    IF COALESCE(drug_unavailable,false) THEN
        RETURN CASE WHEN map_value>=70 THEN 0 WHEN map_value>=60 THEN 1 WHEN map_value>=50 THEN 2 WHEN map_value>=40 THEN 3 ELSE 4 END;
    END IF;
    RETURN CASE WHEN map_value<70 THEN 1 ELSE 0 END;
END $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa2_liver(bilirubin double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN bilirubin IS NULL THEN NULL WHEN bilirubin>12 THEN 4 WHEN bilirubin>6 THEN 3 WHEN bilirubin>3 THEN 2 WHEN bilirubin>1.2 THEN 1 ELSE 0 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa2_hemostasis(platelets double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN platelets IS NULL THEN NULL WHEN platelets<=50 THEN 4 WHEN platelets<=80 THEN 3 WHEN platelets<=100 THEN 2 WHEN platelets<=150 THEN 1 ELSE 0 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa2_kidney(creatinine double precision, uo_rate_6h double precision, uo_rate_12h double precision, uo_rate_24h double precision, anuria_12h boolean, rrt boolean, rrt_criteria boolean)
RETURNS smallint LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE score integer;
BEGIN
    IF COALESCE(rrt,false) OR COALESCE(rrt_criteria,false) THEN RETURN 4; END IF;
    IF creatinine IS NOT NULL THEN score := CASE WHEN creatinine>3.5 THEN 3 WHEN creatinine>2 THEN 2 WHEN creatinine>1.2 THEN 1 ELSE 0 END; END IF;
    IF COALESCE(anuria_12h,false) OR (uo_rate_24h IS NOT NULL AND uo_rate_24h<0.3) THEN score:=GREATEST(COALESCE(score,0),3); END IF;
    IF uo_rate_12h IS NOT NULL AND uo_rate_12h<0.5 THEN score:=GREATEST(COALESCE(score,0),2); END IF;
    IF uo_rate_6h IS NOT NULL AND uo_rate_6h<0.5 THEN score:=GREATEST(COALESCE(score,0),1); END IF;
    RETURN score::smallint;
END $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa1_brain(gcs double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN gcs IS NULL THEN NULL WHEN gcs>=15 THEN 0 WHEN gcs>=13 THEN 1 WHEN gcs>=10 THEN 2 WHEN gcs>=6 THEN 3 ELSE 4 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa1_respiratory(pf_ratio double precision, respiratory_support boolean)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN pf_ratio IS NULL THEN NULL WHEN COALESCE(respiratory_support,false) AND pf_ratio<100 THEN 4 WHEN COALESCE(respiratory_support,false) AND pf_ratio<200 THEN 3 WHEN pf_ratio<300 THEN 2 WHEN pf_ratio<400 THEN 1 ELSE 0 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa1_cardiovascular(map_value double precision, dopamine double precision, epinephrine double precision, norepinephrine double precision, dobutamine boolean)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE
    WHEN COALESCE(dopamine,0)>15 OR COALESCE(epinephrine,0)>0.1 OR COALESCE(norepinephrine,0)>0.1 THEN 4
    WHEN COALESCE(dopamine,0)>5 OR COALESCE(epinephrine,0)>0 OR COALESCE(norepinephrine,0)>0 THEN 3
    WHEN COALESCE(dopamine,0)>0 OR COALESCE(dobutamine,false) THEN 2
    WHEN map_value IS NULL THEN NULL
    WHEN map_value<70 THEN 1 ELSE 0 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa1_liver(bilirubin double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN bilirubin IS NULL THEN NULL WHEN bilirubin>=12 THEN 4 WHEN bilirubin>=6 THEN 3 WHEN bilirubin>=2 THEN 2 WHEN bilirubin>=1.2 THEN 1 ELSE 0 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa1_hemostasis(platelets double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN platelets IS NULL THEN NULL WHEN platelets<20 THEN 4 WHEN platelets<50 THEN 3 WHEN platelets<100 THEN 2 WHEN platelets<150 THEN 1 ELSE 0 END::smallint $$;

CREATE OR REPLACE FUNCTION eicu_sofa2.sofa1_kidney(creatinine double precision, urine_24h_ml double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE WHEN creatinine IS NULL AND urine_24h_ml IS NULL THEN NULL WHEN COALESCE(creatinine,0)>=5 OR urine_24h_ml<200 THEN 4 WHEN COALESCE(creatinine,0)>=3.5 OR urine_24h_ml<500 THEN 3 WHEN COALESCE(creatinine,0)>=2 THEN 2 WHEN COALESCE(creatinine,0)>=1.2 THEN 1 ELSE 0 END::smallint $$;

-- source: sql/20_normalized_events.sql
CREATE TABLE eicu_sofa2.adult_stays AS
SELECT
    p.patientunitstayid,
    p.patienthealthsystemstayid,
    p.uniquepid,
    CASE
        WHEN p.age = '> 89' THEN 90
        WHEN p.age ~ '^[0-9]+$' THEN p.age::integer
    END AS age,
    p.gender,
    p.hospitalid,
    p.wardid,
    p.unittype,
    p.unitstaytype,
    p.admissionweight,
    CASE WHEN p.unitdischargeoffset > 0 THEN p.unitdischargeoffset ELSE 10080 END
        AS dischargeoffset_effective,
    p.unitdischargeoffset IS NULL OR p.unitdischargeoffset <= 0 AS dischargeoffset_imputed
FROM eicu_icu.patient AS p
WHERE CASE
    WHEN p.age = '> 89' THEN 90
    WHEN p.age ~ '^[0-9]+$' THEN p.age::integer
END >= 18;

ALTER TABLE eicu_sofa2.adult_stays
    ADD CONSTRAINT adult_stays_pk PRIMARY KEY (patientunitstayid),
    ADD CONSTRAINT adult_stays_age_ck CHECK (age >= 18),
    ADD CONSTRAINT adult_stays_discharge_ck CHECK (dischargeoffset_effective > 0);

CREATE TABLE eicu_sofa2.hour_grid AS
SELECT
    s.patientunitstayid,
    s.patienthealthsystemstayid,
    s.uniquepid,
    h.hr,
    h.hr * 60 AS startoffset,
    CASE
        WHEN h.hr >= 0 THEN LEAST((h.hr + 1) * 60, s.dischargeoffset_effective)
        ELSE (h.hr + 1) * 60
    END AS endoffset
FROM eicu_sofa2.adult_stays AS s
CROSS JOIN LATERAL generate_series(
    -48,
    GREATEST(ceil(s.dischargeoffset_effective / 60.0)::integer - 1, 0)
) AS h(hr);

ALTER TABLE eicu_sofa2.hour_grid
    ADD CONSTRAINT hour_grid_pk PRIMARY KEY (patientunitstayid, hr),
    ADD CONSTRAINT hour_grid_time_ck CHECK (endoffset > startoffset);

CREATE TEMP TABLE task_eicu_valid_fio2 ON COMMIT DROP AS
SELECT patientunitstayid, chartoffset, fio2::double precision AS fio2_fraction
FROM eicu_derived.pivoted_bg
WHERE fio2 BETWEEN 0.15 AND 1.0;

CREATE INDEX task_eicu_valid_fio2_idx
    ON task_eicu_valid_fio2 (patientunitstayid, chartoffset);

CREATE TABLE eicu_sofa2.oxygen_events AS
WITH oxygen AS (
    SELECT
        bg.patientunitstayid,
        bg.chartoffset AS oxygen_offset,
        'PF'::text AS ratio_type,
        bg.pao2::double precision AS oxygen_value,
        bg.fio2::double precision AS fio2_fraction,
        bg.chartoffset AS fio2_offset,
        'pivoted_bg_same_record'::text AS fio2_source
    FROM eicu_derived.pivoted_bg AS bg
    INNER JOIN eicu_sofa2.adult_stays AS s
        ON s.patientunitstayid = bg.patientunitstayid
    WHERE bg.pao2 BETWEEN 1 AND 1000
      AND bg.fio2 BETWEEN 0.15 AND 1.0
      AND bg.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective

    UNION ALL

    SELECT
        v.patientunitstayid,
        v.chartoffset,
        'SF'::text,
        v.spo2::double precision,
        f.fio2_fraction,
        f.chartoffset,
        'latest_prior_pivoted_bg'::text
    FROM eicu_derived.pivoted_vital AS v
    INNER JOIN eicu_sofa2.adult_stays AS s
        ON s.patientunitstayid = v.patientunitstayid
    INNER JOIN LATERAL (
        SELECT x.chartoffset, x.fio2_fraction
        FROM task_eicu_valid_fio2 AS x
        WHERE x.patientunitstayid = v.patientunitstayid
          AND x.chartoffset <= v.chartoffset
          AND x.chartoffset >= v.chartoffset - 360
        ORDER BY x.chartoffset DESC
        LIMIT 1
    ) AS f ON true
    WHERE v.spo2 > 0 AND v.spo2 < 98
      AND v.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
)
SELECT
    patientunitstayid,
    floor(oxygen_offset / 60.0)::integer AS hr,
    oxygen_offset,
    ratio_type,
    oxygen_value,
    fio2_fraction,
    fio2_offset,
    fio2_source,
    oxygen_value / NULLIF(fio2_fraction, 0) AS ratio_value
FROM oxygen;

CREATE INDEX oxygen_events_stay_hour_idx
    ON eicu_sofa2.oxygen_events (patientunitstayid, hr, ratio_type, ratio_value);

CREATE TABLE eicu_sofa2.urine_hourly AS
WITH first_weight AS (
    SELECT DISTINCT ON (w.patientunitstayid)
        w.patientunitstayid,
        w.weight::double precision AS weight
    FROM eicu_derived.pivoted_weight AS w
    WHERE w.weight BETWEEN 1 AND 400
    ORDER BY w.patientunitstayid, abs(w.chartoffset), w.chartoffset
)
SELECT
    u.patientunitstayid,
    floor(u.chartoffset / 60.0)::integer AS hr,
    sum(u.urineoutput)::double precision AS urine_ml,
    count(*) AS source_records,
    COALESCE(NULLIF(s.admissionweight, 0)::double precision, fw.weight) AS weight_kg,
    min(u.chartoffset) AS first_source_offset,
    max(u.chartoffset) AS last_source_offset
FROM eicu_derived.pivoted_uo AS u
INNER JOIN eicu_sofa2.adult_stays AS s
    ON s.patientunitstayid = u.patientunitstayid
LEFT JOIN first_weight AS fw
    ON fw.patientunitstayid = u.patientunitstayid
WHERE u.urineoutput >= 0
  AND u.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
GROUP BY
    u.patientunitstayid,
    floor(u.chartoffset / 60.0)::integer,
    COALESCE(NULLIF(s.admissionweight, 0)::double precision, fw.weight);

ALTER TABLE eicu_sofa2.urine_hourly
    ADD CONSTRAINT urine_hourly_pk PRIMARY KEY (patientunitstayid, hr),
    ADD CONSTRAINT urine_hourly_nonnegative_ck CHECK (urine_ml >= 0);

-- Parse only rate units that can be converted to mcg/kg/min. Binary pivoted
-- infusion fields remain exposure-only and can never become dose evidence.
CREATE TABLE eicu_sofa2.vasoactive_events AS
WITH raw AS (
    SELECT
        i.infusiondrugid AS source_id,
        i.patientunitstayid,
        i.infusionoffset,
        CASE
            WHEN lower(i.drugname) ~ '(norepinephrine|levophed)' THEN 'norepinephrine'
            WHEN lower(i.drugname) ~ '(epinephrine|adrenalin)' THEN 'epinephrine'
            WHEN lower(i.drugname) ~ 'dopamine' THEN 'dopamine'
            WHEN lower(i.drugname) ~ 'dobutamine' THEN 'dobutamine'
            WHEN lower(i.drugname) ~ '(phenylephrine|neosynephrine)' THEN 'phenylephrine'
            WHEN lower(i.drugname) ~ 'vasopressin' THEN 'vasopressin'
            WHEN lower(i.drugname) ~ 'milrinone' THEN 'milrinone'
        END AS agent,
        i.drugname,
        CASE WHEN trim(i.drugrate) ~ '^[-+]?[0-9]*\.?[0-9]+$'
             THEN trim(i.drugrate)::double precision END AS numeric_rate,
        CASE WHEN trim(i.patientweight) ~ '^[-+]?[0-9]*\.?[0-9]+$'
             THEN trim(i.patientweight)::double precision END AS source_weight,
        CASE
            WHEN lower(i.drugname) LIKE '%mcg/kg/min%' THEN 'mcg/kg/min'
            WHEN lower(i.drugname) LIKE '%mcg/min%' THEN 'mcg/min'
            WHEN lower(i.drugname) LIKE '%mg/kg/min%' THEN 'mg/kg/min'
            ELSE 'unrecognized'
        END AS source_unit
    FROM eicu_icu.infusiondrug AS i
    INNER JOIN eicu_sofa2.adult_stays AS s
        ON s.patientunitstayid = i.patientunitstayid
    WHERE lower(i.drugname) ~ '(norepinephrine|levophed|epinephrine|adrenalin|dopamine|dobutamine|phenylephrine|neosynephrine|vasopressin|milrinone)'
      AND i.infusionoffset BETWEEN -2880 AND s.dischargeoffset_effective
), normalized AS (
    SELECT
        r.*,
        CASE
            WHEN numeric_rate IS NULL THEN NULL
            WHEN source_unit = 'mcg/kg/min' THEN numeric_rate
            WHEN source_unit = 'mg/kg/min' THEN numeric_rate * 1000.0
            WHEN source_unit = 'mcg/min' AND source_weight > 0 THEN numeric_rate / source_weight
        END AS dose_mcg_kg_min,
        CASE
            WHEN numeric_rate IS NULL THEN 'value_unparseable'
            WHEN source_unit = 'mcg/min' AND NOT (source_weight > 0) THEN 'weight_missing'
            WHEN source_unit = 'unrecognized' THEN 'unit_unrecognized'
            ELSE 'dose_candidate'
        END AS initial_status
    FROM raw AS r
), positive AS (
    SELECT
        n.*,
        max(infusionoffset) OVER (
            PARTITION BY patientunitstayid, agent
            ORDER BY infusionoffset
            ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING
        ) AS previous_offset
    FROM normalized AS n
    WHERE COALESCE(numeric_rate, 0) > 0
), grouped AS (
    SELECT
        p.*,
        sum(CASE WHEN previous_offset IS NULL OR infusionoffset - previous_offset > 60 THEN 1 ELSE 0 END)
            OVER (PARTITION BY patientunitstayid, agent ORDER BY infusionoffset) AS episode_id
    FROM positive AS p
), labeled AS (
    SELECT
        g.*,
        min(infusionoffset) OVER (PARTITION BY patientunitstayid, agent, episode_id) AS episode_start,
        max(infusionoffset) OVER (PARTITION BY patientunitstayid, agent, episode_id) AS episode_end,
        lead(infusionoffset) OVER (
            PARTITION BY patientunitstayid, agent, episode_id ORDER BY infusionoffset
        ) AS next_offset
    FROM grouped AS g
), source_events AS (
    SELECT
        patientunitstayid,
        agent,
        infusionoffset AS startoffset,
        LEAST(COALESCE(next_offset, infusionoffset), infusionoffset + 60) AS endoffset,
        greatest(episode_end - episode_start, 0)::double precision AS duration_minutes,
        dose_mcg_kg_min,
        'infusiondrug'::text AS source_table,
        CASE
            WHEN initial_status = 'dose_candidate'
             AND episode_end - episode_start >= 60 THEN 'parsed'
            WHEN initial_status = 'dose_candidate' THEN 'exposure_only'
            ELSE initial_status
        END AS dose_status,
        source_unit,
        source_id,
        drugname AS source_label,
        agent = 'norepinephrine' AS formulation_unresolved
    FROM labeled
    WHERE COALESCE(next_offset, infusionoffset) > infusionoffset
), pivot_exposure AS (
    SELECT
        p.patientunitstayid,
        x.agent,
        p.chartoffset AS startoffset,
        p.chartoffset + 60 AS endoffset,
        60.0 AS duration_minutes,
        NULL::double precision AS dose_mcg_kg_min,
        'pivoted_infusion'::text AS source_table,
        'exposure_only'::text AS dose_status,
        'binary'::text AS source_unit,
        NULL::integer AS source_id,
        x.agent AS source_label,
        x.agent = 'norepinephrine' AS formulation_unresolved
    FROM eicu_derived.pivoted_infusion AS p
    CROSS JOIN LATERAL (VALUES
        ('dopamine', p.dopamine), ('dobutamine', p.dobutamine),
        ('norepinephrine', p.norepinephrine), ('phenylephrine', p.phenylephrine),
        ('epinephrine', p.epinephrine), ('vasopressin', p.vasopressin),
        ('milrinone', p.milrinone)
    ) AS x(agent, exposed)
    INNER JOIN eicu_sofa2.adult_stays AS s
        ON s.patientunitstayid = p.patientunitstayid
    WHERE x.exposed = 1
      AND p.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
)
SELECT * FROM source_events
UNION ALL
SELECT * FROM pivot_exposure;

CREATE INDEX vasoactive_events_stay_time_idx
    ON eicu_sofa2.vasoactive_events (patientunitstayid, startoffset, endoffset);

CREATE TABLE eicu_sofa2.respiratory_support_intervals AS
WITH starts AS (
    SELECT
        v.patientunitstayid,
        (v.hrs * 60)::integer AS startoffset,
        CASE WHEN v.event = 'mechvent start' THEN 'invasive'
             WHEN v.event = 'niv start' THEN 'noninvasive' END AS support_type,
        CASE WHEN v.event = 'mechvent start' THEN '(mechvent end)'
             WHEN v.event = 'niv start' THEN '(niv end|nivend)' END AS end_pattern
    FROM eicu_derived.ventilation_events AS v
    WHERE v.event IN ('mechvent start', 'niv start')
), vent_intervals AS (
    SELECT
        st.patientunitstayid,
        st.startoffset,
        COALESCE((
            SELECT min((v2.hrs * 60)::integer)
            FROM eicu_derived.ventilation_events AS v2
            WHERE v2.patientunitstayid = st.patientunitstayid
              AND v2.event ~ st.end_pattern
              AND (v2.hrs * 60)::integer > st.startoffset
        ), s.dischargeoffset_effective) AS endoffset,
        st.support_type,
        NOT EXISTS (
            SELECT 1 FROM eicu_derived.ventilation_events AS v2
            WHERE v2.patientunitstayid = st.patientunitstayid
              AND v2.event ~ st.end_pattern
              AND (v2.hrs * 60)::integer > st.startoffset
        ) AS end_inferred,
        'ventilation_events'::text AS source_table
    FROM starts AS st
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
), care_intervals AS (
    SELECT DISTINCT
        r.patientunitstayid,
        r.ventstartoffset AS startoffset,
        COALESCE(NULLIF(r.ventendoffset, 0), s.dischargeoffset_effective) AS endoffset,
        'invasive'::text AS support_type,
        r.ventendoffset IS NULL OR r.ventendoffset <= r.ventstartoffset AS end_inferred,
        'respiratorycare'::text AS source_table
    FROM eicu_icu.respiratorycare AS r
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE r.ventstartoffset IS NOT NULL
      AND r.ventstartoffset < s.dischargeoffset_effective
), trach_intervals AS (
    SELECT
        v.patientunitstayid,
        (v.hrs * 60)::integer AS startoffset,
        s.dischargeoffset_effective AS endoffset,
        'tracheostomy'::text AS support_type,
        true AS end_inferred,
        'ventilation_events'::text AS source_table
    FROM eicu_derived.ventilation_events AS v
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE v.event = 'Trach'
), hfnc_intervals AS (
    SELECT
        o.patientunitstayid,
        o.chartoffset AS startoffset,
        o.chartoffset + 60 AS endoffset,
        'high_flow_nasal_cannula'::text AS support_type,
        true AS end_inferred,
        'pivoted_o2'::text AS source_table
    FROM eicu_derived.pivoted_o2 AS o
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE lower(o.o2_device) ~ '(high.?flow|hfnc)'
      AND o.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
)
SELECT * FROM vent_intervals WHERE endoffset > startoffset
UNION ALL SELECT * FROM care_intervals WHERE endoffset > startoffset
UNION ALL SELECT * FROM trach_intervals WHERE endoffset > startoffset
UNION ALL SELECT * FROM hfnc_intervals WHERE endoffset > startoffset;

CREATE INDEX respiratory_support_intervals_stay_time_idx
    ON eicu_sofa2.respiratory_support_intervals
        (patientunitstayid, startoffset, endoffset);

CREATE TABLE eicu_sofa2.hourly_features AS
WITH gcs_ranked AS MATERIALIZED (
    SELECT
        g.patientunitstayid,
        floor(g.chartoffset / 60.0)::integer AS hr,
        g.gcs::double precision AS gcs,
        g.gcsmotor::integer AS gcs_motor,
        g.chartoffset AS gcs_offset,
        row_number() OVER (
            PARTITION BY g.patientunitstayid, floor(g.chartoffset / 60.0)::integer
            ORDER BY eicu_sofa2.sofa2_brain(
                g.gcs::double precision, g.gcsmotor::integer, false
            ) DESC NULLS LAST, g.chartoffset DESC
        ) AS rn
    FROM eicu_derived.pivoted_gcs AS g
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE g.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
), gcs_hour AS MATERIALIZED (
    SELECT patientunitstayid, hr, gcs, gcs_motor, gcs_offset
    FROM gcs_ranked WHERE rn = 1
), delirium_candidates AS MATERIALIZED (
    SELECT
        m.patientunitstayid,
        m.drugstartoffset,
        GREATEST(m.drugstartoffset, -2880) AS active_start,
        LEAST(
            COALESCE(NULLIF(m.drugstopoffset, 0), m.drugstartoffset + 1440),
            s.dischargeoffset_effective
        ) AS active_end
    FROM eicu_icu.medication AS m
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE lower(m.drugname) ~ '(haloperidol|quetiapine|seroquel|olanzapine|zyprexa|risperidone|risperdal|ziprasidone|geodon|clozapine|aripiprazole|abilify)'
      AND m.drugstartoffset < s.dischargeoffset_effective
), delirium_hour AS MATERIALIZED (
    SELECT
        d.patientunitstayid,
        x.hr,
        min(d.drugstartoffset) AS delirium_drug_offset
    FROM delirium_candidates AS d
    CROSS JOIN LATERAL generate_series(
        floor(d.active_start / 60.0)::integer,
        floor((d.active_end - 1) / 60.0)::integer
    ) AS x(hr)
    WHERE d.active_end > d.active_start AND x.hr >= -48
    GROUP BY d.patientunitstayid, x.hr
), pf_ranked AS MATERIALIZED (
    SELECT
        o.*,
        row_number() OVER (
            PARTITION BY o.patientunitstayid, o.hr
            ORDER BY o.ratio_value, o.oxygen_offset DESC
        ) AS rn
    FROM eicu_sofa2.oxygen_events AS o
    WHERE o.ratio_type = 'PF'
), sf_ranked AS MATERIALIZED (
    SELECT
        o.*,
        row_number() OVER (
            PARTITION BY o.patientunitstayid, o.hr
            ORDER BY o.ratio_value, o.oxygen_offset DESC
        ) AS rn
    FROM eicu_sofa2.oxygen_events AS o
    WHERE o.ratio_type = 'SF'
), support_hour AS MATERIALIZED (
    SELECT
        r.patientunitstayid,
        x.hr,
        true AS advanced_respiratory_support,
        string_agg(DISTINCT r.support_type, ';' ORDER BY r.support_type) AS support_types,
        bool_or(r.end_inferred) AS support_end_inferred
    FROM eicu_sofa2.respiratory_support_intervals AS r
    CROSS JOIN LATERAL generate_series(
        floor(r.startoffset / 60.0)::integer,
        floor((r.endoffset - 1) / 60.0)::integer
    ) AS x(hr)
    WHERE x.hr >= -48
    GROUP BY r.patientunitstayid, x.hr
), map_hour AS MATERIALIZED (
    SELECT
        v.patientunitstayid,
        floor(v.chartoffset / 60.0)::integer AS hr,
        min(COALESCE(v.ibp_mean, v.nibp_mean)) FILTER (
            WHERE COALESCE(v.ibp_mean, v.nibp_mean) BETWEEN 20 AND 250
        )::double precision AS map_min,
        min(v.chartoffset) FILTER (
            WHERE COALESCE(v.ibp_mean, v.nibp_mean) BETWEEN 20 AND 250
        ) AS map_offset
    FROM eicu_derived.pivoted_vital AS v
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE v.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
    GROUP BY v.patientunitstayid, floor(v.chartoffset / 60.0)::integer
), lab_hour AS MATERIALIZED (
    SELECT
        l.patientunitstayid,
        floor(l.chartoffset / 60.0)::integer AS hr,
        max(l.bilirubin) FILTER (WHERE l.bilirubin BETWEEN 0 AND 80)::double precision AS bilirubin,
        max(l.creatinine) FILTER (WHERE l.creatinine BETWEEN 0.1 AND 30)::double precision AS creatinine,
        min(l.platelets) FILTER (WHERE l.platelets BETWEEN 1 AND 2000)::double precision AS platelets,
        max(l.potassium) FILTER (WHERE l.potassium BETWEEN 1 AND 15)::double precision AS potassium,
        min(l.bicarbonate) FILTER (WHERE l.bicarbonate BETWEEN 2 AND 60)::double precision AS bicarbonate,
        min(l.chartoffset) AS lab_offset
    FROM eicu_derived.pivoted_lab AS l
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE l.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
    GROUP BY l.patientunitstayid, floor(l.chartoffset / 60.0)::integer
), bg_renal_hour AS MATERIALIZED (
    SELECT
        b.patientunitstayid,
        floor(b.chartoffset / 60.0)::integer AS hr,
        min(b.ph) FILTER (WHERE b.ph BETWEEN 6.5 AND 8.0)::double precision AS ph,
        min(b.chartoffset) AS bg_offset
    FROM eicu_derived.pivoted_bg AS b
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE b.chartoffset BETWEEN -2880 AND s.dischargeoffset_effective
    GROUP BY b.patientunitstayid, floor(b.chartoffset / 60.0)::integer
), urine_rolling AS MATERIALIZED (
    SELECT
        u.*,
        sum(u.urine_ml) OVER w6 AS urine_6h_ml,
        sum(u.urine_ml) OVER w12 AS urine_12h_ml,
        sum(u.urine_ml) OVER w24 AS urine_24h_ml,
        count(*) OVER w6 AS observed_uo_hours_6h,
        count(*) OVER w12 AS observed_uo_hours_12h,
        count(*) OVER w24 AS observed_uo_hours_24h
    FROM eicu_sofa2.urine_hourly AS u
    WINDOW
        w6 AS (PARTITION BY patientunitstayid ORDER BY hr RANGE BETWEEN 5 PRECEDING AND CURRENT ROW),
        w12 AS (PARTITION BY patientunitstayid ORDER BY hr RANGE BETWEEN 11 PRECEDING AND CURRENT ROW),
        w24 AS (PARTITION BY patientunitstayid ORDER BY hr RANGE BETWEEN 23 PRECEDING AND CURRENT ROW)
), vaso_hour AS MATERIALIZED (
    SELECT
        v.patientunitstayid,
        x.hr,
        max(v.dose_mcg_kg_min) FILTER (WHERE v.agent = 'norepinephrine' AND v.dose_status = 'parsed') AS norepinephrine,
        max(v.dose_mcg_kg_min) FILTER (WHERE v.agent = 'epinephrine' AND v.dose_status = 'parsed') AS epinephrine,
        max(v.dose_mcg_kg_min) FILTER (WHERE v.agent = 'dopamine' AND v.dose_status = 'parsed') AS dopamine,
        bool_or(v.agent = 'dobutamine') AS dobutamine_exposure,
        bool_or(v.agent IN ('phenylephrine', 'vasopressin', 'milrinone')) AS other_agent_exposure,
        bool_or(v.agent IN ('norepinephrine', 'epinephrine')) AS ne_epi_exposure,
        bool_or(v.agent = 'dopamine') AS dopamine_exposure,
        bool_or(v.dose_status <> 'parsed') AS dose_unresolved,
        bool_or(v.formulation_unresolved) AS norepinephrine_formulation_unresolved,
        max(v.duration_minutes) AS qualifying_duration_minutes,
        min(v.startoffset) AS vasoactive_offset
    FROM eicu_sofa2.vasoactive_events AS v
    CROSS JOIN LATERAL generate_series(
        floor(v.startoffset / 60.0)::integer,
        floor((v.endoffset - 1) / 60.0)::integer
    ) AS x(hr)
    WHERE v.endoffset > v.startoffset AND x.hr >= -48
    GROUP BY v.patientunitstayid, x.hr
), treatment_hour AS MATERIALIZED (
    SELECT
        t.patientunitstayid,
        floor(t.treatmentoffset / 60.0)::integer AS hr,
        bool_or(lower(t.treatmentstring) ~ '(dialysis|c ?r ?r ?t|c v v h)') AS rrt,
        bool_or(lower(t.treatmentstring) ~ '(ecmo)') AS ecmo,
        bool_or(lower(t.treatmentstring) ~ '(iabp|intra.?aortic balloon|impella|ventricular assist|tandem heart)') AS other_mechanical_cv_support,
        min(t.treatmentoffset) AS treatment_offset
    FROM eicu_icu.treatment AS t
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE t.treatmentoffset BETWEEN -2880 AND s.dischargeoffset_effective
      AND lower(t.treatmentstring) ~ '(dialysis|c ?r ?r ?t|c v v h|ecmo|iabp|intra.?aortic balloon|impella|ventricular assist|tandem heart)'
    GROUP BY t.patientunitstayid, floor(t.treatmentoffset / 60.0)::integer
)
SELECT
    h.patientunitstayid,
    h.patienthealthsystemstayid,
    h.uniquepid,
    h.hr,
    h.startoffset,
    h.endoffset,
    g.gcs,
    g.gcs_motor,
    g.gcs_offset,
    d.delirium_drug_offset IS NOT NULL AS delirium_drug_prescription_proxy,
    d.delirium_drug_offset,
    d.delirium_drug_offset IS NOT NULL AS delirium_indication_unresolved,
    pf.oxygen_value AS pao2,
    pf.ratio_value AS pf_ratio,
    sf.oxygen_value AS spo2,
    sf.ratio_value AS sf_ratio,
    COALESCE(pf.fio2_fraction, sf.fio2_fraction) AS fio2_fraction,
    COALESCE(pf.oxygen_offset, sf.oxygen_offset) AS oxygen_offset,
    COALESCE(pf.fio2_offset, sf.fio2_offset) AS fio2_offset,
    COALESCE(sh.advanced_respiratory_support, false) AS advanced_respiratory_support,
    sh.support_types,
    COALESCE(sh.support_end_inferred, false) AS support_end_inferred,
    COALESCE(th.ecmo, false) AS ecmo,
    COALESCE(th.other_mechanical_cv_support, false) AS other_mechanical_cv_support,
    mh.map_min,
    mh.map_offset,
    vh.norepinephrine,
    vh.epinephrine,
    vh.dopamine,
    COALESCE(vh.dobutamine_exposure, false) AS dobutamine_exposure,
    COALESCE(vh.other_agent_exposure, false) AS other_agent_exposure,
    COALESCE(vh.ne_epi_exposure, false) AS ne_epi_exposure,
    COALESCE(vh.dopamine_exposure, false) AS dopamine_exposure,
    COALESCE(vh.dose_unresolved, false) AS dose_unresolved,
    COALESCE(vh.norepinephrine_formulation_unresolved, false) AS norepinephrine_formulation_unresolved,
    vh.qualifying_duration_minutes,
    vh.vasoactive_offset,
    lh.bilirubin,
    lh.creatinine,
    lh.platelets,
    lh.potassium,
    lh.bicarbonate,
    br.ph,
    lh.lab_offset,
    br.bg_offset,
    CASE WHEN ur.weight_kg > 0 AND h.hr >= 5 THEN ur.urine_6h_ml / ur.weight_kg / 6.0 END AS uo_rate_6h,
    CASE WHEN ur.weight_kg > 0 AND h.hr >= 11 THEN ur.urine_12h_ml / ur.weight_kg / 12.0 END AS uo_rate_12h,
    CASE WHEN ur.weight_kg > 0 AND h.hr >= 23 THEN ur.urine_24h_ml / ur.weight_kg / 24.0 END AS uo_rate_24h,
    ur.urine_24h_ml,
    ur.observed_uo_hours_6h,
    ur.observed_uo_hours_12h,
    ur.observed_uo_hours_24h,
    COALESCE(ur.urine_12h_ml = 0 AND h.hr >= 11, false) AS anuria_12h,
    COALESCE(th.rrt, false) AS rrt,
    th.treatment_offset,
    (
        (lh.creatinine > 1.2 OR (ur.weight_kg > 0 AND ur.urine_24h_ml / ur.weight_kg / 24.0 < 0.3))
        AND (lh.potassium >= 6.0 OR (br.ph <= 7.2 AND lh.bicarbonate <= 12))
    ) IS TRUE AS rrt_criteria_proxy
FROM eicu_sofa2.hour_grid AS h
LEFT JOIN gcs_hour AS g ON g.patientunitstayid = h.patientunitstayid AND g.hr = h.hr
LEFT JOIN delirium_hour AS d ON d.patientunitstayid = h.patientunitstayid AND d.hr = h.hr
LEFT JOIN pf_ranked AS pf ON pf.patientunitstayid = h.patientunitstayid AND pf.hr = h.hr AND pf.rn = 1
LEFT JOIN sf_ranked AS sf ON sf.patientunitstayid = h.patientunitstayid AND sf.hr = h.hr AND sf.rn = 1
LEFT JOIN support_hour AS sh ON sh.patientunitstayid = h.patientunitstayid AND sh.hr = h.hr
LEFT JOIN map_hour AS mh ON mh.patientunitstayid = h.patientunitstayid AND mh.hr = h.hr
LEFT JOIN lab_hour AS lh ON lh.patientunitstayid = h.patientunitstayid AND lh.hr = h.hr
LEFT JOIN bg_renal_hour AS br ON br.patientunitstayid = h.patientunitstayid AND br.hr = h.hr
LEFT JOIN urine_rolling AS ur ON ur.patientunitstayid = h.patientunitstayid AND ur.hr = h.hr
LEFT JOIN vaso_hour AS vh ON vh.patientunitstayid = h.patientunitstayid AND vh.hr = h.hr
LEFT JOIN treatment_hour AS th ON th.patientunitstayid = h.patientunitstayid AND th.hr = h.hr;

ALTER TABLE eicu_sofa2.hourly_features
    ADD CONSTRAINT hourly_features_pk PRIMARY KEY (patientunitstayid, hr),
    ADD CONSTRAINT hourly_features_fio2_ck CHECK (
        fio2_fraction IS NULL OR fio2_fraction BETWEEN 0.15 AND 1.0
    ),
    ADD CONSTRAINT hourly_features_oxygen_causal_ck CHECK (
        oxygen_offset IS NULL OR (fio2_offset <= oxygen_offset AND oxygen_offset - fio2_offset <= 360)
    );

COMMENT ON COLUMN eicu_sofa2.hourly_features.norepinephrine IS
    'Parsed eICU source dose in mcg/kg/min; formulation is not encoded and remains unresolved for strict SOFA-2.';
COMMENT ON TABLE eicu_sofa2.vasoactive_events IS
    'Dose-aware normalized infusion evidence. pivoted_infusion rows are binary exposure only.';

-- source: sql/30_hourly_raw.sql
CREATE TABLE eicu_sofa2.sofa2_hourly_raw AS
WITH scored AS (
    SELECT
        f.*,
        eicu_sofa2.sofa2_brain(f.gcs, f.gcs_motor, false) AS brain_score_strict,
        eicu_sofa2.sofa2_brain(
            f.gcs, f.gcs_motor, f.delirium_drug_prescription_proxy
        ) AS brain_score_proxy,
        eicu_sofa2.sofa2_respiratory(
            f.pf_ratio, f.sf_ratio, f.advanced_respiratory_support, f.ecmo, false
        ) AS respiratory_score_strict,
        eicu_sofa2.sofa2_cardiovascular(
            f.map_min,
            f.norepinephrine,
            f.epinephrine,
            f.other_agent_exposure OR f.dobutamine_exposure
                OR (f.ne_epi_exposure AND f.norepinephrine IS NULL AND f.epinephrine IS NULL)
                OR (f.dopamine_exposure AND f.dopamine IS NULL),
            f.dopamine,
            f.other_mechanical_cv_support,
            false
        ) AS cardiovascular_score_lower_bound,
        CASE WHEN f.dose_unresolved OR f.norepinephrine_formulation_unresolved THEN NULL
             ELSE eicu_sofa2.sofa2_cardiovascular(
                f.map_min, f.norepinephrine, f.epinephrine,
                f.other_agent_exposure OR f.dobutamine_exposure,
                f.dopamine, f.other_mechanical_cv_support, false
             ) END AS cardiovascular_score_strict,
        eicu_sofa2.sofa2_liver(f.bilirubin) AS liver_score_strict,
        eicu_sofa2.sofa2_hemostasis(f.platelets) AS hemostasis_score_strict,
        eicu_sofa2.sofa2_kidney(
            f.creatinine, f.uo_rate_6h, f.uo_rate_12h, f.uo_rate_24h,
            f.anuria_12h, f.rrt, f.rrt_criteria_proxy
        ) AS kidney_score_proxy,
        eicu_sofa2.sofa2_kidney(
            f.creatinine, f.uo_rate_6h, f.uo_rate_12h, f.uo_rate_24h,
            f.anuria_12h, f.rrt, false
        ) AS kidney_score_strict,
        eicu_sofa2.sofa1_brain(f.gcs) AS sofa1_brain_strict,
        eicu_sofa2.sofa1_respiratory(
            f.pf_ratio, f.advanced_respiratory_support
        ) AS sofa1_respiratory_strict,
        CASE WHEN f.dose_unresolved OR f.norepinephrine_formulation_unresolved THEN NULL
             ELSE eicu_sofa2.sofa1_cardiovascular(
                f.map_min, f.dopamine, f.epinephrine, f.norepinephrine,
                f.dobutamine_exposure
             ) END AS sofa1_cardiovascular_strict,
        GREATEST(
            COALESCE(eicu_sofa2.sofa1_cardiovascular(
                f.map_min, f.dopamine, f.epinephrine, f.norepinephrine,
                f.dobutamine_exposure
            ), 0),
            CASE WHEN f.ne_epi_exposure THEN 3
                 WHEN f.dopamine_exposure OR f.dobutamine_exposure THEN 2 ELSE 0 END
        )::smallint AS sofa1_cardiovascular_lower_bound,
        eicu_sofa2.sofa1_liver(f.bilirubin) AS sofa1_liver_strict,
        eicu_sofa2.sofa1_hemostasis(f.platelets) AS sofa1_hemostasis_strict,
        eicu_sofa2.sofa1_kidney(f.creatinine, f.urine_24h_ml) AS sofa1_kidney_strict
    FROM eicu_sofa2.hourly_features AS f
), operational AS (
    SELECT
        s.*,
        COALESCE(brain_score_proxy, 0)::smallint AS brain_score_operational,
        COALESCE(respiratory_score_strict, 0)::smallint AS respiratory_score_operational,
        COALESCE(cardiovascular_score_lower_bound, 0)::smallint AS cardiovascular_score_operational,
        COALESCE(liver_score_strict, 0)::smallint AS liver_score_operational,
        COALESCE(kidney_score_proxy, 0)::smallint AS kidney_score_operational,
        COALESCE(hemostasis_score_strict, 0)::smallint AS hemostasis_score_operational
    FROM scored AS s
)
SELECT
    patientunitstayid,
    patienthealthsystemstayid,
    uniquepid,
    hr,
    startoffset,
    endoffset AS score_offset,
    brain_score_strict,
    brain_score_proxy,
    respiratory_score_strict,
    cardiovascular_score_strict,
    cardiovascular_score_lower_bound,
    liver_score_strict,
    kidney_score_strict,
    kidney_score_proxy,
    hemostasis_score_strict,
    brain_score_operational,
    respiratory_score_operational,
    cardiovascular_score_operational,
    liver_score_operational,
    kidney_score_operational,
    hemostasis_score_operational,
    (brain_score_operational + respiratory_score_operational
     + cardiovascular_score_operational + liver_score_operational
     + kidney_score_operational + hemostasis_score_operational)::smallint
        AS sofa2_total_operational,
    CASE WHEN brain_score_strict IS NOT NULL
           AND respiratory_score_strict IS NOT NULL
           AND cardiovascular_score_strict IS NOT NULL
           AND liver_score_strict IS NOT NULL
           AND kidney_score_strict IS NOT NULL
           AND hemostasis_score_strict IS NOT NULL
         THEN (brain_score_strict + respiratory_score_strict
              + cardiovascular_score_strict + liver_score_strict
              + kidney_score_strict + hemostasis_score_strict)::smallint END
        AS sofa2_total_strict,
    brain_score_strict IS NOT NULL AS brain_observed,
    respiratory_score_strict IS NOT NULL AS respiratory_observed,
    cardiovascular_score_lower_bound IS NOT NULL AS cardiovascular_observed,
    liver_score_strict IS NOT NULL AS liver_observed,
    kidney_score_proxy IS NOT NULL AS kidney_observed,
    hemostasis_score_strict IS NOT NULL AS hemostasis_observed,
    delirium_indication_unresolved,
    dose_unresolved,
    norepinephrine_formulation_unresolved,
    support_end_inferred,
    rrt_criteria_proxy,
    sofa1_brain_strict,
    sofa1_respiratory_strict,
    sofa1_cardiovascular_strict,
    sofa1_cardiovascular_lower_bound,
    sofa1_liver_strict,
    sofa1_hemostasis_strict,
    sofa1_kidney_strict
FROM operational;

ALTER TABLE eicu_sofa2.sofa2_hourly_raw
    ADD CONSTRAINT sofa2_hourly_raw_pk PRIMARY KEY (patientunitstayid, hr),
    ADD CONSTRAINT sofa2_hourly_total_ck CHECK (sofa2_total_operational BETWEEN 0 AND 24);

CREATE INDEX sofa2_hourly_raw_stay_offset_idx
    ON eicu_sofa2.sofa2_hourly_raw (patientunitstayid, score_offset);

CREATE VIEW eicu_sofa2.sofa1_hourly_reference AS
SELECT
    patientunitstayid,
    patienthealthsystemstayid,
    uniquepid,
    hr,
    score_offset,
    sofa1_brain_strict AS brain,
    sofa1_respiratory_strict AS respiratory,
    sofa1_cardiovascular_strict AS cardiovascular_strict,
    sofa1_cardiovascular_lower_bound AS cardiovascular_lower_bound,
    sofa1_liver_strict AS liver,
    sofa1_hemostasis_strict AS hemostasis,
    sofa1_kidney_strict AS kidney,
    (COALESCE(sofa1_brain_strict,0) + COALESCE(sofa1_respiratory_strict,0)
     + COALESCE(sofa1_cardiovascular_lower_bound,0) + COALESCE(sofa1_liver_strict,0)
     + COALESCE(sofa1_hemostasis_strict,0) + COALESCE(sofa1_kidney_strict,0))::smallint
        AS sofa1_total_lower_bound,
    CASE WHEN sofa1_brain_strict IS NOT NULL AND sofa1_respiratory_strict IS NOT NULL
           AND sofa1_cardiovascular_strict IS NOT NULL AND sofa1_liver_strict IS NOT NULL
           AND sofa1_hemostasis_strict IS NOT NULL AND sofa1_kidney_strict IS NOT NULL
         THEN (sofa1_brain_strict + sofa1_respiratory_strict
              + sofa1_cardiovascular_strict + sofa1_liver_strict
              + sofa1_hemostasis_strict + sofa1_kidney_strict)::smallint END AS sofa1_total_strict,
    dose_unresolved OR norepinephrine_formulation_unresolved AS reference_unresolved,
    'Original SOFA/SOFA-1 reference; not SOFA-2'::text AS definition
FROM eicu_sofa2.sofa2_hourly_raw;

-- source: sql/40_aggregations.sql
CREATE TABLE eicu_sofa2.sofa2_daily AS
WITH RECURSIVE day_raw AS MATERIALIZED (
    SELECT
        patientunitstayid, patienthealthsystemstayid, uniquepid,
        floor(hr / 24.0)::integer AS icu_day,
        min(startoffset) AS day_startoffset,
        max(score_offset) AS day_endoffset,
        max(brain_score_proxy) AS brain_raw,
        max(respiratory_score_strict) AS respiratory_raw,
        max(cardiovascular_score_lower_bound) AS cardiovascular_raw,
        max(liver_score_strict) AS liver_raw,
        max(kidney_score_proxy) AS kidney_raw,
        max(hemostasis_score_strict) AS hemostasis_raw,
        bool_or(dose_unresolved OR norepinephrine_formulation_unresolved) AS dose_unresolved
    FROM eicu_sofa2.sofa2_hourly_raw
    WHERE hr >= 0
    GROUP BY patientunitstayid, patienthealthsystemstayid, uniquepid, floor(hr / 24.0)::integer
), filled AS (
    SELECT d.*,
        COALESCE(brain_raw,0)::smallint AS brain,
        COALESCE(respiratory_raw,0)::smallint AS respiratory,
        COALESCE(cardiovascular_raw,0)::smallint AS cardiovascular,
        COALESCE(liver_raw,0)::smallint AS liver,
        COALESCE(kidney_raw,0)::smallint AS kidney,
        COALESCE(hemostasis_raw,0)::smallint AS hemostasis,
        false AS brain_locf, false AS respiratory_locf, false AS cardiovascular_locf,
        false AS liver_locf, false AS kidney_locf, false AS hemostasis_locf
    FROM day_raw d WHERE icu_day=0
    UNION ALL
    SELECT d.*,
        COALESCE(d.brain_raw,f.brain)::smallint,
        COALESCE(d.respiratory_raw,f.respiratory)::smallint,
        COALESCE(d.cardiovascular_raw,f.cardiovascular)::smallint,
        COALESCE(d.liver_raw,f.liver)::smallint,
        COALESCE(d.kidney_raw,f.kidney)::smallint,
        COALESCE(d.hemostasis_raw,f.hemostasis)::smallint,
        d.brain_raw IS NULL, d.respiratory_raw IS NULL, d.cardiovascular_raw IS NULL,
        d.liver_raw IS NULL, d.kidney_raw IS NULL, d.hemostasis_raw IS NULL
    FROM filled f JOIN day_raw d
      ON d.patientunitstayid=f.patientunitstayid AND d.icu_day=f.icu_day+1
)
SELECT *,
    (brain+respiratory+cardiovascular+liver+kidney+hemostasis)::smallint AS sofa2_total_operational,
    brain_raw IS NOT NULL AS brain_observed,
    respiratory_raw IS NOT NULL AS respiratory_observed,
    cardiovascular_raw IS NOT NULL AS cardiovascular_observed,
    liver_raw IS NOT NULL AS liver_observed,
    kidney_raw IS NOT NULL AS kidney_observed,
    hemostasis_raw IS NOT NULL AS hemostasis_observed,
    'canonical_daily_component_maxima'::text AS aggregation_definition
FROM filled;

ALTER TABLE eicu_sofa2.sofa2_daily
    ADD CONSTRAINT sofa2_daily_pk PRIMARY KEY(patientunitstayid,icu_day),
    ADD CONSTRAINT sofa2_daily_total_ck CHECK(sofa2_total_operational BETWEEN 0 AND 24);

CREATE TABLE eicu_sofa2.first_day_sofa2 AS
SELECT patientunitstayid, patienthealthsystemstayid, uniquepid,
       day_startoffset, day_endoffset, brain, respiratory, cardiovascular,
       liver, kidney, hemostasis, sofa2_total_operational,
       brain_observed, respiratory_observed, cardiovascular_observed,
       liver_observed, kidney_observed, hemostasis_observed, dose_unresolved
FROM eicu_sofa2.sofa2_daily WHERE icu_day=0;

ALTER TABLE eicu_sofa2.first_day_sofa2
    ADD CONSTRAINT first_day_sofa2_pk PRIMARY KEY(patientunitstayid);

CREATE TABLE eicu_sofa2.sofa2_hourly_rolling_experimental AS
WITH x AS (
    SELECT patientunitstayid,patienthealthsystemstayid,uniquepid,hr,score_offset,
        max(brain_score_operational) OVER w AS brain,
        max(respiratory_score_operational) OVER w AS respiratory,
        max(cardiovascular_score_operational) OVER w AS cardiovascular,
        max(liver_score_operational) OVER w AS liver,
        max(kidney_score_operational) OVER w AS kidney,
        max(hemostasis_score_operational) OVER w AS hemostasis,
        bool_or(dose_unresolved OR norepinephrine_formulation_unresolved) OVER w AS dose_unresolved
    FROM eicu_sofa2.sofa2_hourly_raw
    WINDOW w AS (PARTITION BY patientunitstayid ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
)
SELECT *, (brain+respiratory+cardiovascular+liver+kidney+hemostasis)::smallint AS sofa2_total_operational,
    'experimental_trailing_24_hour_component_maxima'::text AS aggregation_definition
FROM x WHERE hr>=0;

ALTER TABLE eicu_sofa2.sofa2_hourly_rolling_experimental
    ADD CONSTRAINT sofa2_hourly_rolling_pk PRIMARY KEY(patientunitstayid,hr),
    ADD CONSTRAINT sofa2_hourly_rolling_total_ck CHECK(sofa2_total_operational BETWEEN 0 AND 24);

-- source: sql/50_infection_outputs.sql
CREATE TABLE eicu_sofa2.suspicion_of_infection AS
WITH antimicrobials AS (
    SELECT
        m.medicationid,
        m.patientunitstayid,
        m.drugstartoffset AS antibiotic_offset,
        m.drugname AS antimicrobial,
        m.routeadmin
    FROM eicu_icu.medication AS m
    INNER JOIN eicu_sofa2.adult_stays AS s USING (patientunitstayid)
    WHERE m.drugstartoffset IS NOT NULL
      AND lower(m.drugname) ~ '(vancomycin|piperacillin|tazobactam|cef[a-z]|meropenem|imipenem|ertapenem|aztreonam|levofloxacin|ciprofloxacin|moxifloxacin|metronidazole|clindamycin|linezolid|daptomycin|ampicillin|amoxicillin|nafcillin|oxacillin|penicillin|gentamicin|tobramycin|amikacin|doxycycline|azithromycin|clarithromycin|trimethoprim|sulfameth|fluconazole|micafungin|voriconazole|amphotericin|acyclovir|ganciclovir)'
      AND COALESCE(lower(m.routeadmin),'') !~ '(topical|ophthalmic|otic)'
), cultures AS (
    SELECT
        patientunitstayid,
        culturetakenoffset AS culture_offset,
        min(microlabid) AS microlabid,
        string_agg(DISTINCT culturesite, '; ' ORDER BY culturesite) AS culture_sites,
        string_agg(DISTINCT organism, '; ' ORDER BY organism) AS organisms
    FROM eicu_icu.microlab
    WHERE culturetakenoffset IS NOT NULL
    GROUP BY patientunitstayid, culturetakenoffset
), pairs AS (
    SELECT
        a.patientunitstayid,
        a.medicationid,
        c.microlabid,
        a.antibiotic_offset,
        c.culture_offset,
        LEAST(a.antibiotic_offset,c.culture_offset) AS suspected_infection_offset,
        CASE WHEN a.antibiotic_offset <= c.culture_offset
             THEN 'antibiotic_first' ELSE 'culture_first' END AS pair_direction,
        a.antimicrobial,
        a.routeadmin,
        c.culture_sites,
        c.organisms
    FROM antimicrobials a
    INNER JOIN cultures c USING(patientunitstayid)
    WHERE (a.antibiotic_offset <= c.culture_offset
           AND c.culture_offset-a.antibiotic_offset BETWEEN 0 AND 1440)
       OR (a.antibiotic_offset > c.culture_offset
           AND a.antibiotic_offset-c.culture_offset BETWEEN 0 AND 4320)
)
SELECT
    s.patienthealthsystemstayid,
    s.uniquepid,
    p.*,
    row_number() OVER (
        PARTITION BY p.patientunitstayid
        ORDER BY p.suspected_infection_offset,p.antibiotic_offset,p.culture_offset,
                 p.medicationid,p.microlabid
    ) AS event_number
FROM pairs p
INNER JOIN eicu_sofa2.adult_stays s USING(patientunitstayid);

ALTER TABLE eicu_sofa2.suspicion_of_infection
    ADD CONSTRAINT suspicion_of_infection_pk PRIMARY KEY(patientunitstayid,event_number);

CREATE TEMP TABLE task_eicu_infection_baseline ON COMMIT DROP AS
SELECT
    e.patientunitstayid,e.event_number,
    s2.sofa2_total_operational AS baseline_sofa2_operational,
    s2.score_offset AS baseline_offset,
    s1.sofa1_total_lower_bound AS baseline_sofa1_lower_bound,
    s1.sofa1_total_strict AS baseline_sofa1_strict,
    s1.score_offset AS baseline_sofa1_offset
FROM eicu_sofa2.suspicion_of_infection e
LEFT JOIN LATERAL (
    SELECT r.sofa2_total_operational,r.score_offset
    FROM eicu_sofa2.sofa2_hourly_raw r
    WHERE r.patientunitstayid=e.patientunitstayid
      AND r.score_offset>=e.suspected_infection_offset-2880
      AND r.score_offset<e.suspected_infection_offset
    ORDER BY r.sofa2_total_operational,r.score_offset DESC LIMIT 1
) s2 ON true
LEFT JOIN LATERAL (
    SELECT r.sofa1_total_lower_bound,r.sofa1_total_strict,r.score_offset
    FROM eicu_sofa2.sofa1_hourly_reference r
    WHERE r.patientunitstayid=e.patientunitstayid
      AND r.score_offset>=e.suspected_infection_offset-2880
      AND r.score_offset<e.suspected_infection_offset
    ORDER BY r.sofa1_total_lower_bound,r.score_offset DESC LIMIT 1
) s1 ON true;

CREATE UNIQUE INDEX task_eicu_infection_baseline_pk
    ON task_eicu_infection_baseline(patientunitstayid,event_number);

CREATE TABLE eicu_sofa2.infection_associated_sofa2_hourly_exploratory AS
SELECT
    e.patientunitstayid,e.patienthealthsystemstayid,e.uniquepid,e.event_number,
    e.suspected_infection_offset,e.antibiotic_offset,e.culture_offset,e.pair_direction,
    r.hr,r.score_offset,r.sofa2_total_operational,r.sofa2_total_strict,
    b.baseline_sofa2_operational,b.baseline_offset,
    CASE WHEN b.baseline_sofa2_operational IS NOT NULL
         THEN r.sofa2_total_operational-b.baseline_sofa2_operational END AS delta_observed_baseline,
    r.sofa2_total_operational AS delta_zero_baseline_sensitivity,
    COALESCE(r.sofa2_total_operational-b.baseline_sofa2_operational>=2,false)
        AS infection_associated_delta_ge2_observed_baseline,
    r.sofa2_total_operational>=2 AS infection_associated_delta_ge2_zero_baseline_sensitivity,
    b.baseline_sofa2_operational IS NULL AS baseline_unobserved
FROM eicu_sofa2.suspicion_of_infection e
INNER JOIN eicu_sofa2.sofa2_hourly_raw r
    ON r.patientunitstayid=e.patientunitstayid
   AND r.score_offset>=e.suspected_infection_offset
   AND r.score_offset<=e.suspected_infection_offset+1440
LEFT JOIN task_eicu_infection_baseline b
    ON b.patientunitstayid=e.patientunitstayid AND b.event_number=e.event_number;

ALTER TABLE eicu_sofa2.infection_associated_sofa2_hourly_exploratory
    ADD CONSTRAINT infection_associated_sofa2_hourly_pk
        PRIMARY KEY(patientunitstayid,event_number,score_offset),
    ADD CONSTRAINT infection_associated_sofa2_causal_ck CHECK(
        baseline_offset IS NULL OR
        (baseline_offset<suspected_infection_offset AND baseline_offset<score_offset));

CREATE TABLE eicu_sofa2.infection_associated_sofa2_events_exploratory AS
SELECT
    e.patientunitstayid,e.patienthealthsystemstayid,e.uniquepid,e.event_number,
    e.suspected_infection_offset,e.antibiotic_offset,e.culture_offset,e.pair_direction,
    e.antimicrobial,e.routeadmin,e.culture_sites,e.organisms,
    b.baseline_sofa2_operational,b.baseline_offset,
    max(h.sofa2_total_operational) AS peak_sofa2_operational,
    max(h.sofa2_total_strict) AS peak_sofa2_strict,
    max(h.delta_observed_baseline) AS delta_observed_baseline,
    max(h.delta_zero_baseline_sensitivity) AS delta_zero_baseline_sensitivity,
    bool_or(h.infection_associated_delta_ge2_observed_baseline)
        AS infection_associated_delta_ge2_observed_baseline,
    bool_or(h.infection_associated_delta_ge2_zero_baseline_sensitivity)
        AS infection_associated_delta_ge2_zero_baseline_sensitivity,
    count(h.score_offset) AS observed_postinfection_hours,
    b.baseline_sofa2_operational IS NULL AS baseline_unobserved,
    'exploratory infection-associated SOFA-2; not Sepsis-3'::text AS interpretation
FROM eicu_sofa2.suspicion_of_infection e
LEFT JOIN task_eicu_infection_baseline b
  ON b.patientunitstayid=e.patientunitstayid AND b.event_number=e.event_number
LEFT JOIN eicu_sofa2.infection_associated_sofa2_hourly_exploratory h
  ON h.patientunitstayid=e.patientunitstayid AND h.event_number=e.event_number
GROUP BY e.patientunitstayid,e.patienthealthsystemstayid,e.uniquepid,e.event_number,
         e.suspected_infection_offset,e.antibiotic_offset,e.culture_offset,e.pair_direction,
         e.antimicrobial,e.routeadmin,e.culture_sites,e.organisms,
         b.baseline_sofa2_operational,b.baseline_offset;

ALTER TABLE eicu_sofa2.infection_associated_sofa2_events_exploratory
    ADD CONSTRAINT infection_associated_sofa2_events_pk PRIMARY KEY(patientunitstayid,event_number);

CREATE TABLE eicu_sofa2.sepsis3_sofa1_reference AS
SELECT
    e.patientunitstayid,e.patienthealthsystemstayid,e.uniquepid,e.event_number,
    e.suspected_infection_offset,e.antibiotic_offset,e.culture_offset,e.pair_direction,
    b.baseline_sofa1_lower_bound,b.baseline_sofa1_strict,b.baseline_sofa1_offset,
    max(r.sofa1_total_lower_bound) AS peak_sofa1_lower_bound,
    max(r.sofa1_total_strict) AS peak_sofa1_strict,
    max(r.sofa1_total_lower_bound)-b.baseline_sofa1_lower_bound AS delta_observed_baseline,
    max(r.sofa1_total_lower_bound) AS delta_zero_baseline_sensitivity,
    COALESCE(max(r.sofa1_total_lower_bound)-b.baseline_sofa1_lower_bound>=2,false)
        AS sepsis3_delta_ge2_observed_baseline,
    max(r.sofa1_total_lower_bound)>=2 AS sepsis3_delta_ge2_zero_baseline_sensitivity,
    bool_or(r.reference_unresolved) AS reference_unresolved,
    'Sepsis-3 operational reference using original SOFA/SOFA-1; review unresolved evidence'::text
        AS definition
FROM eicu_sofa2.suspicion_of_infection e
LEFT JOIN task_eicu_infection_baseline b
  ON b.patientunitstayid=e.patientunitstayid AND b.event_number=e.event_number
LEFT JOIN eicu_sofa2.sofa1_hourly_reference r
  ON r.patientunitstayid=e.patientunitstayid
 AND r.score_offset>=e.suspected_infection_offset
 AND r.score_offset<=e.suspected_infection_offset+1440
GROUP BY e.patientunitstayid,e.patienthealthsystemstayid,e.uniquepid,e.event_number,
         e.suspected_infection_offset,e.antibiotic_offset,e.culture_offset,e.pair_direction,
         b.baseline_sofa1_lower_bound,b.baseline_sofa1_strict,b.baseline_sofa1_offset;

ALTER TABLE eicu_sofa2.sepsis3_sofa1_reference
    ADD CONSTRAINT sepsis3_sofa1_reference_pk PRIMARY KEY(patientunitstayid,event_number);

-- source: sql/60_quality_and_metadata.sql
CREATE TABLE eicu_sofa2.data_quality_report(
    check_name text PRIMARY KEY,
    severity text NOT NULL,
    passed boolean NOT NULL,
    observed_value text NOT NULL,
    expected_value text NOT NULL,
    detail text NOT NULL,
    checked_at timestamptz NOT NULL DEFAULT current_timestamp
);

WITH checks AS (
    SELECT 'hour_grid_raw_identity'::text n,
        abs((SELECT count(*) FROM eicu_sofa2.hour_grid)-
            (SELECT count(*) FROM eicu_sofa2.sofa2_hourly_raw))::bigint v,
        'hour grid and raw scores have identical rows'::text d
    UNION ALL SELECT 'hourly_duplicates',count(*),'one row per stay-hour' FROM (
        SELECT patientunitstayid,hr FROM eicu_sofa2.sofa2_hourly_raw
        GROUP BY 1,2 HAVING count(*)>1) x
    UNION ALL SELECT 'fio2_fraction_range',count(*),'FiO2 remains a fraction'
        FROM eicu_sofa2.oxygen_events WHERE fio2_fraction NOT BETWEEN .15 AND 1
    UNION ALL SELECT 'parsed_dose_duration',count(*),'parsed doses require >=60 minute episode'
        FROM eicu_sofa2.vasoactive_events WHERE dose_status='parsed' AND duration_minutes<60
    UNION ALL SELECT 'binary_not_dose',count(*),'pivoted binary infusion is exposure only'
        FROM eicu_sofa2.vasoactive_events
        WHERE source_table='pivoted_infusion' AND dose_status='parsed'
    UNION ALL SELECT 'hourly_score_range',count(*),'SOFA-2 total is 0-24'
        FROM eicu_sofa2.sofa2_hourly_raw WHERE sofa2_total_operational NOT BETWEEN 0 AND 24
    UNION ALL SELECT 'daily_total_identity',count(*),'daily total sums component maxima'
        FROM eicu_sofa2.sofa2_daily WHERE sofa2_total_operational<>
            brain+respiratory+cardiovascular+liver+kidney+hemostasis
    UNION ALL SELECT 'infection_pair_windows',count(*),'pair direction windows are valid'
        FROM eicu_sofa2.suspicion_of_infection
        WHERE (pair_direction='antibiotic_first' AND culture_offset-antibiotic_offset NOT BETWEEN 0 AND 1440)
           OR (pair_direction='culture_first' AND antibiotic_offset-culture_offset NOT BETWEEN 0 AND 4320)
    UNION ALL SELECT 'infection_baseline_causality',count(*),'baseline precedes anchor and score'
        FROM eicu_sofa2.infection_associated_sofa2_hourly_exploratory
        WHERE baseline_offset>=suspected_infection_offset OR baseline_offset>=score_offset
)
INSERT INTO eicu_sofa2.data_quality_report
    (check_name,severity,passed,observed_value,expected_value,detail)
SELECT n,CASE WHEN v=0 THEN 'pass' ELSE 'blocker' END,v=0,v::text,'0',d FROM checks;

INSERT INTO eicu_sofa2.data_quality_report
    (check_name,severity,passed,observed_value,expected_value,detail)
SELECT metric,'info',true,value,'reported',detail FROM (
    SELECT 'coverage_brain_percent'::text metric,
        round(100.0*count(*) FILTER(WHERE brain_observed)/NULLIF(count(*),0),2)::text value,
        'ICU-hour new brain evidence'::text detail FROM eicu_sofa2.sofa2_hourly_raw WHERE hr>=0
    UNION ALL SELECT 'coverage_respiratory_percent',
        round(100.0*count(*) FILTER(WHERE respiratory_observed)/NULLIF(count(*),0),2)::text,
        'ICU-hour paired respiratory evidence' FROM eicu_sofa2.sofa2_hourly_raw WHERE hr>=0
    UNION ALL SELECT 'coverage_cardiovascular_percent',
        round(100.0*count(*) FILTER(WHERE cardiovascular_observed)/NULLIF(count(*),0),2)::text,
        'ICU-hour MAP or vasoactive evidence' FROM eicu_sofa2.sofa2_hourly_raw WHERE hr>=0
    UNION ALL SELECT 'coverage_liver_percent',
        round(100.0*count(*) FILTER(WHERE liver_observed)/NULLIF(count(*),0),2)::text,
        'ICU-hour bilirubin evidence' FROM eicu_sofa2.sofa2_hourly_raw WHERE hr>=0
    UNION ALL SELECT 'coverage_kidney_percent',
        round(100.0*count(*) FILTER(WHERE kidney_observed)/NULLIF(count(*),0),2)::text,
        'ICU-hour kidney evidence' FROM eicu_sofa2.sofa2_hourly_raw WHERE hr>=0
    UNION ALL SELECT 'coverage_hemostasis_percent',
        round(100.0*count(*) FILTER(WHERE hemostasis_observed)/NULLIF(count(*),0),2)::text,
        'ICU-hour platelet evidence' FROM eicu_sofa2.sofa2_hourly_raw WHERE hr>=0
    UNION ALL SELECT 'dose_status_parsed',count(*)::text,'parsed convertible infusion segments'
        FROM eicu_sofa2.vasoactive_events WHERE dose_status='parsed'
    UNION ALL SELECT 'dose_status_exposure_only',count(*)::text,'dose-unresolved exposure rows'
        FROM eicu_sofa2.vasoactive_events WHERE dose_status='exposure_only'
    UNION ALL SELECT 'dose_status_unit_unrecognized',count(*)::text,'unrecognized rate-unit rows'
        FROM eicu_sofa2.vasoactive_events WHERE dose_status='unit_unrecognized'
    UNION ALL SELECT 'ventilation_intervals_inferred_end',count(*)::text,'support intervals with inferred end'
        FROM eicu_sofa2.respiratory_support_intervals WHERE end_inferred
    UNION ALL SELECT 'sofa1_reference_unresolved_events',count(*)::text,
        'infection events with unresolved SOFA-1 dose evidence'
        FROM eicu_sofa2.sepsis3_sofa1_reference WHERE reference_unresolved
) m;

CREATE TABLE eicu_sofa2.pipeline_metadata(
    pipeline_name text PRIMARY KEY,
    definition_version text NOT NULL,
    source_database text NOT NULL,
    source_version text NOT NULL,
    canonical_output text NOT NULL,
    experimental_output text NOT NULL,
    target_schema text NOT NULL,
    row_counts jsonb NOT NULL,
    limitations jsonb NOT NULL,
    built_at timestamptz NOT NULL DEFAULT current_timestamp
);

INSERT INTO eicu_sofa2.pipeline_metadata
    (pipeline_name,definition_version,source_database,source_version,canonical_output,
     experimental_output,target_schema,row_counts,limitations)
SELECT 'eICU SOFA-2','SOFA-2 JAMA 2025; audit 2026-08-03',current_database(),
       'eICU-CRD 2.0','eicu_sofa2.sofa2_daily',
       'eicu_sofa2.sofa2_hourly_rolling_experimental','eicu_sofa2',
       jsonb_build_object(
          'adult_stays',(SELECT count(*) FROM eicu_sofa2.adult_stays),
          'hourly_rows',(SELECT count(*) FROM eicu_sofa2.sofa2_hourly_raw),
          'daily_rows',(SELECT count(*) FROM eicu_sofa2.sofa2_daily),
          'infection_pairs',(SELECT count(*) FROM eicu_sofa2.suspicion_of_infection)),
       jsonb_build_object(
          'dose','binary infusion pivots are exposure-only; unrecognized units remain unresolved',
          'norepinephrine','formulation not encoded; strict score remains unresolved',
          'ventilation','some interval end times are inferred and flagged',
          'infection','SOFA-2 association is exploratory; Sepsis-3 reference uses SOFA-1');

COMMIT;
