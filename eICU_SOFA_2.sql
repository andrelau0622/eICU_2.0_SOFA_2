-- =================================================================
-- eICU v2.0 SOFA-2 动态评分及 Sepsis-3 提取全量终极脚本 (研究级规范)
-- =================================================================
SET work_mem = '2047MB';

-- =================================================================
-- 步骤 0: 环境彻底清理 (包含全量 14 个目标表 + SOI 补丁表)
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
DROP TABLE Michaelmas_derived.sofa2_stage1_liver CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_hourly_raw CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_scores CASCADE;
DROP TABLE IF EXISTS eicu_derived.sofa2_scores_hr_filtered CASCADE;
DROP TABLE IF EXISTS eicu_derived.first_day_sofa2 CASCADE;
DROP TABLE IF EXISTS eicu_derived.suspicion_of_infection CASCADE;
DROP TABLE IF EXISTS eicu_derived.sepsis3_sofa2_delta CASCADE;
DROP TABLE IF EXISTS eicu_derived.icustay_hourly_basedon_icuintime CASCADE;

-- =================================================================
-- 步骤 1: 创建基于 ICU 入院偏移 (Offset) 的时序基本网格表
-- =================================================================
CREATE TABLE eicu_derived.icustay_hourly_basedon_icuintime AS
WITH all_hours AS (
  SELECT patientunitstayid, COALESCE(unitdischargeoffset, 7 * 24 * 60) AS end_offset,
    ARRAY(SELECT * FROM GENERATE_SERIES(-24, CAST(CEIL(COALESCE(unitdischargeoffset, 7 * 24 * 60) / 60.0) AS INT))) AS hrs
  FROM eicu_icu.patient
)
SELECT patientunitstayid, CAST(hr_unnested AS BIGINT) AS hr, CAST(hr_unnested AS BIGINT) * 60 AS startoffset, (CAST(hr_unnested AS BIGINT) + 1) * 60 AS endoffset
FROM all_hours CROSS JOIN UNNEST(all_hours.hrs) AS _t0(hr_unnested);

CREATE INDEX idx_eicu_h_stay_hr ON eicu_derived.icustay_hourly_basedon_icuintime(patientunitstayid, hr);

-- =================================================================
-- 步骤 2: Stage 1 基础架构层 —— 构建全量中间计算特征变量表
-- =================================================================

-- 2.1 神经系统评分 (GCS & 运动评分校准，解决 gcsmotor 命名)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_brain AS
WITH gcs_base AS (
    SELECT g.patientunitstayid, g.chartoffset, 
        COALESCE(CASE WHEN g.gcs <= 5 THEN 4 WHEN g.gcs <= 8 THEN 3 WHEN g.gcs <= 12 THEN 2 WHEN g.gcs <= 14 THEN 1 WHEN g.gcs = 15 THEN 0 ELSE NULL END, 
                 CASE WHEN g.gcsmotor <= 2 THEN 4 WHEN g.gcsmotor = 3 THEN 3 WHEN g.gcsmotor = 4 THEN 2 WHEN g.gcsmotor = 5 THEN 1 WHEN g.gcsmotor = 6 THEN 0 ELSE NULL END) AS brain_score_raw 
    FROM eicu_derived.pivoted_gcs g
),
gcs_grouping AS (
    SELECT patientunitstayid, chartoffset, brain_score_raw, COUNT(brain_score_raw) OVER (PARTITION BY patientunitstayid ORDER BY chartoffset) as grp FROM gcs_base
)
SELECT patientunitstayid, chartoffset AS startoffset, LEAD(chartoffset, 1, 9999999) OVER (PARTITION BY patientunitstayid ORDER BY chartoffset) AS endoffset, COALESCE(FIRST_VALUE(brain_score_raw) OVER (PARTITION BY patientunitstayid, grp ORDER BY chartoffset), 0) AS brain_score_final FROM gcs_grouping;
CREATE INDEX idx_stg1_brain_stay ON eicu_derived.sofa2_stage1_brain(patientunitstayid, startoffset, endoffset);

