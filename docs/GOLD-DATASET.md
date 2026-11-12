# Forma 独立金标准数据集规范（GOLD-DATASET）

**日期：** 2026-11-12　**阶段：** P3-A（离线评测基础设施，Owner 2026-11-12 授权）
**基线：** [SPEC v0.1.1 FROZEN](SPEC.md) §5/§6.2/§10.1.4/§10.1.6–7 · [PLAN v0.1](PLAN.md) §8 · [ROADMAP 授权历史](ROADMAP.md) · [P2 验收报告](P2-ACCEPTANCE.md) §4/§5/§7
**性质：** 本文是**流程规范**，供实际执行者与独立复核者照做并审计。**它不声明任何样本已经采集、任何审核已经完成、任何指标已经测量。**
**授权状态：** P3-B（真实模型评测）未授权；其四项外部前置条件（Provider 凭据与批准模型/外发范围与预算、隔离测试库 UUID 与只读范围、Owner 授权的真实扫描目录、≥150 条经独立核实与脱敏的金标准样本）当前均未满足。P2 §5/§7 记录真实目录扫描、真实模型调用、脱敏判别力前后对照三项仍为 `BLOCKED`。因此本文描述的采集与审核流程**在 P3-A 期间只能以合成样本和确定性替身演练**，演练结果不得说成真实评测结果。

凡本文超出 PLAN/SPEC 既有要求之处，句末标注 **（本文件新增约定）**。指标公式一律不在此重复，见 PLAN §8.2 与 SPEC §10.1.7。
本文 §4、§9、§10 的字段名、枚举值与目录布局与 P3-A 评测基础设施的现有约定（`GoldRecord`/`GoldSplit`/`GoldDataset` 及 `gold-record-1.0`/`gold-split-1.0` Schema）保持一致，以便规范可被直接执行；这些类型由另一名工程师实现，**本文不修改它们**，若代码先行变更，以代码为准并同步更新本文（§10.5）。

---

## 1. 目的与范围

### 1.1 本文要解决的问题

Forma 的映射质量结论只有在**与提示示例完全隔离、由人工依据可核验证据建立、并固定版本**的金标准上测量才成立。SPEC §6.2 已禁止"测试题已经出现在参考答案里"，SPEC §10.1.6 要求 ≥150 条独立样本，PLAN §8.1 给出抽样、脱敏、隔离与审核的总要求。本文把这些要求展开成可执行、可审计的操作规则：来源池、抽样单位、分层配额、脱敏替换表、gold 记录必填内容、泄漏排除判据与登记格式、复核通过条件、版本冻结与复现要素、缺口台账、本地目录与文件命名。

### 1.2 P3-A 做什么

- 制定并冻结本规范；定义 gold 记录与 split manifest 的内容结构与本地布局（§4、§5、§9）。
- 用**完全合成或已脱敏**的记录演练：抽样 → 标注 → 独立复核 → 独立性排除 → 分层计数 → 缺口报告全链路（ROADMAP P3-A 授权允许合成数据与确定性替身）。
- 为评测基础设施给出数据侧约定：加载、校验、排除、计数、报告的职责边界（§10）。
- 输出"当前有多少合格样本、每个分层缺多少"的台账，供 Owner 判断 P3-B 是否具备启动条件。

### 1.3 P3-A 不做什么

- 不做真实模型质量评测，不产出 precision/coverage/field_precision 的实际数值结论（属 P3-B；ROADMAP 记 P3-B 未授权）。
- 不采集、不提交任何真实业务资料；不承诺已存在 ≥150 条合格样本。
- 不逐条重新审计历史 991 条生产记录，也不把 SPEC §6.2 引用的 78/664/143/56/50 当成 gold——PLAN §8.1 已明确那只是来源证据等级分布。
- 不复用 CasePack `forma-governance-cases@1.0` 的 24 条（positive 12 / negative 8 / conflict 2 / refusal 2，见 P2 §4）作为评测样本，也不反向把评测样本塞进提示包。
- 不定义质量阈值。阈值是 PLAN §8.2 提交 Owner 集中复核的建议值，本文只引用、不批准。

### 1.4 与 PLAN §8 的关系

| 关注点 | 权威位置 | 本文位置 |
|---|---|---|
| 指标定义与公式、区间与 bootstrap | PLAN §8.2 / SPEC §10.1.7 | 只引用（§8.3、§10.4），不重述 |
| 样本量、分层目标、排除量报告 | SPEC §10.1.6 / PLAN §8.1 | §2.3、§8 展开为配额表与台账 |
| 隔离与近重复排除 | PLAN §8.1 / SPEC §10.1.6 | §5 给出判据、登记格式与失败处置 |
| 脱敏与判别力对照 | PLAN §8.3 / SPEC §10.1.10 | §3 给出替换表、检查步骤、不合格判据 |
| 纠正进入案例/评测集 | PLAN §8.4 / SPEC §6.2 | §4.4、§7.4 规定审核链与变更规则 |
| 阈值批准与质量 Gate | PLAN §8.2 / ROADMAP 授权历史 | §8.4 规定何时**不得**宣称通过 |
| Evidence 字段与定位口径 | PLAN §7.2 / SPEC §6.3 | §4.1 `citations` 沿用同一口径 |

---

## 2. 采样

### 2.1 来源池

只有下列五类可成为 gold 候选，每条候选必须记录其来源池标识（本地候选台账字段 `source_pool`，不在 gold 记录 Schema 内 **（本文件新增约定）**）：

| 池 | 内容 | 可用状态与约束 |
|---|---|---|
| P1 授权真实目录 | Owner 指定的本地/OneDrive 扫描根目录及其文件 | **当前不具备**：P2 §7 记录缺授权目录输入。取得后须记录 `source_root_id`、目录清单快照日期与授权依据 |
| P2 隔离 DEVONthink 库（只读） | 用户事先准备的隔离测试库中的记录与按需正文 | **当前不具备**：缺确认的库 UUID 与只读范围。查询范围与白名单遵守 PLAN §9.2；生产 Project_Archive 的 991 条不可修改，也不是可丢弃测试材料 |
| P3 历史治理材料 | `tmp` 固定提交内的分类规则、质量报告、991 条样本库、71 条纠正账本 | 只作**候选线索**：PLAN §8.1 要求先一次性核对结构/数量/质量字段再抽选，不重复审计全量；仅凭历史标签不能成为 gold（SPEC §6.2） |
| P4 纠正候选 | Forma Correction Capture 产生的 `candidate_example` | 须经独立审核、可追溯证据与脱敏检查后方可入 gold（PLAN §8.4）；自动输出、模型自我反思、未审核的人工点击不成为 gold |
| P5 合成池 | §9.4 那种完全合成记录 | **P3-A 演练与基础设施自测专用**；必须逐条 `review.redaction = synthetic`，在报告中与真实脱敏样本分列，永不用于宣称"≥150 条真实金标准"（PLAN §8.2 合成压力数据单列） |

### 2.2 抽样单位：簇，而不是文件

抽样、定侧与排除一律以**簇（cluster）**为单位，对应 gold 记录的 `source.project_cluster_key`。簇定义沿用候选簇语义——按目录邻近性、命名实体、时间和文件簇构建候选，无法确定边界时可存在多个候选，且**不以固定第 N 层目录作为项目**（PLAN §6.1 第 1 条；P2 §2 记录 ContextBuilder 不假定目录深度）——并在此固定为五条 **（本文件新增约定：把 PLAN §8.1 的"项目/来源簇"落到可执行边界）**：

1. 同一项目目录树及其全部子目录内的文件属同一簇；
2. 同一 DEVONthink 数据库/Group 子树内的记录属同一簇；
3. 同一文件的不同版本、重印件、改名副本属同一簇（与 §5.4 同源）；
4. 跨项目共享而内容相同的文件（同一 `sha256`）按 SPEC §5.2/§7 的关联语义视为同一来源簇，不得拆成两簇分落两侧。
5. 边界不确定、可归入多个候选簇时，**按保守原则合并成一簇整体定侧**：泄漏风险优先于样本多样性，宁可少一条评测样本，也不允许同一批相关材料的两个部分分别进入提示侧与评测侧（PLAN §8.1「无 SHA 时先隔离保守来源簇」的可执行形态）。

`project_cluster_key` 必须是 ASCII 键（Schema `ref` 模式 `[A-Za-z0-9_-]{1,64}`），**不得**是真实项目目录名——真实目录→键的映射表只存本地簇表 `clusters/clusters.jsonl`，永不提交（本文件新增约定）。

簇表先于抽选建立，字段：`cluster_key / 来源池 / 真实路径或库 UUID（本地） / 成员文件数 / 格式分布 / 是否含关键反例 / 抽取可用性状态`。

### 2.3 分层目标

| 分层轴 | 分层键 | 每键目标 | 由谁计数 | 依据 |
|---|---|---|---|---|
| Profile | `project-archive`、`vendor-library` | 分别统计与报告，互不替代 | 运行器 `perProfileCountable` | PLAN §8.1「两个 Profile 分别报告数量，Vendor 不能拿项目六分类的准确率替代」 |
| 场景类别 | `scenario.category`：`positive`/`negative`/`conflict`/`refusal`/`near_duplicate`/`template_family`/`partial_evidence`/`adversarial_wording` | 每 Profile 每类争取 ≥10 | 运行器 `perCategoryCountable` + `shortfalls` | PLAN §8.1「主要反例场景各争取 ≥10 条」；枚举取自 `gold-record-1.0` |
| 文档类别（项目侧六分类） | `01_招标文件`/`02_投标文件`/`03_厂商支持文件`/`04_技术资料与编制素材`/`05_报价与商务`/`99_待分类` | 各争取 ≥10 | **人工缺口台账（§8.2 表 B）**——运行器的 `shortfalls` 按场景类别而非 `expected.target_category` 计算，故本轴必须由数据集台账单独给出 **（本文件新增约定）** | SPEC §5.1、PLAN §8.1「六类各争取 ≥10 条」 |
| 文档类别（Vendor 侧） | `Datasheet`/`Specification Sheet`/`Whitepaper`/`Solution`/`Brochure`/`Deployment Guide`/`Product Manual`/`待分类` | 各争取 ≥10 | 人工缺口台账；类别清单取自 `vendor-library.v1.json` | PLAN §8.1 的 Profile 隔离要求 **（本文件新增约定：Vendor 按其自身 `categories` 逐类统计，不套用项目六分类）** |
| 关键反例场景 | `ce-pa-1..6`、`ce-vl-1..6`（§2.4） | 各争取 ≥10 | 人工缺口台账（键写在 `scenario.description` 开头，§2.4） | SPEC §10.1.4 |
| 决策形态 | `expected.state` ∈ `mapped`/`hold`/`unknown` | `hold`+`unknown` 合计争取 ≥30 | 人工缺口台账 | PLAN §7.3、P2 §4（conflict/refusal 进入 hold 判定链） |
| 证据可得性 | PDF/DOCX/XLSX 成功抽取各 ≥10；每格式 `unavailable`/`encrypted`/`corrupt`/`truncated`/`hydration_pending`/`changed_during_read` 失败样本各 ≥3 | 争取值 | 人工缺口台账 | PLAN §6.3、SPEC §6.1 第 4 条、V2 |

