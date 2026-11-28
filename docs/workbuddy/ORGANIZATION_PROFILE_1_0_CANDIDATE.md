# Organization Profile 1.0 Candidate (`forma-org-profile-default`)

> **状态：`CANDIDATE — PENDING OWNER APPROVAL`**  
> **版本**：`1.0.0-candidate.1` (`schema_version: forma-org-profile/1.0`)  
> **机器可校验配置**：[organization-profile-1.0.candidate.json](profiles/organization-profile-1.0.candidate.json)  
> **安全约束**：`auto_activate = false`，`grants_execution = false`。候选 Profile 不得自动激活，不包含任何真实客户、路径、报价或私有业务数据；本文档全部示例均为合成数据。

本候选规范依据 `docs/SPEC.md` (v0.1.2) 与 `docs/I1-B1-CAPABILITY-DISCOVERY.md` 实测字段定义编制，作为 Owner 审阅与程序确定性校验的单一权威候选。

---

## 1. Metadata 职责边界（Physical / Business / Management）

| 层级 | 权威来源 | LLM 权限 | 包含字段 |
|---|---|---|---|
| **Physical Metadata** | 确定性 Snapshot 与文件系统 | **只读，禁止 LLM 修改或伪造** | `source_id`、`source_root_id`、`source_relative_path`、`source_sha256`、`byte_size`、`mtime`、`extension`、`fs_state`、`is_dataless`、`magic_mismatch` |
| **Business Metadata** | Approved Profile Schema + 正文/上下文证据 | **仅可提出带证据的候选值；未知填 `null`，禁止编造** | 下表 §2 全部业务字段（经程序校验后生效） |
| **Management Metadata** | 确定性程序与持久化 Ledger | **禁止 LLM 写入** | `profile_id`、`profile_version`、`profile_hash`、`snapshot_hash`、`plan_hash`、`approval_record`、`devonthink_uuid`、`devonthink_database_uuid`、`devonthink_location`、`publication_status`、`readback_verified_at` |

---

## 2. 完整 Business Metadata 字段表

优先复用历史 `Project_Archive` 12 个受治理 Identifier，并补充项目身份、业务年度、文档角色、版本、状态、业务日期、厂商关系与版本关联字段：

