# M11 Import Eligibility — 合成验收报告（2026-11-16）

状态：**现场 = NOT_VERIFIED（本轮无可用 macOS 主机）**；**CI 合成自检 = PASS（30/30）**；**默认过滤未启用**；**切片 5 未授权**。

本报告区分三种证据，三者不得互相替代：

| 证据类别 | 含义 | 本报告结果 |
| --- | --- | --- |
| CI 编译/单测 | GitHub Actions macOS runner 上的自动验证 | **PASS** |
| CI 合成自检 | 同一 runner 上运行 M11 合成夹具（临时目录、真实代码路径） | **PASS（30/30）** |
| macOS 现场 | 在可用 macOS 主机上按 Runbook 执行并留存主机信息 | **NOT_VERIFIED** |

## 1. 执行环境

- 执行会话主机：Linux DevBox（工作目录 `/home/ian/workspace/Forma`）。
- macOS 现场主机：**不可用**——两台已配置的 SSH 主机（`ssh://.host`、`ssh://machine/.host`）均返回 `Permission denied (publickey,…)`，与 `docs/R1-BATCH2A-REPORT.md` 记录一致。未尝试绕过认证。
- CI 权威：`.github/workflows/ci.yml`，`runs-on: macos-15`，固定 Xcode 26.3 / Swift 6。
- 基线：`dev` @ `4a44ee0`（含 #122 Runbook、#123 夹具）。合并后 dev CI run `43858058846` success。

## 2. 方法与边界

执行入口（Runbook：`docs/M11-SYNTHETIC-RUNBOOK.md`）：

```bash
swift run FormaAcceptance m11 --output ~/m11-synthetic-report.json
```

- 只在 `mktemp -d` 临时目录内创建合成文件；报告只含 source id、决策、规则与计数，**不含路径**。
- 不创建 DEVONthink 记录、不调用 Provider、不读取任何真实业务目录、不改仓库。
- CI 侧由 `M11SyntheticAcceptanceTests` 执行同一夹具，并断言 **零 FAIL 且零 NOT_VERIFIED**（宿主缺少 `git` 时相关案例会显式变成 NOT_VERIFIED，而不是默认通过）。

## 3. 逐案例结果

`CI 自检` 列来自 run `43857368729`（PR #123）与 `43858058846`（合并后 dev）；`现场` 列一律 `NOT_VERIFIED`。

| # | 案例 | 期望 | CI 自检 | 现场 |
| --- | --- | --- | --- | --- |
| A1 | 两次扫描的身份与快照 | `source_id` 集合与 `snapshot_fingerprint` 稳定 | PASS | NOT_VERIFIED |
| A2 | Git tracked 文件在 `build/` | `REVIEW`（`git-tracked-review`） | PASS | NOT_VERIFIED |
| A2b | `gitTracked` 事实 | 已提交文件 = `yes` | PASS | NOT_VERIFIED |
| A3 | Git untracked 文件在 `dist/` | `REVIEW`，不得 EXCLUDE | PASS | NOT_VERIFIED |
| A4 | 嵌套 Git 仓库内文件 | `REVIEW` | PASS | NOT_VERIFIED |
| A4b | `nestedRepository` 事实 | = `yes` | PASS | NOT_VERIFIED |
| A5 | `.git` 文件指向授权根内 | 嵌套确认 → `REVIEW` | PASS | NOT_VERIFIED |
| A5b | `.git` 指向授权根外 | `unknown`，不跟随 | PASS | NOT_VERIFIED |
| A6 | `.git` 为符号链接 | 事实 `unknown`，默认 `INCLUDE` | PASS | NOT_VERIFIED |
| A6b | 符号链接 `.git` 的 `nestedRepository` | = `unknown` | PASS | NOT_VERIFIED |
| A7 | 有效 `CACHEDIR.TAG` | 其下文件 `EXCLUDE` | PASS | NOT_VERIFIED |
| A7b | `cacheMarker` 事实 | = `verified` | PASS | NOT_VERIFIED |
| A8 | 无签名 `CACHEDIR.TAG` | 不产生 EXCLUDE | PASS | NOT_VERIFIED |
| A8b | 超大 `CACHEDIR.TAG` | 不读入内存，不排除 | PASS | NOT_VERIFIED |
| A8c | 符号链接 `CACHEDIR.TAG` | 不跟随，不排除 | PASS | NOT_VERIFIED |
| A9 | `build/` 中业务样本 | 不是 EXCLUDE（False Exclusion 反例） | PASS | NOT_VERIFIED |
| A9b | `vendor/` 中业务样本 | 不是 EXCLUDE | PASS | NOT_VERIFIED |
| A12 | 缓存目录内 tracked 文件 | 保护事实优先 → `REVIEW` | PASS | NOT_VERIFIED |
| A10 | 权限不足子目录 | 扫描 issue `unreadable`，不当作不存在 | PASS | NOT_VERIFIED |
| A11 | 扫描后变化的文件 | probe `snapshot=changed` → `DEFER` | PASS | NOT_VERIFIED |
| C1 | 候选是已发现集合的子集 | 过滤只移除 | PASS | NOT_VERIFIED |
| C2 | 完整清单摘要 | 与 v0.1.1 公式一致（默认未启用过滤） | PASS | NOT_VERIFIED |
| C3 | 过滤模式摘要 | 与完整清单摘要不同（正确失效） | PASS | NOT_VERIFIED |
| C4 | 过滤后 Context 成员 | 只含候选 | PASS | NOT_VERIFIED |
| C5 | 资格报告守恒 | `discovered == mapped + unmapped` | PASS | NOT_VERIFIED |
| C6 | 被排除记录可追踪 | 决策 + 规则 + 原因逐条具名 | PASS | NOT_VERIFIED |
| B1 | Manifest 1.0 | 通过 1.0 schema | PASS | NOT_VERIFIED |
| B2 | Manifest 1.1 | 带资格块且通过 1.1 schema | PASS | NOT_VERIFIED |
| B3 | 1.0 工件不携带资格块 | envelope 无 `eligibility` 键 | PASS | NOT_VERIFIED |
| B4 | 未知 schema 版本 | 被拒绝（`incompatible`） | PASS | NOT_VERIFIED |

