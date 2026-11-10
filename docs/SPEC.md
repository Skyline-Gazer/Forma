# Forma — 产品与技术规范（SPEC）

**版本：** v0.1.1  
**状态：** FROZEN — Owner 已确认，允许进入 PLAN 编制；尚未批准实施  
**日期：** 2026-11-10  
**产品仓库：** https://github.com/Skyline-Gazer/Forma  
**参考来源：** `Skyline-Gazer/tmp@cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b`  
**授权范围：** 已授权 Agent 在 Forma 仓库编制 PLAN；**未授权创建 GitHub Project、Issues 或开始产品开发**。

## 1. 产品定位

Forma 是一款 **macOS 原生、AI 驱动的非标准文件资料标准化与 DEVONthink 归档应用**。其价值不在“复制文件”，而在理解混乱目录、不同文件用途、项目归属及业务实体，将其转换为可验证、可执行的标准化映射。

**核心原则：程序获取事实 → AI 理解并生成映射 → 程序校验并执行 → DEVONthink MCP 回读验收。** AI 不直接执行数据库写入。

目标：降低人工逐文件映射成本；保留原始内容、版本和可追溯关系；避免错误推断或不必要的数据副本。非目标：通用跨平台文档管理器、完全自治的数据库操作 Agent、对整个档案进行独立 RAG 重建。

## 2. 已批准的产品决策

| 主题 | 决策 |
|---|---|
| 平台 | 仅 macOS |
| 技术栈 | Swift 6、SwiftUI，必要时 AppKit；不采用 Rust/Tauri |
| 状态与规则 | SQLite（建议 GRDB）、版本化 JSON Schema 与案例包 |
| 文件哈希 | CryptoKit 原生增量 SHA-256；不开发 NPU/GPU 加速 |
| DEVONthink | 优先官方 MCP stdio；经验证的 AppleScript 仅作补充 |
| AI | 可配置模型 API，结构化输出，项目级上下文映射 |
| 案例 | 20–30 条精选正例、反例、拒绝猜测案例；Few-shot，不做模型训练 |
| RAG | 不部署框架、Embedding、Vector DB；历史上下文仅按需经 MCP 查询 |
| Profile A | Project Archive：项目制招投标资料 |
| Profile B | Vendor Library：独立厂商资料，**不强制绑定项目** |
| 去重共享 | 同库、共享元数据与分类语义完全兼容且能力实测可用时可考虑 Replicant（非默认路径）；冲突则独立记录 |
| Prototype | **先验证 AI Mapping 质量，再完成实际 Import 闭环** |
| 流程授权 | 先 SPEC → Owner 确认 → Agent 推 PLAN → 一次复核 → 单独批准后建立 Project |

## 3. 使用场景

### 3.1 项目档案

用户选择 OneDrive 或本地来源目录。Forma 收集目录树、文件清单、必要的文件属性；AI 理解项目边界、客户、投标主体、年份和各文件业务用途。程序校验生成的 Manifest，GUI 显示目标 Group、元数据和证据。后续版本由执行器通过官方接口导入并回读。

### 3.2 独立厂商资料

例如 H3C/Dell 的 **Spec Sheet、Datasheet、Whitepaper、Solution、Brochure、Product Manual、Deployment Guide**，可能没有项目。AI 识别文档类型、厂商品牌与可确认的出具方，使用 Vendor Library Profile 归档。不能为了满足当前 `Project_Archive` 结构而虚构 `projectname`。

同名 `Solution` 文件可能是通用方案，也可能是客户专用投标技术方案；**文档类型与业务用途是两个不同维度**。

### 3.3 跨项目复用

同一 `file_a.pdf` 可用于 Project A 和 Project B。需要先区分“字节内容相同”“是同一条档案记录”“在不同项目中被引用”，不能单凭 SHA-256 自动合并业务记录。满足约束时以 DEVONthink Replicant 多处引用，其他情况保持独立副本与来源证据。

## 4. 体系架构与职责