-- 2.2 氧合特征表 (计算 PaO2/FiO2 比例)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_oxygen AS
SELECT ih.patientunitstayid, ih.hr, ((ARRAY_AGG(bg.pao2 ORDER BY bg.chartoffset DESC))[1] / NULLIF(COALESCE((ARRAY_AGG(bg.fio2 ORDER BY bg.chartoffset DESC))[1], 21), 0) * 100) AS pf_ratio
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_derived.pivoted_bg bg ON ih.patientunitstayid = bg.patientunitstayid AND bg.chartoffset > ih.startoffset AND bg.chartoffset <= ih.endoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_oxygen_stay ON eicu_derived.sofa2_stage1_oxygen(patientunitstayid, hr);

-- 2.3 动态体重校准尿量率表
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_urine AS
SELECT g.patientunitstayid, g.hr, SUM(uo.urineoutput) OVER w24 AS uo_sum_24h, CASE WHEN g.hr >= 24 THEN SUM(uo.urineoutput) OVER w24 / COALESCE(NULLIF(p.admissionweight, 0), 70.0) / 24 END AS rate_24h
FROM eicu_derived.icustay_hourly_basedon_icuintime g LEFT JOIN eicu_derived.pivoted_uo uo ON g.patientunitstayid = uo.patientunitstayid AND uo.chartoffset > g.startoffset AND uo.chartoffset <= g.endoffset JOIN eicu_icu.patient p ON g.patientunitstayid = p.patientunitstayid WINDOW w24 AS (PARTITION BY g.patientunitstayid ORDER BY g.hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);
CREATE INDEX idx_stg1_urine_stay ON eicu_derived.sofa2_stage1_urine(patientunitstayid, hr);

-- 2.4 凝血特征表 (对齐真实列名: platelets)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_coag AS
SELECT ih.patientunitstayid, ih.hr, MIN(lab.platelets) AS platelet_min 
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_derived.pivoted_lab lab ON ih.patientunitstayid = lab.patientunitstayid AND lab.chartoffset > ih.startoffset AND lab.chartoffset <= ih.endoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_coag_stay ON eicu_derived.sofa2_stage1_coag(patientunitstayid, hr);

-- 2.5 肝脏特征表 (对齐真实列名: bilirubin)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_liver AS
SELECT ih.patientunitstayid, ih.hr, MAX(lab.bilirubin) AS bilirubin_max 
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_derived.pivoted_lab lab ON ih.patientunitstayid = lab.patientunitstayid AND lab.chartoffset > ih.startoffset AND lab.chartoffset <= ih.endoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_liver_stay ON eicu_derived.sofa2_stage1_liver(patientunitstayid, hr);

-- 2.6 肾脏实验室特征表 (对齐真实列名: creatinine)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_kidney_labs AS
SELECT ih.patientunitstayid, ih.hr, MAX(lab.creatinine) AS creatinine_max 
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_derived.pivoted_lab lab ON ih.patientunitstayid = lab.patientunitstayid AND lab.chartoffset > ih.startoffset AND lab.chartoffset <= ih.endoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_klabs_stay ON eicu_derived.sofa2_stage1_kidney_labs(patientunitstayid, hr);

-- 2.7 镇静药物事件表
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_sedation AS
SELECT patientunitstayid, infusionoffset AS startoffset, infusionoffset + 60 AS endoffset
FROM eicu_icu.infusiondrug WHERE (drugname ILIKE '%propofol%' OR drugname ILIKE '%midazolam%' OR drugname ILIKE '%dexmedetomidine%' OR drugname ILIKE '%fentanyl%') AND drugrate <> '';
CREATE INDEX idx_stg1_sedation_stay ON eicu_derived.sofa2_stage1_sedation(patientunitstayid, startoffset, endoffset);

