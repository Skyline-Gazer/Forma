# Forma 离线评测口径与结论门禁（EVALUATION-METRICS）

> 状态：P3-A 切片 2b / 2c。本文定义**指标的可执行口径**、**离线运行器语义**、**规模基准口径**与**结论门禁**。
> PLAN §8.2 给出指标名称与验收意图，本文给出分子分母。三者必须同步，顺序是：**先改 PLAN（需求源）→ 再改代码 → 最后更新本文**。本文不是实现真值的背书；口径的实际行为以代码为准，且下列性质各有用例固定：两套单位各自的分母（`coveragePopulation`、`precisionAutoPopulation`、`perFieldRows`）、可引用性单位（`sparsityCountsRecords`）、未命名 Profile 的运行不给出精确率而非 0%（`unattributedRunHasNoPrecisionRow`）、逐字段行按自己的证据判稀疏（`fieldRowSparsityFollowsItsEvidence`）、无定义抽样逐指标失效且与顺序无关（`emptyDrawVoidsInsteadOfSkipping`、`voidingIsOrderIndependent`）、无观测与无区间的区别（`measureWithoutPopulationHasNoInterval`、`clusterResampling`）、拒判原因的单位（`refusalsNameTheReasons`）、用例集来自版本化 split（`casesMustComeFromTheCountableSplit`）、否决与仅披露的划分是逐条选定的（`blockerPartitionIsDeliberate`）、运行器把请求当批而不是当样本（`requestsAreBatchesNotAttempts`）、单次请求超时由运行器兜住（`deadlineBoundsAHungAnswer`）、取消不缩小分母（`cancellationIsDisclosed`）、并发上限可核对（`concurrencyIsBounded`）、缺失的 usage 不补零（`usageIsNeverInvented`）、非流式不冒充首字延迟（`firstTokenIsAbsentUnlessObserved`）、替身运行不得被引用（`standInRunIsRefused`）。

## 1. 目的与范围

### 1.1 本文要解决的问题

一个"准确率"可以容纳四种完全不同的事实：引擎没答、答错、答案被同条目其他证据反驳、没人要这个答案却填了。合同（SPEC）对这四种的处理不同，评审者据此做的决定也不同。把它们合成一个数，就等于把四种后果压成一个数字。

因此本文的第一职责是**固定每个指标看见什么、以什么单位计**：一条记录还是一个槽位观测。

### 1.2 本切片做什么（2a：指标；2b：运行器；2c：规模基准）
- 把一份金标准记录与引擎产出的一条 `ManifestEntry` 判成槽位级结论（§2）。
- 按 PLAN §8.2 的名称计算七个比率，声明各自单位（`EvaluationMeasure.unit`），并公开分子分母（§3）。
- 给出区间：Wilson 95%（比例）+ 按项目簇 bootstrap（相关性）（§4）。
- 规定什么情况下**不许把数字当成质量结论**（§5、§6）。
- 2b：把一份 `GoldDataset` 真正跑起来——批计划、有界并发、单次请求超时、可控重试与退避、取消、部分失败、运行身份与结果追溯，见 §10。
- 2b：采集并记录 Request / Attempt / Batch / Run 四级执行事实与成本/Token/延迟，见 §10。
- 2c：可复现的合成夹具（100 / 1k / 10k）、分阶段计时、并发扫描与故障注入量化、版本化结果结构，见 §11；实验定义与命令见 `docs/EVALUATION-BENCHMARK.md`。

### 1.3 本切片不做什么

- 不调用任何真实 Provider，不产生任何关于真实模型质量的结论。
- 运行器不自带 Provider，也不构造任何 Provider 客户端：谁应答由调用方注入（§10.1）。默认与全部离线验证路径都走确定性替身。
- 不做扫描/OneDrive/DEVONthink 的真机性能实测；2b 与 2c 的执行数字是**运行器与算法层**的证据，不能替代 macOS 上 10,000 文件的扫描验收（M9）。
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

`FieldJudgement` 还带一个 `status`（候选条目为该槽记下的 `FieldOutcome.Status`，无条目为 nil）：`verdict` 说这一格与参考答案是什么关系，`status` 说程序拿它做了什么，§3 第 5 条的拒判原因只由后者提供。`CaseJudgement` 另记录记录级事实，供 §3 的文件级比率直接取用：`candidateState`（引擎到达的 `DecisionState`，无条目为 nil）、`profiles`、`category`、`isAutoMapped`、`declaresHighConfidence`、`matchesProjectReference`、`matchesTargetCategory`、`mainDecisionIsCorrect(runProfile:)`；`FieldJudgement.autoPublishable` 只服务 §6 的 `eligibilityStateInconsistent` 核验，不再进入任何指标的分母。

条目缺失（`entry == nil`）时：每个期望值都是 `withheld`；不可能有 `contradicted`，也不可能自动发布——没有东西可发布。

## 3. 指标口径

**两套单位，各自固定。** PLAN §8.2 给的是文件级定义（`coverage = auto_mapped / total`、`precision_auto = correct_auto_mapped / auto_mapped`、`hold_rate = held / total`、`high_confidence_error_rate`、漏填），本节此前把这三项写成了槽位级计数，属于实现偏离 PLAN，已按 §8.2 更正。分槽位的观察仍然存在，但只有 `field_precision`、`invented_fill_rate` 与 PLAN 的"漏填"三项，且各自的分母写在下面；两套单位之间**没有**换算关系，任何报表不得把一个的分母与另一个的分子相加。

`EvaluationMeasure.population(in:runProfile:)` 对**单条判定**给出 (分子, 分母)；跨用例求和成率。槽位集合按 §2 分类：

- **期望槽** = 除 `allowedUnknown`、`invented` 之外的槽（期望方有值）。
- **空期望槽** = `allowedUnknown` + `invented`（期望方无值）。
- **候选断言** = `correct` + `wrong` + `contradicted` + `invented`（候选方给了值）。

| 指标 | 单位 | 分母 | 分子 |
| --- | --- | --- | --- |
| `coverage` | 记录 | 被判定的记录（每条 1） | `isAutoMapped` 的记录 |
| `precision_auto` | 记录 | `isAutoMapped` 的记录 | 其中 `mainDecisionIsCorrect(runProfile:)` 为真的记录 |
| `high_confidence_error_rate` | 记录 | 有条目且 `declaresHighConfidence` 的记录 | 其中主决策错误的记录 |
| `hold_rate` | 记录 | 被判定的记录 | 条目状态为 `hold` / `unknown` 的记录，以及根本没有条目的记录 |
| `field_precision` | 槽位 | 候选断言 | `correct` |
| `missed_fill_rate`（漏填） | 槽位 | 期望槽 | `withheld` |
| `invented_fill_rate` | 槽位 | 空期望槽 | `invented` |