| Identifier | 中文名称 | 类型 | 必填性（按分区） | 受控值 / 格式 | 未知值处理 | DT 字段映射 |
|---|---|---|---|---|---|---|
| `partition` | 所属分区 | `enum` | 全分区必填 | `project_archive` / `vendor_library` / `shared_reference` / `triage` | 无法归属时降级 `triage` | 无（映射为 `scope/*` Tag） |
| `project_id` | 项目稳定编号 | `string` | `project_archive` 必填；其余可空 | `^PRJ-\d{4}-\d{3}$` | 缺失则转入 `triage` | 无（入 Ledger） |
| `projectname` | 项目名称 | `string` | `project_archive` 必填；其余可空 | 最长 120 字符 | `null`，严禁编造 | `projectname` (`string`) |
| `business_year` | 业务发生年度 | `string` | `project_archive` 必填；其余可空 | `^\d{4}$`（与 `completionyear` 区分） | `null`，不得用 `completionyear` 替代 | 无（映射为 `year/YYYY` Tag） |
| `completionyear` | 归档完成年份 | `string` | 全分区可选 | `^\d{4}$` | `null`；缺省时阻断“归档完成”判定 | `completionyear` (`string`) |
| `bidderentity` | 投标主体 | `string` | 可选 | 最长 80 字符 | `null`（仅限明确证据或已核实项目上下文） | `bidderentity` (`string`) |
| `department` | 业务部门 | `string` | 可选 | 最长 60 字符 | `null`（仅限已核实组织上下文） | `department` (`string`) |
| `salesowner` | 销售负责人 | `string` | 可选 | 最长 60 字符 | `null`，禁止从相似文件复制 | `salesowner` (`string`) |
| `endcustomer` | 最终客户 | `string` | 可选 | 最长 100 字符（区分投标主体/代理/出具方） | `null` | `endcustomer` (`string`) |
| `biddeadline` | 投标截止日期 | `string` | 可选 | `YYYY-MM-DD` 单行文本 | `null`（需明确截止语义证据） | `biddeadline` (`string`) |
| `tenderreference` | 招标编号 | `string` | 可选 | 最长 80 字符 | `null`（须确认为采购/招标编号） | `tenderreference` (`string`) |
| `bsdcode` | BSD 标识 | `string` | 可选 | 最长 60 字符（不得将日期误判为 BSD） | `null` | `bsdcode` (`string`) |
| `documentcategory` | 文档类别 | `enum` | 全分区必填 | `01_招标文件`..`05_报价与商务`、`99_待分类`、`VL_厂商通用资料`、`SR_公司共享资料` | 降级 `99_待分类` | `documentcategory` (`string`) |
| `documenttype` | 文档类型 | `string` | 可选 | 最长 60 字符（如 `招标文件`/`技术标`/`Datasheet`） | `null` | `documenttype` (`string`) |
| `issuer` | 出具厂商/主体 | `string` | 可选 | 最长 100 字符（需署名/签章等法律归属依据） | `null`（仅品牌线索不足时置空） | `issuer` (`string`) |
| `document_role` | 文档业务角色 | `enum` | 全分区必填 | 见 §5 Document Role Taxonomy（20 项互斥） | `unclassified_review` | 无（映射为 `role/*` Tag） |
| `document_version` | 文档版本 | `string` | 可选 | `^v\d+\.\d+$` | `null`（无明确版本时不编造） | 无（入 Ledger + 命名） |
| `document_status` | 文档状态 | `enum` | 全分区必填 | `draft` / `revised` / `final` / `signed` / `superseded` / `archived` / `unknown` | `unknown` | 无（映射为 `status/*` Tag） |
| `document_business_date` | 文档业务日期 | `string` | 可选 | `YYYY-MM-DD` | `null`（禁止以文件 `mtime` 充当业务日期） | 无（入 Ledger + 命名） |
| `vendor_name` | 厂商规范名 | `string` | `vendor_library` 必填；其余可选 | 最长 60 字符 | `null`（`vendor_library` 缺失转 `triage`） | 无（映射为 `vendor/*` Tag） |
| `vendor_relationship` | 厂商关系 | `enum` | 可选 | `oem_authorizer` / `quoting_supplier` / `product_publisher` / `delivery_partner` / `none` / `unknown` | `unknown` | 无（入 Ledger） |
| `version_group_id` | 版本组标识 | `string` | 可选 | `^VG-[A-Za-z0-9_-]{6,40}$` | `null`（单版本文件不创建） | 无（入 Ledger） |
| `supersedes_source_id` | 取代前版 ID | `string` | 可选 | 指向已验证前版的 `source_id` | `null` | 无（入 Ledger） |

---

## 3. 项目身份、主体关系与版本关联

- **项目注册表（Project Registry）**：以程序生成的 `project_id`（`PRJ-YYYY-NNN`）为主键，记录规范 `projectname`、别名、`endcustomer`、`bidderentity`、`department`、`salesowner`、`business_year`、`completionyear`、`tenderreference`、`bsdcode`、`biddeadline`。
- **N:1 关系约束**：每份归入 `01_项目档案` 的文档必须有明确证据关联到唯一 `project_id`；若证据同时命中多个项目或与注册表冲突，一律进入 `99_待确认资料/conflict_or_ambiguous`。
- **通用与共享边界**：`02_厂商通用资料` 与 `03_公司共享资料` 的 `project_id` **必须为 `null`**，严禁为凑齐目录层级而强行绑定项目。
- **版本与状态**：同一文档的修订版保留独立物理文件，通过 `version_group_id` 与 `supersedes_source_id` 关联；被取代的旧版本在管理层标记为 `status/superseded`，绝不静默覆盖或删除。

---

## 4. 目录结构与分区处置规则（最大深度 4 层）

```text
<DestinationRoot>/
├── 01_项目档案/
│   └── {business_year}/
│       └── {project_id}_{project_short}/
│           ├── 01_招标文件/
│           ├── 02_投标文件/
│           ├── 03_厂商支持文件/
│           ├── 04_技术资料与编制素材/
│           ├── 05_报价与商务/
│           └── 99_待分类/
├── 02_厂商通用资料/
│   └── {vendor_name}/
│       ├── Datasheet/
│       ├── Whitepaper_Solution/
│       ├── Manual_Guide/
│       └── General_Material/
├── 03_公司共享资料/
│   ├── 公司资质/
│   ├── 通用模板与规范/
│   └── 历史案例素材/
└── 99_待确认资料/
    ├── unassigned_project/
    ├── conflict_or_ambiguous/
    ├── unreadable_or_corrupt/
    └── extension_mismatch/
```

