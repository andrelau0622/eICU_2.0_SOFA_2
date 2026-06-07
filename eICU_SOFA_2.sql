-- =================================================================
-- eICU v2.0 SOFA-2 动态评分及 Sepsis-3 提取
-- =================================================================
SET work_mem = '2047MB';

-- =================================================================
-- 步骤 0: 环境彻底清理
-- =================================================================
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_sedation CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_delirium CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_brain CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_resp_support CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_mech CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_oxygen CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_kidney_labs CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_rrt CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_urine CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_coag CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_stage1_liver CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_hourly_raw CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_scores CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_scores_hr_filtered CASCADE;
DROP TABLE IF EXISTS eicu_derived.first_day_sofa2 CASCADE;
DROP TABLE IF EXISTS eicu_derived.suspicion_of_infection CASCADE;
DROP TABLE IF EXISTS eicu_derived.sepsis3_sofa2_delta CASCADE;
DROP TABLE IF EXISTS eicu_derived.icustay_hourly_basedon_icuintime CASCADE;

-- =================================================================
-- 步骤 1: 时间轴网格 (基础)
-- =================================================================
CREATE TABLE eicu_derived.icustay_hourly_basedon_icuintime AS
WITH all_hours AS (
  SELECT patientunitstayid, COALESCE(unitdischargeoffset, 7 * 24 * 60) AS end_offset,
    ARRAY(SELECT * FROM GENERATE_SERIES(-24, CAST(CEIL(COALESCE(unitdischargeoffset, 7 * 24 * 60) / 60.0) AS INT))) AS hrs
  FROM eicu_icu.patient
)
SELECT patientunitstayid, CAST(hr_unnested AS BIGINT) AS hr, CAST(hr_unnested AS BIGINT) * 60 AS startoffset, (CAST(hr_unnested AS BIGINT) + 1) * 60 AS endoffset
FROM all_hours CROSS JOIN UNNEST(all_hours.hrs) AS _t0(hr_unnested);

CREATE INDEX IF NOT EXISTS idx_eicu_h_stay_hr ON eicu_derived.icustay_hourly_basedon_icuintime(patientunitstayid, hr);

-- =================================================================
-- 步骤 2: Stage 1 构建 9 个组件表
-- =================================================================
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_sedation AS
SELECT patientunitstayid, infusionoffset AS startoffset, infusionoffset + 60 AS endoffset
FROM eicu_icu.infusiondrug WHERE (drugname ILIKE '%propofol%' OR drugname ILIKE '%midazolam%' OR drugname ILIKE '%dexmedetomidine%' OR drugname ILIKE '%fentanyl%') AND drugrate <> '';

CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_brain AS
WITH gcs_base AS (SELECT g.patientunitstayid, g.chartoffset, COALESCE(CASE WHEN g.gcs <= 5 THEN 4 WHEN g.gcs <= 8 THEN 3 WHEN g.gcs <= 12 THEN 2 WHEN g.gcs <= 14 THEN 1 WHEN g.gcs = 15 THEN 0 ELSE NULL END, CASE WHEN g.gcsmotor <= 2 THEN 4 WHEN g.gcsmotor = 3 THEN 3 WHEN g.gcsmotor = 4 THEN 2 WHEN g.gcsmotor = 5 THEN 1 WHEN g.gcsmotor = 6 THEN 0 ELSE NULL END) AS brain_score_raw FROM eicu_derived.pivoted_gcs g),
gcs_grouping AS (SELECT patientunitstayid, chartoffset, brain_score_raw, COUNT(brain_score_raw) OVER (PARTITION BY patientunitstayid ORDER BY chartoffset) as grp FROM gcs_base)
SELECT patientunitstayid, chartoffset AS startoffset, LEAD(chartoffset, 1, 9999999) OVER (PARTITION BY patientunitstayid ORDER BY chartoffset) AS endoffset, COALESCE(FIRST_VALUE(brain_score_raw) OVER (PARTITION BY patientunitstayid, grp ORDER BY chartoffset), 0) AS brain_score_final FROM gcs_grouping;

CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_mech AS
SELECT ih.patientunitstayid, ih.hr, MAX(CASE WHEN t.treatmentstring ILIKE '%ECMO%' THEN 1 ELSE 0 END) AS is_ecmo FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_icu.treatment t ON ih.patientunitstayid = t.patientunitstayid WHERE t.treatmentoffset >= ih.startoffset AND t.treatmentoffset <= ih.endoffset GROUP BY ih.patientunitstayid, ih.hr;

CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_oxygen AS
SELECT ih.patientunitstayid, ih.hr, ((ARRAY_AGG(bg.pao2 ORDER BY bg.chartoffset DESC))[1] / NULLIF(COALESCE((ARRAY_AGG(bg.fio2 ORDER BY bg.chartoffset DESC))[1], 21), 0) * 100) AS pf_ratio
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_derived.pivoted_bg bg ON ih.patientunitstayid = bg.patientunitstayid AND bg.chartoffset > ih.startoffset AND bg.chartoffset <= ih.endoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;

CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_urine AS
SELECT g.patientunitstayid, g.hr, SUM(uo.urineoutput) OVER w24 AS uo_sum_24h, CASE WHEN g.hr >= 24 THEN SUM(uo.urineoutput) OVER w24 / COALESCE(NULLIF(p.admissionweight, 0), 70.0) / 24 END AS rate_24h
FROM eicu_derived.icustay_hourly_basedon_icuintime g LEFT JOIN eicu_derived.pivoted_uo uo ON g.patientunitstayid = uo.patientunitstayid AND uo.chartoffset > g.startoffset AND uo.chartoffset <= g.endoffset JOIN eicu_icu.patient p ON g.patientunitstayid = p.patientunitstayid WINDOW w24 AS (PARTITION BY g.patientunitstayid ORDER BY g.hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);

-- 保持文件结构完整性的占位符表
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_coag AS SELECT patientunitstayid, hr FROM eicu_derived.icustay_hourly_basedon_icuintime WHERE 1=0; 
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_liver AS SELECT patientunitstayid, hr FROM eicu_derived.icustay_hourly_basedon_icuintime WHERE 1=0; 
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_kidney_labs AS SELECT patientunitstayid, hr FROM eicu_derived.icustay_hourly_basedon_icuintime WHERE 1=0; 
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_delirium AS SELECT patientunitstayid, hr FROM eicu_derived.icustay_hourly_basedon_icuintime WHERE 1=0; 
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_resp_support AS SELECT patientunitstayid, hr FROM eicu_derived.icustay_hourly_basedon_icuintime WHERE 1=0; 
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_rrt AS SELECT patientunitstayid, hr FROM eicu_derived.icustay_hourly_basedon_icuintime WHERE 1=0; 

-- =================================================================
-- 步骤 3: 每小时原始评分表
-- =================================================================
CREATE TABLE eicu_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.patientunitstayid, p.uniquepid as subject_id, hr, ih.startoffset, ih.endoffset 
    FROM eicu_derived.icustay_hourly_basedon_icuintime ih 
    INNER JOIN eicu_icu.patient p ON ih.patientunitstayid = p.patientunitstayid
)
SELECT co.patientunitstayid AS stay_id, co.subject_id, co.hr,
    COALESCE(br.brain_score_final, 0) AS brain_score,
    CASE WHEN ox.pf_ratio <= 100 THEN 4 WHEN ox.pf_ratio <= 200 THEN 3 WHEN ox.pf_ratio <= 300 THEN 2 WHEN ox.pf_ratio <= 400 THEN 1 ELSE 0 END AS respiratory_score,
    CASE WHEN MAX(inf.norepinephrine) > 0.1 THEN 4 WHEN MAX(inf.norepinephrine) > 0 THEN 3 ELSE 0 END AS cardiovascular_score,
    CASE WHEN MAX(lab.bilirubin) > 12.0 THEN 4 WHEN MAX(lab.bilirubin) > 6.0 THEN 3 WHEN MAX(lab.bilirubin) > 2.0 THEN 2 WHEN MAX(lab.bilirubin) > 1.2 THEN 1 ELSE 0 END AS liver_score,
    CASE WHEN MAX(lab.creatinine) > 3.5 THEN 3 WHEN MAX(lab.creatinine) > 2.0 THEN 2 WHEN MAX(lab.creatinine) > 1.2 THEN 1 ELSE 0 END AS kidney_score,
    CASE WHEN MIN(lab.platelets) < 20 THEN 4 WHEN MIN(lab.platelets) < 50 THEN 3 WHEN MIN(lab.platelets) < 100 THEN 2 WHEN MIN(lab.platelets) < 150 THEN 1 ELSE 0 END AS hemostasis_score
