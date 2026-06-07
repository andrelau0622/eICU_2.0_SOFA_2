# eICU v2.0 SOFA-2 Dynamic Scoring & Sepsis-3 Extraction

该项目提供了一套完整的 SQL 脚本，用于在 **eICU Collaborative Research Database (v2.0)** 中计算动态 SOFA-2 (Sequential Organ Failure Assessment) 评分，并根据最新的 Sepsis-3 标准提取脓毒症患者队列。

此脚本通过构建基于 ICU 入室时间的动态时间轴，实现了高时间分辨率的器官功能评估与感染判定。

## 主要功能

* **高精度时间网格构建**：以患者入室为零点，构建从入室前 24 小时（-24h）到出室的逐小时观察窗口。
* **多系统动态评分**：提取并清洗神经、呼吸、心血管、肝脏、肾脏及凝血系统的临床数据。
* **24 小时滚动窗口评估**：基于过去 24 小时的最差临床表现动态计算各系统 SOFA 得分。
* **Sepsis-3 队列识别**：通过联合分析抗生素使用与微生物培养记录，精准定位感染疑似时间 (Suspicion of Infection, SOI)，并计算核心诊断指标 Delta SOFA。

---

## 环境与依赖要求

* **数据库系统**：PostgreSQL (建议配置充足的 `work_mem`，脚本默认设置为 `2047MB`)。
* **底层数据**：已完整导入的 eICU v2.0 数据库，主要依赖 `eicu_icu` 模式 (Schema)。
* **预处理数据**：依赖部分 `eicu_derived` 模式中的透视表（如 `pivoted_gcs`, `pivoted_bg`, `pivoted_uo`, `pivoted_infusion`, `pivoted_lab` 等）。在运行本脚本前，请确保这些前置派生表已生成。

---

## 执行流程说明

本脚本的执行逻辑分为以下 7 个核心步骤：

* **步骤 0：环境清理** - 级联删除 (`CASCADE`) 旧有表结构，防止数据冲突。
* **步骤 1：时间轴网格构建** - 生成基础表 `icustay_hourly_basedon_icuintime`，确立每位患者在 ICU 期间的逐小时时间切片。
* **步骤 2：组件表提取 (Stage 1)** - 并行提取镇静、脑功能 (GCS)、机械通气/ECMO、氧合指数 (P/F ratio) 及尿量等独立子表。
* **步骤 3：每小时原始评分计算** - 汇总 Stage 1 数据，计算特定小时内各器官系统的绝对 SOFA 原始得分。
* **步骤 4：核心结果生成** - 利用窗口函数，取前 24 小时内的最差值作为当前最终得分，计算总分，并生成入室首日 SOFA 评分表 (`first_day_sofa2`)。还包含用于机器学习交叉验证的 `fold_id` 划分。
* **步骤 5：感染疑似时间 (SOI) 提取** - 筛选在微生物培养前 72 小时至培养后 24 小时内接受抗生素治疗的记录，确定最早的感染时间点。
* **步骤 6：Sepsis-3 诊断标准计算** - 基于 SOI 及动态 SOFA 评分，计算特征时间窗（-48h 至 +24h）内的 SOFA 评分基线及变异值 (`delta_sofa2`)。

---

## 核心输出表

运行完毕后，您可以在 `eicu_derived` 模式下获取以下核心结果表供后续分析或建模使用：

* **`sofa2_scores`**：包含时间轴延伸至入室前 24 小时的完整逐小时 SOFA 评分详情与总分。
* **`sofa2_scores_hr_filtered`**：过滤掉入室前数据，仅保留 ICU 期间（hr >= 0）的动态 SOFA 评分。
* **`first_day_sofa2`**：每位患者入室首日（0-23 小时）的最高 SOFA 总分汇总。
* **`suspicion_of_infection`**：每位患者基于 eICU 数据的精确感染疑似时间 (SOI) 偏移量。
* **`sepsis3_sofa2_delta`**：用于 Sepsis-3 诊断判定的关键表，包含感染相关的最大 SOFA 恶化值 (`delta_sofa2`)。

---

## 使用指南

您可以使用 `psql` 命令行工具或任何支持 PostgreSQL 的数据库可视化工具（如 DBeaver, DataGrip）直接执行该脚本：

```bash
psql -U your_username -d eicu_database -f sofa2_sepsis3_extraction.sql

```

> **注意事项：**
> 在 **步骤 2** 中，部分系统（凝血、肝脏、肾脏检验指标、谵妄等）使用了占位符形式创建了空表（`WHERE 1=0`）。这是为了保持文件和数据管道的结构完整性。实际的检验指标评估已在 **步骤 3** (`sofa2_hourly_raw`) 中直接通过联表 `pivoted_lab` 进行了处理。如果您需要深入研究这些独立子系统，可以后续自行扩展占位表逻辑。