```text
SwiftUI（Workspace / Mapping / Exceptions / Settings）
                         │
Swift Core（任务编排、SQLite、权限、模型 Provider）
                         │
Scanner → Context Builder → AI Mapper → Validator
                                      │
                             Standardized Manifest
                                      │
                           Executor（后续阶段）
                                      │
                       DEVONthink MCP Adapter
                                      │
                        独立查询、回读与验收
```

- **Scanner：** 递归枚举路径，生成不可由 AI 伪造且跨不变扫描稳定的 `source_id`、相对路径、名称、扩展名、大小、时间戳、云端占位状态。扫描阶段不强制读取大文件全文或计算所有 SHA。身份与变更快照契约见 §4.1。
- **Context Builder：** 先基于目录邻近性、命名、文件簇与同批上下文生成项目候选，再将候选与已有 DEVONthink 项目做只读对齐；未能匹配的候选标为 `unconfirmed`。不得把既有项目名称列表当作当前来源的事实真值，也不得假设固定目录层级。
- **AI Mapper：** 识别业务语义，提出项目/文档类型/分类/关键元数据/关系候选，并附字段级证据、冲突与未知项。模型进程不持有数据库写入能力、MCP 写工具句柄或可调用写工具清单；写权限仅由独立 Executor/Adapter 入口持有。
- **Validator：** 验证 Profile、Schema、字段格式、枚举、证据、冲突、权限；对不合格映射保留待处理状态。
- **Executor：** 唯一写入者，消费已验证、带版本与快照指纹的 Manifest；对异常可跳过，不能悄悄重判 AI 映射。
- **DEVONthink Adapter：** 统一处理 MCP 的启动、stdio/JSON-RPC、批量调用、超时、断连、回读、能力检测。公开 ReadOnlyClient（显式工具白名单）和 WriteClient（Executor 独享）两个接口；工具层拒绝越权调用。
- **SQLite：** 保存任务、映射、摘要缓存、执行账本、案例与必要关联，不复制全部 DEVONthink 档案正文，不以本地库替代 DEVONthink 对实际记录的权威性。

### 4.1 来源身份、快照与重扫契约（Prototype 阻塞项）

- `source_id` 是**扫描来源的持久化逻辑身份**，不是内容哈希、DEVONthink UUID，也不是每轮随机生成的任务 ID。首次发现文件时由程序分配稳定 ID（例如 UUIDv7），在 SQLite 保存 `source_root_id + normalized_relative_path → source_id` 的唯一映射；重复扫描相同注册来源与相对路径，复用原 ID。`source_root_id` 是用户注册的持久来源标识，不依赖当前卷名。需考虑 Unicode 规范化、大小写敏感性和路径分隔符；路径映射按来源卷实际语义匹配。
- 同路径文件内容改变时，`source_id` 默认**不变**，而 `snapshot_fingerprint` 与内容版本更新，旧 Manifest 必须失效。`snapshot_fingerprint` 由可获取的大小、mtime、文件身份/版本标识与必要时 SHA-256 组成；不能把 mtime 或 inode 单独当作不可篡改内容证据。
- 文件移动/重命名：有可靠 File Provider 标识或稳定文件 ID 且能排除冲突时，可以保留原 `source_id` 并更新路径；否则按新来源条目处理，旧条目标记 missing/moved-candidate，不自动认定为相同档案，使用哈希和 Ledger 关联去重。跨卷/云端重建 inode 不得导致静默误关联。
- 重新扫描与进程重启必须使用同一持久化状态；即使 SQLite 遗失，也不能直接重新导入，Executor 在写入前还需查询真实 DEVONthink 和已有导入账本。源路径存在并非已完成云端 hydration。
- 输入快照改变后，不得继续执行基于旧快照的 Manifest；需重新提取证据并重新验证受影响文件。

### 4.2 只读与写入隔离（Prototype 阻塞项）