必须写下来的判断：

1. **`isAutoMapped` = 条目 `state == .validated` 且 `eligibleForAutoExecution == true`，只看这两个条目级事实，不叠加任何槽位级条件。** 这正是"程序会自己把它写出去"的形状：`ManifestValidator.computeEligibility` 只在 `validated` 之上计算合格性，两者缺一，该记录就不会自动落地，因此留在 `coverage` 的分母里拉低覆盖率，而**完全不在 `precision_auto` 的分母里**（0/0，不是 0/1：对根本不会发生的写出报精确率，量的是这个程序不会走的路径）。
   条目级开关与槽位级规则（§2 的 `autoPublishable`）不需要在指标里再交一次，是因为程序自己已经交过了：`ManifestValidator` 只在 `.evidenced` / `.inherited` 上保留取值，而带值就要带让它通过引用核对与继承核验的 evidence id，`validated` 又要求每个 `required_for_validated` 字段都有值。该事实由 `ManifestValidatorTests.autoMappedImpliesPublishableSlots` 钉住——把 `publishableStatuses` 改成与写出侧不符的集合会让那条用例失败，而不是让 `precision_auto` 静默换成另一个量。无条目（引擎没给出该记录）在 `coverage` 里算分母不算分子——0% 的 coverage 是合法可引用的结果，不是"没测到"。
2. **一条记录"正确"要同时满足三个分量**（PLAN §8.2）：本次运行的 Profile ∈ 该记录标注的 `profiles`；项目归属与期望簇键一致；目标类别出现在条目 group path 里。三分量各自留成 `matchesProjectReference` / `matchesTargetCategory` / Profile 判定，坏数字要能追到是哪个分量弄坏的。
   - **项目分量按程序真正写下的东西读。** manifest 的 `project_candidate` association 里写的是提示发出的**不透明 ref**（`ManifestValidator` 的原文是 `"context revision N candidate <ref>"`），而参考答案记的是**项目簇键**（GOLD-DATASET「期望项目归属」）；两者靠运行上下文的 `ContextCandidate.id → projectKey` 表对齐，这张表由 `CaseJudgement(gold:entry:projectKeys:)` 从外部注入。判定同时接受条目自己写出的项目线索：`.projectname` 槽的值、group path 与 database name。
   - 没有这张表、而条目的项目线索只剩一个解不开的 ref 时，判为**不匹配**而不是略过：不可核查的归属不能算通过。（`runProfile == nil` 的后果见下一条，两种"无从核查"不要混成一件。）
   - **`runProfile == nil`（运行没有唯一命名一个 Profile）时这两项指标没有人口**：`precision_auto` 与 `high_confidence_error_rate` 的分子分母都是 0，报成 N/A 而不是 0%。写"0/40"等于给读者一个"观测到的 0% 精确率"，而事实只是运行没说这批文件是在哪个 Profile 下判的——按 §5 的可引用规则它还会被判为"确有观测"。多 Profile 运行由 **Profile 切面**给出这两个率（那一层的 `runProfile` 就是切面自己的 key），`coverage` / `hold_rate` / 槽位级三项不依赖归属，照常计。`EvaluationReport` 在身份里只有一个 Profile 时自动填入 `runProfileID`，多个时保持 nil 让上面这条生效。
   - 期望方留空（`project_reference` / `target_category` 为显式 `null`）的分量**真空满足**：harness 不能替标注员发明项目或类别，把它判成漏答是在为数据集自己的沉默扣分。
   - 一个文件被多个候选项目认领时，association 集合记的是**所有**认领者，不是程序挑中的那一个；这种歧义不会污染 `precision_auto`——冲突归属会阻断合格性，该记录落在分母之外（`computeEligibility` 的 `.conflict` 拒绝与 `associationReason` 失效路径）。残留风险只有调用方交来的表与它交来的 `conflictedSourceIDs` 不自洽。
3. **`contradicted` 留在槽位级分母里，不进分子**（`field_precision`）。被自身证据反驳的值是引擎确实给出过的断言，忽略它会让精确率报出程序没有的把握；而它作为状态（`.conflict`）会让整个条目失去 `eligibleForAutoExecution`，所以同一条记录本来就不在文件级 `precision_auto` 的分母里。
4. **"漏填"与"答错"分列两项，不得相加**：`missed_fill_rate` 的分子是 `withheld`（含候选只给空串/纯空白的槽，§7），`field_precision` 的分母只含候选断言，两者对同一个槽各说各话。`allowedUnknown`（期望方也放弃猜测的槽）不是期望槽，永远不进漏填分母——一致的未知不是漏答，这正是 PLAN 要求报告把两者分开的原因。
5. **拒判原因与混淆矩阵并列，各自单位**（PLAN §8.2 的"分层"行同时列了两者）。`EvaluationMetrics.refusals(_:)` 给出两个字典：`byRecordState` 按记录停在哪个 `DecisionState`（无条目为 `absent`）计未自动落地的文件；`bySlotStatus` 按政策留下的 `FieldOutcome.Status`（无条目同样 `absent`）计那些期望却没填的槽，其中 `unknown` 与 `not_applicable` 就是 PLAN §8.2 要求与"错漏"分开的"允许未知"那一半——它们不进 `missed_fill_rate` 的分子（第 4 条），但在这里仍数得出条数——**这一半遍历全部记录**，包括已经自动落地却漏了字段的文件：文件级它不是拒判，槽级它正是评审要补的那几格，跳过这批就会把报表最需要理由的情形（不完整的自动写出）藏起来，而且总数会与 `missed_fill_rate` 的分子不再相等（两处表格说的是同一次运行）。**两者永不相加**——一个是文件数、一个是槽位数，相加就是本节第 1 条要避免的那种混淆。混淆矩阵说的是"引擎到达哪个决定"，这一对说的是"为什么没把参考答案要的东西写出去"，读者据此分配复核工作。键全部来自 manifest 自己的词汇表，报表不新造标签。
6. **搁置按条目计**：条目被扣在 `hold` / `unknown` 时该记录整体计 1，即使个别槽带着值——评审者从被扣住的条目里拿不到可用产出；无条目同样计 1（没有任何产出）。`unknown` / `invalidated` / 请求失败的分列计数由 `EvaluationMetrics.confusion(_:)` 给出（§9），不折进同一个数字。
7. **`field_precision` 另有 12 条逐字段行**（`EvaluationSlice.stratum == .field`，`key` 为字段 rawValue；PLAN §8.2"12 字段分别报告"）。逐字段分母之和等于 pooled 分母，因此既不会重计也不会漏计。逐字段行的 `caseCount` / `clusterCount` 数的是**对该字段有过候选断言的记录与项目簇**，不是整个切面的规模：否则 40 条记录里只有 2 条填过的字段会因为"切面有 40 条"而躲过 §5 的稀疏门禁，并可被单独引用。`.field` 行的 `clusterInterval` **恒为 nil，且不属于下面 §5 的三原因之一**：那一层按构造不计算簇级带，它的 `clusterCount` 只说明有多少项目断言过这个字段（判别某条 pooled 行为何没有带，才用 §5 的 (a)(b)(c)）。逐字段行只出在 **overall 层**：PLAN §8.2 的"12 字段分别报告"挂在 `field_precision` 一行，而"每 Profile/类别"挂在"分层"一行，两者相交成的 field × Profile × 类别网格不是 PLAN 要求的东西，把它铺开会用几百行表格淹没真正薄的那几格（要按层看某一字段时，2b 的运行器可以按切面重跑同一套判据）。逐字段行只带 Wilson 区间，不带簇级区间——那里 nil 是**按构造**而非对稀薄的判断，pooled 行才报簇区间。