-- 2.8 谵妄药物事件表
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_delirium AS
WITH meds AS (
    SELECT patientunitstayid, drugstartoffset, drugstopoffset FROM eicu_icu.medication
    WHERE drugname ILIKE '%haloperidol%' OR drugname ILIKE '%quetiapine%' OR drugname ILIKE '%olanzapine%' OR drugname ILIKE '%risperidone%'
)
SELECT ih.patientunitstayid, ih.hr, MAX(CASE WHEN m.patientunitstayid IS NOT NULL THEN 1 ELSE 0 END) AS on_delirium_med
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN meds m ON ih.patientunitstayid = m.patientunitstayid AND m.drugstartoffset <= ih.endoffset AND COALESCE(m.drugstopoffset, m.drugstartoffset + 24*60) >= ih.startoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_delirium_stay ON eicu_derived.sofa2_stage1_delirium(patientunitstayid, hr);

-- 2.9 呼吸支持事件表 (加强版双源融合)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_resp_support AS
WITH resp_events AS (
    SELECT patientunitstayid, treatmentoffset AS event_offset FROM eicu_icu.treatment
    WHERE treatmentstring ILIKE '%mechanical ventilation%' OR treatmentstring ILIKE '%non-invasive ventilation%' OR treatmentstring ILIKE '%CPAP%' OR treatmentstring ILIKE '%BiPAP%' OR treatmentstring ILIKE '%intubation%' OR treatmentstring ILIKE '%ventilation%'
    UNION ALL
    SELECT patientunitstayid, respcarestatusoffset AS event_offset FROM eicu_icu.respiratorycare
)
SELECT ih.patientunitstayid, ih.hr, MAX(CASE WHEN r.patientunitstayid IS NOT NULL THEN 1 ELSE 0 END) AS with_resp_support
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN resp_events r ON ih.patientunitstayid = r.patientunitstayid AND r.event_offset <= ih.endoffset AND r.event_offset >= ih.startoffset - 24*60 WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_respsup_stay ON eicu_derived.sofa2_stage1_resp_support(patientunitstayid, hr);

-- 2.10 肾脏替代治疗事件表 (RRT)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_rrt AS
WITH rrt_treat AS (
    SELECT patientunitstayid, treatmentoffset FROM eicu_icu.treatment WHERE treatmentstring ILIKE '%dialysis%' OR treatmentstring ILIKE '%CRRT%'
)
SELECT ih.patientunitstayid, ih.hr, MAX(CASE WHEN t.patientunitstayid IS NOT NULL THEN 1 ELSE 0 END) AS on_rrt
FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN rrt_treat t ON ih.patientunitstayid = t.patientunitstayid AND t.treatmentoffset >= ih.startoffset AND t.treatmentoffset <= ih.endoffset WHERE ih.hr >= -24 GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_rrt_stay ON eicu_derived.sofa2_stage1_rrt(patientunitstayid, hr);

-- 2.11 生命支持机械事件表 (ECMO)
CREATE UNLOGGED TABLE eicu_derived.sofa2_stage1_mech AS
SELECT ih.patientunitstayid, ih.hr, MAX(CASE WHEN t.treatmentstring ILIKE '%ECMO%' THEN 1 ELSE 0 END) AS is_ecmo FROM eicu_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN eicu_icu.treatment t ON ih.patientunitstayid = t.patientunitstayid WHERE t.treatmentoffset >= ih.startoffset AND t.treatmentoffset <= ih.endoffset GROUP BY ih.patientunitstayid, ih.hr;
CREATE INDEX idx_stg1_mech_stay ON eicu_derived.sofa2_stage1_mech(patientunitstayid, hr);