- Prototype 可且应使用只读 MCP 查询对照既有文件和历史档案；写入操作**全部禁止**，包括测试库写入。只读测试需使用指定的可丢弃/隔离测试数据库，避免对生产档案做任何写入。
- 只读 Adapter 只包含明确列举的查询工具，不接受任意名称的 MCP tool call 透传；模型获得的是已校验的结构化搜索结果而非可执行工具句柄。
- Import 阶段由 Executor 单写者串行协调同一来源与同一目标 UUID 的操作；并发可用于只读扫描、文件内容提取和 AI 请求，但同一记录写入须加互斥/事务性 Ledger 协调。MCP 超时不能视为写入失败，必须回读判定再继续。

## 5. Mapping Profile 设计

每个 Profile 必须数据化、版本化，包含目标数据库、目录布局、分类枚举、字段约束、允许未知值的规则、相关示例包和执行政策。不得将 Project Archive 的六分类硬编码为 Forma 全局永久规范。

### 5.1 Project Archive v1

当前分类：

| Group | 业务语义 |
|---|---|
| `01_招标文件` | 采购方发布的招标/询价/采购需求，以及已确认属于采购附件的空白模板 |
| `02_投标文件` | 正式或在编的投标/响应、技术标、商务标、价格分册、填报完成的技术响应表 |
| `03_厂商支持文件` | 原厂授权、独家提供者声明、厂商项目承诺等 |
| `04_技术资料与编制素材` | 通用规格书、白皮书、彩页、手册、通用技术方案及复用素材 |
| `05_报价与商务` | 独立厂商/渠道报价、价格评估与报价明细，不包括投标文件中的商务分册 |
| `99_待分类` | 缺乏可靠证据、格式不可读或业务类别冲突 |

关键业务反例：

- 项目名称含“采购”不代表文件一定是 `01`；实际投标稿归 `02`。
- `BID_CONTENTS` 技术对标表若填写品牌型号、实际参数及满足/偏差，应归 `02`，不能因为前缀而机械归 `04`。
- 招标方下发的**空白报价模板**属于采购附件，可归 `01`；已有实际单价/折扣/总价的独立报价才考虑 `05`。
- 商务标、投标价格分册归 `02`；不要按“商务”两个字归 `05`。
- 厂商项目授权/售后承诺归 `03`；操作性的激活授权指南可能归 `04`。
- `TENDER_`、`BID_`、目录名、文件扩展名均为线索，不是不可推翻的定论。

### 5.2 原生 Custom Metadata

第一版沿用 Project Archive 已治理的 **12 个字段**，不自动创建新字段，不改变稳定英文 Identifier，显示名称继续由 DEVONthink 使用中文：

`projectname`、`completionyear`、`bidderentity`、`department`、`salesowner`、`endcustomer`、`biddeadline`、`tenderreference`、`bsdcode`、`documentcategory`、`documenttype`、`issuer`。

- 这些字段的**实际中文 Label、原生数据类型和读写能力**应在实现前从已确认的现场治理配置核对；不得凭推测创建或重命名。
- `completionyear` 指归档完成年份，不能从文档封面年份、产品版本年或投标日期直接得出。
- `biddeadline` 当前是 `YYYY-MM-DD` **单行文本**，首版不进行 Date 类型迁移。
- 投标主体 `bidderentity`、最终客户 `endcustomer`、出具方 `issuer` 是不同角色；品牌名不必然等于法律出具方。
- `documentcategory` 对独立记录应与实际所在 Group 一致；**Replicant 仅适用于其所有父组的类别、项目记录级字段等语义完全兼容的少数情况，并非默认执行路径**。类别、负责人、项目名称冲突时一律新建独立记录；不能假装共享记录可按父组存不同分类值。
- 不能凭相似文件的元数据补写当前文件缺少证据的主体、销售、期限、项目编号。

### 5.2.1 Project Archive 的 12 字段证据与可空约束

以下为 **Forma 映射层** 的最低约束，不擅自改变现有 DEVONthink 字段类型或定义。`required` 指允许自动确认某类目标映射前必须证据成立，不等同于所有业务文件都必须非空。字段名称使用实际内部 Identifier，原生显示名以现场定义为准。