**计数口径（硬性）：**

- **≥150 指去重后的合格记录数**：同一文件无论命中多少个分层键，只在总量中计 1（PLAN §8.1「场景可交叉计数，不能将同一文件重复计入总量」）。分层目标之和大于 150 是正常的，因为一条记录可同时支撑"某场景类别"与"某文档类别"；但同一分层轴内的同一键不得用同一条记录重复抵消缺口。
- Vendor 侧与项目侧的分层达成数互不相通（上表第一行）。一条记录可同时列在 `profiles` 数组的两个值中，仅当它的期望在两个 Profile 下都成立且复核者逐条确认（例：`ce-vl-4`、`ce-pa-5` 的跨 Profile 归属对照）；默认只列一个，列两个必须在台账 `notes` 说明理由 **（本文件新增约定）**。
- 单一簇在同一分层轴内最多贡献 **3 条**计入"达标"的记录，其余标 `coverage_redundant`：仍计入总量与混淆矩阵，但不用于抵消其他簇的缺口 **（本文件新增约定：防止单个超大项目簇伪造覆盖面）**。
- 未通过复核、`adjudication_pending`、合成（`redaction = synthetic`）的记录不计入达标数；其数量必须分别单列（§8.2 表 A、PLAN §8.2「未审核 gold 单独报告」）。
- 建议下限：两个 Profile 合计合格真实脱敏记录 ≥150，其中 Vendor 侧 ≥40 **（本文件新增约定：`40` 为提交 Owner 批准的建议值，批准前只作内部缺口判定，不作验收结论）**。

### 2.4 反例场景键与 `scenario.category` 的对应

场景键取自两个 Profile 的 `counter_examples` 原文（各 6 条，与 P2 §4「两个 Profile 各内嵌 6 条 SPEC 反例规则」一致）。**键名是本文新增约定**；`scenario.category` 只能有一个值，故键与类别的对应固定如下，便于人工台账与运行器计数都能核对：

| 键 | 场景（期望判定） | 主 `scenario.category` | 来源 |
|---|---|---|---|
| `ce-pa-1` | 项目名含"采购"但正文为实际投标稿 → `02_投标文件` | `adversarial_wording` | SPEC §5.1/§10.1.4 |
| `ce-pa-2` | 已填品牌型号与满足/偏差的 `BID_CONTENTS` 技术对标表 → `02`，不因前缀归 `04` | `partial_evidence` | SPEC §10.1.4 |
| `ce-pa-3` | 招标方下发的空白报价模板（`01` 采购附件）vs 含实际单价/折扣/总价的独立报价（`05`） | `template_family` | SPEC §10.1.4 |
| `ce-pa-4` | 商务标/投标价格分册归 `02`，不因"商务"二字归 `05` | `negative` | SPEC §10.1.4 |
| `ce-pa-5` | 原厂项目授权/售后承诺（`03`）vs 操作性激活授权指南（`04`） | `negative` | SPEC §10.1.4 |
| `ce-pa-6` | 通用 Datasheet vs 客户专用投标方案；`TENDER_`/`BID_`/目录名/扩展名只是线索，与正文冲突时按证据判定或 hold | `conflict` | SPEC §5.1/§10.1.4 |
| `ce-vl-1` | 通用厂商资料允许 `projectname = null`，不得虚构项目 | `refusal` | `vendor-library.v1.json` |
| `ce-vl-2` | 同一厂商材料服务多个项目时，在 Vendor Library 仍是无项目归属的一条记录 | `refusal` | 同上 |
| `ce-vl-3` | 品牌名 ≠ 法律出具主体；无署名/签章证据时 `issuer` 留空 | `refusal` | 同上 |
| `ce-vl-4` | 原厂项目授权函属项目侧 `03`；产品授权/激活操作指南属厂商资料 | `negative` | 同上 |
| `ce-vl-5` | Vendor 材料不强行映射到 `04`；跨 Profile 引用须遵守目的库语义 | `negative` | 同上 |
| `ce-vl-6` | 归档完成年 ≠ 产品发布年；Vendor Library 不要求 `completionyear`，也不得从版本年推断 | `partial_evidence` | 同上 |
| （补充轴） | 模板近重复家族（同一模板换项目/换名批量出现） | `near_duplicate` | PLAN §8.1 近重复要求 |

登记规则：`scenario.description` 必须以命中的键开头，形如 `ce-pa-3: 空白报价模板与已填报价的归属区分（合成示例）`，随后为 8–200 字的场景说明（Schema 强制 8–200 字符）。多个键同时命中时，主键写在最前，其余键以逗号列在其后 **（本文件新增约定：键不入 Schema，只能以描述前缀形式审计）**。

### 2.5 抽选程序与候选排除码

1. 固定授权范围：记录 `source_root_id`/库 UUID、目录清单快照日期、授权依据（PLAN §8.1「使用获准的真实目录清单」）。
2. 建立簇表（§2.2），一次性核对历史材料的结构/数量/质量字段（PLAN §8.1），不重复审计全量。
3. 按 §2.3 配额优先补齐**未达标分层**，再补正例密度；同簇内优先选取正文可核验、格式在 PDF/DOCX/XLSX 内的文件（SPEC §6.1 第 4 条）。
4. 每个未进入 gold 的候选在本地候选台账记一条原因码，取值固定为：`unreadable`、`ocr_not_supported`、`format_out_of_scope`、`permission_denied`、`no_verifiable_evidence`、`historical_label_only`、`insufficient_authorization`、`sha_pending`、`coverage_redundant`、`cluster_cross_side`、`deferred`。这套码只用于抽选台账，**与 §5 的 `removed_records.reason` 是两套**（后者是 Schema 枚举，不得自造值）**（本文件新增约定：区分"没抽进来"与"抽进来后因泄漏被移出"）**。
5. 抽选结果与被排除清单一并冻结（§7.2）；冻结后不得因评测结果不利而回头改抽选。

---

## 3. 脱敏

### 3.1 通则

真实文件与 gold 本体只保留在受限本地目录，公开仓库仅放脱敏/合成案例与汇总指标（PLAN §8.1、§2.1）。脱敏不是可选美化：文件名与目录本身可能携带客户、人员、报价信息，不能因它们是"路径字段"就默认低敏（PLAN §8.3）。gold 记录里的所有可见文本（`source.redacted_relative_path`、`redacted_filename`、`citations[].excerpt`、`scenario.description`、`expected.*` 各值、`notes`）**必须已经是脱敏后的形态**：`review.redaction` 只能是 `synthetic` 或 `reviewed`，`unredacted` 的记录按 Schema 校验直接非法（`GoldRecord.check`）。脱敏词表与占位符由 `RedactionPlan`（`redaction.v1`）产生，角色为 `customer/vendor/bidder/agent/person/project/amount/identifier`，标签形如 `«客户1»`、`«金额A1B2C3D4E5F6»`；盐值只存本地。

### 3.2 必须替换的字段

| 真实材料中的内容 | 处理 | 约束与依据 |
|---|---|---|
| 客户/最终客户（`endcustomer`、正文委托方） | `«客户N»`（role `customer`） | 同一实体在同一记录内标签一致；不得与厂商/投标主体/代理塌缩（PLAN §8.3「稳定但不同的占位符」） |
| 投标主体、代理、出具方（`bidderentity`、`issuer`、落款） | 分别 `«投标主体N»`/`«代理N»`/`«厂商N»` | 与客户是 SPEC §5.2 明令不得混同的四种角色，脱敏后必须仍可区分 |
| 自然人姓名、工号、邮箱、电话（`salesowner`/`department` 线索） | `«人员N»`（role `person`）；**不得保留首字母缩写、邮箱前缀、内部账号** | 残留 initials/handle 仍是可识别人员信息，判为脱敏失败 **（本文件新增约定）** |
| 单价、折扣、总价、金额区间 | `«金额<摘要>»`，同一数值在所有位置得到同一标签 | 必须保留"空白/已填/投标价格分册"三态语义（PLAN §8.3），不得把"空白模板"与"已填价格"抹成同样外观 |
| 项目名与项目目录名（`projectname`、路径段、簇名） | `«项目N»` 或合成名（`示例项目_<年>_<主题>`）；`project_cluster_key` 只能是 ASCII 键（§2.2） | 标签不稳定会使 §5 的文件名家族比对失效 |
| 招标编号、内部编号、`bsdcode` | `«标识N»` 或合成编号（`ZB-DEMO-<年>-<序号>`） | 编号常与年份/客户联合可识别 |
| DEVONthink 记录 UUID / 库 UUID | `source.source_uuid` 仅存本地受限目录（该文件永不提交）；进入任何可分享材料时只写盐化/SHA-256 摘要 | PLAN §7.2「公开导出使用脱敏引用」；P2 §4 forged-UUID 口径 **（本文件新增约定：可分享形态只写摘要）** |
| 绝对路径、用户名、主机名、内部域名、共享路径 | 替换为相对路径或 `<内部主机>` 占位 | PLAN §8.3 日志默认隐藏内部绝对路径 |
| 密钥、凭据、受保护资料 | 不外发、不写入 gold 记录、不入仓库 | PLAN §8.3 硬性禁止 |
| `citations[].label` | 只能是 ASCII 短标签（如 `body-p1-signature`、`xlsx-price-rows`） | Schema `ref` 模式限制 `[A-Za-z0-9_-]{1,64}`，且标签会进入导出 **（本文件新增约定：标签命名规范）** |

### 3.3 允许保留的判别线索

类别判定依赖结构与语义，不依赖具体名称。以下允许保留：