## 4. 区间

- **Wilson 95%**（`EvaluationRate.wilson95Lower/Upper`）：这些比率贴近 0 或 1，正态近似会给出越出 [0,1] 的对称区间，把十几条观测的确信度报虚。区间值由 `wilsonBoundsTheStandardWay` 按教科书数值钉死（5/20 ⇒ 0.1119–0.4687 等）——此前一个把 `/n` 写成 `/(1 + z²/n)` 的错误实现会让**所有**区间退化成 [0,1]，却仍能通过任何"端点是否落在单位区间内"的断言。
- **按项目簇 bootstrap**（`ClusterBootstrap.summarize`，入口只有一个）：带是重抽样比率分布的两个顺序统计量。**两次及以下**抽样时 2.5% 与 97.5% 的下标落在同一个样本上，报出来的是**宽度为零的"置信带"**；再多几次的近秩分位数则只是那批簇的极值（20 次时下界就是样本最小值），照样被读成 95% 带。`ClusterBootstrap.minimumResamples = 20` 是本 harness 停止把这种结果称为"带"的地方——它不是数学边界，与 `minimumClusters`、`sparseCaseLimit` 同为策略值（§5），PLAN 未规定重抽样次数；`Request.init` 与 `EvaluationRunIdentity.init` 都只拒绝 `resamples < 1`（要 0 次抽样不是"少一列"，而是根本没要这次测量），其余不垫高。重抽样的单位是 `clusterKey`（项目簇），不是记录。同一项目的多个文件不是独立观测；按记录抽会把"一个项目的形状"读成普遍性。簇数 < 5（`minimumClusters`）时返回 nil——少于这个簇，区间宽度是种子的产物而不是数据的。任一次重抽样的分母为 0 ⇒ **该指标的整体区间为 nil**（这一层薄到给不出簇级区间），而不是把那次抽样丢掉后照报：丢掉后剩下的恰好都是"有答案的簇"，区间会在最需要报宽的地方被压窄。失效逐指标独立、且与抽样顺序无关——某指标被判无定义不会带走同一次抽样里其他指标的份额（`invented_fill_rate` 排在 `precision_auto` 之后，正是顺序敏感会露馅的位置）；该性质由 `EvaluationMetricsTests.voidingIsOrderIndependent` 固定，把实现退回"清空 + break"时该用例会失败。七个指标共用同一组抽样索引（索引只与种子和簇数有关）。分位点（2.5%/97.5%）直接取自重抽样分布，不做正态拟合：少量簇的比率分布是块状的，**块本身就是发现**。
- 抽样使用 `SplitMix64`；`SystemRandomNumberGenerator` 跨版本不保证序列，而一次测量必须能从记录里复跑。种子与重抽样次数**只有 `EvaluationRunIdentity` 一份**：`EvaluationReport.init` 不再接受 `EvaluationMetrics.Request`，报表里的每一条带就是用发布出来的那两个数算的。此前两处各存一份（`Request` 默认 2000，身份由调用方另填），于是"发布 1 次抽样、实际按 2000 次算带"这种矛盾在类型上就能写出来，而 §5 的第三个 nil 原因（短抽样）恰恰是读者从发布值读的——那个数说谎，(c) 就永远不会出现，读者对带的信任度判断直接失真。`EvaluationRunIdentity.init` 也拒绝 `bootstrapResamples < 1`，因为它现在就是本次计算用的次数。

## 5. 稀疏与"可引用"

**本节的阈值是 harness 自定的策略，不是 SPEC/PLAN 条款。** SPEC 与 PLAN 都没有规定最小格样本量（SPEC §10.1.6 讲的是 ≥150 条独立评测集；PLAN §13 第 1 条把"质量接受阈值"列为待 Owner 决策，并写明"未批准前只能报告测量，不宣称最终质量通过"）。本文此前把它写成 SPEC 条款，属于引用失真，已更正。取 30 的理由是常见的最小格经验值，写在这里是为了可被争辩而不是被藏在代码里。

