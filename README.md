# eICU v2.0 SOFA-2 Dynamic Scoring & Sepsis-3 Extraction

该项目提供了一套完整的 SQL 脚本，用于在 **eICU Collaborative Research Database (v2.0)** 中计算动态 SOFA-2 (Sequential Organ Failure Assessment) 评分，并根据最新的 Sepsis-3 标准提取脓毒症患者队列。

此脚本通过构建基于 ICU 入室时间的动态时间轴，实现了高时间分辨率的器官功能评估与感染判定。

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

## 核心特性 (Key Features)

* **高分辨率时序对齐**：基于 `icuintime` 零点偏移（Offset），建立严格的 `-24h` 至出院的每小时时序网格，杜绝未来数据穿越 (Data Leakage)。
* **24小时滑动窗口 (24h Sliding Window)**：严格遵循 SOFA 评分的“最差值”原则，动态计算过去 24 小时内各器官的极值。
* **eICU 专属逻辑补丁**：
* 构建 eICU 专属的 **“可疑感染期 (Suspicion of Infection, SOI)”** 代理变量（融合抗生素与血培养时间戳）。


* **AI / ML 友好**：内建基于 `patientunitstayid` 和 `subject_id` 物理哈希的 `fold_id` (0-9) 埋点，确保在交叉验证中同一患者的所有入室记录被严格隔离在同一折内。

---

## 环境依赖 (Prerequisites)

1. 已在本地或服务器部署完整的 [eICU-CRD v2.0](https://eicu-crd.mit.edu/) 数据库（PostgreSQL 环境）。
2. 已完成 eICU 官方的预处理概念表（需包含 `eicu_derived` 模式下的基础透视表，如 `pivoted_gcs`, `pivoted_bg`, `pivoted_lab`, `pivoted_vital` 等）。
3. 数据库需预留至少 5GB 的空闲存储空间用于生成临时特征全量表。

---

## 架构与计算流程 (Pipeline Architecture)

本脚本 (`eicu_sepsis3_sofa2_extraction.sql`) 采用流水线式架构，分 8 个阶段自动执行：

* **Step 0: 环境清理** - 安全重置并删除旧版缓存表。
* **Step 1: 时序网格生成** - 构建 `icustay_hourly_basedon_icuintime` 小时级骨架。
* **Step 2: 独立器官特征提取 (Stage 1)** - 并行提取 6 大系统（神经、呼吸、凝血、肝脏、肾脏、心血管/尿量）及辅助支持（镇静、谵妄、RRT、ECMO、机械通气）的每小时数据。
* **Step 3: 原始评分计算** - 汇合生成 `sofa2_hourly_raw`。
* **Step 4: 动态级联评分** - 基于 24h 滑动窗口生成 `sofa2_scores`（附带 ML `fold_id`）。
* **Step 5 & 6: 截面与过滤** - 生成入室首日评分表 `first_day_sofa2`。
* **Step 7: SOI 锚定** - 根据抗生素与微生物培养时间差提取可疑感染时间轴 `suspicion_of_infection`。
* **Step 8: Sepsis-3 最终判定** - 计算 SOI 前后（-48h 到 +24h）的急性器官衰竭激增 `sepsis3_sofa2_delta`。

---

## 核心输出数据字典 (Output Tables)

成功运行脚本后，您的 `eicu_derived` 模式下将生成以下供直接查询/导出的核心表：

| 表名 (Table Name) | 颗粒度 | 描述 (Description) |
| --- | --- | --- |
| `sofa2_scores` | 每患者每小时 | 包含 6 大系统详细评分、总分及哈希 `fold_id`。是时序深度学习模型（如 RNN/Transformer）的最佳输入。 |
| `first_day_sofa2` | 每患者每次入室 | 患者进入 ICU 前 24 小时内的最高 SOFA 总分，适用于常规横断面统计与基线特征对比。 |
| `suspicion_of_infection` | 每患者每次入室 | Sepsis 判定的核心时间锚点（抗生素与血培养联合判定）。 |
| `sepsis3_sofa2_delta` | 每患者每小时 | 仅包含发生可疑感染窗口期（-48h ~ +24h）的数据，直接提供 `delta_sofa2` 字段用于 Sepsis-3 （ΔSOFA ≥ 2）阳性标签的极速筛选。 |

---

## 使用指南 (Usage)

1. 下载本仓库中的 SQL 脚本：
```bash
git clone https://github.com/YourUsername/eICU-Sepsis3-Pipeline.git

```


2. 使用 `psql` 或您的数据库客户端（如 DBeaver, DataGrip）连接至 eICU 数据库。
3. 确保当前拥有对 `eicu_derived` Schema 的建表与修改权限。
4. 执行全量脚本（视硬件性能，通常耗时 5-15 分钟）：
```bash
psql -U your_username -d eicu -f eicu_sepsis3_sofa2_extraction.sql

```
