# Eligibility — SPEC/PLAN 契约差异提案（Owner 已批准 A–E）

状态：**APPROVED — Owner 正式批准 A–E 全量（2026-11-16，见 ROADMAP 授权历史）**。契约修订已落地：SPEC v0.1.2（§6.1-1、§6.3、§10.1-1、§10.1-5、§13 版本历史与迁移记录）与 PLAN v0.2（§6.1、§7.1、模块表、§16）；本文保留为决策依据原文。实施边界：切片 1–4 已授权（本文 §5 顺序）；切片 5（I1 Executor 重判）未授权；**生产默认过滤启用**须全链路完成、macOS 真实目录验证与 Owner 再确认（Owner 授权条件 3）。基线：`dev` @ `6b52071`。

实施记录（2026-11-16）：切片 1–4 已全部实施并合入 `dev`——#117（`inputDigest` 绑定策略与判定指纹，完整清单模式逐字节不变）、#118（Context/Mapping 过滤接线，`nil` 为兼容路径）、#119（Manifest 资格块 + `schema_version 1.1` + 按声明版本校验，1.0 工件不变）、#120（运行级资格报告与路径无关导出）。默认过滤仍**未启用**（Owner 条件 3）；切片 5 未授权。

## 1. 当前已实施与未实施

**已实施（视图层，2e/2f，未动契约）**：`SourceListing` → `EligibilityView` 纯函数视图、四态决策与解释、dry-run 统计/导出、覆写与失效逻辑、只读事实探测、`mappingCandidates()`。

**已实施（切片 1–4，2026-11-16 合并，默认关闭）**：`inputDigest` 绑定 `policy_digest` 与判定指纹（#117）；`buildContext(…, eligibility:)` 与 `MappingRunRequest.eligibility` 的 opt-in 接线（#118）；Manifest 可选资格块 + `schema_version 1.1` + 按声明版本校验（#119）；运行级 `EligibilityReport` 与路径无关导出（#120）。

**未实施 / 未授权**：切片 5（I1 Executor 写入前重判）；**生产默认过滤的正式启用**（Owner 条件 3：全链路完成 + macOS 真实目录验证 + Owner 再确认）；真实目录误排除复核（`MACOS-VALIDATION-BACKLOG` M11 现场项，本轮无 macOS 主机 → NOT_VERIFIED）。上述三项互不替代。

## 2. 与冻结文本的逐条冲突点

| # | 冻结条款（原文位置） | 冲突 |
| --- | --- | --- |
| C1 | SPEC §6.1-1「程序读取**完整文件清单**和目录树，先组织项目级上下文」；PLAN §6.1-1「离线扫描完整清单，保留全部条目」 | 过滤 Mapping 输入后，模型看到的不再是"完整清单"；不修订则实现违反字面契约 |
| C2 | SPEC §6.3「Manifest 绑定：每份最终 Manifest 保存 `source_id`、`snapshot_fingerprint`、`profile_version`、`case_pack_version`、`model_provider/model_id`、输入来源及决策版本」 | 绑定字段不含 `policy_id/policy_version/policy_digest`；一份用不同资格规则产生的 Manifest 无法被识别与复现 |
| C3 | SPEC §10.1-5「Manifest 有来源定位、字段级 Evidence、缺失项、冲突项…」；§10.1-1 扫描一致性 | "被排除而未进入 Mapping 的记录"会被读者当成"目录里没有这个文件"；缺失项/覆盖语义需要新增一类"已发现但未参与映射"的状态 |
| C4 | PLAN 模块表 `ContextBuilder 全清单 → 项目候选上下文`；`scans/source_snapshots` 表「快照不可原位改写」 | `ContextBuilder.inputDigest` 现只由 scope+profile+entries 构成；资格过滤改变输入必须同时改变 digest 定义，否则旧 Context revision 与新输入无法区分 |

## 3. 建议的契约修订（提案文本）

**A. 扫描与身份不变量（写入 SPEC §6.1/§10.1，防误读）**
> 完整扫描清单、`source_id` 分配、`missing`/移动判定与覆盖率统计**不因资格判定发生任何变化**。Eligibility 是清单之上的可重算派生视图；被 `EXCLUDE/REVIEW/DEFER` 的记录仍是已发现来源。

（无需改动现有条款即成立，此条为显式加固，防止读者把过滤当删除。）

**B. Mapping 输入定义（SPEC §6.1-1 修订）**
> 程序读取完整文件清单与目录树；向模型提供项目级上下文时，缺省输入为 `EligibilityView.mappingCandidates()` 产出的 INCLUDE 子集，并记录参与判定的 `policy_digest` 与探测事实摘要。视图之外被排除的记录数量、规则与原因分布必须随报告留存。

**C. Manifest 绑定扩展（SPEC §6.3 修订）**
> Manifest 工件若由资格过滤后的输入产生，必须额外保存 `policy_id`、`policy_version`、`policy_digest` 与"已发现未映射"计数字段。旧 Manifest（无该块）继续按现契约有效；Validator 对其不得施加新字段要求。

**D. Context 输入与失效（PLAN 模块表/存储表注记）**
> `ContextBuilder.inputDigest = H(scopeID, profile_version, canonical(entries), policy_digest, canonical(deciding_facts))`。规则或事实变化产生新 revision；旧 revision 保留可查、不原位改写（沿用既有"快照不可原位改写"约束）。被排除记录从新 revision 消失属于 `removed_from_eligibility`，不触发 `missing` 判定。

**E. 报告语义（SPEC §10.1-5 追加验收）**
> 映射/导入报告必须单列：已发现未进入 Mapping 的记录数、按决策与规则的分布、可解释原因码；该数字不得为零默认省略。

## 4. 决策选项

1. **APPROVE（A–E 全量）**：按 §5 切片顺序实施；每片独立 PR + macOS CI。
2. **APPROVE-PARTIAL**：仅 A+B+D（Context 输入过滤与失效），Manifest 扩展（C/E）推迟到后续批次——报告仍用现契约，未映射记录只在 eligibility 导出中体现。
3. **REJECT**：维持现状（纯函数 + dry-run，生产默认输入不过滤）；Issue #51 的接线项保持未实施。

## 5. 批准后的实施切片顺序（预告，不预先实施）

1. `inputDigest` 纳入 `policy_digest` + 决策事实摘要（含既有 revision/失效测试回归）。
2. `ContextBuilder.build` 输入切到 INCLUDE 子集（默认开，显式 `eligibilityEnabled=false` 回退路径保留一个批次）。
3. Manifest envelope 新增可选 eligibility 块 + Schema 版本升级 + Validator 兼容旧工件。
4. GUI/报告"已发现未映射"单列（R1 Batch 2B 应用功能另行授权，不与本切片混批）。
5. I1 Executor 写入前重判并固定 policy digest（需 I1 授权，见 §12 of POLICY）。

## 6. 验收 Gate（对批准后实现）

- 全部既有 eligibility 测试 + 新增过滤接线确定性测试；`false_exclusion` 反例清单在过滤后的 Context 输入中逐条仍为候选。
- 扫描身份/missing/覆盖率既有测试**零修改通过**（C1 不变量的机械证明）。
- 旧 Manifest/Context revision 全部可读取、可解释；无任何原位改写。
- 真实目录误排除复核仍走 `MACOS-VALIDATION-BACKLOG` M10/M11，不由合成测试替代。