| Identifier | 映射约束 | 自动推断规则与空值 |
|---|---|---|
| `projectname` | Project Archive 必须有已确认的目标项目关联 | 可由来源项目目录与项目文档交叉证实；存在冲突不自动确认 |
| `completionyear` | Project Archive 需可确定归档完成年 | 四位年；不得用文件版本年、投标日期直接替代，未知留空并标记阻断归档决策 |
| `bidderentity` | 可选 | 只能从明确的投标主体证据或已核实项目上下文继承，未知 null |
| `department` | 可选 | 只能从已核实的来源组织上下文继承，未知 null |
| `salesowner` | 可选 | 只能从已核实的来源组织上下文继承，未知 null |
| `endcustomer` | 可选 | 不得混同出具方、代理机构、投标主体，未知 null |
| `biddeadline` | 可选 | 文本 `YYYY-MM-DD`，须有截止日期语义的证据，未知 null |
| `tenderreference` | 可选 | 须确认是采购/招标编号而不是其他内部编码，未知 null |
| `bsdcode` | 可选 | 须确认 BSD 是内部编号或指定规则；不能将日期推断为 BSD 编号，未知 null |
| `documentcategory` | 已验证归档必须存在 | 必须匹配目标 Group；未决文件按 Profile 的待分类策略 |
| `documenttype` | 可选 | 从标题/内容确认细分类型，如 Datasheet、授权函等，未知 null |
| `issuer` | 可选 | 法律出具主体须有署名、签章或其他明确依据；品牌线索不足时 null |

共享 Replicant 的每个记录级字段只有一个值。Vendor Library 可以复用字段契约但须允许无项目归属，独立 Profile 决定必填约束；严禁为满足 Project Archive 的必填而补造项目。

### 5.3 Vendor Library v1

- 允许 `projectname = null`，支持文件类型如 Datasheet / Spec Sheet / Whitepaper / Solution / Brochure / Manual / Guide。
- 可识别厂商品牌、具体出具主体、产品系列与文档类型，但不可未经证据确认法律主体。
- **具体物理目录层次和目标数据库选择留待 PLAN 技术设计**，不能视为当前已创建的 DEVONthink 数据库；不同数据库不能使用同库 Replicant 假设。
- Vendor Library 的资料不必强行映射到 Project Archive 的 `04_技术资料与编制素材`；跨 Profile 可引用但必须遵守目的库和记录语义。

## 6. AI Mapping 与案例库

### 6.1 工作机制

1. 程序读取完整文件清单和目录树，先组织“项目级上下文”，而非每个文件重复调用 AI。
2. 向模型提供目标 Profile Schema、字段约束、**约 20–30 条精选典型案例**和该批文件上下文。
3. 模型使用受约束的 JSON 输出，明确每个文件用途、归属、元数据、来源证据与不确定性。
4. 如果不确定，程序按需提取少量证据：PDF 标题/前几页、DOCX 正文、XLSX 结构与必要单元格、相关同项目资料；再做一次针对性复判。**Prototype 必须实际覆盖 PDF/DOCX/XLSX 的最小只读抽取**，其他格式和 OCR 完整支持可延后；无法可靠提取时记录能力边界，不虚称正文已读取。
5. 如仍缺乏上下文，可选经 MCP 检索既有 DEVONthink 分类和元数据；**不部署 RAG 平台、向量数据库或本地 Embedding 模型**。
6. 仍无法确认的字段为 `null`，归属不明确的文件保持待分类/异常；绝不将 AI 置信度当作事实证据。

### 6.2 典型案例管理

从 `tmp` 已治理的 991 条记录及后续 71 条纠正材料中筛选正例、反例、冲突案例、拒绝猜测案例。参考材料报告存在：78 条经有限正文核验、664 条文件名/路径高置信、143 条中置信、56 条仅历史标签、50 条异常；**全部不能自动等同人工金标准**。