- 文档结构线索：章节标题、"技术规格要求/响应/偏差"字样、表格列名、页数、是否有落款与印章占位、是否有截止日期语句。
- 命名前缀与目录角色线索：`TENDER_`、`BID_`、`BID_CONTENTS`、`01_招标/`、`报价分册/`——SPEC §5.1 明确它们是线索而非定论，评测必须保留，否则 `ce-pa-*` 系列反例无法成立。
- 空白/已填状态：表单是否有实际值、价格表是否有单价与总价、技术响应表是否已填品牌型号与满足/偏差。
- 时间粒度：本地 gold 保留完整日期（`biddeadline` 需要 `YYYY-MM-DD` 期望值）；可分享材料只到年份 **（本文件新增约定）**。
- 类别与文档类型标签（`01_招标文件`、`Datasheet` 等）：它们是 Profile 枚举，不涉密。

### 3.4 脱敏后仍需保持判别力：对照做法

PLAN §8.3 要求在受限本地环境对**同一组关键反例**做脱敏前后对照；P2 §5 记录该对照目前 `BLOCKED`（需真实凭据与授权），`RedactionPlan` 的角色区分仅有单元测试。可执行做法 **（本文件新增约定：把 PLAN §8.3 的一句话展开成步骤与失败判据）**：

1. 选定对照集：`ce-pa-1..6` 与 `ce-vl-1..6` 各取 ≥3 条**已复核通过**的记录，共 ≥36 条。
2. 每条保存两个输入形态：脱敏前（仅本地、永不外发、永不写入 gold 文件）与脱敏后（`RedactionPlan` 应用后的相对路径 + 文件名 + 正文引用）；两条形态的**期望必须完全相同**——脱敏改变外观，不改变答案。
3. "判别力未损失"的检查项（逐条打勾）：
   - 空白 vs 已填价格仍可区分（`ce-pa-3`）；
   - 客户/厂商/投标主体/代理四类角色标签互不重合（`ce-pa-5`、`ce-vl-3`）；
   - `projectname` 应为 null 的线索未被抹去（`ce-vl-1`）；
   - `TENDER_`/`BID_`/`BID_CONTENTS` 前缀仍在（`ce-pa-2`、`ce-pa-6`）；
   - 已填技术响应表的品牌/参数/偏差语义仍在（`ce-pa-2`）。
4. 任一条目在脱敏后**失去**上述线索，即判该脱敏方案不合格：回到 `RedactionPlan` 的角色/术语配置修正后**整批重做**，并在审核台账记录"因判别力损失重做"。
5. 同模型脱敏前后调用对比：凭据与授权具备后按 PLAN §8.3 执行；不具备时用本地/确定性替身完成**流程对照**并注明云端局限。两种情形都**只公布汇总差异，不公布原文**。P3-A 的替身演练只能证明"对照机制可运行"，不得表述为脱敏判别力已验证。

### 3.5 三类高风险字段的专门规则

- **客户（`endcustomer`）**：占位后仍须与 `issuer`/`bidderentity`/`agent` 可区分（SPEC §5.2 第 3 条）。同一标签覆盖客户与代理即失格，`ce-pa-5` 类反例会失效。
- **人员（`salesowner`、`department`）**：`person` 标签；若期望值来自"已核实的来源组织上下文继承"（SPEC §5.2.1），记录必须在 `citations` 中给出该上下文来源；给不出时期望只能是"允许未知"（§4.2），不能写 `must_be_null` 之外的猜测。
- **报价（金额类线索）**：占位符按数值摘要生成，同一金额在正文与表格出现两次仍是同一标签；gold 必须显式写明该文件属"空白报价模板 / 已填报价 / 投标价格分册"三态中的哪一态——这是 `ce-pa-3`、`ce-pa-4` 的判别根据，缺失即视为脱敏损失。
- **高影响主体字段（`issuer` 等）**：脱敏不得制造"看起来有证据"的主体。没有署名/签章线索时，期望必须是 `null` 且不列入 `allowed_unknown_fields`（即填了就算错），依据 SPEC §5.2 第 5 条、PLAN §5.3 的严格证据政策与 `ce-vl-3`。

### 3.6 禁止提交真实资料（硬性）

- 真实文件名、目录、正文、报价、UUID、历史账本、书签、缓存、真实证据一律不进 Git（PLAN §2.1、§8.3「书签/缓存/真实证据不进入 Git」、SPEC §6.2）。
- 公开仓库只允许两类样本：`review.redaction = synthetic` 的完全合成记录，以及 `reviewed` 且通过 §3.2 全表替换的记录；后者提交前必须由**非作者**再执行一次脱敏检查并记录（本文件新增约定）。
- 仓库内已存在的示例文件名/路径（CasePack JSON、两个 Profile 的 `counter_examples` 文本、Tests 夹具、`docs/` 示例）都是**提示侧材料**，永不作为真实 gold，也不参与评测集（§5.1）。
- gold 本地根目录必须位于 Git 工作树之外 **（本文件新增约定）**：当前 `.gitignore` 只覆盖构建产物与 `*.sqlite`/`.env*`，不覆盖评测数据，靠工作树外放置才不会因 `git add -A` 误提交。
- 导出可分享报告前须再次脱敏（PLAN §8.3）。

---

## 4. 标注：gold 记录必须包含什么

### 4.1 必填内容（与 `gold-record-1.0` 一一对应）

一条 gold 记录必须包含以下十一组内容，缺一即不得进入评测集：

| 组 | 记录字段 | 规则与依据 |
|---|---|---|
| Schema 与身份 | `schema_version`（`"1.0"`）、`record_id`、`dataset_revision` | `record_id` 形如 `gd-000101`，稳定且永不重用（§9.3）；`dataset_revision` 为三段数字（§7.1） |
| Profile | `profiles[]`，取值 `project-archive` / `vendor-library` | 默认一个；同时列两个须 `notes` 说明（§2.3）。分层按 Profile 分别报告（PLAN §8.1） |
| 场景类别 | `scenario.category`（8 值枚举）+ `scenario.description`（8–200 字，以 `ce-*` 键开头） | §2.4；枚举值即 PLAN §8.1 的"反例场景"承载位 |
| 来源身份 | `source.project_cluster_key`、`source_uuid?`、`sha256?`、`redacted_relative_path`、`redacted_filename`、`near_duplicate_group?` | PLAN §8.1 的排除判据所需；真实 UUID/路径只留本地（§3.2）；`near_duplicate_group` 由 §5.3 人工判定后登记。**可选身份键的写法固定为"省略键"而不是写 `null`**：这三个键在 `gold-record-1.0` 中只接受字符串，显式 `null` 会被 Schema 判非法（`expected.project_reference`、`target_category`、`target_type`、`citations[].locator` 则必须写显式 `null`，因为"应为空"是期望的一部分，§4.1/§4.2）——本文件新增约定 |
| 期望决策状态 | `expected.state` ∈ `DecisionState` | **本文限定只用 `mapped`/`hold`/`unknown`**；`validated`/`invalidated` 是程序验证与失效标志，不能作为人工期望（PLAN §7.3、§7.1）——本文件新增约定 |
| 期望项目归属 | `expected.project_reference`：项目簇键（或占位项目标签），无归属时显式 `null` | SPEC §5.2.1（项目侧须有已确认关联）、§5.3/`ce-vl-1`（Vendor 允许 null）；严禁虚构项目 |
| 目标类别与类型 | `expected.target_category`、`expected.target_type` | 必须落在该 Profile 的 `categories`/`document_types` 内或显式 `null`；**`target_type` 键必须存在**（`GoldRecord.Expected` 对缺键直接判非法：类型"应为空"与"没写"不是同一件事） |
| 12 字段期望 | `expected.metadata`（12 个 identifier 全在）+ `expected.allowed_unknown_fields[]` | §4.2 |
| 支持正文引用 | `citations[]`（1–16 条）：`label`、`excerpt`（≤512）、`locator?` | PLAN §7.2 Evidence 契约：相对路径 + 快照 + PDF 页/字符区间、DOCX 部件/段落、XLSX 工作表/单元格，或 MCP 库/记录 UUID + 查询时间 + 工具 + 返回属性；`locator` 为 ≤256 字符的确定性文本描述（本文件新增约定：写法见 §4.2 示例） |
| 标注记录 | `annotation.annotator_code`、`annotated_on`、`basis` ∈ `verified_document_text`/`verified_business_fact`/`both` | §4.3；代号格式见 §6.3 |
| 审核状态与脱敏形态 | `review.status` ∈ `confirmed`/`adjudication_pending`/`rejected`、`review.redaction` ∈ `synthetic`/`reviewed`、`reviewer_code`、`reviewed_on` | PLAN §8.1 争议口径；`unredacted` 非法（§3.1） |
| 用途归属 | `usage` ∈ `evaluation`/`fewshot`/`excluded` | 与 split manifest 的 `evaluation_record_ids`/`prompt_record_ids` 必须一致（§5.6） |
| 数据集 revision | `dataset_revision` 与所在目录及 manifest 一致 | PLAN §8.1「固定 split manifest 与 gold revision」 |

**Schema 无法表达、因此本文追加要求的两项**（本文件新增约定，登记位置固定）：

1. **"为什么不选另一类"**：SPEC §6.2 要求案例说明`why_not`，`gold-record-1.0` 目前没有该字段。P3-A 期间的做法：把该说明写入 `scenario.description` 的后半句或 `notes`（本地台账 `review/notes.jsonl`，键为 `record_id`），并在 §6.2 复核清单第 5 项逐条核对；若评测基础设施后续为记录增加字段，以代码为准并更新本节。
2. **逐字段的期望理由**：`allowed_unknown_fields` 只能表达"允许未知"，不能表达"为什么"。每个列入该集合的字段与每个"填了就算错"的高影响字段，必须在本地台账写一句理由并挂 `citations[].label` 或"无相关线索"的说明。

### 4.2 12 字段期望的三种语义

SPEC §5.2.1 同时存在"未知留空"与"该文件本就不应有值"两种空，PLAN §8.2 要求逐字段区分"允许未知"与"错漏"。`gold-record-1.0` 的表达方式是 `metadata`（值或显式 `null`）加上 `allowed_unknown_fields`（列出"留空不算错"的字段），因此三态映射固定为 **（本文件新增约定：三态到两个字段的映射表，供标注者直接照做）**：

