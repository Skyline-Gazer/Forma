# Forma 离线评测口径与结论门禁（EVALUATION-METRICS）

> 状态：P3-A 切片 2a。本文定义**指标的可执行口径**与**结论门禁**。
> PLAN §8.2 给出指标名称与验收意图，本文给出分子分母。三者必须同步，顺序是：**先改 PLAN（需求源）→ 再改代码 → 最后更新本文**。本文不是实现真值的背书；口径的实际行为以代码为准，且下列性质各有用例固定：两套单位各自的分母（`coveragePopulation`、`precisionAutoPopulation`、`perFieldRows`）、可引用性单位（`sparsityCountsRecords`）、未命名 Profile 的运行不给出精确率而非 0%（`unattributedRunHasNoPrecisionRow`）、逐字段行按自己的证据判稀疏（`fieldRowSparsityFollowsItsEvidence`）、无定义抽样逐指标失效且与顺序无关（`emptyDrawVoidsInsteadOfSkipping`、`voidingIsOrderIndependent`）、无观测与无区间的区别（`measureWithoutPopulationHasNoInterval`、`clusterResampling`）、拒判原因的单位（`refusalsNameTheReasons`）、用例集来自版本化 split（`casesMustComeFromTheCountableSplit`）。

## 1. 目的与范围

### 1.1 本文要解决的问题

一个"准确率"可以容纳四种完全不同的事实：引擎没答、答错、答案被同条目其他证据反驳、没人要这个答案却填了。合同（SPEC）对这四种的处理不同，评审者据此做的决定也不同。把它们合成一个数，就等于把四种后果压成一个数字。

因此本文的第一职责是**固定每个指标看见什么、以什么单位计**：一条记录还是一个槽位观测。

### 1.2 本切片做什么

- 把一份金标准记录与引擎产出的一条 `ManifestEntry` 判成槽位级结论（§2）。
- 按 PLAN §8.2 的名称计算七个比率，声明各自单位（`EvaluationMeasure.unit`），并公开分子分母（§3）。
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

`CaseJudgement` 另记录记录级事实，供 §3 的文件级比率直接取用：`candidateState`（引擎到达的 `DecisionState`，无条目为 nil）、`profiles`、`category`、`isAutoMapped`、`declaresHighConfidence`、`matchesProjectReference`、`matchesTargetCategory`、`mainDecisionIsCorrect(runProfile:)`；`FieldJudgement.autoPublishable` 只服务 §6 的 `eligibilityStateInconsistent` 核验，不再进入任何指标的分母。

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
   - 没有这张表、而条目的项目线索只剩一个解不开的 ref 时，判为**不匹配**而不是略过：不可核查的归属不能算通过。同理 `runProfile == nil`（运行没有唯一命名一个 Profile）时 `precision_auto` 与 `high_confidence_error_rate` 的分子恒为 0，分母照实给出。
   - **`runProfile == nil`（运行没有唯一命名一个 Profile）时这两项指标没有人口**：`precision_auto` 与 `high_confidence_error_rate` 的分子分母都是 0，报成 N/A 而不是 0%。写"0/40"等于给读者一个"观测到的 0% 精确率"，而事实只是运行没说这批文件是在哪个 Profile 下判的——按 §5 的可引用规则它还会被判为"确有观测"。多 Profile 运行由 **Profile 切面**给出这两个率（那一层的 `runProfile` 就是切面自己的 key），`coverage` / `hold_rate` / 槽位级三项不依赖归属，照常计。`EvaluationReport` 在身份里只有一个 Profile 时自动填入 `runProfileID`，多个时保持 nil 让上面这条生效。
   - 期望方留空（`project_reference` / `target_category` 为显式 `null`）的分量**真空满足**：harness 不能替标注员发明项目或类别，把它判成漏答是在为数据集自己的沉默扣分。
   - 一个文件被多个候选项目认领时，association 集合记的是**所有**认领者，不是程序挑中的那一个；这种歧义不会污染 `precision_auto`——冲突归属会阻断合格性，该记录落在分母之外（`computeEligibility` 的 `.conflict` 拒绝与 `associationReason` 失效路径）。残留风险只有调用方交来的表与它交来的 `conflictedSourceIDs` 不自洽。
