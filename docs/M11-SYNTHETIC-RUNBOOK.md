# M11 合成验收 Runbook（macOS 现场）

状态：**待执行**。本文件是 `MACOS-VALIDATION-BACKLOG` M11 的现场执行脚本说明；合成验收通过**不等于**真实业务目录误排除率达标，也**不授权**开启默认过滤。

## 1. 边界（执行前必须确认）

- 只在 `mktemp -d` 创建的临时目录内工作；不指向 `~/Documents`、OneDrive、任何真实业务目录。
- 不创建 DEVONthink 记录，不调用 Provider，不外发任何文件，不修改仓库。
- 合成文件内容全部为占位文本；报告只含 source id、决策、规则与计数，**不含路径**。
- 默认过滤保持关闭：任何需要"默认启用"的步骤都**不在本 Runbook 内**。

## 2. 前置条件

1. macOS 14+（记录 `sw_vers -productVersion`、`uname -m`、APFS 卷）。
2. Swift 6 工具链（`swift --version`），仓库位于 `dev` ≥ `f9bd4ea`。
3. `git --version` 可用（用于 tracked / 嵌套仓库案例；缺失时相关案例记 `NOT_VERIFIED`）。

## 3. 执行

```bash
cd <repo>
swift run FormaAcceptance m11 --output ~/m11-synthetic-report.json
```

若该命令不存在（旧版检出），先 `git pull` 到含 `Sources/FormaAcceptance` 的提交；仍不可用时按 §5 的手工替代步骤执行，并在报告中写明使用了手工路径。

命令结束后：

- 标准输出打印逐案例 `PASS` / `FAIL` / `NOT_VERIFIED` 与策略 digest；
- `~/m11-synthetic-report.json` 为完整证据（含 `policy_digest`、`decisions_digest`、逐案例细节）；
- 退出码 `0` = 全部 PASS；`1` = 至少一个 FAIL；`3` = 无 FAIL 但存在 `NOT_VERIFIED`（例如宿主无 `git`）；`2` = 参数/环境错误。

## 4. 案例矩阵与期望

| # | 案例 | 期望 |
| --- | --- | --- |
| A1 | 两次扫描同一目录 | `source_id` 集合完全一致；`snapshot_fingerprint` 不变 |
| A2 | Git tracked 文件置于 `build/` | 不 EXCLUDE；`REVIEW`（`git-tracked-review`） |
| A3 | Git untracked 文件置于 `dist/` | `REVIEW`（`generated-directory-review`），不得 EXCLUDE |
| A4 | 嵌套 Git 仓库内的文件 | `REVIEW`（`nested-repository-review`），探测 `nestedRepository=confirmed` |
| A5 | `.git` 为文件（`gitdir:`）指向授权根内 | `nestedRepository` = confirmed；指向根外 = `unknown`，不跟随 |
| A6 | `.git` 为符号链接 | `nestedRepository=unknown`，不跟随；无规则命中 → 默认 `INCLUDE` |
| A7 | 有效 `CACHEDIR.TAG`（43 字节签名） | 其下文件 `EXCLUDE`（`verified-cache-directory`），且 `cacheMarker=verified` |
| A8 | 无签名 / 超大 / 符号链接 `CACHEDIR.TAG` | 分别为 `present_unverified` / 不读入内存 / `unreadable`；均不得产生 EXCLUDE |
| A9 | 业务样本（PDF/DOCX/XLSX 命名）置于 `build/`、`dist/`、`vendor/` | 一律不是 `EXCLUDE`（False Exclusion 反例） |
| A10 | 权限不足的子目录（`chmod 000`） | 扫描 issue `unreadable`，不得当成"不存在"（该目录内文件不产生条目） |
| A11 | 扫描期间改变的文件 | 状态为 `source_changed`/`DEFER`，不静默沿用旧快照 |
| A12 | `CACHEDIR.TAG` 有效但同目录有 Git tracked 文件 | `REVIEW`（保护事实优先于缓存排除） |