案例至少包含：场景标签、脱敏后的输入文件名和目录上下文、明确证据、期望映射、为什么不选其他类别、证据等级、来源版本。不得把全部 991 条硬塞进 Prompt，也不得把未核实的 AI 输出自动追加为 gold examples。

Prototype 应从同一批候选资料中另外划出**不进入提示示例的独立评测集**，防止“测试题已经出现在参考答案里”。

### 6.3 标准化 Manifest

AI 只能提出语义部分，原始文件身份由程序产生。结构示意：

```json
{
  "schema_version": "1.0",
  "profile_id": "project-archive.v1",
  "source_id": "persisted-scanner-identity",
  "source_relative_path": "folder/file.pdf",
  "target": {
    "database": "Project_Archive",
    "projectname": "Example Project",
    "documentcategory": "03_厂商支持文件"
  },
  "documenttype": "Vendor Authorization",
  "metadata": {
    "issuer": null,
    "bidderentity": null
  },
  "associations": [],
  "decision": {
    "state": "mapped",
    "confidence": "medium",
    "evidence": [
      { "field": "documenttype", "source": "filename", "locator": "file.pdf" }
    ],
    "conflicts": []
  }
}
```

正式 Schema 必须明确 `unknown`、`hold`、`mapped`、`validated` 及各字段可空语义。不得让 AI 生成或替换源 ID、DEVONthink UUID、文件 Hash 或经系统确认的文件属性。模型返回内容作为不可信输入处理。

**Evidence 契约：** `source` 枚举 `filename | path | content | sibling | fs_metadata | mcp`；每条证据包含 `field`、`source`、`locator`（文件相对路径/记录 UUID；正文证据额外为页码、表格工作表+单元格或字符区间）、`quote_or_value`、`extraction_status`。无法指向证据的关键值必须是 null/hold；不允许仅靠引用相似历史文档证明当前文档的法律主体。

**Confidence 不决定写入许可：** AI 可提供定性判断及其理由，程序依独立的证据规则决定 `eligible_for_auto_execution`，例如项目身份与分类关键证据存在、来源无冲突、Schema 有效、快照有效。不得用“已填写字段数/总字段数”代替证据可靠度，也不得以模型自报 high 作为唯一门禁；对高影响/法律主体字段采用字段级政策。

**Manifest 绑定：** 每份最终 Manifest 保存 `source_id`、`snapshot_fingerprint`、`profile_version`、`case_pack_version`、`model_provider/model_id`、输入来源及决策版本。输入修改后旧决策自动失效，不能在恢复时静默重判或使用过期结果。

## 7. 去重、关联和 Replicant

**三个身份必须分开：**

- **Content Identity：** SHA-256 标识字节内容。
- **Record Identity：** DEVONthink UUID 标识实际档案记录及其记录级元数据。
- **Association Identity：** 文件在某个项目/Group 中的业务用途与来源关系。

| 场景 | 决策 |
|---|---|
| 同一来源已经正确导入并验证 | 幂等跳过，必要时回读 |
| 同内容、同项目、同目标业务含义 | 不产生无意义重复，复用已有记录 |
| 同内容、不同项目、**所有共享元数据与分类语义完全兼容**且能力实测可用 | 可考虑同库 Replicant；不是默认路径 |
| 同内容，但 `projectname`、`salesowner`、`documentcategory` 等必要记录级字段冲突 | **保留独立记录** |
| 文件名相同但内容不同 | 独立保存 |
| 同哈希但来源、独立历史版本或审计意义不同 | 不自动合并，应保留独立语义 |
| 不同 DEVONthink 数据库 | 不假设支持 Replicant，按独立导入政策处理 |

**Replicant 不是 CoW。** 同一记录多位置引用意味着正文与记录级元数据共享；同一文件在两个项目里需要不同 `documentcategory` 或不同销售负责人时，首版不为了省空间而牺牲字段正确性。

