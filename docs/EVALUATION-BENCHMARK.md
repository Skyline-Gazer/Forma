# Forma 离线运行器规模基准（EVALUATION-BENCHMARK）

> 状态：P3-A 切片 2c。本文定义**合成运行器基准**的实验、口径、命令与限制。
> 三种不同的东西不得混写：**Runner Scale Benchmark != Real File Scan Benchmark != Provider Benchmark**。

## 1. 这个基准是什么

`FormaBenchmark`（`Sources/FormaBenchmark/main.swift`）把一份合成的 `GoldDataset` 交给**与生产完全相同的**评测路径：`MappingEngine.plannedBatches` → 确定性替身 → `ManifestValidator` → `CaseJudgement` → `EvaluationReport` → `EvaluationArtifact`。基准层只负责生成夹具、注入故障、计时、采样内存、输出结果，不重新实现任何判定。

因此它回答的是**运行器与算法层在 N 条合成记录下的开销与记账守恒**，不回答：

| 不是 | 为什么 | 归属 |
| --- | --- | --- |
| 真实 10,000 文件扫描验收 | 夹具是内存中的 `GoldRecord`，不读磁盘、不经过 `PDFKit`、不经过 OneDrive/DEVONthink | M9，见 `docs/MACOS-VALIDATION-BACKLOG.md` |
| Provider 评测 | `isSubstitute == true`，没有 socket、没有凭据、没有 usage 上报 | P3-B（未授权） |
| 模型质量结论 | `EvaluationReport` 的 `substituteAnswers` 否决随每个结果一起导出 | §6 门禁 |

PLAN §8.2 的原文要求「合成压力数据单列，不冒充真实实测」，本文件就是那个"单列"。

## 2. 夹具

`EvaluationBenchmarkFixture.Spec`（`Sources/FormaCore/Evaluation/EvaluationBenchmarkFixture.swift`）：

| 字段 | 含义 |
| --- | --- |
| `record_count` | 可计数的评测记录（矩阵轴：100 / 1,000 / 10,000） |
| `cluster_count` | 项目簇数，决定 `plannedBatches` 的分组 |
| `prompt_record_count` / `removed_record_count` | few-shot 与撤回记录，用于验证边界分母 |
| `seed` | 固定种子；参与字段稀疏度与场景抽签，不只是标签 |
| `version` | `bench-1.0.0`，记录形状变更时升版 |

约束：

- 记录是 `GoldRecord` + `GoldSplit` + `CasePack.shipped()` 交给 `GoldDataset`，因此 split 校验、泄漏检查、countable 集合与所有分母都是生产实现。
- 派生而非随机：每条记录的 id、簇、字段值由 `(seed, index)` 决定，不含墙钟、进程状态或真实路径。`fixture_id` = spec 摘要。
- 合成身份：`synthetic/` 下的假路径、`sha256 == nil`（没人测过）、`review.redaction == .synthetic`；few-shot 记录使用独立簇空间，避免把评测记录误判为泄漏。
- 合法样本：Project Archive 的真实类别/文档类型枚举取值；`profiles` 同时列出两个 Profile，因此两个运行 Profile 都可用。
- 字段稀疏度：约 1/3 的记录不声明 `documenttype`，约 1/4 另外留空可选项目槽；证据行数随之变化。
- 批大小不是夹具属性：`entryLimit` 直接传给 `MappingEngine.plannedBatches`。
- 夹具构造时间与运行器时间分别计时，互不混用。

## 3. 分阶段计时

`EvaluationStageTimings` / `EvaluationStageMeasurement` 记录 7 个阶段，每个阶段都有墙钟毫秒、观测数、`MeasurementKind` 与不可观测原因：

| 阶段 | 谁测 | 观测数 |
| --- | --- | --- |
| `fixture_preparation` | 基准层 | 记录数 |
| `batch_planning` | `EvaluationRunner` | 条目数 |
| `request_execution` | `EvaluationRunner` | 已产生结果的请求数 |
| `manifest_validation` | `EvaluationRunner` | 条目数 |
| `case_judgement` | `EvaluationRunner` | 样本数 |
| `report_and_metrics` | `EvaluationRunner` | 样本数 |
| `artifact_serialization` | 基准层 | 导出字节数 |