- **门禁的单位是记录数**：`EvaluationSlice.caseCount` 是本切面被判定的记录条数，`isSparse = caseCount < 30`。它不看 `rate.denominator`：§3 之后各指标的 `rate.denominator` 单位由 `EvaluationMeasure.unit`（`.records` / `.slots`）声明，同一个切面里既可能是记录也可能是槽位观测——3 条记录 × 12 槽能凑出 36 个槽位观测，150 条记录会让槽位分母上千，用槽位数当门禁两头失真（薄样本被放行、干净样本里天然小分母的指标被永久封死）。
- Wilson 区间按**该指标自身的观测单位**计算（`EvaluationMeasure.unit`）：记录级比率就在记录数上取置信宽度，槽位级比率就在槽位数上。那是这批观测自身的置信宽度，与"够不够格下结论"是两个问题，两处的单位各写在文档里。
- 分母为 0 时 `estimate == nil` 且 Wilson 端点为 nil（没测过的东西不存在"0 分"这种质量结论）。PLAN §8.2 要求"所有零分母标 N/A"：`nil` 就是那个 N/A，报表不得把它印成 0，也不得印成 100%。
- `clusterInterval` 为 nil 有**三个不同的原因**，读者必须能分开（这三条只描述会计算簇级带的 pooled 行；`.field` 行按构造没有带，见 §3 第 7 条）：**(a)** 本切面簇数 < `ClusterBootstrap.minimumClusters`（5），簇太少、无可变异性；**(b)** 至少一次重抽样的分母为 0，即该指标在这一层过薄（§4）；**(c)** `identity.bootstrapResamples < ClusterBootstrap.minimumResamples`（20），抽样太少：两次及以下零宽，再多也只是簇样本的极值。此条判别只在结果经 `EvaluationReport` 发布时成立——那里带的抽样次数就是 `identity` 的那一份；直接调 `slices(for:request:)` 的调用方（测试就是这么用的）要自己保证 `request.resamples` 与它声称的身份一致，`Request` 本身不记录发布值；`resamples < 1` 由 `Request.init` 直接拒绝，不留这一档。三者都只关掉簇级区间，**不影响 `isQuotableOnOwnMerits`**：记录数达标的切面照样可以引用率（配 Wilson），只是没有簇级区间可报（`resamplesComeFromTheRunIdentity`）。`(c)` 是请求可以合法表达的一种形态——**只要率、不要带**——因此重抽样层既不 `precondition` 崩溃也不把参数垫高：一次跑批不该因为关掉一列而整体中止，而静默改写运行参数正是最难被读者发现的改动。每个切面都随区间一起给出 `clusterCount`：`(a)` 时它 < 5，`(b)` 与 `(c)` 时它 ≥ 5，这两者靠 `EvaluationRunIdentity.bootstrapResamples` 区分——那个数与算出这批切面所用的抽样次数一道发布（**同一个来源**：`EvaluationReport` 的次数取自 `EvaluationRunIdentity.bootstrapResamples`，报表层不留第二份，见 §4），读者用同一份报告就能把「太薄」与「没人要带」分开（`singleDrawHasNoBand` 钉住率不受影响，`resamplesComeFromTheRunIdentity` 钉住带确实按身份里的次数计算——两半只差那一个数：1 次时没有带，2000 次时有带）。`resamples: 2` 与 `resamples: 1` 同属 (c)：一次抽样是"没有带"，两次是"带是舍入产物"，对读者的处置一样——只引用率，不引用带。`isQuotableOnOwnMerits` 不看它，因为"能不能引用这条率"与"有没有簇级区间"是两个问题。
- 可引用性（`EvaluationSlice.isQuotableOnOwnMerits`）= 记录数达标 **且** 该指标确有观测（`rate.denominator > 0`）。两半缺一不可：只有前半，`precision_auto` 在"没有任何可自动发布产出"的运行里会因为 40 条记录而变得可引用，而它其实什么都没看过。
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
| `pendingAdjudicationExcluded` | `GoldDataset` 的可计数集合不含 N 条争议记录（PLAN §8.1 要求报告排除量）。披露行同时写出本次判定的 M 条里有 K 条仍为争议，并按**实际生效的门禁**说明本行为哪一句作保：K>0 指向 `caseSetNotDerivedFromSplit` 的否决；K=0 而集合已因越界/重复被否决时写"不为「本次分母不含争议记录」作保"；两者皆无才写"故本次分母不含争议记录"。**排除动作发生在数据集层，这一行永远不等于"本次运行做过排除"**（旧措辞"数据集把 N 条争议记录排除在可计数集合之外"会被这样读，已改） | 否——仅披露 |
| `caseSetNotDerivedFromSplit` | 被判定记录不在 `Report.countableRecordIDs` 内、同一记录被判定两次，或该记录自身仍为 `adjudication_pending` | 是 |
| `stratumQuotasUnmet` | `Report.shortfalls` 非空：某些 Profile x 类别格少于 `GoldDataset.stratumTarget`（10）条，即未达 PLAN §8.1 的抽样计划。仅披露的算术理由：格数是 2 Profile x 8 类别 = 16，每格 10 条要 160 条，而 §8.1 的独立样本下限是 150——**总数达标与每格填满本就冲突**，用它否决会让质量结论在满足 PLAN 自身要求的数据集上也不可达；而薄格在 §5 的 30 条下限处本就不可单独引用，保护并不落空 | **否**——仅披露 |
| `identityDisagreesWithDataset` | 运行身份与所测数据集不是同一批：`goldRevision`↔`datasetRevision`、`splitID`、`casePackVersion` 任一项不一致。PLAN §8.2 的门禁就是"这些标识全部一致"；判定用例只带记录号、带不出 revision，所以这一层没有别的检查会发现它 | 是 |
| `eligibilityStateInconsistent` | 候选在未达 `validated` 的条目上带有可自动发布的槽位 | 是 |

`isQualityClaimAllowed = 不存在否决型阻塞`。

九类里两类只披露不否决（表中"否"）。这一划分本身由 `blockerPartitionIsDeliberate` 钉住：`preventsQualityClaim` 读的是一个显式集合，新增一类不会静默继承任何一边——想让它只披露，必须同时改表、改集合、改用例。

`caseSetNotDerivedFromSplit` 是上一条得以成立的前提：排除动作发生在 `GoldDataset`，报告层只披露数量；若没有"用例必须落在可计数集合内"的核验，披露就只是一句无人为之背书的话。重复判定同一条记录也走这个 blocker——同一个来源计两次会直接改写所有分母。

披露行自己就得把话说圆：只报数据集排除数，那么一个把 id 表与审核状态算歪的运行器会让"争议记录已排除"成为一句无人报警的假话；报上本次用例中仍为争议的那个数，读者就能看见两个数是否一致（`pendingDisclosureIsAuditable`）。核验有**两条独立的路**，因为让它们一致的东西恰恰是人的细心：id 必须在 `Report.countableRecordIDs` 里（数据集口径），且该条记录自身的 `review.status` 不能还是 `adjudication_pending`（`CaseJudgement.pendingAdjudication`）。只有前者时，一个把 id 表和审核状态算歪的调用方会让"争议记录已排除"变成一句假话而无人报警。命中任何一条都**不静默剔除**：报告照旧给出这次实际喂进来的 `cases` 数，同时否决结论——把运行器接错藏起来，比让一次运行难看严重得多。