FROM co 
LEFT JOIN eicu_derived.sofa2_stage1_brain br ON co.patientunitstayid = br.patientunitstayid AND co.endoffset > br.startoffset AND co.endoffset <= br.endoffset
LEFT JOIN eicu_derived.pivoted_infusion inf ON co.patientunitstayid = inf.patientunitstayid AND inf.chartoffset >= co.startoffset AND inf.chartoffset <= co.endoffset
LEFT JOIN eicu_derived.sofa2_stage1_oxygen ox ON co.patientunitstayid = ox.patientunitstayid AND co.hr = ox.hr
LEFT JOIN eicu_derived.pivoted_lab lab ON co.patientunitstayid = lab.patientunitstayid AND lab.chartoffset > co.startoffset AND lab.chartoffset <= co.endoffset
GROUP BY co.patientunitstayid, co.subject_id, co.hr, co.startoffset, co.endoffset, br.brain_score_final, ox.pf_ratio;

-- =================================================================
-- 步骤 4: 核心结果表构建
-- =================================================================
CREATE TABLE eicu_derived.sofa2_scores AS
SELECT *, 
       (brain_score + respiratory_score + cardiovascular_score + liver_score + kidney_score + hemostasis_score) AS sofa2_total, 
       (ABS(hashtext(subject_id)) % 10) AS fold_id
FROM (
    SELECT stay_id, subject_id, hr,
           MAX(brain_score) OVER w AS brain_score, 
           MAX(respiratory_score) OVER w AS respiratory_score, 
           MAX(cardiovascular_score) OVER w AS cardiovascular_score, 
           MAX(liver_score) OVER w AS liver_score, 
           MAX(kidney_score) OVER w AS kidney_score, 
           MAX(hemostasis_score) OVER w AS hemostasis_score 
    FROM eicu_derived.sofa2_hourly_raw 
    WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING)
) x;

CREATE TABLE eicu_derived.sofa2_scores_hr_filtered AS 
SELECT * FROM eicu_derived.sofa2_scores WHERE hr >= 0;

CREATE TABLE eicu_derived.first_day_sofa2 AS
SELECT stay_id, subject_id, MAX(sofa2_total) AS sofa2_total 
FROM eicu_derived.sofa2_scores_hr_filtered WHERE hr BETWEEN 0 AND 23 GROUP BY stay_id, subject_id;

-- =================================================================
-- 步骤 5: eICU 专属 Suspicion of Infection 构建
-- =================================================================
CREATE TABLE eicu_derived.suspicion_of_infection AS
WITH abx AS (
    SELECT patientunitstayid, treatmentoffset AS abx_offset
    FROM eicu_icu.treatment
    WHERE treatmentstring ILIKE '%antibacterial%' OR treatmentstring ILIKE '%antibiotic%' OR treatmentstring ILIKE '%anti-infective%'
),
cult AS (
    SELECT patientunitstayid, culturetakenoffset AS culture_offset
    FROM eicu_icu.microlab
),
soi_matches AS (
    SELECT a.patientunitstayid, a.abx_offset, c.culture_offset,
           CASE WHEN a.abx_offset <= c.culture_offset THEN a.abx_offset ELSE c.culture_offset END AS suspected_infection_time_offset
    FROM abx a JOIN cult c ON a.patientunitstayid = c.patientunitstayid
    WHERE (a.abx_offset >= c.culture_offset - 72 * 60) AND (a.abx_offset <= c.culture_offset + 24 * 60)  
)
SELECT patientunitstayid, MIN(suspected_infection_time_offset) AS suspected_infection_time_offset
FROM soi_matches GROUP BY patientunitstayid;

-- =================================================================
-- 步骤 6: Sepsis-3 Delta 提取
-- =================================================================
CREATE TABLE eicu_derived.sepsis3_sofa2_delta AS
WITH soi AS (SELECT patientunitstayid AS stay_id, suspected_infection_time_offset FROM eicu_derived.suspicion_of_infection)
SELECT s.stay_id, s.suspected_infection_time_offset, sofa.sofa2_total, (sofa.sofa2_total - MIN(sofa.sofa2_total) OVER(PARTITION BY s.stay_id)) as delta_sofa2 
FROM soi s JOIN eicu_derived.sofa2_scores sofa ON s.stay_id = sofa.stay_id WHERE sofa.hr BETWEEN -48 AND 24;