**能力边界：** 已验证的 `move_record` 和 `get_record_parents` 不等同于“已验证 Replicant 创建”。在实现该功能前，必须使用可丢弃记录验证官方 MCP 是否支持 Replicate 操作；否则检查 DEVONthink 官方 AppleScript 支持的方式并回读验证。未验证前不能承诺 Replicant 已可通过 MCP 自动创建。Forma SQLite 存储的项目关联必须可核对、导出或从 DEVONthink 实际关系重建，不能变成不可恢复的唯一真相。

## 8. 文件扫描、导入、性能与可靠性

### 8.1 扫描与 OneDrive

原生 macOS 文件访问与安全范围授权。必须识别 OneDrive File Provider 占位文件（可能出现 `SF_DATALESS`）；文件路径存在不代表云端内容已经完整可读。扫描阶段先获取元数据和清单；需要全文、SHA 或导入时再协调数据预热。

### 8.2 哈希和去重

使用 CryptoKit 分块 SHA-256，不全部读入内存。按需读取，建立与文件身份、大小、修改状态绑定的 SHA 缓存，避免每轮重复读取。同名不是重复证据；相同 SHA 不自动抹掉不同业务记录。DEVONthink 自身内容哈希不能未经证明替代标准 SHA-256。

### 8.3 可靠执行（Prototype 后续）

采用持久化 Ledger，记录 `source_id + snapshot_fingerprint + manifest_version → 目标 Group → DEVONthink UUID → 哈希结果 → Metadata → MCP 回读结果`。断点恢复必须先查已有真实记录，不能盲目重新导入。仅阻断出错记录/任务，不对正常批次设置额外审批门禁。原始来源永远不修改或删除，不直接编辑 DEVONthink `.dtBase2` 内部文件。写入 Group、Metadata 和 Replicant 的操作需要支持错误恢复，并对受影响 UUID 避免并发冲突。

**执行仲裁三态：** 在目标记录身份及 Manifest 有效性已核实的前提下，`既存且业务字段/位置/哈希一致 → SKIP_VERIFIED`；`明确不存在 → IMPORT`；`存在但与 Manifest 不一致 → CONFLICT_HOLD`（不自动覆盖、不创建第二副本）。对于 MCP 请求超时或响应不确定，进入 `VERIFY_REQUIRED`，只读回查后才能进入三态之一。仅以 SHA 相同不可断定是既存的同一条业务记录。记录创建与元数据写入间的部分成功状态也必须先回查并恢复，而非简单重跑 import。

## 9. macOS 原生界面与数据安全

- **Workspace：** 选择来源、Profile、目标库、扫描与任务进度。
- **Mapping：** 分项目展示映射结果、字段来源、文档类型、目标分类、置信度与冲突。
- **Exceptions：** 集中处理低证据、冲突、导入失败，不强迫逐文件人工确认。
- **Settings：** AI Provider、模型密钥、DEVONthink MCP、来源权限、Profile 管理。

采用 SwiftUI 主导、必要时结合 Quick Look/PDFKit/AppKit，避免复杂的管理面板风格。长任务使用 Swift Concurrency 保持 UI 响应，任务状态落 SQLite；GUI 退出后是否继续运行由后续任务生命周期设计确认。

**隐私与安全措施：** API Key 存放 Keychain，不写入日志。首次使用云端 Provider 前必须让用户明确启用并说明实际外发范围；允许完全离线扫描/Manifest 查看。默认采用字段分级：目录结构与扩展名等低敏信息可发送；客户、联系人、报价等敏感字段应脱敏或经用户明确选择；密钥、凭据、受保护资料不得发送。脱敏要保留区分角色与文档用途的必要线索（如将不同实体替换成稳定不同的占位符）；测试集必须包含脱敏前后关键反例判别力对照。不同 Provider 的数据处理策略在界面显示，模型 API 兼容本地服务模式（本地模式不要求云端外发）。

