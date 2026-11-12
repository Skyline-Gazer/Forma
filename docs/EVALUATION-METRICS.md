# Forma 离线评测口径与结论门禁（EVALUATION-METRICS）

> 状态：P3-A 切片 2a。本文定义**指标的可执行口径**与**结论门禁**。
> PLAN §8.2 给出指标名称与验收意图，本文给出分子分母；两处不一致时以本文为实现事实、以 PLAN 为需求出处，且必须先改 PLAN 再改代码。

## 1. 目的与范围

### 1.1 本文要解决的问题

一个"准确率"可以容纳四种完全不同的事实：引擎没答、答错、答案被同条目其他证据反驳、没人要这个答案却填了。合同（SPEC）对这四种的处理不同，评审者据此做的决定也不同。把它们合成一个数，就等于把四种后果压成一个数字。

因此本文的第一职责是**固定每个指标看见哪些槽位**。

### 1.2 本切片做什么

- 把一份金标准记录与引擎产出的一条 `ManifestEntry` 判成槽位级结论（§2）。
- 按 PLAN §8.2 的名称计算六个比率，并公开分子分母（§3）。
- 给出区间：Wilson 95%（比例）+ 按项目簇 bootstrap（相关性）（§4）。
- 规定什么情况下**不许把数字当成质量结论**（§5、§6）。

### 1.3 本切片不做什么

- 不调用任何真实 Provider，不产生任何关于真实模型质量的结论。
- 不含评测运行器（逐条送样、重试、并发、成本/Token/TTFT/P95 采集），见 §8。
- 不改变 `docs/GOLD-DATASET.md` 的数据集规则；本文只消费 `GoldDataset.Report`。

### 1.4 与 P3-A / P3-B 授权边界的对应

本文全部逻辑可用合成记录与确定性替身演练——这是 P3-A 已授权的范围。"跑一次真实模型并报告分数"属 P3-B，前置条件（凭据、外发授权、预算、隔离 DEVONthink 库、≥150 条独立核实的真实样本）未授权，且 §6 的门禁会在报告层面把结论拦住。

## 2. 判定词汇

一条记录的 12 个元数据槽位各自得到一个结论（`FieldJudgement.Verdict`）：

| 结论 | 条件 | 属于 |
| --- | --- | --- |
| `correct` | 期望有值，候选有非空值，二者相等（§7），且该槽无冲突 | 期望槽 / 候选断言 |
| `wrong` | 期望有值，候选有值且不相等，无冲突 | 期望槽 / 候选断言 |
| `contradicted` | 候选该槽携带冲突记录（同条目内互斥证据） | 期望槽 / 候选断言 |
| `withheld` | 期望有值，候选没给值，或只给了空串/纯空白 | 期望槽 |
| `invented` | 期望无值，候选给了值 | 空期望槽 / 候选断言 |
| `allowedUnknown` | 期望无值，候选也无值 | 空期望槽 |

判定顺序即上表匹配顺序：先排除"两边都空"，再排除"期望空"，再排除"候选空"，**冲突优先于对错**——被自身证据反驳的值不是"错"，是"永远不许自动发布"，两者必须在后续限制上分道。

`CaseJudgement` 还记录条目级事实：`candidateState`（引擎到达的 `DecisionState`，无条目为 nil）、`autoPublishable`、`highConfidence`。

条目缺失（`entry == nil`）时：每个期望值都是 `withheld`；不可能有 `contradicted`，也不可能自动发布——没有东西可发布。

## 3. 指标口径

`EvaluationMeasure.population(in:)` 对**单条判定**给出 (分子, 分母)；跨用例求和后成率。槽位集合按上表分类：

- **期望槽** = 除 `allowedUnknown`、`invented` 之外的槽（期望方有值）。
- **空期望槽** = `allowedUnknown` + `invented`（期望方无值）。
- **候选断言** = `correct` + `wrong` + `contradicted` + `invented`（候选方给了值）。

| 指标 | 分母 | 分子 | 附加限制 |
| --- | --- | --- | --- |
| `coverage` | 期望槽 | `correct` + `wrong` | — |
| `precision_auto` | `correct`+`wrong` 且该槽**可自动发布** | `correct` 且**可自动发布** | 可自动发布 = 条目 `eligibleForAutoExecution` == true ∧ 该槽 `status ∈ {evidenced, inherited}` ∧ 该槽 `evidenceIDs` 非空 |
| `high_confidence_error_rate` | `correct`+`wrong` 且条目 `confidence == .high` | `wrong` 且条目 `confidence == .high` | — |
| `field_precision` | 候选断言 | `correct` | — |
| `hold_rate` | 期望槽 | 见下"搁置" | — |
| `invented_fill_rate` | 空期望槽 | `invented` | — |