3. **`contradicted` 留在槽位级分母里，不进分子**（`field_precision`）。被自身证据反驳的值是引擎确实给出过的断言，忽略它会让精确率报出程序没有的把握；而它作为状态（`.conflict`）会让整个条目失去 `eligibleForAutoExecution`，所以同一条记录本来就不在文件级 `precision_auto` 的分母里。
4. **"漏填"与"答错"分列两项，不得相加**：`missed_fill_rate` 的分子是 `withheld`（含候选只给空串/纯空白的槽，§7），`field_precision` 的分母只含候选断言，两者对同一个槽各说各话。`allowedUnknown`（期望方也放弃猜测的槽）不是期望槽，永远不进漏填分母——一致的未知不是漏答，这正是 PLAN 要求报告把两者分开的原因。
5. **拒判原因与混淆矩阵并列，各自单位**（PLAN §8.2 的"分层"行同时列了两者）。`EvaluationMetrics.refusals(_:)` 给出两个字典：`byRecordState` 按记录停在哪个 `DecisionState`（无条目为 `absent`）计未自动落地的文件；`bySlotStatus` 按政策留下的 `FieldOutcome.Status`（无条目同样 `absent`）计那些期望却没填的槽。**两者永不相加**——一个是文件数、一个是槽位数，相加就是本节第 1 条要避免的那种混淆。混淆矩阵说的是"引擎到达哪个决定"，这一对说的是"为什么没把参考答案要的东西写出去"，读者据此分配复核工作。键全部来自 manifest 自己的词汇表，报表不新造标签。
6. **搁置按条目计**：条目被扣在 `hold` / `unknown` 时该记录整体计 1，即使个别槽带着值——评审者从被扣住的条目里拿不到可用产出；无条目同样计 1（没有任何产出）。`unknown` / `invalidated` / 请求失败的分列计数由 `EvaluationMetrics.confusion(_:)` 给出（§9），不折进同一个数字。
7. **`field_precision` 另有 12 条逐字段行**（`EvaluationSlice.stratum == .field`，`key` 为字段 rawValue；PLAN §8.2"12 字段分别报告"）。逐字段分母之和等于 pooled 分母，因此既不会重计也不会漏计。逐字段行的 `caseCount` / `clusterCount` 数的是**对该字段有过候选断言的记录与项目簇**，不是整个切面的规模：否则 40 条记录里只有 2 条填过的字段会因为"切面有 40 条"而躲过 §5 的稀疏门禁，并可被单独引用。逐字段行只出在 **overall 层**：PLAN §8.2 的"12 字段分别报告"挂在 `field_precision` 一行，而"每 Profile/类别"挂在"分层"一行，两者相交成的 field × Profile × 类别网格不是 PLAN 要求的东西，把它铺开会用几百行表格淹没真正薄的那几格（要按层看某一字段时，2b 的运行器可以按切面重跑同一套判据）。逐字段行只带 Wilson 区间，不带簇级区间——那里 nil 是**按构造**而非对稀薄的判断，pooled 行才报簇区间。

## 4. 区间