`eligibility_state` 与导出侧同源：`ManifestExport.revalidate` 把「条目自称可自动执行却不是 `validated`」判为 `eligibility_state` 违规。评测层遇到同一形状时**否决结论而不是替它兜底**——在一个程序自己不会写出的 manifest 上算出的 `precision_auto`，量的不是这个程序。判据放在报告层（`CaseJudgement.candidateState` 与槽位 `autoPublishable`），指标口径本身不动。

为什么争议排除只披露：一次运行确实测了它测的东西，把"有 3 条待裁决"当成整次运行作废，只会诱导人不登记争议。反之，**替身与样本不足必须否决**：合成数据可以把管线跑通、可以把分母做大，但不能认证任何质量门槛——这条与 `GoldDataset.meetsIndependentTarget` 只用 `reviewedCountable` 的口径一致。


### 6.1 建议阈值与差距（`EvaluationReport.targets`）

PLAN §8.2 在给出建议阈值的同时要求"**必须展示实际值与差距**"，并规定"阈值是建议、不是已批准政策；Owner 未批准前不能声称最终质量 Gate 已通过"。本层照此发布一张显示表，**不参与门禁**：`isQualityClaimAllowed` 只由 `claimBlockers` 决定，一条建议没达到不会否决，全达到了也不会放行。

| 指标 | 方向 | PLAN 建议值 |
| --- | --- | --- |
| `precision_auto` | 下限 | 0.95 |
| `coverage` | 下限 | 0.70 |
| `field_precision` | 下限 | 0.98 |
| `high_confidence_error_rate` | 上限 | 0.02 |
| `hold_rate` | 上限 | 0.30 |
| `invented_fill_rate` | 上限 | 0（"观察错误数为 0"） |

每行除建议值外还带**本次实测**、**差距**（`shortfall`：正数=未达，≤0=已达；实际值为 nil 时它也是 nil——没测过的东西谈不上差距）、**人口**（该率真正的分母）与**判定记录数**、以及该指标的簇级区间。人口与记录数分开是必要的：一次混跑两个 Profile 的运行，`precision_auto` 的人口为 0、判定记录数仍是 40，写成"40 条都没达标"是把"无法判定"报成"判输了"，与 §3 的 N/A 规矩冲突。

差距照发，即使该切面自己不可引用（样本不足 30 条、或没有带）：把不达标的差距藏起来才是真正的静默兜底。能不能引用由 `isQuotable(_:)` 回答，它读的是 §5 的同一批事实，所以两处不会给出不同答案。

同一段 PLAN 里还有两条**故意不做成表**：`关键反例不能出现系统性混淆` 与逐字段分别报告——PLAN 没给它们数值，硬造一个就是把 harness 的猜测披上 PLAN 的权威。它们的落点是 `confusion`（含每类别记录数）与 12 条 `.field` 行（各带自己的 `caseCount`/稀疏判定），由读者按分布读，而不是由本层判"通过/不通过"。

## 7. "相等"只有一个定义

`ValueNormalization.folded/equal`（`Sources/FormaCore/Mapping/ValueNormalization.swift`）：`folding([.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`（POSIX en_US）→ 去首尾空白。它是**弱**比较：`2026` 与 `2026年` 是不同值，简繁汉字是不同码位（不是折叠关系），要做语义归一必须由 Profile 自己声明。

`equal` 对可选值：两边都缺 ⇒ 相等；一边缺 ⇒ 不等；**空串或纯空白与任何值都不等**，包括另一个空串——"没写"和"写了个空的"都不是断言（见 §3 的 `withheld`）。

`ManifestValidator` 与评测指标共用它。这不是代码复用偏好：如果评测用一种相等、发布校验用另一种，就会测出一条程序里根本不存在的判定路径。

一个来自存储层的连带事实：`Bounded.text` 有 4 字符下限，短于 4 字符的 `conflicts`/`evidenceIDs` 文本会被丢弃。夹具里写两字的冲突说明会静默失效，因此测试用"与第 3 页的记载相互矛盾"。

## 8. 尚未实现

| 项 | 归属 | 前置条件 |
| --- | --- | --- |
| ~~评测运行器（逐条送样、重试、并发上限、超时）~~ | P3-A 切片 2b：**已实现**，见 §10 | 无 |
| ~~成本 / Token / TTFT / P95 采集~~ | P3-A 切片 2b：**已实现**，见 §10 | 无 |
| ~~离线规模基准（合成夹具、分阶段计时、并发扫描、故障量化、结果结构）~~ | P3-A 切片 2c：**已实现**，见 §11 | 无 |
| 真实 Provider 适配与网络隔离开关 | P3-B | 凭据、外发授权、预算 |
| ≥150 条独立核实的真实金标准样本 | P3-B | 隔离 DEVONthink 库、授权目录 |
| 报告发布与看板 | P3-B | 上述全部 |
| 场景配额的可交叉计数（一条记录同时计入多个场景） | 冻结 schema（`gold-record-1.0`） | `scenario` 为单值对象，需 schema 升版才能表达；当前按互斥格子计数，见 §6 |

首段那串用例名不是装饰：`DocumentationIntegrityTests` 会读本文，断言每个名字都能在 `Tests` 源码里找到对应的 `func`（改名而未同步文档会让它失败）。

本文的 §3、§5、§6 是三处**口径**，§10 是第四处（运行器语义），§11 是与之相邻的基准与阶段语义（不新增分子分母）；切片 2b / 2c 与 P3-B 不得另立定义；要改先改本文。

## 9. 接口事实