| 期望语义 | 写法 | 评分含义（口径见 PLAN §8.2 逐字段与漏填统计） |
|---|---|---|
| 必须有值 V | `metadata.<f> = "V"`，且 `<f>` **不在** `allowed_unknown_fields`，且 `V` 有 `citation` | 预测 null 记为漏填；预测其他值记为字段错误 |
| 必须为空 | `metadata.<f> = null`，且 `<f>` **不在** `allowed_unknown_fields` | 预测任何非 null 即为错（高影响字段属业务/法律错误，PLAN §5.3） |
| 允许未知 | `metadata.<f> = null`，且 `<f>` **在** `allowed_unknown_fields` | 预测 null 不算错；预测非 null 时该值必须有可核验证据支撑，仍按字段错误计分 |

约束：

- 12 个 identifier 全部必填键：`projectname`、`completionyear`、`bidderentity`、`department`、`salesowner`、`endcustomer`、`biddeadline`、`tenderreference`、`bsdcode`、`documentcategory`、`documenttype`、`issuer`。
- 值的形态遵守 Profile 与 SPEC §5.2.1：`completionyear` 四位年；`biddeadline` 文本 `YYYY-MM-DD`（首版不迁移 Date 类型）；`tenderreference` 须确认是采购/招标编号；`bsdcode` 不得由日期推断；`issuer`/`bidderentity`/`endcustomer` 不得互相回填。
- `documentcategory` 在项目侧 Profile 为 `required_for_validated=true`、`nullable=false`；Vendor 侧无项目归属时 `projectname` 通常为"必须为空"或"允许未知"（`ce-vl-1`）。
- `allowed_unknown_fields` 上限 12 且不得重复（Schema 约束）；一条记录若一半以上字段都靠"允许未知"过关，说明它证据贫瘠，应退回重标而不是拿来凑数 **（本文件新增约定：复核清单第 9 项）**。
- `expected.state` 与类别期望必须自洽：`hold`/`unknown` 的记录，其 `target_category` 应为该 Profile 的待分类项或显式 `null`，不得同时写具体类别与非 `mapped` 状态。
- 无引用即无期望：任何 `must be value` 的字段必须能通过 `citations[].label` 回溯到具体证据；`locator` 写法示例 `pdf:01_招标/…ZB-DEMO-2026-014.pdf#p1,c0-96@snapshot-20261120`（本地相对路径 + 页/字符区间 + 快照标签；本文件新增约定，只要求可解析、可复算，不要求格式统一）。

### 4.3 `annotation.basis`：gold 的依据类型

- `verified_document_text`：正文/单元格/结构事实直接支持期望（对应 PLAN §8.1「可核验正文」）。
- `verified_business_fact`：由已核实的业务事实支持（归档事实记录、已确认的项目关联、MCP 只读回读属性），须把事实来源写进 `citations`（`source = mcp` 口径见 PLAN §7.2）。
- `both`：两条链都有。
- **只有文件名/路径线索**（PLAN §8.1 的 `filename_path_only` 级、SPEC §6.2 的 664 条一类）**不能填任何 `basis` 值成为 gold**：它至多是抽选线索（§2.1 P3）。仅历史标签（56 条一类）同理不得成为 gold（SPEC §6.2）。
  - 例外与唯一合法形态 **（本文件新增约定）**：当**正确答案本身是"线索不足 ⇒ hold/待分类"**时，仍可用 `verified_document_text` 标注，并引用能证明"确无更高级线索"的那段结构事实（例如价格表全部单元格为空）。此时期望是 `hold`，不是猜测出的类别。

### 4.4 争议条目：`adjudication_pending`

标注者与复核者结论不一致，或业务事实需第三方确认时：`review.status = adjudication_pending`。

- 该记录**不参与准确率分母**：`GoldRecord.isCountable` 只承认 `confirmed`（PLAN §8.1 排除口径由实现承载），运行器以 `pendingAdjudication` 报告排除量。
- 争议记录**保留在 `evaluation_record_ids` 中**，不得写进 `removed_records`——"移出评测集"只用于 §5 的泄漏排除，语义不同 **（本文件新增约定：区分"争议排除"与"泄漏移除"）**。
- 不得删除争议记录、不得静默改答案、不得由标注者自行降级为"两种都对"；裁决完成后作为新 revision 的一部分被确认或替换（§7.4）。
- 排除量与待裁决清单必须进入缺口报告（§8.2 表 A），让 Owner 能分辨"数量不足"与"审核未完成"。

---

## 5. 独立性与泄漏排除

### 5.1 必须比对的对象

1. shipped CasePack（`forma-governance-cases@1.0`）的 24 条样本：**只贡献 `family` 一轴**——`GoldDataset.promptIdentityKeys` 为每条案例生成唯一一条键 `family:` + `GoldRecord.filenameFamily(of: input.redactedFilename)`。实现原先还挂了一条 `path:`（相对路径完全相等），现已删除：`GoldRecord.independenceKeys` 里从来没有 `path:`，所以那条键写了也永不命中，留着只会让人以为路径比对在工作 **（本文件新增约定：本文只按实际生效的轴描述）**；
2. 数据集中被标为 `usage = fewshot` 的记录：贡献其**全部五条独立性键** `cluster`/`uuid`/`sha`/`family`/`near`（同样不含 `path:`；`near` 仅在该记录赋了 `near_duplicate_group` 时存在），见 §5.6；
3. 两个 Profile 的 `counter_examples` 与 `document_types.clues` 文本、`MappingPrompt` 组装文本、仓库内 Tests 夹具与 `docs/` 示例中出现过的文件名/路径：由数据集管理员在每次冻结前**人工枚举一次**并写入 `overlap.json`（清单从仓库内容现算，不手工维护 **（本文件新增约定）**）。
4. 已定给提示侧的全部簇（§5.6 的 manifest 视图）。

**机械可判定的轴只有五条**：`cluster`（`project_cluster_key`）、`uuid`（`source_uuid`）、`sha`（`sha256`，小写后比较）、`family`（`GoldRecord.filenameFamily(of:)` 的结果）、`near`（`source.near_duplicate_group`）。比较只在"评测记录的五类键"与"提示侧展开出的键"之间做**完全相等**，除此之外没有任何模糊匹配、相似度或距离计算（§5.3）；提示侧展开出的键为：shipped CasePack = `family` 一轴，`usage = fewshot` 记录 = 五轴（`near` 视赋组情况而定）。

**自动比对的已知限度：** shipped CasePack 的样本不携带 `project_cluster_key`、`source_uuid` 或 `sha256`，`promptIdentityKeys` 只能为其生成 `family` 一轴，因此**与 CasePack 之间可机械命中的只有文件名家族**；`cluster`/`uuid`/`sha`/`near` 四条轴对 CasePack 永远不产生交集，也就是说**同一项目簇里换了名字的另一个文件、以及同一项目里内容相同但文件名家族不同的文件，都不会自动报出交集**。这使 PLAN §8.1 的"无 SHA 时先隔离保守来源簇"成为唯一有效的防线：数据集管理员必须维护本地 CasePack 案例→项目簇归属表（`casepack-cluster-map.json`，§9.1），并对每条 `evaluation` 记录人工核对 `project_cluster_key` 是否与任一 CasePack 案例同簇（本文件新增约定：这是人工责任，运行器不代替）。

### 5.2 排除判据与登记用的原因码

命中任一判据即必须把该记录**移出 `evaluation_record_ids` 并写入 `removed_records`**，`reason` 只能用下表左列的固定枚举值（`GoldSplit.RemovalReason`），且理由必须点名**命中的那条轴**（本文件新增约定：轴与理由一致是**审计要求**，由数据集管理员与复核者负责核对）。运行器侧的实际机制是：只要一条 `evaluation` 记录仍可计数且与提示侧存在交集，它就同时被从 `countableIDs` 剔除并以 `"<record_id>~<counterparty>:<axis>"` 形式出现在 `Report.undeclaredOverlaps`；由于 `GoldSplit.check` 不允许"已声明移除的记录仍留在评测侧"，**"已声明但仍在评测集"不是合法状态**，因此出现在该清单里的交集一律属于未处理干净的数据集，而不是"等人工确认"的中间态。该清单非空即不得发布本报告（§8.2 表 A、§10.3）。

| reason（固定枚举） | 判据 | 说明 |
|---|---|---|
| `prompt_cluster_overlap` | 与提示侧某记录/案例同属一个 `project_cluster_key` | 簇是单位：整簇定侧（§2.2） |
| `prompt_source_overlap` | `source_uuid` 完全相等 | 本地原值比对；可分享材料只写摘要（§3.2） |
| `prompt_hash_overlap` | `sha256` 完全相等 | 内容相同即同一来源，无论名字 |
| `prompt_filename_family_overlap` | `redacted_filename` 规范化家族相等 | 家族算法见 §5.3 |
| `near_duplicate` | 人工判定模板/标题/片段近重复（§5.3） | 判定后写 `source.near_duplicate_group` |
| `same_file_other_version` | 同文件不同版本/改名副本分落两侧 | PLAN §8.1 硬性禁止 |
| `adjudication_unresolved` | 争议无法裁决而无法留在集内 | 与 §4.4 的 `adjudication_pending` 不同：后者保留在评测集内不计数 |
| `privacy_review_failed` | §3.4/§6.2 脱敏检查不通过 | 移除同时记录脱敏失格项 |
| `duplicate_record_id` | 两条记录同号 | 分母无法解释，整体拒绝该 revision |

每条移除还须填 `counterparty_record_id`，指向与之冲突的 CasePack `case_id` 或另一条 gold `record_id`（可缺省，缺省时只声明"该轴已冲突"）。`reason` 与轴、`counterparty_record_id` 与被冲突记录的一致性由 §6.2 checklist 第 8 项人工核对：运行器不校验这两处对应关系，只校验清单结构（§5.2、§10.3）。

### 5.3 确定性比对算法（不引入向量库）

PLAN §1 与 SPEC §6.1 第 5 条禁止 Embedding/Vector DB/RAG；PLAN §8.1 规定近重复"用规范化标题/文本片段比对及人工复核"。