**强制控制：** Mapper 仅接收数据与只读查询结果，无写工具句柄；所有 MCP tool name 经只读白名单检查。Manifest 输入经 Schema 校验及来源权限检查，文档内容永远视为不可信数据，不能修改系统指令、写入策略、路径授权或自动执行许可。日志脱敏默认开启，不记录原文、客户名、报价或内部绝对路径。公开仓库仅包含脱敏或合成案例；私密历史资料不能默认推送 GitHub。

## 10. 验收标准

### 10.1 首个 Prototype（本轮设计目标）

1. 使用真实本地或 OneDrive 目录树扫描；对同一来源连续两次扫描，内容/路径未变的 `source_id` 集合必须一致；内容变化能使 `snapshot_fingerprint` 变化并使旧 Manifest 失效。文件移动、云端换 inode、同路径替换均有明确状态与非误合并测试。
2. 使用真实、可配置的 AI 模型 API 输出符合 Schema 的结构化映射；至少验证两种 Provider 的相同测试输入与 Schema 解析容错。第二种 Provider 的稳定性问题应记录，不要求两者分类结果完全一致。
3. 同时演示 Project Archive 与独立 Vendor Library 两个 Profile；独立厂商资料不强迫填写项目。支持 PDF、DOCX、XLSX 的最小只读证据抽取和提取失败回退；其它格式后续扩展。
4. 正确区分关键反例：空白报价模板/真实报价、商务标/独立报价、填好响应的技术表/通用技术表、项目授权/通用操作指南、通用 Datasheet/客户专用投标方案，以及项目名含“采购”但正文为投标稿。
5. Manifest 有来源定位、字段级 Evidence、缺失项、冲突项、版本与快照信息；Validator 可以校验、拒绝不可信证据和导出结果。Mapper 实际无法触达任何 MCP 写入工具。
6. **独立评测集**：目标 ≥150 条，经可核验正文/业务证据人工或独立审核建立金标准，六类/主要反例场景各争取 ≥10 条；不存在足够合格资料时明确报告未达样本量，**禁止宣称通过该项类别准确率验收**，不可把 78 条有限正文核验直接当成完整金标准。Few-shot/评测集按来源 UUID、文件来源簇和 SHA-256（存在时）排除交集与近重复；按项目簇隔离更优。
7. **指标与判定公式**：`coverage = auto_mapped / total`；`precision_auto = correct_auto_mapped / auto_mapped`；`high_confidence_error_rate = incorrect_high_confidence / high_confidence_predictions`（不能误称普通错误率为过度自信率）；`field_precision = correct_nonnull_field_predictions / evaluated_nonnull_field_predictions`，另外逐字段记录漏填；`hold_rate = held / total`。展示混淆矩阵、每 Profile/类别分层样本数与可信区间/不确定性。Prototype 报告必须同时给出业务接受阈值建议和实际测量；在 Owner 未批准阈值前不得宣称最终质量 Gate 通过。
8. **只读 MCP 验证**：在隔离测试数据库进行 read-only 查询，对照 Record Identity、既存记录与同项目重复候选；模拟三态决策，但 **Prototype 全程零写入 DEVONthink**。不能把“零写入”理解为“禁止查询”。
9. **性能/成本基线**：报告本地扫描 1 万文件耗时（不足量时注明实际规模并不可宣称 1 万实测）、每文件/每批 tokens、平均及 P95 调用时延、Provider 单价和实测/外推 1,000 文件费用；区分首次云文件 hydration 与纯元数据扫描。成本数据必须写明模型与计价日期。
10. 不对已验收的 991 条生产业务记录进行修改。首次云端 AI 使用经授权，测试至少包含客户/人员/报价字段的脱敏以及脱敏前后核心判别力验证。

### 10.2 后续 Import 闭环

1. 使用隔离测试组与测试记录，验证实际导入 → 元数据写入 → MCP 独立回读。
2. 对可支持的文件验证源/目标 SHA；重复运行不产生重复记录，断点恢复可核对。
3. 复核 `documentcategory` 与记录实际 Group 一致；Replicant 的多个父组/共享 Metadata 必须单独验收。
4. 覆盖同项目重复、跨项目共享且兼容、跨项目元数据冲突、同名不同内容、独立版本、跨库及失败恢复。
5. 不破坏已有文件、UUID、历史版本与其他业务元数据。

