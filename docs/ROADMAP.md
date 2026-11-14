# Forma — Implementation Roadmap (Approved Planning Baseline)

**状态：P0/P1/P2 已授权并完成工程实现；P3-A（离线评测基础设施）已授权进行中；I1 已收尾——I1-A 离线实现、I1-B0 执行边界硬化、I1-B1 真实 MCP 能力发现与只读验证、I1-B2 隔离库真实 Import 集成验收均已完成，整体结论为「Import Integration Verified（Limited Scope / 限定范围）」，见下方「I1 最终状态」；`import_file` 精确返回结构、`dropped_fields` 部分成功路径、响应前断连与写入中崩溃仍为 NOT_VERIFIED，Replicant 与生产迁移未验证/未授权；P3-B 真实模型评测、I2、R1 均未授权（R1 仅有 `docs/R1-READINESS.md` 的技术调查与实施方案，不等于开发授权）。**  
**基线：** [SPEC v0.1.1 FROZEN](SPEC.md) · [PLAN v0.1](PLAN.md) · [PLAN PR #1 merged](https://github.com/Skyline-Gazer/Forma/pull/1) · [P2 验收报告](P2-ACCEPTANCE.md) · [I1-A 离线验收](I1-A-ACCEPTANCE.md) · [I1-B1 能力发现](I1-B1-CAPABILITY-DISCOVERY.md) · [I1-B2 预检](I1-B2-PREFLIGHT.md) · [I1-B2 现场验收](I1-B2-ACCEPTANCE.md) · [R1 Readiness](R1-READINESS.md)  
**Owner 决策记录：** 2026-11-11（P0/P1 授权）· 2026-11-12（P2 收尾接受 + P3 拆分授权）· 2026-11-13（I1-A）· 2026-11-14（I1-B1、I1-B2 预检、库绑定与写入授权；I1 收尾文档修订），详见下方「授权历史」

## 已批准的三项 Owner 决策

1. **AI Mapping 质量目标：候选值，非正式验收 Gate。** 初始参考 PLAN 提议的 precision_auto ≥95%、coverage ≥70%、field_precision ≥98%、high_confidence_error_rate ≤2%；应先做真实独立测量，结合 Profile、分层样本量、风险和置信区间，再由 Owner 批准最终 Gate。禁止将建议值写成已经获批通过。
2. **目标与年份：** Vendor Library 使用**独立的 DEVONthink 数据库**（具体库 UUID 和目录结构留待 V6 现场绑定）；Project Archive **保持现有 Group 布局**；completionyear 必须来自**已核实的归档完成事实**，不能从投标截止年、封面日期或产品年份猜测；不明则 hold。
3. **发行与生命周期：** **macOS 14+ 为当前开发基线**，P0/V7 核实兼容性；默认 GUI 退出时保存任务及未决操作状态，**下次启动先回查后恢复**。首版不做独立后台 Worker；签名/沙盒/分发策略以实测为准。

## I1 最终状态（2026-11-14 收尾）

`dev` @ `e1a1379`（PR #75 合并，CI run `43581724081` success）。四个切片分别验收，**不合并成一个“I1 全部通过”的结论**。

| 切片 | PR | 结论 | 证据 |
| --- | --- | --- | --- |
| I1-A 离线 Import 基础 | #62–#65 | **Offline Verified** | [I1-A-ACCEPTANCE](I1-A-ACCEPTANCE.md)、[ADR](ADR-I1-A-IMPORT-CONTRACT.md) |
| I1-B0 执行边界硬化 | #66–#68 | **Offline Verified**（补写前核验目标、恢复前核验来源） | `Tests/FormaCoreTests/ImportB0BoundaryTests.swift` |
| I1-B1 真实 MCP 能力发现 | #69–#70 | **MCP Discovery Verified**；只读集成 Partial | [I1-B1-CAPABILITY-DISCOVERY](I1-B1-CAPABILITY-DISCOVERY.md) |
| I1-B2 隔离库真实 Import | #71–#75 | **Import Integration Verified（Limited Scope）** | [I1-B2-ACCEPTANCE](I1-B2-ACCEPTANCE.md) |

限定边界：隔离库 + 本轮创建的 2 个 Group + 4 条合成记录 + 8 个允许字段 + 3 个授权工具；生产库零写入；未删除任何沙盒对象。

仍未验证（不得升格为 PASS）：`import_file` 精确返回结构、`dropped_fields` 部分成功、请求发出后响应前断连、写入进行中的真实崩溃、异步可见性延迟场景、真实业务文件与 OneDrive 占位、生产库迁移、Replicant/多父组（属 I2）。

可复现性缺口：现场运行的装配驱动器未入库（仓库内 `ImportReadTransport` 仅有测试用 `FakeImportTransport`），因此该次运行无法从仓库一键复现，只有组件可复用。

因此 **Issue #7（E5 Epic）不因本收尾而完成**，Import 也不宣称生产就绪。

## 主链与可选分支

```mermaid
flowchart LR
    E0["E0 / P0\nContracts"] --> E1["E1 / P1\nSource facts"]
    E1 --> E2["E2 / P2\nAI mapping"]
    E2 --> E3["E3 / P2\nNative UI"]
    E3 --> E4["E4 / P3\nEvaluation"]
    E4 --> E5["E5 / I1\nImport"]
    E5 --> E7["E7 / R1\nRelease"]
    E5 --> E6["E6 / I2\nOptional sharing"]
```

P2 的 E2/E3 可部分并行，但用户可操作的 Prototype 应形成完整 Mapping + UI 流程。I2 **不阻塞** I1 和 R1；V1–V4 优先为 Prototype 提供实际能力证据，V5 仅阻塞 Replicant 选项。

## Epic / Feature 索引

| Epic | 阶段 | Feature Issues | 验收出口 |
|---|---|---|---|
| [#2 E0 契约与只读能力](https://github.com/Skyline-Gazer/Forma/issues/2) | P0 | [#10 MCP/字段](https://github.com/Skyline-Gazer/Forma/issues/10), [#11 Providers/Extractors](https://github.com/Skyline-Gazer/Forma/issues/11) | V1–V4、真实只读探针；生产零写 |
| [#3 E1 来源事实](https://github.com/Skyline-Gazer/Forma/issues/3) | P1 | [#12 source_id](https://github.com/Skyline-Gazer/Forma/issues/12), [#13 snapshot/evidence](https://github.com/Skyline-Gazer/Forma/issues/13) | 重扫、移动、替换、快照和只读证据 |
| [#4 E2 AI Mapping](https://github.com/Skyline-Gazer/Forma/issues/4) | P2 | [#14 Context/Profile](https://github.com/Skyline-Gazer/Forma/issues/14), [#15 Providers/CasePack](https://github.com/Skyline-Gazer/Forma/issues/15), [#16 Validator](https://github.com/Skyline-Gazer/Forma/issues/16) | 双 Profile 真实 Manifest、可验证 Evidence |
| [#5 E3 Native UI](https://github.com/Skyline-Gazer/Forma/issues/5) | P2 | [#17 Mapping UI](https://github.com/Skyline-Gazer/Forma/issues/17), [#18 Privacy/Correction](https://github.com/Skyline-Gazer/Forma/issues/18) | Workspace/Mapping/Exceptions/Settings、脱敏/纠错闭环 |
| [#6 E4 质量评测](https://github.com/Skyline-Gazer/Forma/issues/6) | P3 | [#19 gold/metrics](https://github.com/Skyline-Gazer/Forma/issues/19), [#20 performance/cost](https://github.com/Skyline-Gazer/Forma/issues/20) | 已授权 P3-A：金标准规范与离线评测基础设施（可用合成数据与确定性替身）。暂未授权 P3-B：真实模型与样本报告。正式 Gate 待 Owner 实测后批准（授权见下方「授权历史」） |
| [#7 E5 Import](https://github.com/Skyline-Gazer/Forma/issues/7) | I1 | [#21 Write/SHA](https://github.com/Skyline-Gazer/Forma/issues/21), [#22 Ledger/Recovery](https://github.com/Skyline-Gazer/Forma/issues/22) | 隔离记录读写回读、幂等、VERIFY_REQUIRED 已在限定范围内达成（`docs/I1-B2-ACCEPTANCE.md`）；未达成：`import_file` 返回结构、`dropped_fields` 部分成功、响应前断连、写入中崩溃、OneDrive hydration、生产迁移 —— **Epic 保持未完成** |
| [#8 E6 Optional Sharing](https://github.com/Skyline-Gazer/Forma/issues/8) | I2 | [#23 Associations/Replicant](https://github.com/Skyline-Gazer/Forma/issues/23) | 元数据兼容才考虑 Replicant；不支持可关闭 |
| [#9 E7 Release](https://github.com/Skyline-Gazer/Forma/issues/9) | R1 | [#24 Release/Lifecycle](https://github.com/Skyline-Gazer/Forma/issues/24) | **Planned / Awaiting Authorization**：真实安装、授权恢复、签名公证与重启核查。技术调查与实施方案见 `docs/R1-READINESS.md`（不构成开发授权） |

## 实施与治理边界

- **授权历史**
  - **2026-11-11（原文保留，不改动当时的时间记录）：** 实施 P0（技术契约与基础工程）与 P1（Scanner / Source Identity / Snapshot / Evidence / 最小 GUI），在 `dev` 以可独立审查的 PR 集成，并配置 GitHub Actions macOS 构建与单元测试。P2、P3、I1、I2、R1 未授权。
  - **2026-11-12（Owner 决策；取代上一条中「P2、P3 未授权」的现状效力，上一条作为历史证据保留）：**
    - P0 / P1：已授权并完成。
    - P2：已授权，工程实现完成；外部现场验收仍有未关闭项——Provider 真实调用、隔离 DEVONthink 库对齐、授权 OneDrive 目录三项保持 `BLOCKED`，GUI 人工交互保持 `NOT_VERIFIED`，且不得因阶段收尾而关闭；CI 编译成功与合成数据测试通过不得表述为真实环境验证通过，P2 不宣称生产就绪。
    - **P3-A：正式授权启动离线评测准备工作**（金标准数据集规范与评测基础设施，允许合成数据与确定性替身）。
    - **P3-B：真实模型评测暂未授权执行**，等待四项外部前置条件：Provider 真实 API 凭据与批准的模型、外发数据范围与费用预算；经确认的独立测试库 UUID 与只读范围；Owner 授权的真实扫描目录与访问边界；≥150 条经独立核实与脱敏的金标准样本。凭据一律经本地 Keychain 或经批准的 Secret 管理，不提交仓库。
    - I1 / I2 / R1：未授权。
    - 质量阈值（precision_auto ≥95%、coverage ≥70%、field_precision ≥98%、high_confidence_error_rate ≤2%）仍为待批候选值；正式 Gate 须在真实测量、分层、区间与风险分析后由 Owner 再次批准，Agent 不得自行宣布其已成为验收标准。
  - **2026-11-13（Owner 授权 I1-A：可靠 Import 的离线设计确认与基础实现）：** 允许在 DevBox + macOS CI 内开发 Preflight、SHA/快照校验、幂等操作键、版本化 SQLite Intent/Ledger、四态仲裁、单写者与重启恢复、Fake MCP Transport、故障注入与独立回读验证。幂等键为 `(source_id, snapshot_fingerprint, manifest_revision, target_association_id, operation_kind)`；写入前先持久化 Intent；不确定副作用进入 VERIFY_REQUIRED；不声明未经真实接口证明的 exactly-once。**明确禁止**：真实 DEVONthink 写工具调用、真实记录/Group 创建、生产库写入、真实文件 Import、真实 OneDrive hydration、真实 Provider 请求、修改冻结 SPEC、默认启用应用层 WriteClient、把 Fake Transport 成功当作现场验收。I1-B（隔离库真实写入、Metadata/UUID/SHA 回读、断连与重复运行）须 Owner 单独批准；在此之前 I1-A 只报 **Offline Verified**。
  - **2026-11-14（Owner 授权 I1-B1：真实 MCP 能力发现与只读验证）：** 允许在 macOS 上用官方 DEVONthink MCP 执行 `initialize`/`tools/list`/分页与只读调用，记录版本、schema 摘要与能力矩阵；发现真实契约缺陷时允许在独立 PR 修复 `DEVONthinkReadOnlyClient` 并通过 macOS CI。仍**禁止**任何写工具调用、真实记录/Group 创建与生产库记录级查询；Owner 本轮未指定隔离测试库，因此库级验收记为 `BLOCKED`。结果见 `docs/I1-B1-CAPABILITY-DISCOVERY.md`；写入提案见 `docs/I1-B2-AUTHORIZATION-PROPOSAL.md`（**未获批准前不得执行**）。
  - **2026-11-14（I1-B2 预检与隔离库绑定，未授权写入）：** 完成默认拒绝执行边界（`Sources/FormaCore/Import/ImportWriteBoundary.swift`）；Owner 创建 `Forma_I1B2_Sandbox` 后，通过只读 `get_databases` 完成绑定（名称精确、`is_inbox=false`、与生产库 UUID 不同、初始 0 条记录、根下 6 个子项 = 3 个系统组 + 3 个智能组），并复核 3 个写工具 schema digest、8 个 Metadata 字段与 4 个合成文件 SHA-256。预检报告见 `docs/I1-B2-PREFLIGHT.md`。**本轮仍为零写调用**；写入需 Owner 明确批准提案后才可执行。
  - **2026-11-14（Owner 授权 I1-B2 真实写入，并在隔离库完成验收）：** 授权仅在 `Forma_I1B2_Sandbox` 与本轮 `Forma_I1B2/<run-id>` 内使用 `create_group_path`、`import_file`（`mode=import`）与 `set_record_custom_metadata`（`mode=merge`，8 个 identifier），预算 4 条记录 / 2 个 Group；禁止删除、移动、Replicant、字段定义变更与任何生产库写入。真实调用全部经 `GuardedImportWriteTransport`（实现见 PR #74）。结果：4 条合成记录全部导入，源/目标标准 SHA-256 逐字节一致，Metadata merge 后逐字段回读通过且未写入字段未被改动，重复执行 `SKIP_VERIFIED` 且不再调用 `import_file`，冲突拒绝覆盖，超时后以只读回查判定（写入实际已落库），断连无盲重试，重启恢复无重复记录，生产库零写入。报告见 `docs/I1-B2-ACCEPTANCE.md`。`import_file` 精确返回结构与 `dropped_fields` 部分成功路径仍为 **NOT_VERIFIED**。
  - **2026-11-14（I1 收尾：只读取证复核、文档纠错与 Issue 收敛；未新增任何写入授权）：** 复核实基线 `dev` @ `e1a1379`（PR #75 合并，CI run `43581724081` success），PR #71–#75 全部 merged。收尾只做只读工作：未调用任何 DEVONthink 写工具，未刷新写预算，未触碰沙盒对象，未访问生产库，未同步 CNB，`main` 与 ADS pin 未改，SPEC v0.1.1 未改。文档修订：`docs/I1-B2-ACCEPTANCE.md` 把“写请求超时 / 发送前断连 / 发送后响应前断连”三种情况分开判定（第三种为 **NOT_VERIFIED**）、把 Metadata 表述修正为“6 非空 + 2 显式 null → missing + 4 未写入”、把 `import_file` 返回结构拆成“适配器层结论 VERIFIED / 字段结构 NOT_VERIFIED”。原始证据目录 `~/.forma/evidence/i1-b2/` 位于运行主机（macOS），本轮复核主机为 DevBox，**未重读**该目录，因此现场观察值保持原记录强度、未验证项不升格。R1 仅完成技术调查与实施方案（`docs/R1-READINESS.md`），**不构成开发授权**。
- 默认只读：除 I1-B2 已按 Owner 批准、在隔离库与本轮 Group 内完成的限定写入外，Forma 对 DEVONthink **默认禁止任何写入**；生产 Project_Archive 现有 991 条记录不可修改。任何新的真实写入（含 I1 剩余探针、崩溃注入、I2 Replicant、生产迁移）都需要 Owner 单独授权与新预算。
- SPEC 产品契约有变化须先获 Owner 批准修订；一般实现细节以 PLAN 和对应 Issue 为准。
- 公开仓库只允许脱敏/合成案例；真实资料留本地。
- 不引入 Rust/Tauri、独立 RAG/Vector DB 或不必要服务。
- 正常执行异常驱动复核；不为每批资料引入不必要审批。
- 前一阶段授权（合并 PLAN、建立 Roadmap 与 Issues）已于 2026-11-11 执行完毕；进入 P0/P1 需要且已经取得 Owner 在本轮开发指令中的明确授权，后续阶段仍需另行授权。

## GitHub Project 看板状态

仓库 Issues 和本文件已经建立可执行的 Roadmap；**GitHub Projects v2 看板尚未创建**。当前连接只暴露 GitHub Issues 与 PR 的创建/管理能力，没有 GitHub Projects 的创建/添加条目写入接口，因此不能假装看板已经存在。将来有 GitHub Projects 写权限工具时，可按上表建立单个 Forma Project 并批量导入这些 Issues；不应重复创建任务。