- **文件名家族**（由 `GoldRecord.filenameFamily(of:)` 计算，`family` 轴）：去扩展名 → 小写 → 非字母数字字符一律换成空格 → **以子串方式**剔除标记 `副本`、`最终`、`定稿`、`修改`、`拷贝`、`copy`、`final`、`new`、`old`、`draft`、`backup`（不是按整词丢弃，否则 `副本最终` 这类连写会把同一文档的两个名字留在两个家族）→ 丢弃纯数字词元与 `v<数字>` 形如 `v2`/`v3` 的版本记号 → 直接拼接。因此 `报告 v2.docx`、`报告-V3(最终).docx`、`报告 副本.docx` 归入同一家族。该算法**纯字符串、确定性、可手工复算**，本文只描述口径，不得把它扩展为相似度/距离度量。
- **近重复分组**：FormaCore **不做**标题或正文的相似度计算，只做**分组标签相等**比较——两条记录的 `source.near_duplicate_group` 相同即视为同一近重复组（`near` 轴），其评测侧记录以 `near_duplicate` 原因码排除（§5.2）。
  - 组标签由**数据集管理员**按下列判据预先赋值，可由人工执行，也可由外部脚本辅助生成后逐条确认（本文件新增约定：FormaCore 之外的环节）：
    1. 规范化：NFC 归一 → 去空白与中英标点差异 → 小写 → 移除数字串与占位符（`«…»`、`ZB-DEMO-*`）→ 截断前 2000 字符；
    2. 判据一：规范化标题完全相等；
    3. 判据二：规范化后的 `excerpt` 存在长度 ≥24 字符的连续公共子串，或同时出现 ≥3 个长度 ≥6 字符的公共词元；
    4. 命中产生 `suspected_near_duplicate` 清单，**逐条人工判定**是否同族，判定与判据、对方记录号写入 `overlap.json`。
  - **上述 24/6/3 阈值是人工赋值分组时的判据，不是 FormaCore 的计算**；本文保留它们只为让分组决定可被第三者复算与审计（本文件新增约定）。未赋组标签的记录在 `near` 轴上没有键，因此该轴的完整性取决于 §6.2 checklist 第 8 项是否真的执行。

### 5.4 版本与改名副本

同一文件的修订版、重印件、改名副本、导出件属同一簇/同一家族（§2.2 第 3 条），**不得分落提示侧与评测侧**（PLAN §8.1 原文要求）。命中即以 `same_file_other_version` 或 `prompt_filename_family_overlap` 移除评测侧那一条，整簇改判给一侧。

### 5.5 SHA 不可得时

`source.sha256` 缺省表示尚未计算或云文件未 hydration（PLAN §8.1「无 SHA 时先隔离保守来源簇，补齐后再确认」）。处理 **（本文件新增约定：把该句落成规则）**：

1. 该记录所在簇标 `sha_pending`（本地簇表 + 候选台账），并按簇整体隔离在评测侧；
2. 该记录**不得计入 §8.1 的"合格真实脱敏记录"达标数**——它的唯一性还没被证明；
3. 补齐 SHA 后必须重跑 §5.2 全量比对，若发现与提示侧冲突即按 §5.2 移除（这会使 revision 递增，§7.4）。

### 5.6 归属一致性（`usage` 与 manifest）

- `usage = evaluation` 的记录必须出现在 `split-manifest.json` 的 `evaluation_record_ids`；`usage = fewshot` 的必须出现在 `prompt_record_ids`；`usage = excluded` 的两侧都不出现。
- `prompt_record_ids` 与 `evaluation_record_ids` 必须**不相交**；已写进 `removed_records` 的记录不得再留在 `evaluation_record_ids`（由 `GoldSplit.check` 强制，违反即无法解码）。
- `review.status = rejected` 的记录**不得**声明 `usage = evaluation`（否则整条记录非法），它只能作为 `excluded` 留在本地树里当审核历史（`GoldRecord.check` 的口径，本文据此规定 rejected 的处置）。
- **`usage` 三个取值的含义由本文件固定**（本文件新增约定）：`evaluation` = 参与本轮独立评测的合格样本；`fewshot` = 该记录登记的目的是说明"这份材料已进入提示侧"，用作 §5.2 的提示侧身份键，它本身不属于评测集；`excluded` = 既不入评测也不作提示侧输入（含 §6.2 判 `rejected` 的审核历史）。
- 一条记录**一生只定侧一次**：不得把先前用于某轮评测结论的 `evaluation` 记录在后续 revision 里改成 `fewshot`（那是 PLAN §8.1「禁止同一文件分落提示/评测」的变相违反，因为答案已经进过提示），也不得反向把已入包的提示材料临时改成 `evaluation` 来凑数量。定侧变化只能以"新记录号 + `changelog.json` 理由"发生（§7.4）。
- `fewshot` 记录的存在不改变 §1.3 的禁令：本文的评测样本仍然不得复用 CasePack 的 24 条案例，`fewshot` 记录是本地对提示侧清单的**镜像登记**，不是把评测样本送去当例子。

### 5.7 无法排除时

任何记录在 §5.2/§5.3 判据上无法确定归属、或存在未解决的交集，**移出评测集**（PLAN §8.1「无法排除时移出评测」），按 §5.2 写入 `removed_records`。移出是降低合格样本数、扩大缺口报告（§8.2），而不是保留并加注说明。

### 5.8 反向泄漏

评测完成后，评测集的具体答案不得回流提示侧：不得把评测中答错样本的期望值直接塞进 CasePack/Prompt（PLAN §8.1「评测后不向 Prompt 泄漏具体答案」）。纠错产生的候选只走 PLAN §8.4 的链条（`candidate_example → 独立审核 → 可追溯证据 → 脱敏检查 → 入正式 CasePack`），包升级须记录增删理由、对固定独立评测集回归，并报告泄漏检查结果（§7.4）。

---

## 6. 审核流程

### 6.1 角色与分离要求

- **标注者（annotator）**：读正文/引用与业务事实，写期望（§4）。
- **复核者（reviewer）**：**必须与标注者不是同一人**，独立重读证据后判定。PLAN §8.1 的"人工或独立审核者"与 SPEC §6.2 的"全部不能自动等同人工金标准"是本分离的依据。
- **裁决者（adjudicator）**：Owner 指定，处理 §4.4 争议。
- **数据集管理员（steward）**：执行冻结、生成 manifest、保管盐值与簇表；不参与标注（本文件新增约定：四角色分离）。

同一自然人可承担不同 revision 的标注与复核，但**不得复核自己标注的同一条记录**；复核者代号与标注者代号相同而记录为 `confirmed`，视为审核缺陷，该记录必须退回（本文件新增约定）。

### 6.2 复核通过条件（逐条 checklist）

复核者逐项确认，全绿才可置 `review.status = confirmed` 并填 `reviewed_on`：

1. 每条"必须有值"的字段都能在 `citations` 中找到对应 `label`，其 `locator` 指向真实存在的快照与有效区间/部件/单元格（PLAN §7.2：引用存在、属授权输入、同一有效快照、定位有效、quote 与提取值一致）；
2. `excerpt` 与实际提取内容一致（不可凭记忆撰写）；
3. `target_category`/`target_type` 在该 Profile 枚举内或显式 `null`，且 `target_type` 键存在（§4.1）；`expected.state` 与类别期望自洽（§4.2 末条）；
4. 12 键齐全，`allowed_unknown_fields` 的每一项都有本地台账理由；高影响主体字段在无署名/签章证据时为 `null` 且**不在**该集合内（SPEC §5.2 第 3/5 条、`ce-vl-3`）；
5. 记录某处（`scenario.description` 或本地台账）确实说明了"为什么不选另一类"，并与 §2.4 场景键相符（§4.1 追加要求 1）；
6. `annotation.basis` 与实际依据匹配，且不是"只有文件名/路径线索"（§4.3）；
7. 脱敏检查：§3.2 全表逐项无残留；角色标签互不塌缩；报价三态仍可辨；§3.4 五项检查逐条打勾；
8. 独立性检查：§5.2 六类交集判据无命中，或命中已按 §5.2/§5.7 移除并声明；`project_cluster_key` 已对 CasePack 簇归属表人工核对（§5.1 限度）；
9. `allowed_unknown_fields` 不超过该记录字段总数的一半（§4.2 末条）；
10. 若期望依赖 `sibling` 线索，必须能回连具体来源与上下文成员关系，不允许循环互证（PLAN §7.2）；
11. `usage` 与 manifest 归属一致（§5.6）。

任一项不过：退回标注（保持未确认状态，见 §6.4）或判 `rejected`（`usage = excluded`），并记录原因；**不得"先接受后补证据"**。

### 6.3 记录审核者与日期

`annotation.annotator_code`、`review.reviewer_code` 是**角色代号**，格式固定 `^[A-Z]{1,4}[0-9]{1,3}$`（Schema 强制）：`A1..A9` 标注者、`R1..R9` 复核者、`J1..J3` 裁决者、`S1` 数据集管理员 **（本文件新增约定：代号段划分）**。`annotated_on`/`reviewed_on`/`generated_on` 为 ISO `YYYY-MM-DD`。

进入仓库的任何材料**绝不写真实姓名**：`gold-record-1.0` 的说明明确要求审核者身份是角色代号而非员工名，这与 CasePack Schema 对 `reviewer_role` 的约束（不得是客户或具体员工）、SPEC §6.2/PLAN §2.1 的匿名要求同源。代号↔真人映射表只存 `review/` 目录内，永不出本机、永不提交（本文件新增约定）。

### 6.4 复核不可达时

单人可用、复核者缺席、或复核者无法访问原文件时：

- **`review.status` 没有"pending"值**（只有 `confirmed`/`adjudication_pending`/`rejected`），因此未复核记录**不得写入已冻结 revision 的 `records/`**：它们留在本地暂存区 `review/pending/`（§9.1），冻结时不进入 manifest（本文件新增约定：把"不计入 ≥150"落成"根本不在冻结集内"，避免与 Schema 枚举冲突）。
- 缺口报告的表 A 必须列出待复核数量（`unreviewed_pending`），使"数量不足"与"审核未完成"可分辨（PLAN §8.2 未审核 gold 单独报告）。
- 不得以"标注者自查"冒充复核，不得因数量压力批量置 `confirmed`。
- 唯二例外，且必须 Owner 书面同意 **（本文件新增约定）**：
  1. `single_review`：记录仅经一人标注即进入评测。此时 `review.reviewer_code` 仍须填写，取值为该标注者本人代号，并在本地台账标 `single_review`；报告中该分层必须标注"未经独立复核"，其结论不得用于宣称任何质量 Gate 通过；
  2. 延后复核：P3-B 启动前完成复核，否则该记录按待复核处理（留在 `review/pending/`）。