- **Wilson 95%**（`EvaluationRate.wilson95Lower/Upper`）：这些比率贴近 0 或 1，正态近似会给出越出 [0,1] 的对称区间，把十几条观测的确信度报虚。区间值由 `wilsonBoundsTheStandardWay` 按教科书数值钉死（5/20 ⇒ 0.1119–0.4687 等）——此前一个把 `/n` 写成 `/(1 + z²/n)` 的错误实现会让**所有**区间退化成 [0,1]，却仍能通过任何"端点是否落在单位区间内"的断言。
- **按项目簇 bootstrap**（`ClusterBootstrap.summarize`，入口只有一个）：带是重抽样比率分布的两个顺序统计量。**两次及以下**抽样时 2.5% 与 97.5% 的下标落在同一个样本上，报出来的是**宽度为零的"置信带"**；再多几次的近秩分位数则只是那批簇的极值（20 次时下界就是样本最小值），照样被读成 95% 带。`ClusterBootstrap.minimumResamples = 20` 是本 harness 停止把这种结果称为"带"的地方——它不是数学边界，与 `minimumClusters`、`sparseCaseLimit` 同为策略值（§5），PLAN 未规定重抽样次数；`Request.init` 只拒绝 `resamples < 1`（要 0 次抽样不是"少一列"，而是根本没要这次测量），其余不垫高。重抽样的单位是 `clusterKey`（项目簇），不是记录。同一项目的多个文件不是独立观测；按记录抽会把"一个项目的形状"读成普遍性。簇数 < 5（`minimumClusters`）时返回 nil——少于这个簇，区间宽度是种子的产物而不是数据的。任一次重抽样的分母为 0 ⇒ **该指标的整体区间为 nil**（这一层薄到给不出簇级区间），而不是把那次抽样丢掉后照报：丢掉后剩下的恰好都是"有答案的簇"，区间会在最需要报宽的地方被压窄。失效逐指标独立、且与抽样顺序无关——某指标被判无定义不会带走同一次抽样里其他指标的份额（`invented_fill_rate` 排在 `precision_auto` 之后，正是顺序敏感会露馅的位置）；该性质由 `EvaluationMetricsTests.voidingIsOrderIndependent` 固定，把实现退回"清空 + break"时该用例会失败。七个指标共用同一组抽样索引（索引只与种子和簇数有关）。分位点（2.5%/97.5%）直接取自重抽样分布，不做正态拟合：少量簇的比率分布是块状的，**块本身就是发现**。
- 抽样使用 `SplitMix64`，种子与重抽样次数写入 `EvaluationRunIdentity`；`SystemRandomNumberGenerator` 跨版本不保证序列，而一次测量必须能从记录里复跑。

## 5. 稀疏与"可引用"

**本节的阈值是 harness 自定的策略，不是 SPEC/PLAN 条款。** SPEC 与 PLAN 都没有规定最小格样本量（SPEC §10.1.6 讲的是 ≥150 条独立评测集；PLAN §13 第 1 条把"质量接受阈值"列为待 Owner 决策，并写明"未批准前只能报告测量，不宣称最终质量通过"）。本文此前把它写成 SPEC 条款，属于引用失真，已更正。取 30 的理由是常见的最小格经验值，写在这里是为了可被争辩而不是被藏在代码里。