| 类型 / 成员 | 位置 | 不变量 |
| --- | --- | --- |
| `FieldJudgement`（+ `Verdict`）、`CaseJudgement` | `Sources/FormaCore/Evaluation/EvaluationJudgement.swift` | 判定顺序固定；`publishableStatuses = {evidenced, inherited}` 只喂 `autoPublishable`，而 `autoPublishable` 只喂 §6 的核验 |
| `CaseJudgement(gold:entry:projectKeys:)` | 同上 | `projectKeys` 是运行上下文的 `candidate_ref → 项目簇键` 表；缺表而条目只有未解析 ref 时判项目不匹配（§3 第 2 条） |
| `CaseJudgement.isAutoMapped` / `.mainDecisionIsCorrect(runProfile:)` | 同上 | `isAutoMapped = state == .validated && eligibleForAutoExecution`；主决策 = Profile ∧ 项目 ∧ 类别 |
| `EvaluationMeasure.unit` / `.population(in:runProfile:)` | `Sources/FormaCore/Evaluation/EvaluationMetrics.swift` | 单位由指标声明（`.records` / `.slots`）；单条判定的分子分母跨用例可加；`runProfile` 为 nil 时 `precision_auto` 与 `high_confidence_error_rate` **没有人口**（分子分母都是 0 ⇒ N/A，不是 0%，§3 第 2 条） |
| `EvaluationMeasure.population(in:)`（逐字段） | 同上 | 只为 `field_precision` 的 12 条 `.field` 行服务；行分母之和 == pooled 分母 |
| `EvaluationRate` | 同上 | 分母（槽位观测）为 0 ⇒ `estimate` 与 Wilson 端点为 nil |
| `EvaluationSlice.caseCount` / `isSparse` / `sparseCaseLimit` | 同上 | 可引用性以**该行自身证据的记录数**计（pooled 行 = 切面记录数；`.field` 行 = 对该字段有候选断言的记录数）；`sparseCaseLimit = 30` 是 harness 策略（§5） |
| `ClusterBootstrap.summarize(measures:rows:indices:resamples:seed:)`（`Row` 把簇键与该行的分子分母绑在一起）| 同上 | 唯一公开入口；`indices` 是**表内行下标**（不是切面内的位置），`rows` 由调用方按 `allCases` 列序**每种归属算一次**并缓存（`slices(for:)` 的 `tables`：overall / category 用 `request.runProfileID` 那一层，Profile 切面用自己的 key——不同归属本就是不同的测量，不共用）；簇总计直接走这份分组，一行的簇键只在一处被读到；簇 < `minimumClusters`、任一无定义抽样、或 `resamples < minimumResamples` ⇒ 该指标区间为 nil（§5 的 (a)(b)(c)） |
| `EvaluationMetrics.slices(for:request:)` | 同上 | 切面 = overall ∪ 出现的每个 Profile ∪ 出现的每个类别（另有 §3 第 7 条的 12 条逐字段行）；一条记录属于两个 Profile 时在两个切面各出现一次，绝不计为两条记录；Profile 切面把**该切面的 Profile** 当作 `runProfile`，其余切面用 `request.runProfileID`，为 nil 时 `precision_auto` 与 `high_confidence_error_rate` 在那些行**没有人口**（N/A，§3 第 2 条）；分子分母表按归属各算一次并缓存，不同归属不共用（它们本就是不同的测量） |
| `EvaluationMetrics.confusion(_:)` | 同上 | 键形如 `mapped->absent`；无条目用 `absent` |
| `EvaluationMetrics.refusals(_:)` → `Refusals` | 同上 | PLAN §8.2 的拒判原因；`byRecordState` 只数未自动落地的记录，`bySlotStatus` 遍历全部记录数未填的期望槽；两个字典不得合并（§3 第 5 条），后者的总数与 `missed_fill_rate` 的分子一致 |
| `EvaluationRunIdentity` | `Sources/FormaCore/Evaluation/EvaluationReport.swift` | 替身标志是身份的字段，不是脚注 |
| `EvaluationReport`（`Blocker`/`Finding`/`isQuotable`/`targets`） | 同上 | 门禁在报告层，不在调用方；`claimBlockers` 逐项披露，被否决的运行仍原样发布各切面（否决不是隐藏）；每条带所用的抽样次数与种子取自 `identity`，报表层不留第二份 |
| `MappingAnswering.isSubstitute` | `Sources/FormaCore/Mapping/MappingEngine.swift` | 协议扩展默认返回 `true`：不声明就是替身，新 conformer 不会静默解锁质量结论；只有 `ProviderMappingClient` 显式返回 `false` |
| `MappingAttempt.timeToFirstTokenMilliseconds` | `Sources/FormaCore/Mapping/ProviderMappingClient.swift` | 仅流式应答可填；非流式请求永远为 nil，`ProviderMappingClient` 从不设置它（§10.3） |

共享夹具：`Tests/FormaCoreTests/EvaluationTestSupport.swift`（`EvaluationFixtures.gold/candidate/values/judgement/projectKeys`）。`candidate` 写出的 association basis 用生产原文格式，项目对错只能通过 `projectKeys(for:wrong:)` 表达——夹具自己把簇键塞进条目的话，测的就不是要跑的那条路了。指标与门禁两个 suite 必须用同一套构造器，否则会在 12 槽与 4 字下限这类细节上各自漂移。

## 10. 离线运行器语义（切片 2b）

本节定义**运行器怎么跑**，不改 §3、§5、§6 的分子分母。运行器只替换一条缝：谁应答。

### 10.1 组合与默认

`EvaluationRunner` 只做四件事：批计划（`MappingEngine.plannedBatches`，因此分组、opaque ref 与附加证据行与生产同一条代码路径）、校验（`ManifestValidator`）、判定（`CaseJudgement`）、门禁（`EvaluationReport`）。它没有 Provider 成员，也不构造 `ProviderMappingClient`：谁应答由调用方注入（`MappingAnswering`），因此"默认禁止真实 Provider 请求"是类型性质而不是需要记住的开关（`standInRunIsRefused`）。样本、上下文、证据行全部由 `EvaluationFixture` 合成，磁盘上不读任何东西；未实测的 `sizeBytes`/`sha256`/`modificationTimeNanoseconds` 一律 nil。

替身通过 `MappingAnswering.isSubstitute` 暴露自己，该标志进入 `EvaluationRunIdentity.isSubstitute`，而 `EvaluationReport` 的门禁据此否决每一条质量结论。`isSubstitute` 的协议默认值是 `true`：fail closed。

### 10.2 样本 / 请求 / attempt 三层

| 层 | 单位 | 定义 |
| --- | --- | --- |
| 样本（sample） | 一条金标准记录 | 分母只由 `GoldDataset.Report.countableRecords` 决定，**重试与拆批都不改变它** |
| 请求（request） | 一个 batch | `MappingEngine.plannedBatches` 产出的批；批计划把同一候选的文件放进同一批，超过 `entryLimit` 再拆 |
| attempt | 一次 `MappingAnswering` 调用 | 首次请求 + 重试；批内的 Provider 自身重试（限流、单轮修复）计入 attempt 的 `requests`，不改变 attempt 数 |