- 复核者之间分歧 → §4.4 `adjudication_pending` → 裁决者结论写入新 revision；始终无法裁决而无法保留时，用 `adjudication_unresolved` 移除（§5.2）。

---

## 7. 版本管理

### 7.1 revision 命名与不可变性

- `dataset_revision` 为三段数字 `M.m.p`（Schema `revision` 模式），例如 `1.0.0`。**冻结日期不写在 revision 里**，写在 split manifest 的 `generated_on` **（本文件新增约定：三位数的含义）**：
  - `M` 变更：记录结构或本文 §4 口径变更（例如 Schema 升版）；
  - `m` 变更：样本集变更（新增、替换、移除）；
  - `p` 变更：不改期望内容的修正（代号/日期补录、台账说明、重算分层）。
- 本地目录名可附人类可读标签（`gold-1.2.0-20261120`），但目录内的 `dataset_revision` 字段必须是纯三段数字，且**同一次加载内所有记录与 manifest 的 revision 必须完全一致**（`GoldDataset.verify` 会整体拒绝混版）。
- **已冻结 revision 不可变**：任何改写、补字段、换样本都是新 revision。评测引用某 revision 后，该 revision 目录下所有文件的摘要必须永久可核对（`digest.sha256`，§9.1）。
- `record_id` 永不重用：被替换记录的号进入墓碑清单，避免历史结论被重新解释。

### 7.2 split manifest 固定

每次冻结产出 `<revision 目录>/split-manifest.json`，至少包括 `split_id`、`dataset_revision`、`generated_on`、`casepack{id,version}`、`prompt_record_ids`、`evaluation_record_ids`、`removed_records[]`、`notes`（样例见 §9.5）。它同时是簇归属、排除声明与分层/缺口视图的**唯一权威入口**：评测运行时只按 manifest 取样本。manifest 与记录目录不一致（引用不存在的记录号、两侧相交、移除记录仍在评测侧、revision 混版）时，运行器整体拒绝加载而非静默跳过（§10.3）。

`split_id` 建议 `gs-<M>-<m>-<p>-<n>` 形式（如 `gs-1-0-0-1`），表示"同一 revision 的第 n 份分割视图"；Schema 的 `split_id` 模式是 `^[a-z][a-z0-9-]{2,63}$`，**不含点号**，所以 revision 数字在 `split_id` 里用连字符分隔（本文件新增约定）。同一 revision 允许多份视图（例如为不同 Profile 子集分别评测），但每份视图与同一 `records/` 目录的组合必须在报告里唯一标识。

### 7.3 复现一次评测结论所需的三件套

一条评测结论必须能由下列三样东西重放（PLAN §6.2 run revision、§8.1、§8.2）：

1. **gold revision**：`dataset_revision` 数值 + 该 revision 目录的 `digest.sha256`；
2. **split manifest**：`split_id` 与 `generated_on` 及其摘要（含簇归属、`removed_records`、分层与缺口快照）；
3. **Profile 与模型的完整标识与日期**：`profile_id@profile_version`（`project-archive@1.0` / `vendor-library@1.0`）、`casepack{id,version}`（`forma-governance-cases@1.0`，由 manifest 固定携带）、Prompt/Schema/提取器/`redaction.v1` 版本、Provider 与**完整 model_id**、计价日期与币种（费用口径见 PLAN §8.2）。

缺任一件即标"不可复现"，其结论不得作为 Owner 批准阈值的依据。真实目录评测还须补记 `source_root_id` 与扫描快照日期（§2.5 第 1 步）。

### 7.4 新增/替换样本的变更规则

- 新增或替换只能通过新 revision；变更清单（`changelog.json`）逐条写明**理由**（PLAN §8.4「包升级记录增删理由」同类要求）。
- 每次变更必须重新执行：§5 全量独立性比对（含 §5.1 的 CasePack 簇人工核对）、§6.2 复核（新增/替换条目）、分层计数与缺口重算。
- 若同时改动 CasePack/Profile，必须按 PLAN §7.3 的依赖关系重新验证受影响条目，不无条件复用旧结论；并对固定独立评测集做回归比较（PLAN §8.4）。
- 合格记录总数不得因变更而下降却不在报告中说明；分层达成状态必须重算，不得沿用旧 revision 的分层结论。
- **禁止指标驱动的换样**：不得为提高某次测量值而替换掉"答错"的样本；错答样本留在集内并进入混淆矩阵。唯一合法移除理由是 §5.2 九类原因码、§6.2 复核不通过、来源授权失效 **（本文件新增约定）**。
- 冻结时点：P3-B 启动前冻结一个 revision 作为该轮评测的唯一基准，该轮内不得换 revision（本文件新增约定）。

---

## 8. 数量与缺口

### 8.1 硬性数量要求

- 独立评测目标 **≥150 条合格记录**：经 §6 复核为 `confirmed`、`usage = evaluation` 且在 manifest 内、通过 §5 独立性检查、`annotation.basis` 支持其期望、`review.redaction = reviewed`（真实脱敏）（SPEC §10.1.6、PLAN §8.1）。
- 每分层争取 ≥10（§2.3）。`sha_pending`（§5.5）、待复核（§6.4）、`adjudication_pending`（§4.4）、`excluded`/`fewshot`/被移除记录、以及 `synthetic` 记录均不计入 ≥150 的**真实**样本数。
- **合成与真实由代码区分**：`GoldDataset.Report` 同时给出 `countableRecords`（含 `review.redaction = synthetic` 的记录，用于把评测 harness 跑通）与 `reviewedCountable`（只计 `review.redaction == .reviewed` 的记录），而 `meetsIndependentTarget` **只**以 `reviewedCountable` 与 `GoldDataset.independentTarget = 150` 比较。也就是说：**合成记录可以驱动 harness，但不能宣告达标**——这条保证有实现用例（`synthetic rows exercise the harness but cannot certify the target`），不再依赖报告撰写人的自觉。报告仍须把两个数分列展示，因为 PLAN §8.1 的"≥150"讲的是对真实材料的独立核实。
- 若当前不具备任何授权真实来源（P2 §7 现状），则真实合格样本数为 0，必须如实报告"未达样本量"（SPEC §10.1.6），不得以合成演练数量替代。

### 8.2 缺口报告（必须输出的四张表）

每个 revision 冻结时随产物生成缺口台账（模板，**不是结果**）：

```
表 A 总量与排除（行首标 `R` 的取运行器 `Report` 原值，未标的由本文台账补充）
   R required_total           = GoldDataset.requiredMinimum（= independentTarget = 150）
   R meets_independent_target = Report.meetsIndependentTarget（只由 reviewedCountable 与 150 比较得出，本文不另行判定）
   R reviewed_countable       = Report.reviewedCountable（真实脱敏 `reviewed` 且 confirmed、未被独立性排除的记录数）
   R countable_records        = Report.countableRecords（含 synthetic，只说明 harness 覆盖面，不参与达标）
   R unaccounted_records      = Report.unaccountedRecords（排序后的记录 id 列表：`records/` 里存在，但 split 既没放进 `evaluation_record_ids`/`prompt_record_ids`，也没写进 `removed_records`——**没人对它作过决定**；见 §8.2 末、§10.4）
     qualified_reviewed       = 本文口径的合格数 = reviewedCountable 再扣除 §5.5 中 `sha256` 尚未补齐的记录（唯一性未证明），因此 ≤ reviewed_countable，两者必须并列公布
     unreviewed_pending       = 留在 `review/pending/`、未进入冻结集的记录数（§6.4）
   R adjudication_pending     = Report.pendingAdjudication（§4.4，排除但必须报告）
     removed_records          = 按 §5.2 九个原因码分别计数（含各自 counterparty 数）
   R undeclared_overlaps      = Report.undeclaredOverlaps（格式 `<record_id>~<counterparty>:<axis>`，`axis` ∈ `cluster|uuid|sha|family|near`；**已决定要评分、但它与提示侧相交**）
     sha_pending_clusters     = §5.5 标记的簇数
     synthetic_only           = 标 synthetic 的合成记录数（单列，永不并入上面任何达标数）
表 B 分层（逐 Profile）
   轴（场景类别 / 文档类别 / ce-* 场景键 / 决策形态 / 格式与状态） | 键 | 目标 | 合格(reviewed) | 合成 | 缺口 | coverage_redundant
表 C 簇归属
   project_cluster_key | 侧 | 成员记录数 | 命中判据与 reason | counterparty | 备注
表 D 依据与脱敏
   annotation.basis 分布 | 各格式抽取成功/失败样本数 | 脱敏对照集条目数与五项检查结果（§3.4）
```

表 A 的 `adjudication_pending` 与 `removed_records` 就是 PLAN §8.1 要求"必须报告排除量"的落点。

**两条清单不得混用，且都必须为空才允许宣称台账完整**（本文件新增约定，取运行器原值，不靠撰写人自觉）：`Report.unaccountedRecords` 非空 = 目录里存在 split 三处清单都没登记过的记录，即"没人对它作过决定"，此时分母无法由台账重新推出，报告不得发布（§7.3 的复现三件套不成立）；`Report.undeclaredOverlaps` 非空 = 已经决定要评分的记录与提示侧相交，属于 §5 的隔离失效。前者的修法是把记录归入 `evaluation_record_ids`、`prompt_record_ids` 或 `removed_records` 之一（§5.6 的 `usage` 归属一致性），后者的修法是 §5.2 的移出评测侧。

### 8.3 与指标的关系

指标定义、计算式、Wilson 区间、项目簇 bootstrap、零分母 `N/A`、逐字段漏填口径全部见 PLAN §8.2 与 SPEC §10.1.7，本文不重述。本文只约束**分母的资格**：进入准确率分母的必须是 §8.1 意义上的合格记录；`adjudication_pending` 只出现在表 A；未复核记录不在冻结集内（§6.4）。运行器 `Report.shortfalls[].required` 是 PLAN §8.1 的"争取 ≥10"这一事实的展示值，`GoldDataset` 自身不把它当通过/失败开关；是否算通过由报告撰写人与 Owner 判断。

### 8.4 数量不足时的禁止事项