- **门禁的单位是记录数**：`EvaluationSlice.caseCount` 是本切面被判定的记录条数，`isSparse = caseCount < 30`。它不看 `rate.denominator`：§3 之后各指标的 `rate.denominator` 单位由 `EvaluationMeasure.unit`（`.records` / `.slots`）声明，同一个切面里既可能是记录也可能是槽位观测——3 条记录 × 12 槽能凑出 36 个槽位观测，150 条记录会让槽位分母上千，用槽位数当门禁两头失真（薄样本被放行、干净样本里天然小分母的指标被永久封死）。
- Wilson 区间按**该指标自身的观测单位**计算（`EvaluationMeasure.unit`）：记录级比率就在记录数上取置信宽度，槽位级比率就在槽位数上。那是这批观测自身的置信宽度，与"够不够格下结论"是两个问题，两处的单位各写在文档里。
- 分母为 0 时 `estimate == nil` 且 Wilson 端点为 nil（没测过的东西不存在"0 分"这种质量结论）。PLAN §8.2 要求"所有零分母标 N/A"：`nil` 就是那个 N/A，报表不得把它印成 0，也不得印成 100%。
- `clusterInterval` 为 nil 有**三个不同的原因**，读者必须能分开：**(a)** 本切面簇数 < `ClusterBootstrap.minimumClusters`（5），簇太少、无可变异性；**(b)** 至少一次重抽样的分母为 0，即该指标在这一层过薄（§4）；**(c)** `Request.resamples < ClusterBootstrap.minimumResamples`（20），抽样太少：两次及以下零宽，再多也只是簇样本的极值；`resamples < 1` 由 `Request.init` 直接拒绝，不留这一档。三者都只关掉簇级区间，**不影响 `isQuotableOnOwnMerits`**：记录数达标的切面照样可以引用率（配 Wilson），只是没有簇级区间可报（`resamplesArePublishedWithTheRun`）。`(c)` 是请求可以合法表达的一种形态——**只要率、不要带**——因此重抽样层既不 `precondition` 崩溃也不把参数垫高：一次跑批不该因为关掉一列而整体中止，而静默改写运行参数正是最难被读者发现的改动。每个切面都随区间一起给出 `clusterCount`：`(a)` 时它 < 5，`(b)` 与 `(c)` 时它 ≥ 5，这两者靠 `EvaluationRunIdentity.bootstrapResamples` 区分——那个数与算出这批切面所用的 `Request.resamples` 一道发布，读者用同一份报告就能把「太薄」与「没人要带」分开（`singleDrawHasNoBand` 钉住率不受影响，`resamplesArePublishedWithTheRun` 钉住身份与切面来自同一次请求）。`resamples: 2` 与 `resamples: 1` 同属 (c)：一次抽样是"没有带"，两次是"带是舍入产物"，对读者的处置一样——只引用率，不引用带。`isQuotableOnOwnMerits` 不看它，因为"能不能引用这条率"与"有没有簇级区间"是两个问题。
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
| `pendingAdjudicationExcluded` | 数据集把争议记录排除在可计数集合之外（PLAN §8.1 要求报告排除量）。披露行同时写出**两个数**：数据集排除 N 条、本次判定的 M 条记录里仍有 K 条争议（K 应为 0），并按 K 决定是否说"排除确实发生" | 否——仅披露 |
| `caseSetNotDerivedFromSplit` | 被判定记录不在 `Report.countableRecordIDs` 内、同一记录被判定两次，或该记录自身仍为 `adjudication_pending` | 是 |
| `eligibilityStateInconsistent` | 候选在未达 `validated` 的条目上带有可自动发布的槽位 | 是 |

`isQualityClaimAllowed = 不存在否决型阻塞`。

`caseSetNotDerivedFromSplit` 是上一条得以成立的前提：排除动作发生在 `GoldDataset`，报告层只披露数量；若没有"用例必须落在可计数集合内"的核验，披露就只是一句无人为之背书的话。重复判定同一条记录也走这个 blocker——同一个来源计两次会直接改写所有分母。