所以 `attemptCount` 永远 ≥ `issuedRequestCount` ≥ 1，`sampleCount` 与前两者无关。`requestCount` 是计划中的批数，`issuedRequestCount` 是真正发出的批数；取消发生在下发之前的部分算**未下发**，不算失败请求（`cancellationIsDisclosed`）。请求行 `EvaluationRequestObservation` 按批序保留 `recordIDs`，因此任何一个数字都能回到它覆盖的记录。

### 10.3 延迟、首字与"没有观测"

- `LatencyDistribution` 取**Provider 上报**的 `MappingAttempt.latencyMilliseconds`；为 0 视为"未上报"（0 是该字段的默认值，不是观测），因此替身全零延迟不会给出 p50 = 0 ms。
- `FirstTokenLatency` 只有 `MappingAttempt.timeToFirstTokenMilliseconds` 非 nil 时才有样本。非流式请求只有一个观测——整段响应——把它当首字延迟会让慢的非流式 Provider 看起来首字很快，所以该字段对非流式路径永远为空，报表打印"未观测"而不是 0 ms（`firstTokenIsAbsentUnlessObserved`）。
- 百分位沿用 §4 已经使用的最近秩约定（`sorted[Int(Double(count - 1) * q)]`），同一份报告里的区间与延迟不会被两套约定算出不同结果。
- 任一层没有观测时，该层的所有分位数为 nil；`sampleCount = 0` 与 `estimate = 0` 是两种不同的陈述。

### 10.4 Token 与成本

| 事实 | 字段 | 规则 |
| --- | --- | --- |
| 来源 | `MeasurementKind` | `measured` / `simulated` / `extrapolated` / `unavailable`，四者互不混用 |
| Token | `TokenUsage`（input/output/cacheRead/cacheCreation，各自可缺） | 未上报的槽是 nil，永不当 0；任一侧求和只会把来源降格，不会升格 |
| 计价 | `TokenPricing`（id/provider/modelID/currency/effectiveOn/source/四个单价） | 由调用方给定；FormaCore 不自带任何价格 |
| 成本 | `CostEstimate` | `amount = 实测 usage × 给定单价`；`isRealSpend` 仅在 `kind == .measured` 为真 |
| 外推 | `thousandSampleExtrapolation` | `1000/N × 实测费用`（PLAN §8.2），`basis` 记录它从哪一层缩放而来，绝不作为支出发布（`costCarriesItsProvenance`） |

替身上报的 usage 一律标 `simulated`，无论数字多大；缺 usage 时 `hasCounts == false`、`total == nil`、`amount == nil`，不编造 Token 数（`usageIsNeverInvented`）。

### 10.5 并发、吞吐与部分失败

`maximumConcurrency` 是配置上限，`observedConcurrency` 是运行器在下发时实际达到的峰值——两者都发布，否则并发实现的 bug 会伪装成配置。吞吐量按本次运行墙钟计算，是**这一次执行**的事实，不是 Provider 的能力结论。单个请求失败不会中止运行：记录留在分母里，`candidateState` 记为 `.unknown` 并由 §3 的 hold 与拒判原因口径承接（`requestsAreBatchesNotAttempts`）。

单次请求超时由运行器用任务竞速实现，不依赖应答方自觉：超时后取消该调用，并保留被取消调用仍返回的记账（已计费的请求不能因为"不再等待"而从遥测里消失）（`deadlineBoundsAHungAnswer`）。

### 10.6 运行身份与可导出报告

`runID` 由数据集（split、casePack）、配置（Profile 版本、Provider/model、并发、超时、重试、批上限、抽样、种子、计价版本）与样本集共同派生，同一数据集 + 同一配置重跑得同一 `runID` 与同一 `manifestID`（`runIsReproducible`）。`EvaluationArtifact` 是导出体：身份、边界、遥测、报告，**不含 Manifest**（相对路径、组路径与证据摘录不进可分享文件）；替身与薄样本的否决随数字一起导出，不生成"只留结论"的摘要（`exportIsRedactedAndSelfDescribing`）。数据集边界单独成节：`promptSideRecords`、`withdrawnRecords`、`pendingAdjudication`、`unaccountedRecords` 与 `evaluated` 并列发布，被排除的材料从不进入应答，也不进入分母（`boundaryDisclosesExclusions`）。

### 10.7 本节的限制

本节全部数字来自合成样本与确定性替身，只证明运行器与算法层的正确性和开销，**不证明任何模型的质量**，也不能替代 macOS 上 10,000 文件扫描的性能验收（见 `docs/MACOS-VALIDATION-BACKLOG.md`）。

## 11. 规模基准与阶段语义（切片 2c）

本节只定义**基准如何测量**，不新增分子分母；实验定义、命令与结果在 `docs/EVALUATION-BENCHMARK.md`。三种基准不得互相替代：运行器规模基准 ≠ 真实文件扫描基准 ≠ Provider 基准。

### 11.1 夹具与身份

`EvaluationBenchmarkFixture.Spec` 的 `version`、`seed`、记录数、簇数、few-shot 数与撤回数共同决定 `fixture_id`；同一 spec 在任何进程生成相同的 `GoldRecord`、`GoldSplit` 与 countable 集合。夹具走生产 `GoldDataset` 的 split/泄漏校验，批计划走生产 `MappingEngine.plannedBatches`；基准不重写 Mapping、Validator、Judgement 或 Report。合成路径、nil 的 `sha256`、`.synthetic` 审核标记说明没有真实文件被读取。

`benchmark_id` 只绑定 fixture 与场景（逻辑身份），跨机器可复现；`measurement_id` 与 `executed_at` 绑定本次测量，绝不把两台机器的结果写成同一次测量。2c 不改变 2b 的 `runID` / `manifestID` 派生材料（`runIsReproducible`）。

### 11.2 阶段耗时与总耗时

`EvaluationStageTimings` 记录 7 个阶段（夹具构造、批计划、请求执行、Manifest 校验、用例判定、报告/指标、工件序列化），每阶段带墙钟毫秒、观测数、`MeasurementKind` 与不可观测原因。第 8 项"总耗时"不是阶段：`total_wall_clock_milliseconds` 用同一单调时钟在整段执行外单独测得；`sumOfStageMilliseconds` 只是下界，`unaccountedMilliseconds` 明列未覆盖部分。夹具构造与运行器执行分别计时，互斥阶段不相加冒充总耗时。`EvaluationArtifact` 升到 schema 1.1 以携带阶段明细；旧版导出缺该键时解码为 nil，不伪造耗时。