## 4. Acceptance Gates 对照

| Gate | 结论 | 证据 |
| --- | --- | --- |
| 完整扫描与 source identity 不变 | **CI 证明** | A1；扫描代码路径未改 |
| 过滤只作用于 Mapping 候选 | **CI 证明** | C1、C4；`mappingEntries` 只做交集 |
| 被排除条目仍可追踪 | **CI 证明** | C6；`EligibilityReport` 逐条说明 |
| Context digest 正确失效 | **CI 证明** | C2、C3 |
| Manifest 1.0/1.1 均能处理 | **CI 证明** | B1–B4 |
| 报告统计守恒 | **CI 证明** | C5 |
| 合成受保护文件无 False Exclusion | **CI 证明（合成范围）** | A2、A9、A9b、A12 |
| 默认过滤仍关闭 | **结构保证** | C2；`FormaApp` 未改，生产调用不传 `eligibility` |

以上"CI 证明"仅表示合成范围内成立；**真实业务目录的误排除率仍未测量**。

## 5. 真实目录测试仍缺的条件

1. 一台可用的 macOS 14+ 主机（本轮两台 SSH 主机认证失败）。
2. Owner 授权的只读目录（不得使用生产 `Project_Archive` 991 条记录）。
3. 人工复核工作流与复核人（对每条 `EXCLUDE`/`REVIEW` 给出业务结论）。
4. 真实 OneDrive 目录以覆盖 dataless / hydration / 权限失败场景。
5. 若要在 CI 之外留存证据：主机 `sw_vers`/`uname -m`/APFS 卷信息与 `m11-synthetic-report.json`。

## 6. 默认过滤启用前的剩余 Gate

1. **全链路实现** — 已完成（#116–#123）。
2. **macOS 现场验证** — 合成（本报告 §3 待现场复跑）+ 真实授权目录人工复核；**两者都未完成**。
3. **Owner 再确认** — 未发生。

另：切片 5（I1 Executor 写入前资格重判）仍未授权；P3-B、DEVONthink 真实写入、Provider 外发、R1 Batch 2B GUI 同样未授权。

## 7. 禁止升格的表述

- 不得将本报告的 CI 合成自检写成"macOS 现场通过"。
- 不得将合成 fixture 的 False Exclusion 结果写成"真实业务误排除率达标"。
- 不得以 CI 绿灯关闭 `MACOS-VALIDATION-BACKLOG` M11，也不得据此开启默认过滤。

## 8. 2026-11-17 交接核对（Mac 执行声明）

收到的交接说明称"Mac 端 M11 Synthetic Acceptance 已执行"，但**本轮未收到任何报告原件或可核对的摘要**。为核实，按下列位置逐一查找，均无 M11 现场证据：

| 查找位置 | 结果 |
| --- | --- |
| 仓库 `docs/`、提交历史（`git log --since 2026-11-16 12:00`） | 无新增 M11 现场报告 |
| 远程分支与 open PR | 无新分支、无 open PR |
| Issue #51 评论与全部 Issue 状态 | 最后更新 2026-11-16，无现场记录 |
| 本机 `~/m11-synthetic-report.json`、`/tmp`、`~/Downloads`、`~/Desktop` | 不存在 |
| `~/.forma/evidence/`（此前现场证据存放处） | 只有 `r1-batch2a/`，无 `m11` |

因此判定：**Mac 合成执行 = CLAIMED BUT UNVERIFIED（UNKNOWN）**。按交接规则，不凭文字陈述推定 PASS；`MACOS-VALIDATION-BACKLOG` M11、默认过滤与切片 5 的状态**一律不变**。

要在下一次交接中升级为 `macOS Synthetic Field Verified`，报告必须包含：

1. 主机信息：`sw_vers -productVersion`、`uname -m`、根卷是否 APFS；
2. 实际命令与**退出码**（`swift run FormaAcceptance m11 --output <path>`，期望 `0`）；
3. `m11-synthetic-report.json` 原件（含 `policy_digest`、`decisions_digest`、逐案例 `status`/`detail`）；
4. 逐案例结果：若存在 `FAIL` 或 `NOT_VERIFIED`，给出案例 ID、条件与输出；
5. 声明未产生外部副作用（未写 DEVONthink、未调 Provider、未扫描真实业务目录）；
6. 默认过滤仍关闭的确认（`FormaApp` 未改、生产调用不传 `eligibility`）。

缺任一项即保持 `UNKNOWN`；有 `FAIL` 则按缺陷处理，另行开 Issue 并给出可复现条件。