附加对照（不依赖文件系统，用于证据完整性）：

| # | 对照 | 期望 |
| --- | --- | --- |
| B1 | 完整清单模式下 `inputDigest` | 与 v0.1.1 公式逐字节一致 |
| B2 | 过滤模式下的 `inputDigest` | 与完整清单模式不同，且绑定 `policy_digest` 与判定指纹 |
| B3 | Manifest 1.0 / 1.1 | 各自按声明版本校验通过；1.1 块缺字段被拒；1.0 payload 不含 `eligibility` 键 |
| B4 | `EligibilityReport` | `discovered == mapped + unmapped`；`per_decision`/`per_rule` 求和等于 `discovered` |
| B5 | 默认行为 | `buildContext(eligibility: nil)` 与历史摘要一致；未启用过滤 |

## 5. 手工替代步骤（无夹具命令时）

对每个案例目录执行只读流程：

1. `SourceWorkspace.scan` 两次，比较 `source_id` 与 `snapshot_fingerprint`（A1）。
2. `EligibilityFactCollector.probe` 采集事实，记录 `provenance`（A2–A8）。
3. `EligibilityViewBuilder.build` 生成视图，导出 `EligibilitySummary` 与 `EligibilityReport`（A9、B4）。
4. `ContextBuilder.inputDigest` 两种模式对比（B1、B2）。
5. `FormaJSON.encode` + `ArtifactSchemaValidator.manifest(forSchemaVersion:)` 校验 1.0/1.1（B3）。
6. 把每条案例的 `decision`、`decided_by_rule_id`、`explanation_code`、`override_state`、`policy_digest` 记入报告。

## 6. 判定与产物

- 判定只有三种：`PASS`（与期望一致且有证据）、`FAIL`（与期望不一致）、`NOT_VERIFIED`（未执行或环境缺失）。
- **CI 通过、合成 PASS 都不得写成现场"真实目录"通过**。
- 报告必须包含：执行主机信息、命令、每条案例判定、`policy_digest`/`decisions_digest`、临时目录已清理的确认。

## 7. 与默认启用门的关系

默认过滤启用需要三道前置，本 Runbook 只覆盖第 2 道的一部分：

1. 全链路实现（已完成并合并）；
2. macOS 现场验证——**合成（本文件）+ 真实授权目录人工复核**，两者都必需；
3. Owner 再确认。

未满足全部三道前，`FormaApp` 保持完整清单模式，任何"临时打开看看"的调试都必须在本机分支完成且不合并。

## 8. 现场执行记录

### 2026-11-17（Owner 提供证据）

| 项 | 值 |
| --- | --- |
| 主机 | macOS 27.0.1（26A434）/ arm64 / MacBookPro18,3（Apple M1 Pro）/ APFS |
| 工具链 | Swift 6.4；Git 2.54.0 |
| 仓库 / HEAD | `Skyline-Gazer/Forma` / `dev` @ `a4da6f5`（跟踪工作树干净） |
| 命令 | `swift run FormaAcceptance m11 --output ~/m11-synthetic-report.json` |
| 退出码 | `0` |
| 结果 | 30 PASS / 0 FAIL / 0 NOT_VERIFIED（CLI case-summary 级） |
| 策略 | `eligibility.v2`；policy digest `aa7796df…d2a57`（与仓库钉扎值一致） |
| decisions digest | `f5203037…3df7e`（主机相关，未跨机重算） |
| 证据 | `~/.forma/evidence/m11/report.json`、`run.log`（Owner 声明 SHA-256；独立复核 PENDING） |

**总体分类：`MACOS_SYNTHETIC_PARTIAL`**（偏差 B3：本地 `NOT_VERIFIED` / CI PASS；A8b：安全 PASS、内存行为未测量）。真实目录验收仍 `NOT_STARTED`，默认启用仍 `NOT_AUTHORIZED`。

下次复跑时请保留同一组证据项，并在本节追加新行而不是覆盖历史。