第八项「总耗时」不是阶段：`total_wall_clock_milliseconds` 在整段执行外单独用同一单调时钟测得。`sumOfStageMilliseconds` 只是下界，`unaccountedMilliseconds` 明确列出总耗时里没有阶段覆盖的部分；数据集构造、样本准备、摘要材料与计时本身都在覆盖之外。**阶段耗时不相加冒充总耗时。**

阶段 `kind` 说的是"这段时间怎么来的"（本机单调时钟 = `.measured`，阶段没跑 = `.unavailable`），不表示应答是真实的；应答来源由 `EvaluationRunIdentity.isSubstitute` 披露。

## 4. 场景矩阵

| 维度 | 场景 |
| --- | --- |
| 记录数 | 100 / 1,000 / 10,000 |
| 并发上限 | 1 / 2 / 4 / 8 |
| Batch Entry Limit | 25 / 100 |
| 应答方 | 确定性 `SubstituteAnswerer`（永远） |
| 故障 | success / retry / timeout（请求级失败）/ permanent_unavailable / delayed / partial（withhold） |
| 中断 | cancelled（飞行中）/ not_issued（首个请求前） |
| 调度跳过 | **仅 not_issued 离线模拟**；`SKIP_VERIFIED` 是 Import 状态，不在运行器里实现，也不改变分母 |

故障率按请求掷签（种子 + 固定记录顺序），因此 10k 规模与 100 规模的注入可复现。为避免 bootstrap 次数与样本量组合成失控开销，10k 场景固定 `bootstrapResamples = 20`。

**三种执行入口不得混淆：**

1. 常规 PR：`.github/workflows/benchmark.yml` 的 `smoke` 作业，`--sweep`（100 条，12 个格子）。只在**契约违约**时失败，绝对耗时不是 Gate。
2. 手动 10k：`workflow_dispatch` 的 `scale` 作业，每个格子一个进程。
3. 未来 M9：真实目录的真实文件扫描（未执行）。

## 5. 运行命令

```bash
# 本地 / DevBox（需要 macOS 工具链；Linux 不能编译 FormaCore 的 CryptoKit 等依赖）
swift build --target FormaBenchmark
swift run FormaBenchmark --records 1000 --clusters 100 --entry-limit 100 \
  --concurrency 4 --bootstrap 20 --json /tmp/bench.json

# 并发扫描（每个格子建议独立进程，峰值内存才可归因）
for c in 1 2 4 8; do
  swift run FormaBenchmark --records 10000 --concurrency "$c" --entry-limit 100 \
    --clusters 100 --label "10k-c$c" --json "/tmp/10k-c$c.json"
done

# 与上一次结果做可解释比较（只报告，不决定退出码）
swift run FormaBenchmark --records 1000 --concurrency 4 --baseline /tmp/bench.json \
  --json /tmp/bench-next.json
```

GitHub Actions：

```bash
gh workflow run benchmark.yml --ref <branch> \
  -f record_counts=100,1000,10000 -f concurrency=1,2,4,8
```

`--json` 输出是 `EvaluationBenchmark.Result` 数组：`benchmark_schema_version`、`benchmark_id`（逻辑身份，跨机器可复现）、`measurement_id`（本次测量的独立追溯）、`fixture_id`/`fixture_seed`/`fixture_version`、`stage_timings`、`execution_telemetry`（复用 2b 的 `EvaluationTelemetry`）、`peak_memory`、`environment`、`limitations`。环境记录 OS、机型、内存、核数与 CI 传入的 Swift/Xcode 版本；**不含主机名、用户名、路径、凭据、Manifest、证据正文**。峰值内存用 `ru_maxrss`（进程生命期最大值），不可得时输出 `unavailable` 而不是 0。

## 6. 正确性门禁