**分区与反例处置规则（继承 `docs/SPEC.md` §5.1）**：
1. 项目名称含“采购”不代表归 `01_招标文件`；己方投标稿归 `02_投标文件`。
2. `BID_CONTENTS` 技术对标表若已填报品牌型号与响应参数，归 `02_投标文件`；不可仅凭文件名前缀归 `04`。
3. 招标方下发的**空白报价/响应模板**归 `01_招标文件`；独立厂商/渠道报价（含单价/折扣/总价）归 `05_报价与商务`；投标文件中的商务标/价格分册归 `02_投标文件`。
4. 项目专属原厂授权/售后承诺归 `03_厂商支持文件`；通用产品规格书、白皮书、安装/激活指南归 `02_厂商通用资料`（不绑定单一项目）。
5. 跨项目公司资质与通用模板归 `03_公司共享资料`。
6. 证据不足、多项目冲突、损坏不可读或扩展名与魔数不匹配（`extension_mismatch`）的文件一律进入 `99_待确认资料/{triage_reason}`。

---

## 5. Document Role Taxonomy（20 项互斥角色）

| `document_role` | `role_code`（命名片段） | 默认分区 | 默认 `documentcategory` | 关键判别边界 |
|---|---|---|---|---|
| `tender_notice` | `招标公告` | `project_archive` | `01_招标文件` | 买方/代理发布之公告 |
| `tender_rfp` | `招标文件` | `project_archive` | `01_招标文件` | 买方正式招标/询价/需求书 |
| `tender_addendum` | `澄清补遗` | `project_archive` | `01_招标文件` | 买方澄清、补遗、答疑 |
| `tender_blank_template` | `空白模板` | `project_archive` | `01_招标文件` | 随标书下发的空白表；已填报归 `02` |
| `bid_technical` | `技术标` | `project_archive` | `02_投标文件` | 面向特定客户/项目的投标技术方案 |
| `bid_commercial` | `商务标` | `project_archive` | `02_投标文件` | 投标商务分册（非 `05`） |
| `bid_pricing` | `价格分册` | `project_archive` | `02_投标文件` | 投标正式报价分册 |
| `bid_compliance_matrix` | `技术对标表` | `project_archive` | `02_投标文件` | 已填报型号/偏差的对标响应表 |
| `vendor_authorization` | `原厂授权` | `project_archive` | `03_厂商支持文件` | 项目专属原厂授权函（MAF） |
| `vendor_commitment` | `厂商承诺` | `project_archive` | `03_厂商支持文件` | 厂商项目售后/维保/唯一性承诺 |
| `vendor_quote` | `厂商报价` | `project_archive` | `05_报价与商务` | 独立供应商/渠道报价单 |
| `vendor_datasheet` | `规格书` | `vendor_library` | `VL_厂商通用资料` | 通用产品参数规格书 |
| `vendor_whitepaper` | `白皮书方案` | `vendor_library` | `VL_厂商通用资料` | 通用白皮书、彩页或通用方案 |
| `vendor_manual` | `产品手册` | `vendor_library` | `VL_厂商通用资料` | 产品手册、部署或激活指南 |
| `internal_qualification` | `公司资质` | `shared_reference` | `SR_公司共享资料` | 跨项目公司证照、体系认证 |
| `internal_template` | `内部模板` | `shared_reference` | `SR_公司共享资料` | 可复用内部标书模板与规范 |
| `internal_review_note` | `内部评审` | `project_archive` | `04_技术资料与编制素材` | 项目内部勘测、编写与评审记录 |
| `contract_agreement` | `合同协议` | `project_archive` | `05_报价与商务` | 项目合同或补充协议 |
| `acceptance_report` | `验收文档` | `project_archive` | `05_报价与商务` | 项目交付验收单/终验报告 |
| `unclassified_review` | `待确认` | `triage` | `99_待分类` | 证据不足、冲突、损坏或失配 |

---

## 6. 文件命名模板与规范化规则