三个必须写下来的判断：

1. **`coverage` 的分母计入 `contradicted`（引擎确实给出了一个值，够到了这一格），分子只含 `correct` + `wrong`。** 被自身证据反驳的槽位**留在分母里拉低覆盖率**，只是不进分子。coverage 回答"引擎够到了多少该答的槽位"，答错也算够到，被反驳不算够到。**0% 的 coverage 是合法可引用的结果**（被问到 42 个槽、一个没答），不是"没测到"。
2. **可自动发布** = 条目 `eligibleForAutoExecution` **且** 该槽 `status ∈ {evidenced, inherited}` **且** 该槽 `evidenceIDs` 非空。条目级开关由 `ManifestValidator.computeEligibility` 在登记时算出并存进条目（快照匹配、引用可用、无 `.conflict` 槽、必填齐备等），指标层**不重算条目级规则**，只补上条目级开关没有的那一半：这一格自己的状态与引用。
   为什么必须有这一半：`contradicted` 槽已被 `correct/wrong` 的筛选排除在外，`.conflict` 状态更是直接让条目失去开关；剩下能进分母而又不该算"会自动写出去"的，是状态为 `rejected_by_policy` / `not_applicable` / `unknown` 却带着值的槽——按条目级开关它们会被计入"程序会自动发布"，从而把 `precision_auto` 抬高。执行路径（真正写出 DEVONthink/OneDrive）尚未实现，因此这一条是**指标先行定义的契约**：将来实现执行器时，写入的槽位集合必须与之相同，否则 `precision_auto` 度量的就不是程序真正发布的东西。
3. **搁置**：条目状态为 `hold` 或 `unknown` 时，该条目的**全部**期望槽计为搁置（即使个别槽带着值）——评审者从被扣住的条目里拿不到任何可用产出。否则条目级搁置会在指标里隐身。

## 4. 区间

- **Wilson 95%**（`EvaluationRate.wilson95Lower/Upper`）：这些比率贴近 0 或 1，正态近似会给出越出 [0,1] 的对称区间，把十几条观测的确信度报虚。
- **按项目簇 bootstrap**（`ClusterBootstrap.interval`）：重抽样的单位是 `clusterKey`（项目簇），不是记录。同一项目的多个文件不是独立观测；按记录抽会把"一个项目的形状"读成普遍性。簇数 < 5（`minimumClusters`）时返回 nil——少于这个簇，区间宽度是种子的产物而不是数据的。任一次重抽样的分母为 0 ⇒ **该指标的整体区间为 nil**（这一层薄到给不出簇级区间），而不是把那次抽样丢掉后照报：丢掉后剩下的恰好都是"有答案的簇"，区间会在最需要报宽的地方被压窄。失效逐指标独立、且与抽样顺序无关——某指标被判无定义不会带走同一次抽样里其他指标的份额（`invented_fill_rate` 排在 `precision_auto` 之后，正是顺序敏感会露馅的位置）。六个指标共用同一组抽样索引（索引只与种子和簇数有关）。分位点（2.5%/97.5%）直接取自重抽样分布，不做正态拟合：少量簇的比率分布是块状的，**块本身就是发现**。
- 抽样使用 `SplitMix64`，种子与重抽样次数写入 `EvaluationRunIdentity`；`SystemRandomNumberGenerator` 跨版本不保证序列，而一次测量必须能从记录里复跑。

## 5. 稀疏与"可引用"

SPEC §10.1.6：观测数 < 30 的率只能是候选值。

- 每个 `EvaluationRate` 自带 `denominator` 与 `isSparse`；分母为 0 时 `estimate == nil`、`isSparse == true`（没测过的东西不存在"0 分"这种质量结论）。
- `EvaluationReport.isQuotable(_:stratum:key:)` **逐数**判定，而不是整份报告一票：总体 42 条、某反例类别只有 2 条是常态，而被引用的往往正是那一行。
- `quotableMeasures` 只列总体切面下非稀疏的指标，供摘要直接取用。

## 6. 结论门禁

`EvaluationReport` 在计算完所有率之后，根据运行身份与 `GoldDataset.Report` 生成 `claimBlockers`：

| 阻塞类型 | 触发 | 是否否决质量结论 |
| --- | --- | --- |
| `substituteAnswers` | 答案来自确定性替身 | 是 |
| `insufficientIndependentSamples` | `reviewedCountable < 150` | 是 |
| `undeclaredPromptOverlap` | 评测集与提示侧存在未声明交集 | 是 |
| `unaccountedRecords` | 目录中存在三处清单都未登记的记录 | 是 |
| `pendingAdjudicationExcluded` | 有争议记录被排除出分母 | 否——仅披露 |
| `eligibilityStateInconsistent` | 候选在未达 `validated` 的条目上带有可自动发布的槽位 | 是 |