`Result.violations()` 与 `EvaluationBenchmarkTests` 固定下列状态机关系（不是性能阈值）：

- `sampleCount == countableRecordIDs.count`
- `requestCount >= issuedRequestCount`
- `attemptCount >= issuedRequestCount`（取消前未发起首调的批次不计入 issued）
- `observedConcurrency <= maximumConcurrency`
- `succeededRequests + failedRequests == issuedRequestCount`
- `retryCount == attemptCount - issuedRequestCount`
- 替身运行不得发表质量结论、不得把 usage/延迟标成 `measured`、不得出现 TTFT
- `allowCloud == false`、无计价版本、`peak_memory` 不可用时不给字节数
- 7 个阶段全部存在且可观测

所有失败样本保留在合法分母中：故障注入只改变 outcome，不改变 `countableRecordIDs`。

## 7. 结果

> 只记录实际执行得到的数字；共享 Runner 的绝对耗时不作为合并 Gate。

**运行 A（优化前，2026-11-12，[run 43244063426](https://github.com/Skyline-Gazer/Forma/actions/runs/43244063426)，`workflow_dispatch`，分支 `p3a-slice-2c-benchmark`，12 个格子全部 `violations() == []`）**：

环境：macOS 15.8.2 (24H232) / VirtualMac2,1 / 3 cores / Swift 6.2.4 / Xcode 26.3 / GitHub macos-15 共享 Runner。100 个簇，`entryLimit = 100`，`bootstrapResamples = 20`，替身模拟延迟 2 ms。

| 场景 | 记录 | 并发上限/观测峰值 | 请求/已下发/attempt/retry | 失败 | 请求墙钟 ms | samples/s | P50/P95 ms | 基准总耗时 ms | 阶段和(下界) ms | 未覆盖 ms | 峰值 RSS MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scale-100-c1 | 100 | 1/1 | 100/100/100/0 | 0 | 1379 | 72.5 | 2.0/2.0 | 1641 | 1555 | 86 | 13.7 |
| scale-100-c2 | 100 | 2/2 | 100/100/100/0 | 0 | 500 | 200.0 | 2.0/2.0 | 782 | 673 | 109 | 13.8 |
| scale-100-c4 | 100 | 4/4 | 100/100/100/0 | 0 | 340 | 294.1 | 2.0/2.0 | 805 | 658 | 147 | 14.1 |
| scale-100-c8 | 100 | 8/8 | 100/100/100/0 | 0 | 194 | 515.5 | 2.0/2.0 | 498 | 386 | 112 | 14.0 |
| scale-1000-c1 | 1000 | 1/1 | 100/100/100/0 | 0 | 2344 | 426.6 | 2.0/2.0 | 4435 | 3629 | 806 | 28.6 |
| scale-1000-c2 | 1000 | 2/2 | 100/100/100/0 | 0 | 1224 | 817.0 | 2.0/2.0 | 2872 | 2229 | 643 | 29.2 |
| scale-1000-c4 | 1000 | 4/4 | 100/100/100/0 | 0 | 428 | 2336.4 | 2.0/2.0 | 1775 | 1185 | 590 | 28.8 |
| scale-1000-c8 | 1000 | 8/8 | 100/100/100/0 | 0 | 420 | 2381.0 | 2.0/2.0 | 1844 | 1370 | 474 | 28.8 |
| scale-10000-c1 | 10000 | 1/1 | 100/100/100/0 | 0 | 8693 | 1150.4 | 2.0/2.0 | 38655 | 33740 | 4915 | 164.7 |
| scale-10000-c2 | 10000 | 2/2 | 100/100/100/0 | 0 | 6266 | 1595.9 | 2.0/2.0 | 36264 | 30875 | 5389 | 158.3 |
| scale-10000-c4 | 10000 | 4/4 | 100/100/100/0 | 0 | 2531 | 3951.0 | 2.0/2.0 | 28165 | 23324 | 4841 | 160.1 |
| scale-10000-c8 | 10000 | 8/8 | 100/100/100/0 | 0 | 2872 | 3481.9 | 2.0/2.0 | 31731 | 26749 | 4982 | 162.2 |

P50/P95 是替身 `reportedLatencyMilliseconds` 的 `simulated` 值（2 ms），不是 Provider 观测；`LatencyDistribution.kind == .simulated`。`unaccounted` 是总耗时里没有阶段覆盖的部分（摘要材料、样本准备、计时本身），因此阶段和只是下界。机器可读结果见该 run 的 `benchmark-scale` artifact（12 个 JSON，各有独立 `measurement_id`）。

**运行 B（优化后）**：见 §9 与 PR 中的补充运行；**未执行前不填数字**。

## 8. 统计限制

- 一次运行 = 一个测量；`measurement_id` 与 `executed_at` 使之不可与另一台机器的结果混成"同一次测量"。`benchmark_id` 只绑定逻辑输入。
- 吞吐与 P50/P95 来自 `EvaluationTelemetry`，口径与 `docs/EVALUATION-METRICS.md` §10 完全一致；替身延迟一律 `simulated`。
- 共享 GitHub Hosted Runner 的墙钟抖动大（同一并发档位 c4/c8 在 10k 上相差数秒）；`--baseline` 只打印倍率并标记 `>1.5x` 供人工复核，不阻断合并。
- 峰值 RSS 是进程生命期最大值，每格子一个进程；`--sweep` 的多格子运行明确标记为不可用。
- 合成 fixture 的内存/耗时曲线只描述运行器与算法层，不预测真实 10,000 文件扫描（后者含 IO、hydration、PDF 抽取）。
- 每格子恰好 100 个请求（100 个簇、每簇一批到十批），所以"记录数"轴主要放大校验/判定/报告阶段，而不是请求数。

## 9. 性能瓶颈与 M9 剩余

> 本节只在实际基准执行后填写观测到的热点；未观测不写推测。

运行 A 的 10,000 记录平均阶段耗时（4 个并发档位的平均）：`case_judgement` 17,980 ms、`request_execution` 5,091 ms、`manifest_validation` 3,683 ms、`fixture_preparation` 1,011 ms、`report_and_metrics` 551 ms、`batch_planning` 352 ms、`artifact_serialization` 5 ms。

**定位**：`Manifest.entry(for:)` 是 `entries.first { ... }` 线性扫描，而 `EvaluationRunner.run` 每个样本调用一次 → O(n²)。这是运行 A 在 10k 上 `case_judgement` 独占约 18 s 的原因，且不是 Provider 或 IO 开销。按"先采样定位、再优化"的约束，本切片在 runner 里为 manifest 条目建一次索引（`Dictionary`，保留首个匹配，与 `entry(for:)` 语义完全一致），不改 `Manifest` 的公开 API，也不改任何判定规则。**运行 A 的数字是优化前的，不能当作当前代码的性能**。

并发趋势（运行 A）：记录数固定时，提高并发确实压低 `request_execution`（10k：c1 8693 ms → c4 2531 ms），c8 未再提升，受共享 Runner 与模拟延迟抖动影响；`observedConcurrency` 始终等于配置值，1/2/4/8 全部满足上限。峰值 RSS 随记录数近似线性（100 → ~14 MB、1k → ~29 MB、10k → ~160 MB），且在整个并发扫描内几乎不变，说明内存主要与样本规模而非在飞请求数相关。

M9 仍需真实 macOS 现场：真实 10,000 文件目录、硬件/系统/磁盘条件、元数据扫描墙钟、峰值内存、OneDrive 元数据扫描/hydration/缓存命中读取/SHA 抽取分列。见 `docs/MACOS-VALIDATION-BACKLOG.md` 的 M9 条目。

## 10. 授权边界

本设施属于已授权的 P3-A 离线评测准备（合成数据与确定性替身）。未触碰：真实 Provider 调用与费用（P3-B）、真实业务文件、DEVONthink 写入（I1）、Import 状态机与 `SKIP_VERIFIED`、发行签名/公证（R1）、Issue #51 的完整扫描语义、冻结 SPEC。