- **生成权威**：由确定性程序按已批准 Profile 模板渲染；LLM **严禁**自由命名。
- **保留合规原名**：`keep_if_already_conforming = true`；已符合模板正则的文件保留原名。
- **分区模板**：
  - `project_archive`：`{project_id}_{role_code}_{title_short}[_{vendor_name}][_{date_compact}][_{document_version}][_{status_tag}].{ext}`
  - `vendor_library`：`{vendor_name}_{role_code}_{title_short}[_{date_compact}][_{document_version}].{ext}`
  - `shared_reference`：`共享_{role_code}_{title_short}[_{date_compact}][_{document_version}].{ext}`
  - `triage`：`待确认_{triage_reason}_{original_stem}.{ext}`
- **格式与清洗**：分隔符 `_`；文件名日期 `YYYYMMDD`；版本 `v<major>.<minor>`；Unicode `NFC` 归一化；替换非法字符 `[\/:*?"<>|\x00-\x1f]` 为 `-`；空白折叠为 `-`；单文件名 `<=120` 字符且 `<=180` UTF-8 字节。
- **扩展名保护**：始终保留原始扩展名，严禁在 `extension_mismatch` 时擅自改写扩展名。
- **未知字段与碰撞**：可选 token 为 `null` 时直接省略（绝不输出 `_null_`）；目标重名碰撞时追加 `_dup{n}` 或 `_{sha6}` 并记录于预览，绝不覆盖。

---

## 7. Tags 白名单、派生与冲突处理

- **白名单命名空间**：仅允许 `role/*`、`status/*`、`year/*`、`vendor/*`、`scope/*`、`review/*`。
- **确定性派生**：由程序从已校验的 Business Metadata 派生（如 `document_role` → `role/*`、`document_status` → `status/*`、`partition` → `scope/*`、`business_year` → `year/YYYY`、`vendor_name` → `vendor/<slug>`）。
- **冲突处理**：写入 DEVONthink 时采用合并语义，保留用户既有非 Forma 标签；若目标记录上已存在与新派生结果冲突的 Forma 受控命名空间标签，**阻断该记录自动发布并标为 `REVIEW`**，不静默覆盖。

---

## 8. Metadata ↔ DEVONthink 4.4.2 Mapping 对照表

- **传输与模式**：优先 DEVONthink 4.4.2 内置 MCP（`localhost:8420`），采用 **Index** 原件（禁止 Import 复制字节），写入模式为 `merge`，**强制执行 `list_custom_metadata_fields` 预检 + 独立回读**。
- **严格白名单**：仅允许写入以下 12 个原生 `string` 字段；未知 key 一律拒绝写入（防止 `set_record_custom_metadata` 自动创建数据库字段）。

| Profile Business Field | DEVONthink Identifier | 现场中文 Label | DT 原生类型 | 未入 DT 自定义字段的去向 |
|---|---|---|---|---|
| `projectname` | `projectname` | 项目名称 | `string` | — |
| `completionyear` | `completionyear` | 完成年份 | `string` | — |
| `bidderentity` | `bidderentity` | 投标主体 | `string` | — |
| `department` | `department` | 业务部门 | `string` | — |
| `salesowner` | `salesowner` | 销售负责人 | `string` | — |
| `endcustomer` | `endcustomer` | 最终客户 | `string` | — |
| `biddeadline` | `biddeadline` | 投标截止日期 | `string` | — |
| `tenderreference` | `tenderreference` | 招标编号 | `string` | — |
| `bsdcode` | `bsdcode` | BSD标识 | `string` | — |
| `documentcategory` | `documentcategory` | 文档类别 | `string` | — |
| `documenttype` | `documenttype` | 文档类型 | `string` | — |
| `issuer` | `issuer` | 出具厂商 | `string` | — |
| `project_id`, `business_year`, `document_role`, `document_version`, `document_status`, `document_business_date`, `vendor_name`, `vendor_relationship`, `version_group_id`, `supersedes_source_id` | *（不写入 DT Custom Metadata）* | — | — | 持久化于 Forma 本地 Ledger，并按白名单规则投影至文件名与 DT Tags（`role/*`, `status/*`, `year/*`, `vendor/*`, `scope/*`） |

---

## 9. 重复文件、版本与 Profile 生命周期