- 必须报告"数量与场景缺口"，可以继续展示功能，但**不得宣称类别准确率验收通过**（PLAN §8.1、SPEC §10.1.6 原文）。
- `meetsIndependentTarget = false` 或表 B 任一分层未达标时，报告必须显式携带"本数据集不足以支持类别准确率验收"的结论句 **（本文件新增约定：该结论句由撰写人负责，运行器只提供事实）**。
- 不得把"样本不足"当作通过的理由，也不得为通过而缩小评测范围或隐藏缺口表（PLAN §P3 回退条款：未达项单列未通过，不降低标准、不加审批层）。
- **禁止为凑数自动生成、批量复制或伪造"真实金标准"**：模型自动输出、自我反思、未审核的人工点击都不成为 gold（PLAN §8.4、SPEC §6.2）；合成记录必须永久 `redaction = synthetic` 并与真实样本分列（§8.1、PLAN §8.2 合成压力数据单列）。
- 不得把 78 条有限正文核验、664 条文件名/路径高置信、143 条中置信、56 条仅历史标签、50 条异常当成金标准（SPEC §6.2、PLAN §8.1）。
- Owner 批准阈值之前，不得声称最终质量 Gate 已通过（PLAN §8.2、§P3、ROADMAP 授权历史）。

---

## 9. 目录与文件布局

### 9.1 本地根目录（全部不提交）

评测基础设施按 `<revision 目录>/split-manifest.json` 与 `<revision 目录>/records/*.json` 加载（`GoldDataset.load(directory:)`），因此布局固定如下 **（本文件新增约定：其余文件是审计产物，不参与加载）**：

```
<FormaEvalRoot>/                       # Owner 指定的受限本地根；必须在任何 Git 工作树之外
├─ revisions/
│  └─ gold-1.2.0-20261120/             # 目录名可读；内部 revision 字段仍是 "1.2.0"
│     ├─ split-manifest.json           # 加载必需（§7.2、§9.5）
│     ├─ records/                      # 加载必需：**只放 gold 记录，一条一个 .json**
│     │  ├─ gd-000101.json
│     │  └─ gd-000103.json
│     ├─ overlap.json                  # §5.1/§5.3 人工判定明细
│     ├─ changelog.json                # §7.4 增删理由
│     ├─ gap-report.json               # §8.2 表 A–D
│     └─ digest.sha256                 # 上述全部文件摘要
├─ clusters/clusters.jsonl             # 簇表（§2.2：ASCII 键 ↔ 真实目录/库 UUID）
├─ candidates/candidates.jsonl         # 候选与抽选原因码（§2.5 第 4 步）
├─ casepack-cluster-map.json           # CasePack 案例 → 项目簇归属表（§5.1 人工核对输入）
├─ quarantine/                         # §5.7 无法排除的记录：隔离不删除
├─ raw/                                # 真实来源快照，受授权范围限制；不复制进任何可分享物
├─ redaction/                          # RedactionPlan 盐值与 term→role 表；绝不外发、绝不入仓
└─ review/
   ├─ pending/                         # §6.4 未复核记录，冻结时不进入 records/
   ├─ notes.jsonl                      # why_not 与逐字段理由（§4.1 追加要求）
   └─ roster.json                      # 代号 ↔ 真人映射，永不出本机
```

**硬规则：**

- `records/` 目录内**只允许 gold 记录 JSON**：加载器枚举该目录下所有 `.json` 当作记录，任何摘要/说明/临时文件混入都会被解析失败或污染分母（本文件新增约定）。
- 目录权限 `0700`、文件权限 `0600`；`raw/`、`redaction/`、`review/roster.json` 永不打包分享（本文件新增约定）。
- 仓库侧唯一允许出现的 gold 内容是本文件的合成示例；若评测基础设施需要可提交夹具，由实现者指定路径，且每条必须 `review.redaction = synthetic`。

### 9.2 什么能提交、什么不能

| 材料 | 仓库 | 说明 |
|---|---|---|
| 本文件（规范与合成示例） | 可 | 无真实名、路径、编号 |
| `redaction = synthetic` 的评测夹具 | 可（路径由实现者决定） | 必须明显合成，实体全部占位 |
| `reviewed` 脱敏记录 | 仅当 §3.2 全表通过且二次脱敏检查已记录；优先留本地 | — |
| 汇总指标与分层数量（表 A–D） | 可 | PLAN §8.1「公开仓库仅放脱敏/合成案例与汇总指标」 |
| 真实版本的 `records/`、`split-manifest.json`、`clusters.jsonl`、`raw/`、`redaction/`、`review/` | **否** | 硬性禁止（§3.6） |
| 真实文件名/目录/报价/UUID/绝对路径/人员名 | **否** | 出现在错误信息、日志、测试快照中同样禁止 |

### 9.3 文件名与标识规范 **（本文件新增约定）**

- 目录与文件名：ASCII 小写、连字符分隔，无空格与中文；固定名 `split-manifest.json`、`overlap.json`、`changelog.json`、`gap-report.json`、`digest.sha256`。
- 记录文件：`<record_id>.json`，即 `gd-000101.json`；`record_id` 模式 `[A-Za-z0-9_-]{1,64}`，序号零填充 6 位、永不重用。
- 簇键 `cl-<pa|vl>-<三位序号>`（如 `cl-pa-001`）；近重复组 `nd-<pa|vl>-<序号>`；`split_id` 见 §7.2；`revision` 三段数字。
- 日期一律 `YYYY-MM-DD`，年份一律四位（与 `biddeadline`/`completionyear` 的形态一致）。
- 每条记录一个独立 JSON 文件、UTF-8、键序稳定；不再使用 JSONL 单文件形态（§9.1 加载布局）。

### 9.4 合成 gold 记录样例

**以下记录 100% 为虚构合成数据**：实体、编号、日期、摘要值皆为演示占位，不对应任何真实项目、客户或文件；`sha256` 为全零示意串。文件位置 `records/gd-000101.json`。

```json
{
  "schema_version": "1.0",
  "record_id": "gd-000101",
  "dataset_revision": "1.0.0",
  "profiles": ["project-archive"],
  "scenario": {
    "category": "template_family",
    "description": "ce-pa-3: 空白采购报价附件应归 01，含实际单价与总价的独立报价才考虑 05（合成示例）"
  },
  "source": {
    "project_cluster_key": "cl-pa-001",
    "source_uuid": "00000000-0000-4000-8000-00000000DEMO",
    "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "redacted_relative_path": "示例项目_2026_智慧园区智能化/01_招标/QUOTATION_空白报价表_ZB-DEMO-2026-014.xlsx",
    "redacted_filename": "QUOTATION_空白报价表_ZB-DEMO-2026-014.xlsx"
  },
  "expected": {
    "state": "mapped",
    "project_reference": "cl-pa-001",
    "target_category": "01_招标文件",
    "target_type": "Blank Procurement Template",
    "metadata": {
      "projectname": "«项目1»",
      "completionyear": "2026",
      "bidderentity": null,
      "department": null,
      "salesowner": null,
      "endcustomer": "«客户1»",
      "biddeadline": null,
      "tenderreference": "«标识1»",
      "bsdcode": null,
      "documentcategory": "01_招标文件",
      "documenttype": "Blank Procurement Template",
      "issuer": null
    },
    "allowed_unknown_fields": ["biddeadline", "issuer", "bsdcode", "department", "salesowner"]
  },
  "citations": [
    {
      "label": "xlsx-price-rows",
      "excerpt": "报价表（示例）：单价、折扣、合计三列全部为空，仅表头与«客户1»名称行存在。",
      "locator": "xlsx:示例项目_2026_智慧园区智能化/01_招标/QUOTATION_空白报价表_ZB-DEMO-2026-014.xlsx#sheet=报价,sheet2!A1:F1@snapshot-20261120"
    },
    {
      "label": "body-p1-title",
      "excerpt": "附件四：报价表（招标文件组成部分，模板，不得改动表头）。招标编号 «标识1»。",
      "locator": "pdf:示例项目_2026_智慧园区智能化/01_招标/TENDER_招标公告_ZB-DEMO-2026-014.pdf#p3,c0-118@snapshot-20261120"
    }
  ],
  "annotation": {
    "annotator_code": "A2",
    "annotated_on": "2026-11-20",
    "basis": "verified_document_text"
  },
  "review": {
    "status": "confirmed",
    "redaction": "synthetic",
    "reviewer_code": "R1",
    "reviewed_on": "2026-11-20"
  },
  "usage": "evaluation"
}
```

读法要点：`projectname` 有值且不在 `allowed_unknown_fields` → 预测 null 记漏填；`issuer` 为 `null` **且**在 `allowed_unknown_fields` → 留空不算错，但填写必须是已核实的署名主体，否则按字段错误计分（§4.2）；`bidderentity` 为 `null` 且**不**在该集合 → 填任何值即为错（`ce-pa-3` 附件本身无投标主体证据，SPEC §5.2 第 5 条）；`target_type` 键必须存在。

### 9.5 合成 split manifest 样例

同样**完全虚构**：四条记录、三侧归属、一条声明式移除。文件位置 `split-manifest.json`。

```json
{
  "schema_version": "1.0",
  "split_id": "gs-1-0-0-1",
  "dataset_revision": "1.0.0",
  "generated_on": "2026-11-20",
  "casepack": { "id": "forma-governance-cases", "version": "1.0" },
  "prompt_record_ids": ["gd-000104"],
  "evaluation_record_ids": ["gd-000101", "gd-000103"],
  "removed_records": [
    {
      "record_id": "gd-000102",
      "reason": "prompt_cluster_overlap",
      "counterparty_record_id": "pa-neg-price-volume-01"
    }
  ],
  "notes": "合成演练视图，仅说明结构；全部记录 redaction=synthetic，不代表任何真实样本量或质量结论。"
}
```

对应要求：`gd-000104` 的记录文件须写 `usage = fewshot`，`gd-000101`/`gd-000103` 须 `usage = evaluation` 且都存在于 `records/`；`gd-000102` 可以存在于 `records/`（`usage = excluded`），但绝不可出现在 `evaluation_record_ids`（§5.6）；`counterparty_record_id` 与命中轴同名（cluster ↔ `prompt_cluster_overlap`，§5.2）。

`reason` 与命中轴、`counterparty_record_id` 与被冲突记录的一致性**只是本文 §5.2/§6.2 的人工审计要求**：运行器不校验这两处对应关系（§10.3 A6 已从结构上排除"声明了却仍在评测侧"的形态），所以样例中 `prompt_cluster_overlap` ↔ `cluster` 的对应属于执行者自己核对的一项。

---

## 10. 与评测运行器的接口