-- =================================================================
-- 步骤 3: 每小时原始评分计算表 (聚合级联优化，消除死锁)
-- =================================================================
CREATE TABLE eicu_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.patientunitstayid, p.uniquepid as subject_id, p.patienthealthsystemstayid as hadm_id, hr, ih.startoffset, ih.endoffset 
    FROM eicu_derived.icustay_hourly_basedon_icuintime ih INNER JOIN eicu_icu.patient p ON ih.patientunitstayid = p.patientunitstayid
),
cv_drugs AS (
    SELECT co.patientunitstayid, co.hr, MAX(inf.norepinephrine) as rate_nor, MIN(v.ibp_mean) as mbp_min
    FROM co LEFT JOIN eicu_derived.pivoted_infusion inf ON co.patientunitstayid = inf.patientunitstayid AND inf.chartoffset >= co.startoffset AND inf.chartoffset <= co.endoffset
    LEFT JOIN eicu_derived.pivoted_vital v ON co.patientunitstayid = v.patientunitstayid AND v.chartoffset > co.startoffset AND v.chartoffset <= co.endoffset GROUP BY co.patientunitstayid, co.hr
)
SELECT co.patientunitstayid AS stay_id, co.hadm_id, co.subject_id, co.hr,
    COALESCE(br.brain_score_final, 0) AS brain_score,
    CASE WHEN ox.pf_ratio <= 100 THEN 4 WHEN ox.pf_ratio <= 200 THEN 3 WHEN ox.pf_ratio <= 300 THEN 2 WHEN ox.pf_ratio <= 400 THEN 1 ELSE 0 END AS respiratory_score,
    CASE WHEN COALESCE(cv.rate_nor, 0) > 0.1 THEN 4 WHEN COALESCE(cv.rate_nor, 0) > 0 THEN 3 WHEN COALESCE(cv.mbp_min, 70) < 70 THEN 1 ELSE 0 END AS cardiovascular_score,
    CASE WHEN liv.bilirubin_max > 12.0 THEN 4 WHEN liv.bilirubin_max > 6.0 THEN 3 WHEN liv.bilirubin_max > 2.0 THEN 2 WHEN liv.bilirubin_max > 1.2 THEN 1 ELSE 0 END AS liver_score,
    CASE WHEN rrt.on_rrt = 1 THEN 4 WHEN kl.creatinine_max > 3.5 OR ur.rate_24h < 0.2 THEN 3 WHEN kl.creatinine_max > 2.0 THEN 2 WHEN kl.creatinine_max > 1.2 THEN 1 ELSE 0 END AS kidney_score,
    CASE WHEN cg.platelet_min < 20 THEN 4 WHEN cg.platelet_min < 50 THEN 3 WHEN cg.platelet_min < 100 THEN 2 WHEN cg.platelet_min < 150 THEN 1 ELSE 0 END AS hemostasis_score
FROM co 
LEFT JOIN eicu_derived.sofa2_stage1_brain br ON co.patientunitstayid = br.patientunitstayid AND co.endoffset > br.startoffset AND co.endoffset <= br.endoffset
LEFT JOIN eicu_derived.sofa2_stage1_oxygen ox ON co.patientunitstayid = ox.patientunitstayid AND co.hr = ox.hr
LEFT JOIN cv_drugs cv ON co.patientunitstayid = cv.patientunitstayid AND co.hr = cv.hr
LEFT JOIN eicu_derived.sofa2_stage1_liver liv ON co.patientunitstayid = liv.patientunitstayid AND co.hr = liv.hr
LEFT JOIN eicu_derived.sofa2_stage1_kidney_labs kl ON co.patientunitstayid = kl.patientunitstayid AND co.hr = kl.hr
LEFT JOIN eicu_derived.sofa2_stage1_urine ur ON co.patientunitstayid = ur.patientunitstayid AND co.hr = ur.hr
LEFT JOIN eicu_derived.sofa2_stage1_rrt rrt ON co.patientunitstayid = rrt.patientunitstayid AND co.hr = rrt.hr
LEFT JOIN eicu_derived.sofa2_stage1_coag cg ON co.patientunitstayid = cg.patientunitstayid AND co.hr = cg.hr;

CREATE INDEX idx_sofa2_raw_calc ON eicu_derived.sofa2_hourly_raw(stay_id, hr);

-- =================================================================
-- 步骤 4: 核心结果层构建 —— 24h 滑动窗口总表 (含哈希平衡 fold_id 埋点)
-- =================================================================
CREATE TABLE eicu_derived.sofa2_scores AS
SELECT *, 
       (brain_score + respiratory_score + cardiovascular_score + liver_score + kidney_score + hemostasis_score) AS sofa2_total, 
       (ABS(hashtext(subject_id)) % 10) AS fold_id