### 11.3 守恒与故障注入

基准的固定断言是状态机关系，不是性能阈值：`sampleCount == countableRecordIDs.count`、`requestCount >= issuedRequestCount`、`attemptCount >= issuedRequestCount`、`observedConcurrency <= maximumConcurrency`，以及 `succeededRequests + failedRequests == issuedRequestCount`、`retryCount == attemptCount - issuedRequestCount`。2c 同时修正 2b 的一处记账漏洞：在首个 attempt 之前就被取消的批次现在不算"已下发请求"，否则它会以 `attempts == 0` 同时破坏上述不变量并把"我们停了"记成"请求失败"（`cancellationAccounting`）。

故障（失败比例、重试、超时结果、永久不可用、延迟、部分完成、取消、未下发）只在替身层注入 outcome；失败样本始终留在合法分母中。`SKIP_VERIFIED` 属于 Import 状态机，不在运行器里实现，也不改变分母；not-issued 只是取消造成的调度事实。

### 11.4 来源与限制

`execution_telemetry` 直接复用 2b 的 `EvaluationTelemetry`（含 measured / simulated / extrapolated / unavailable）。本机墙钟与 `ru_maxrss` 可以是 `.measured`，但替身的 usage、费用、模型延迟仍是 `.simulated` / `.unavailable`，且随每个结果导出 `limitations` 与 `substituteAnswers` 否决。峰值内存不可得时输出 `unavailable` 而非 0。共享 Runner 的绝对耗时不设合并 Gate；`--baseline` 只做可解释的倍率比较。合成 10,000 记录的内存与吞吐曲线只描述算法层，不预测 M9 的真实 10,000 文件扫描（含 IO、hydration 与 PDF 抽取）。

正确性由 `EvaluationBenchmarkTests` 覆盖：夹具可复现（`fixtureReproducibility`）、10k 身份唯一（`tenThousandIdentities`）、边界分母（`boundaryListsAreNotCountable`）、样本/请求/attempt 守恒（`sampleRequestAttemptInvariant`）、拆批守恒（`batchSplittingConservation`）、并发上限（`concurrencyBound`）、重试记账（`retryAccounting`）、取消记账（`cancellationAccounting`）、缺失观测（`missingObservationSemantics`）、阶段覆盖（`performanceStageCoverage`）、脱敏与 schema（`redactedExportAndSchema`）、身份区分（`benchmarkIdentityVersusMeasurement`）、无 Provider 访问（`noProviderAccess`）。10k 合成基准实测到 `Manifest.entry(for:)` 线性扫描造成的 O(n²) 判定开销后，runner 改为一次建索引（保留首个匹配），判定规则与 §3、§5、§6 的口径均未改动，见 `docs/EVALUATION-BENCHMARK.md` §9。

## 12. 外发与脱敏边界（切片 2d）

本节不新增分子分母：§3 / §5 / §6 仍是唯一的指标口径。切片 2d 只约束"哪些字节可以离开机器"，契约、覆盖矩阵与威胁矩阵在 `docs/PRIVACY-EGRESS-CONTRACT.md`。

对评测层的直接影响只有三处：`EvaluationRunner` 默认 `allowCloud == false` 且替身运行不构造 Provider 客户端；`EvaluationArtifact` 与 Benchmark Result 不含 Manifest、路径、证据正文或凭据，schema 1.1 的 `stage_timings` 缺失时解码为 nil；`MappingAttempt.requestIdentities` 按 wire 请求记录语义摘要与线摘要，二者不得混用。2a 的分母、2b 的 Sample/Request/Attempt 语义、2c 的基准守恒与 `runID` 派生材料均未改动（`artifactVersionCompatibility`）。真实 Provider 外发与脱敏前后同模型判别力对照仍为 P3-B / BLOCKED。

## 13. 导入资格策略指标（切片 2e）

本节新增的是**资格策略**的指标，不改 §3 / §5 / §6 / §10–§12 的任何定义。策略与数据流见 `docs/IMPORT-ELIGIBILITY-POLICY.md`。

| 指标 | 分子 | 分母 | 单位 | 样本来源 | `MeasurementKind` | 适用 Profile | 不可用条件 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `false_exclusion_rate` | 被独立标注为应保护的业务样本中判为 `EXCLUDE` 的数量 | 同一 fixture 中应保护样本总数 | records | 独立标注的业务样本 | 调用方声明（合成 fixture 必须为 `simulated`） | 该次运行 Profile | 无应保护样本 |
| `review_rate` | `REVIEW` 数 | `discovered` | records | 本次 `SourceListing` | 同上 | 该次运行 Profile | `discovered == 0` |
| `mapping_candidates_reduction` | `discovered − include` | `discovered` | records | 本次 `SourceListing` | 同上 | 该次运行 Profile | `discovered == 0` |
| `token_reduction` | `exclude × tokensPerFile` | `discovered × tokensPerFile` | tokens | 调用方假设 | `extrapolated` | 该次运行 Profile | 无真实 usage 且无假设 |
| `estimated_import_bytes_reduction` | 被排除记录的逻辑字节 | 全部已知逻辑字节 | logical_bytes | `size_bytes` | `extrapolated` | 该次运行 Profile | 无任何记录报告大小 |

规则：

- **false exclusion 的分母**必须是"已独立标注为应保留的业务样本"，不能是"所有被排除记录"——后者会把漏排稀释掉（`businessMaterialInWeakDirectoriesIsProtected`）。合成数据只能报告 synthetic fixture false exclusion，不能宣布真实业务误排除率达标。
- **零分母**统一输出 N/A（`value == nil` + `unavailableReason`），不是 0%（`zeroDenominator`）。
- **逻辑体积 ≠ 物理磁盘**：`estimated_import_bytes_reduction` 的 `assumption` 明写硬链接、APFS clone、OneDrive 占位与压缩使物理节省未知（`dryRunConservation`）。
- **Token** 只有在调用方给出每文件假设时才输出，且标为 `extrapolated`；不得写成真实 Token 节省或费用减少（`tokenReductionAssumption`）。
- 策略指标与 2a–2d 的质量/运行器/基准指标并列报告，不合并、不互相替代。
- 导出统计只含计数、规则 ID、决策与 digest，不含路径、文件名或证据正文（`exportIsPathFree`）。