本节只界定职责边界。`GoldRecord` / `GoldSplit` / `GoldDataset` 由另一名工程师在 P3-A 评测基础设施中实现，**本文不修改、不规定其内部实现，也不声明其已完成或已验证**。

### 10.1 类型职责

| 类型 | 职责 | 边界（明确不做） |
|---|---|---|
| `GoldRecord` | 一条 gold 期望：`profiles[]`、场景类别与描述、来源身份三轴（簇键 / UUID / SHA）+ 脱敏路径与文件名 + 近重复组、期望状态与项目归属、类别/类型、12 字段 `metadata` 与 `allowed_unknown_fields`、`citations`、标注与审核记录、`usage`；**公开构造器与解码器都跑同一套域检查（`init` 为 `throws`）**，所以不合规记录无法在内存里存在——从代码里生成的夹具也不能绕过脱敏与 rejected 检查，不只是"加载时拒绝"；另提供确定性的文件名家族算法与五条独立性键 | 不做 Provider 调用；不计算指标；不判断自身是否"正确"；**不做文本相似度或阈值计算**（近重复只比组标签，§5.3） |
| `GoldSplit` | 记录级三侧归属（`prompt_record_ids`/`evaluation_record_ids`/`removed_records`）与固定 CasePack 版本引用；强制两侧不相交、移除记录不得留在评测侧、移除 id 不重复 | 不解释期望值；不改写 gold；不决定阈值 |
| `GoldDataset` | 加载 revision 目录（`split-manifest.json` + `records/*.json`）、Schema 校验、一致性核验（`verify`）、与提示侧（shipped CasePack + `usage=fewshot` 记录）的独立性排除、`countableIDs` 计算、分层与缺口 `Report`；常量 `independentTarget = 150`、`stratumTarget = 10`；`meetsIndependentTarget` 只由 `reviewedCountable` 推出 | 不采集样本、不写 CasePack/Prompt、不触发真实扫描或云外发；把 ≥150 与各层 ≥10 作为**报告条件**而非内部通过/失败开关（缺口必须可测量，见 §8.4）；不判定阈值是否获批 |

### 10.2 加载路径

运行器只从 §9.1 的本地 revision 目录读取 `<revision 目录>/split-manifest.json` 与 `<revision 目录>/records/*.json`；不联网、不读 Keychain、不接受调用方内联传入的"单条样本"充当 gold（避免绕过 §6 复核）。仓库内合成夹具若存在，须以 `review.redaction = synthetic` 加载，可驱动 harness 但不参与达标（§8.1）。提示侧的 CasePack 由 `load(directory:)` 自行加载 shipped pack 并作为 `GoldDataset` 的常驻属性（比对与报告必须用同一包，否则两侧对"教过什么"的判断可能不一致），其版本另由 `split-manifest.json` 的 `casepack` 字段固定并进入报告（§7.3 第 2 件）。

### 10.3 校验与拒绝条件

以下情形按实现事实分两类：**A = 该 revision 整体不可用**（Schema 校验失败、解码/构造抛错或 `verify`/`check` 拒绝），**B = 数据集可以加载，但相应记录不计数并进入报告**。

**A 类（整体拒绝，不存在"静默跳过该条"）**

1. `records/` 内混入非记录 JSON，或某条记录缺 `citations`、缺 `target_type` 键、`metadata` 不满 12 键、`profiles` 越枚举或重复、`review.redaction = unredacted`、`review.status = rejected` 却 `usage = evaluation`、代号/日期/摘要不匹配 Schema 模式（`GoldRecord.check` + Schema；构造器同样生效）；
2. 两条记录同号 → `FormaError.invalidOutput`；
3. 记录的 `dataset_revision` 与 manifest 不一致（混版）→ `FormaError.incompatible`；
4. `evaluation_record_ids` 引用目录中不存在的记录 → `FormaError.invalidSource`；
5. `prompt_record_ids` 中的 id 既不属于 shipped CasePack 的 `case_id`，也不属于任何 `usage = fewshot` 记录 → `FormaError.invalidSource`（manifest 不能声称一个从未计算过的隔离）；
6. `GoldSplit` 自身拒绝：同一记录同时出现在 prompt 与 evaluation 两侧、或 `removed_records` 里的记录仍出现在 `evaluation_record_ids`（均 `FormaError.incompatible`）。**因此"已声明排除但仍在评测集"不是合法状态**，§5.2 的移除必须真正落实为两侧清单的修改。

**B 类（加载成功但不计数，报告必须处理）**

7. 仍可计数的评测记录与提示侧存在交集 → 从 `countableIDs` 剔除，并以 `"<record_id>~<counterparty>:<axis>"` 出现在 `Report.undeclaredOverlaps`，`axis` 取值 `cluster|uuid|sha|family|near`；该清单非空即不得发布本报告（§8.2 表 A）。由于 A 类第 6 条排除了"已声明仍在集内"的形态，运行器不再核对 `reason` 与 `axis` 是否对应——那属于 §6.2 checklist 第 8 项的人工审计；
8. `review.status = adjudication_pending` → 不计数，数量进入 `pendingAdjudication`（§4.4）；
9. `sha256`/`near_duplicate_group` 等可选身份键缺省 → 相应轴上没有键，该记录的隔离强度下降，仍须按 §5.5/§5.3 由人工补齐并计入表 A 的 `sha_pending_clusters`。

### 10.4 校验通过后交给指标层与报告层的东西

- 合格记录集合（`countableIDs`）；
- `Report` 字段（实际形态与顺序，共 15 项）：`datasetRevision`、`splitID`、`casePackVersion`、`totalRecords`、`evaluationRecords`、`countableRecords`、`reviewedCountable`、`pendingAdjudication`、`perProfileCountable`、`perCategoryCountable`、`shortfalls`、`undeclaredOverlaps`、`unaccountedRecords`、`meetsIndependentTarget`、`requiredMinimum`；
- **`unaccountedRecords` 与 `undeclaredOverlaps` 语义不同，报告必须分别处理**（§8.2 表 A 末）：前者是排序后的记录 id 列表，指"`records/` 里存在，但 split 既没放进 `evaluation_record_ids`/`prompt_record_ids`、也没写进 `removed_records`"——**没人对它作过决定**，它不进任何计数，所以台账不完整（`GoldDataset.unaccounted` = 目录记录 id 集合减去三处清单之并集）；后者是"**已决定要评分**但该记录与提示侧相交"，它已被从 `countableIDs` 剔除。两者的修复动作也不同：前者按 §5.6 把记录归入三处之一，后者按 §5.2 移出评测侧并写 `removed_records`。**任一列表非空即不得宣称台账完整或发布本报告**——这是本文"目录里没有一条记录处于未登记状态"的要求第一次由代码给出支撑（§3.6、§9.3），不再是纪律条款；
- 本文要求、运行器**不**产出的补充台账（报告必须引用）：文档类别轴与 `ce-*` 轴计数（§2.3）、表 C 簇归属、表 D 依据与脱敏对照（§8.2）、CasePack 案例→项目簇人工核对结果（§5.1）；
- 复现标识（§7.3 三件套）与 Profile `versionKey`。

指标计算、区间与 bootstrap 一律按 PLAN §8.2 由指标层完成，本数据集层不实现、不近似。

### 10.5 规范与实现的同步责任 **（本文件新增约定）**

本文 §4/§9/§10 的字段名、枚举与目录布局以 `GoldRecord`/`GoldSplit`/`GoldDataset` 及 `gold-record-1.0`/`gold-split-1.0` Schema 的现状为准。**改动方负责同步**：任何一方变更结构、枚举或加载布局，必须在同一变更里更新本文对应小节与 §9.4/§9.5 样例；本文不保留旧别名、不做兼容层。

### 10.6 与提示侧的隔离由运行器强制执行

`GoldSplit` 的归属表是提示构造（CasePack 选择）与评测集合的唯一交集判据；评测记录进入 Prompt 属缺陷而非策略（§5.8）。独立性比对必须是确定性字符串轴（§5.3），禁止引入向量检索或模型判断。

---

## 11. 现状与未闭合项（如实登记）

| 项 | 状态 | 缺口 |
|---|---|---|
| 本规范 | 已撰写，待 Owner 与独立复核者评审 | 本文不声称已获批准 |
| 授权真实来源（P1/P2） | **不具备** | P2 §7：缺 Provider 凭据与外发授权、隔离库 UUID、授权 OneDrive 目录 |
| ≥150 合格真实脱敏样本 | **未建立，当前为 0 条** | ROADMAP 记为 P3-B 前置条件之一；须按 §2–§6 实际采集与复核 |
| CasePack 案例→项目簇归属表（§5.1 限度所需人工输入） | **未建立** | 由数据集管理员按 `casepack{id,version}` 逐条核对 24 例后建立 |
| 脱敏判别力前后对照（§3.4） | **未验证** | P2 §5 记为 `BLOCKED`；本文只规定做法，P3-A 只能以替身演练流程 |
| 独立性排除实际执行（§5） | **未执行** | 尚无真实候选集可比对；轴覆盖限度见 §5.1 |
| 缺口台账表 A–D（§8.2） | **未产出** | 依赖上述各项；模板已在本文给出 |
| 质量阈值 | **待批建议值** | PLAN §8.2；Owner 批准前不得称 Gate 通过（本文不重复公式） |
| `gold-split-1.0` Schema 曾把 `generated_on` 指向未定义的 `$defs/date`（悬空 `$ref`），当时任何 split manifest 都无法通过 Schema 校验 | **已修复**：`$defs.date`（`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`）已定义并被 `generated_on` 引用 | 本文 §9.5 样例在该修复后的 Schema 下重新校验通过（见文末核对记录）；本条保留为历史事实，不是开放缺陷 |

---

**本文与实现的核对记录：** 2026-11-12 按当时的 `Sources/FormaCore/Evaluation/GoldRecord.swift`、`GoldSplit.swift`、`GoldDataset.swift` 与 `Sources/FormaCore/Mapping/Schemas/gold-record-1.0.schema.json`、`gold-split-1.0.schema.json` 复核 §4/§5/§8/§10 的字段名、枚举、拒绝条件与报告字段；§9.4 与 §9.5 两个 JSON 样例对上述两个 Schema 重新逐关键字校验通过（`gold-split-1.0` 修复 `$defs/date` 后，`generated_on = "2026-11-20"` 符合 `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`）。本文不声称任何样本已采集、任何审核已完成、任何阈值已批准或任何评测已验收。