`isQualityClaimAllowed = 不存在否决型阻塞`。

`eligibility_state` 与导出侧同源：`ManifestExport.revalidate` 把「条目自称可自动执行却不是 `validated`」判为 `eligibility_state` 违规。评测层遇到同一形状时**否决结论而不是替它兜底**——在一个程序自己不会写出的 manifest 上算出的 `precision_auto`，量的不是这个程序。判据放在报告层（`CaseJudgement.candidateState` 与槽位 `autoPublishable`），指标口径本身不动。

为什么争议排除只披露：一次运行确实测了它测的东西，把"有 3 条待裁决"当成整次运行作废，只会诱导人不登记争议。反之，**替身与样本不足必须否决**：合成数据可以把管线跑通、可以把分母做大，但不能认证任何质量门槛——这条与 `GoldDataset.meetsIndependentTarget` 只用 `reviewedCountable` 的口径一致。

## 7. "相等"只有一个定义

`ValueNormalization.folded/equal`（`Sources/FormaCore/Mapping/ValueNormalization.swift`）：`folding([.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`（POSIX en_US）→ 去首尾空白。它是**弱**比较：`2026` 与 `2026年` 是不同值，简繁汉字是不同码位（不是折叠关系），要做语义归一必须由 Profile 自己声明。

`equal` 对可选值：两边都缺 ⇒ 相等；一边缺 ⇒ 不等；**空串或纯空白与任何值都不等**，包括另一个空串——"没写"和"写了个空的"都不是断言（见 §3 的 `withheld`）。

`ManifestValidator` 与评测指标共用它。这不是代码复用偏好：如果评测用一种相等、发布校验用另一种，就会测出一条程序里根本不存在的判定路径。

一个来自存储层的连带事实：`Bounded.text` 有 4 字符下限，短于 4 字符的 `conflicts`/`evidenceIDs` 文本会被丢弃。夹具里写两字的冲突说明会静默失效，因此测试用"与第 3 页的记载相互矛盾"。

## 8. 尚未实现

| 项 | 归属 | 前置条件 |
| --- | --- | --- |
| 评测运行器（逐条送样、重试、并发上限、超时） | P3-A 切片 2b | 无 |
| 成本 / Token / TTFT / P95 采集 | P3-A 切片 2b | 无 |
| 真实 Provider 适配与网络隔离开关 | P3-B | 凭据、外发授权、预算 |
| ≥150 条独立核实的真实金标准样本 | P3-B | 隔离 DEVONthink 库、授权目录 |
| 报告发布与看板 | P3-B | 上述全部 |

本文的 §3、§5、§6 是三处**口径**，切片 2b 与 P3-B 不得另立定义；要改先改本文。

## 9. 接口事实

| 类型 / 成员 | 位置 | 不变量 |
| --- | --- | --- |
| `FieldJudgement`（+ `Verdict`）、`CaseJudgement` | `Sources/FormaCore/Evaluation/EvaluationJudgement.swift` | 判定顺序固定；`publishableStatuses = {evidenced, inherited}` |
| `EvaluationMeasure.population(in:)` | `Sources/FormaCore/Evaluation/EvaluationMetrics.swift` | 单条判定的分子分母；跨用例可加 |
| `EvaluationRate` | 同上 | 分母 0 ⇒ `estimate == nil` 且 `isSparse`；`sparseLimit = 30` |
| `ClusterBootstrap.summarize(cases:indices:measures:resamples:seed:)` | 同上 | 一次遍历同时产出率与区间；`indices` 选样本，不复制判定 |
| `ClusterBootstrap.interval(cases:measure:resamples:seed:)` | 同上 | 簇 < 5 返回 nil；同种子同区间；任一无定义抽样 ⇒ nil |
| `EvaluationMetrics.slices(for:request:)` | 同上 | 切面 = overall ∪ 出现的每个 Profile ∪ 出现的每个类别；一条记录属于两个 Profile 时在两个切面各出现一次，绝不计为两条记录 |
| `EvaluationMetrics.confusion(_:)` | 同上 | 键形如 `mapped->absent`；无条目用 `absent` |
| `EvaluationRunIdentity` | `Sources/FormaCore/Evaluation/EvaluationReport.swift` | 替身标志是身份的字段，不是脚注 |
| `EvaluationReport`（`Blocker`/`Finding`/`isQuotable`） | 同上 | 门禁在报告层，不在调用方 |

共享夹具：`Tests/FormaCoreTests/EvaluationTestSupport.swift`（`EvaluationFixtures.gold/candidate/values`）。指标与门禁两个 suite 必须用同一套构造器，否则会在 12 槽与 4 字下限这类细节上各自漂移。