## 11. 待 PLAN 阶段技术验证的问题（按阻塞关系）

| 编号 | 待验证事项 | 阻塞范围 |
|---|---|---|
| V1 | 官方 MCP 工具清单、只读查询与权限隔离；仅查询不写入 | **Prototype** |
| V2 | PDF/DOCX/XLSX 最小正文/表格抽取与 OneDrive 占位文件回退 | **Prototype** |
| V3 | 12 个 Custom Metadata 字段现场 Label、Identifier、原生类型，以及枚举/空值映射 | **Prototype Schema** |
| V4 | 两种 Provider 的结构化输出兼容、模型调用成本与脱敏判别力 | **Prototype** |
| V5 | Replicant 创建、多父组和修改传播：MCP 优先、官方 AppleScript 后备；只在临时记录实测 | **Import 共享功能**，不阻塞 Mapping Prototype |
| V6 | Vendor Library 目标库/层次与共享政策、Project Association 导出/重建 | **Import 设计**，不阻塞 Profile 的只读映射 |
| V7 | macOS sandbox、授权路径、签名打包、GUI 退出后任务生命周期 | **发行/Import Worker**，Prototype 可先按开发构建验证 |

### 11.1 Correction Capture（后续闭环但接口应在 Prototype 定义）

- 用户或已授权运营者纠正某条映射时，保存原判断、新判断、来源文件身份/快照、差异、字段证据、审核状态及案例归属，不改写原始历史。按内容哈希/来源身份、场景和语义相似检查重复候选。
- 修正结果只作为 `candidate_example`；只有经明确审核、证据可追溯且完成脱敏的代表性案例才能进入正式 `Case Pack`。AI 的自我输出或自我确认不自动成为 gold 标签。
- Case Pack 版本化，记录增删理由及冲突案例；每次变更需对独立评测集进行回归，避免案例积累造成 Prompt 膨胀或泄漏测试答案。

### 11.2 术语

- **Profile**：一组可版本化的目标分类、字段约束、存储与异常处理政策。
- **Manifest**：AI 输出经程序补充身份、快照、证据与验证结果后的可复现映射决策；不等于可直接写库的指令。
- **Ledger**：执行与恢复账本，以来源身份、快照和最终 DEVONthink UUID 关联真实操作结果。
- **Case Pack**：精选、脱敏、经审核的 Few-shot 正反例集合，不等于全量历史数据库。
- **Snapshot Fingerprint**：来源文件某一版本的变更检测证据组合；不同于不可变 Content Identity/SHA-256，不能单独作为内容去重证明。
- **Replicant**：DEVONthink 同一记录的多父组引用，共享内容与记录级元数据，不提供 CoW 分叉语义。

## 12. 参考资料与变更纪律

- 参考提交：[`tmp@cba4bc3`](https://github.com/Skyline-Gazer/tmp/commit/cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b)。内容包括新增文件分类规则、修正账本、样本治理报告、样本库与历史快照。**提炼规则和已确认样本，不照搬历史 Python 实现和审计技术债。**
- 本次编写已读取分类规则、质量报告和部分修正记录；大型分类样本库 JSON 未能完整读取。因此 PLAN 引用其详细结构时应做一次性格式核验，不需要重做 991 条业务审计。
- 本 SPEC 明确的 Profile、字段语义、AI 执行权限、共享与去重政策如需改变，必须修订 SPEC；一般模块划分、库选型和迭代顺序由后续 PLAN 决定。

**下一道明确审批边界：** SPEC 已冻结；Agent 现可编制并提交候选 PLAN 供 Owner 集中复核。PLAN 经复核且获得 Owner 另一次明确授权后，才可建立 GitHub Project Roadmap、Issues 并进入产品开发。