- **精确字节重复（`source_sha256`）**：绝不自动删除或覆盖。同项目/同分区内重复标为 `REVIEW/duplicate-content`；跨项目复用保持独立记录与路径，不默认创建 Replicant。
- **语义版本**：全部版本独立保留，通过 `version_group_id` + `supersedes_source_id` 关联，旧版补标 `status/superseded`。
- **Profile 生命周期**：采用 SemVer 与规范化 JSON SHA-256（`profile_hash`）；仅 Owner 显式批准后方可从 `candidate` 转为 `~/.forma-workbuddy/profiles/` 中的 `active`；任何 `profile_hash` 变更自动使未执行计划失效；既有已归档文件/记录不随 Profile 更新隐式迁移。

---

## 10. 代表性合成命名与目录示例（8 类典型场景）

| 场景 | 原始相对路径（合成） | 目标目录 | 确定性渲染文件名 | 关键 Metadata 与 DT Tags |
|---|---|---|---|---|
| 1. 招标文件 | `inbox_batch_01/采购需求书_终稿.pdf` | `01_项目档案/2026/PRJ-2026-001_星云网络升级/01_招标文件` | `PRJ-2026-001_招标文件_网络升级采购需求_20261110_v1.0_final.pdf` | `projectname=星云数据中心网络升级项目`, `endcustomer=星云科技有限公司`, `tenderreference=XY-ZB-2026-018`, `biddeadline=2026-12-15`, Tags: `role/tender`, `status/final`, `year/2026`, `scope/project` |
| 2. 投标响应 | `inbox_batch_01/投标技术方案_草稿.docx` | `01_项目档案/2026/PRJ-2026-001_星云网络升级/02_投标文件` | `PRJ-2026-001_技术标_核心交换机响应方案_20261118_v1.0_draft.docx` | `bidderentity=示例集成有限公司`, `documentcategory=02_投标文件`, Tags: `role/bid`, `status/draft`, `year/2026`, `scope/project` |
| 3. 原厂授权 | `inbox_batch_01/scan_auth_003.pdf` | `01_项目档案/2026/PRJ-2026-001_星云网络升级/03_厂商支持文件` | `PRJ-2026-001_原厂授权_核心交换机项目授权_VendorAlpha_20261119_signed.pdf` | `issuer=示例网络设备有限公司`, `documentcategory=03_厂商支持文件`, Tags: `role/vendor-auth`, `status/signed`, `vendor/vendoralpha`, `scope/project` |
| 4. 厂商报价 | `inbox_batch_01/渠道报价表.xlsx` | `01_项目档案/2026/PRJ-2026-001_星云网络升级/05_报价与商务` | `PRJ-2026-001_厂商报价_核心设备配置报价_VendorAlpha_20261120_v1.0_final.xlsx` | `issuer=示例分销科技有限公司`, `documentcategory=05_报价与商务`, Tags: `role/vendor-quote`, `status/final`, `vendor/vendoralpha`, `scope/project` |
| 5. 内部资料 | `inbox_batch_01/ISO27001证书扫描.pdf` | `03_公司共享资料/公司资质` | `共享_公司资质_ISO27001信息安全管理体系证书_20260301.pdf` | `project_id=null`, `documentcategory=SR_公司共享资料`, Tags: `role/internal-shared`, `status/signed`, `year/2026`, `scope/shared-reference` |
| 6. 通用产品资料 | `inbox_batch_01/S9000_Datasheet_EN.pdf` | `02_厂商通用资料/VendorAlpha/Datasheet` | `VendorAlpha_规格书_S9000系列交换机规格书_20260815_v2.1.pdf` | `project_id=null`, `documentcategory=VL_厂商通用资料`, `documenttype=Datasheet`, Tags: `role/technical-ref`, `status/final`, `vendor/vendoralpha`, `scope/vendor-library` |
| 7. 修订版本 | `inbox_batch_01/投标技术方案_修订二版.docx` | `01_项目档案/2026/PRJ-2026-001_星云网络升级/02_投标文件` | `PRJ-2026-001_技术标_核心交换机响应方案_20261125_v2.0_revised.docx` | `version_group_id=VG-PRJ2026001-TECH`, `supersedes_source_id=src-ex-02-placeholder`, Tags: `role/bid`, `status/revised`, `scope/project` |
| 8. 无法归属文档 | `inbox_batch_01/未命名报价草稿.xlsx` | `99_待确认资料/unassigned_project` | `待确认_unassigned_project_未命名报价草稿.xlsx` | `project_id=null`, `documentcategory=99_待分类`, Tags: `status/unknown`, `scope/triage`, `review/unassigned-project` |