披露行自己就得把话说圆：只报数据集排除数，那么一个把 id 表与审核状态算歪的运行器会让"争议记录已排除"成为一句无人报警的假话；报上本次用例中仍为争议的那个数，读者就能看见两个数是否一致（`pendingDisclosureIsAuditable`）。核验有**两条独立的路**，因为让它们一致的东西恰恰是人的细心：id 必须在 `Report.countableRecordIDs` 里（数据集口径），且该条记录自身的 `review.status` 不能还是 `adjudication_pending`（`CaseJudgement.pendingAdjudication`）。只有前者时，一个把 id 表和审核状态算歪的调用方会让"争议记录已排除"变成一句假话而无人报警。命中任何一条都**不静默剔除**：报告照旧给出这次实际喂进来的 `cases` 数，同时否决结论——把运行器接错藏起来，比让一次运行难看严重得多。

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
| `FieldJudgement`（+ `Verdict`）、`CaseJudgement` | `Sources/FormaCore/Evaluation/EvaluationJudgement.swift` | 判定顺序固定；`publishableStatuses = {evidenced, inherited}` 只喂 `autoPublishable`，而 `autoPublishable` 只喂 §6 的核验 |
| `CaseJudgement(gold:entry:projectKeys:)` | 同上 | `projectKeys` 是运行上下文的 `candidate_ref → 项目簇键` 表；缺表而条目只有未解析 ref 时判项目不匹配（§3 第 2 条） |
| `CaseJudgement.isAutoMapped` / `.mainDecisionIsCorrect(runProfile:)` | 同上 | `isAutoMapped = state == .validated && eligibleForAutoExecution`；主决策 = Profile ∧ 项目 ∧ 类别 |
| `EvaluationMeasure.unit` / `.population(in:runProfile:)` | `Sources/FormaCore/Evaluation/EvaluationMetrics.swift` | 单位由指标声明（`.records` / `.slots`）；单条判定的分子分母跨用例可加；`runProfile` 为 nil 时 `precision_auto` 与 `high_confidence_error_rate` **没有人口**（分子分母都是 0 ⇒ N/A，不是 0%，§3 第 2 条） |
| `EvaluationMeasure.population(in:)`（逐字段） | 同上 | 只为 `field_precision` 的 12 条 `.field` 行服务；行分母之和 == pooled 分母 |
| `EvaluationRate` | 同上 | 分母（槽位观测）为 0 ⇒ `estimate` 与 Wilson 端点为 nil |
| `EvaluationSlice.caseCount` / `isSparse` / `sparseCaseLimit` | 同上 | 可引用性以**该行自身证据的记录数**计（pooled 行 = 切面记录数；`.field` 行 = 对该字段有候选断言的记录数）；`sparseCaseLimit = 30` 是 harness 策略（§5） |
| `ClusterBootstrap.summarize(measures:populations:indices:keys:resamples:seed:)` | 同上 | 唯一公开入口；`populations` 由调用方按 `allCases` 列序**每种归属算一次**并缓存（`slices(for:)` 的 `tables`：overall / category 用 `request.runProfileID` 那一层，Profile 切面用自己的 key——不同归属本就是不同的测量，不共用）；簇 < `minimumClusters`、任一无定义抽样、或 `resamples < minimumResamples` ⇒ 该指标区间为 nil（§5 的 (a)(b)(c)） |
| `EvaluationMetrics.slices(for:request:)` | 同上 | 切面 = overall ∪ 出现的每个 Profile ∪ 出现的每个类别（另有 §3 第 7 条的 12 条逐字段行）；一条记录属于两个 Profile 时在两个切面各出现一次，绝不计为两条记录；Profile 切面把**该切面的 Profile** 当作 `runProfile`，其余切面用 `request.runProfileID`，为 nil 时 `precision_auto` 与 `high_confidence_error_rate` 在那些行**没有人口**（N/A，§3 第 2 条）；分子分母表按归属各算一次并缓存，不同归属不共用（它们本就是不同的测量） |
| `EvaluationMetrics.confusion(_:)` | 同上 | 键形如 `mapped->absent`；无条目用 `absent` |
| `EvaluationMetrics.refusals(_:)` → `Refusals` | 同上 | PLAN §8.2 的拒判原因；`byRecordState` 数记录、`bySlotStatus` 数槽位，两个字典不得合并（§3 第 5 条） |
| `EvaluationRunIdentity` | `Sources/FormaCore/Evaluation/EvaluationReport.swift` | 替身标志是身份的字段，不是脚注 |
| `EvaluationReport`（`Blocker`/`Finding`/`isQuotable`） | 同上 | 门禁在报告层，不在调用方 |

共享夹具：`Tests/FormaCoreTests/EvaluationTestSupport.swift`（`EvaluationFixtures.gold/candidate/values/judgement/projectKeys`）。`candidate` 写出的 association basis 用生产原文格式，项目对错只能通过 `projectKeys(for:wrong:)` 表达——夹具自己把簇键塞进条目的话，测的就不是要跑的那条路了。指标与门禁两个 suite 必须用同一套构造器，否则会在 12 槽与 4 字下限这类细节上各自漂移。