FROM (
    SELECT stay_id, hadm_id, subject_id, hr,
           MAX(brain_score) OVER w AS brain_score, 
           MAX(respiratory_score) OVER w AS respiratory_score, 
           MAX(cardiovascular_score) OVER w AS cardiovascular_score, 
           MAX(liver_score) OVER w AS liver_score, 
           MAX(kidney_score) OVER w AS kidney_score, 
           MAX(hemostasis_score) OVER w AS hemostasis_score 
    FROM eicu_derived.sofa2_hourly_raw 
    WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING)
) x;

CREATE INDEX idx_sofa2_scores_stay ON eicu_derived.sofa2_scores(stay_id);

-- =================================================================
-- 步骤 5: 时间轴过滤表 (过滤物理入 ICU 前的负数时间)
-- =================================================================
CREATE TABLE eicu_derived.sofa2_scores_hr_filtered AS 
SELECT * FROM eicu_derived.sofa2_scores WHERE hr >= 0;

CREATE INDEX idx_sofa2_scores_filtered_hr ON eicu_derived.sofa2_scores_hr_filtered(stay_id, hr);

-- =================================================================
-- 步骤 6: 入 ICU 首日截面评分表 (first_day_sofa2)
-- =================================================================
CREATE TABLE eicu_derived.first_day_sofa2 AS
SELECT stay_id, subject_id, hadm_id, MAX(sofa2_total) AS sofa2_total 
FROM eicu_derived.sofa2_scores_hr_filtered WHERE hr BETWEEN 0 AND 23 GROUP BY stay_id, subject_id, hadm_id;

CREATE INDEX idx_first_day_sofa2_stay ON eicu_derived.first_day_sofa2(stay_id);

-- =================================================================
-- 步骤 7: eICU 专属可疑感染发生期 (Suspicion of Infection) 补丁表
-- =================================================================
CREATE TABLE eicu_derived.suspicion_of_infection AS
WITH abx AS (
    SELECT patientunitstayid, treatmentoffset AS abx_offset FROM eicu_icu.treatment
    WHERE treatmentstring ILIKE '%antibacterial%' OR treatmentstring ILIKE '%antibiotic%' OR treatmentstring ILIKE '%anti-infective%'
),
cult AS (
    SELECT patientunitstayid, culturetakenoffset AS culture_offset FROM eicu_icu.microlab
),
soi_matches AS (
    SELECT a.patientunitstayid, a.abx_offset, c.culture_offset,
           CASE WHEN a.abx_offset <= c.culture_offset THEN a.abx_offset ELSE c.culture_offset END AS suspected_infection_time_offset
    FROM abx a JOIN cult c ON a.patientunitstayid = c.patientunitstayid
    WHERE (a.abx_offset >= c.culture_offset - 72 * 60) AND (a.abx_offset <= c.culture_offset + 24 * 60)  
)
SELECT patientunitstayid, MIN(suspected_infection_time_offset) AS suspected_infection_time_offset
FROM soi_matches GROUP BY patientunitstayid;

CREATE INDEX idx_soi_stay ON eicu_derived.suspicion_of_infection(patientunitstayid);

-- =================================================================
-- 步骤 8: 终极队列提取 —— 动态 Sepsis-3 器官衰竭急性激增 Delta 表
-- =================================================================
CREATE TABLE eicu_derived.sepsis3_sofa2_delta AS
WITH soi AS (
    SELECT patientunitstayid AS stay_id, suspected_infection_time_offset FROM eicu_derived.suspicion_of_infection
)
SELECT s.stay_id, s.suspected_infection_time_offset, sofa.hr, sofa.sofa2_total, 
       (sofa.sofa2_total - MIN(sofa.sofa2_total) OVER(PARTITION BY s.stay_id)) as delta_sofa2 
FROM soi s JOIN eicu_derived.sofa2_scores sofa ON s.stay_id = sofa.stay_id 
WHERE sofa.hr BETWEEN CAST(s.suspected_infection_time_offset / 60 AS INT) - 48 
                  AND CAST(s.suspected_infection_time_offset / 60 AS INT) + 24;

CREATE INDEX idx_sepsis3_delta_stay ON eicu_derived.sepsis3_sofa2_delta(stay_id);
