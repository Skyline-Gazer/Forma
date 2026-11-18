# M11 Import Eligibility — 合成验收报告（2026-11-16）

状态：**macOS 合成 = `MACOS_SYNTHETIC_PARTIAL`**（2026-11-17 Mac 执行 30/30 PASS；原始证据独立完整性复核 = `VERIFIED`；两处偏差见 §8）；**CI 合成自检 = PASS（30/30）**；**真实目录验收 = NOT_STARTED**；**默认过滤未启用**；**切片 5 未授权**。

本报告区分三种证据，三者不得互相替代：

| 证据类别 | 含义 | 本报告结果 |
| --- | --- | --- |
| CI 编译/单测 | GitHub Actions macOS runner 上的自动验证 | **PASS** |
| CI 合成自检 | 同一 runner 上运行 M11 合成夹具（临时目录、真实代码路径） | **PASS（30/30）** |
| macOS 现场 | Mac 主机按 Runbook 执行（2026-11-17，Owner 提供证据） | **`MACOS_SYNTHETIC_PARTIAL`**（30/30 PASS；B3 本地未验证/CI PASS；A8b 内存未测量） |

## 1. 执行环境

- 执行会话主机：Linux DevBox（仓库工作目录，路径不在此记录）。
- macOS 现场主机：**本会话不可直接访问**——两台已配置的 SSH 主机（`ssh://.host`、`ssh://machine/.host`）均返回 `Permission denied (publickey,…)`，与 `docs/R1-BATCH2A-REPORT.md` 记录一致；未尝试绕过认证。2026-11-17 的现场合成由 Owner 在其 Mac 上执行（见 §8）。
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

`CI 自检` 列来自 run `43857368729`（PR #123）与 `43858058846`（合并后 dev）。`现场` 列记录 **2026-11-17 Mac 执行之前**的状态（当时本会话没有 Mac 主机）；Mac 执行后的总体结果为 **30/30 PASS**（Owner 提供的 CLI case-summary 级，逐案例 `detail` 原件待复核），两处偏差见 §8.4，因此不逐行回填该列。

| # | 案例 | 期望 | CI 自检 | 现场（Mac 前） |
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

1. 一台可由**本执行会话**直接访问的 macOS 14+ 主机（2026-11-17 的合成执行由 Owner 在其 Mac 上完成；本会话的两台 SSH 主机仍认证失败）。
2. Owner 授权的只读目录（不得使用生产 `Project_Archive` 991 条记录）。
3. 人工复核工作流与复核人（对每条 `EXCLUDE`/`REVIEW` 给出业务结论）。
4. 真实 OneDrive 目录以覆盖 dataless / hydration / 权限失败场景。
5. 若要在 CI 之外留存证据：主机 `sw_vers`/`uname -m`/APFS 卷信息与 `m11-synthetic-report.json`。

## 6. 默认过滤启用前的剩余 Gate

1. **全链路实现** — 已完成（#116–#123）。
2. **macOS 现场验证** — 合成：**部分完成**（2026-11-17，`MACOS_SYNTHETIC_PARTIAL`，见 §8）；B3/A8b 两处偏差需分别收口；真实授权目录人工复核：**未开始**。
3. **Owner 再确认** — 未发生。

另：切片 5（I1 Executor 写入前资格重判）仍未授权；P3-B、DEVONthink 真实写入、Provider 外发、R1 Batch 2B GUI 同样未授权。

## 7. 禁止升格的表述

- 不得将本报告的 CI 合成自检写成"macOS 现场通过"。
- 不得将合成 fixture 的 False Exclusion 结果写成"真实业务误排除率达标"。
- 不得以 CI 绿灯关闭 `MACOS-VALIDATION-BACKLOG` M11，也不得据此开启默认过滤。

## 8. 2026-11-17 macOS 现场执行（Owner 提供证据）

本节取代 2026-11-17 早些时候的"CLAIMED BUT UNVERIFIED"核对结论：当时无法从本会话访问 Mac，Owner 随后提供了下述执行摘要。**仍未被独立验证的是原始证据文件，而不是"执行是否存在"。**

### 8.1 主机与基线

| 项 | 值 |
| --- | --- |
| 操作系统 | macOS 27.0.1（26A434） |
| 架构 / 机型 | arm64 / MacBookPro18,3（Apple M1 Pro） |
| 文件系统 | APFS |
| 工具链 | Swift 6.4；Git 2.54.0 |
| 仓库 / 分支 | `Skyline-Gazer/Forma` / `dev` |
| HEAD | `a4da6f5`（跟踪工作树干净；既有未跟踪 `tmp/` 未触碰） |

### 8.2 命令与结果

| 项 | 值 |
| --- | --- |
| 命令 | `swift run FormaAcceptance m11 --output ~/m11-synthetic-report.json` |
| 退出码 | **`0`** |
| CLI 案例 | **30 PASS / 0 FAIL / 0 NOT_VERIFIED**（CLI case-summary 级） |
| 策略 | `eligibility.v2` |
| policy digest | `aa7796df…d2a57` — **与仓库钉扎值一致（本会话独立核对）** |
| decisions digest | `f5203037…3df7e` — 主机相关值，**本会话未重算** |

### 8.3 证据文件与完整性（已独立复核 = VERIFIED）

| 文件 | 字节 | SHA-256（本会话复算） |
| --- | --- | --- |
| `~/.forma/evidence/m11/report.json` | 6,078 | `339e211622ef12f19da0d37d14ddc5f9c73051c4b40e4432eb6725da8f823586` |
| `~/.forma/evidence/m11/run.log` | 3,331 | `bad4ce801570ed442848cfa078efc10a4923ad3edae81977b2613f55714af1ff` |

复核方式（DevBox，只读，2026-11-17）：

1. 两文件存在，`sha256sum` 复算值与 Owner 声明**逐字节一致**（见上表完整值）。
2. `jq` 解析 `report.json`：`schema_version 1.0`、`policy_id forma-import-eligibility`、`policy_version eligibility.v2`、`generated_at 2026-11-17T01:18:04.934Z`、`host "Version 27.0.1 (Build 26A434)"`；`policy_digest` 与仓库钉扎值**逐字符一致**（`EligibilityLicenseAuditTests` 同值）；`decisions_digest` 与声明一致。
3. `cases` 长度 30、ID 唯一、状态全部 `PASS`（无 `FAIL`/`NOT_VERIFIED`）；ID 集合与本报告 §3 表**完全一致**。
4. `run.log` 的 30 行 `PASS` 与 `report.json` 的 `(status, id)` 序列**逐行一致**，末行摘要 `30 PASS · 0 FAIL · 0 NOT_VERIFIED`。
5. 敏感信息扫描：`report.json` 无路径、无凭据、无业务资料；`run.log` 仅一处执行主机主目录路径（末行 `report written to`），已脱敏处理，**原始文件不入库**。

仍不随复核升级的项（证据本身不含）：

- 退出码 `0`、架构 `arm64`、机型 `MacBookPro18,3` 为 Owner 声明——`report.json` 的 `host` 只含系统版本串，无架构字段。
- `decisions_digest` 与主机相关，跨机不可重算，未复算。
- `A1` 的 `scan_state=incomplete` 是夹具 `locked/`（权限 `000`）产生 `unreadable` issue 的**预期结果**（`SourceReconciliation.swift:78`：`issues.isEmpty ? .complete : .incomplete`），不是缺陷。

### 8.4 两处偏差（分别保留结论）

| 案例 | 本地执行 | CI | 处置 |
| --- | --- | --- | --- |
| **B3（Owner 编号）** — schema 1.1 资格块缺必需字段应被拒 | `NOT_VERIFIED`（该夹具未在本地运行） | **PASS**（`ManifestEligibilityBlockTests.incompleteEligibilityBlockIsRefused`，run `43859870793`，head `a4da6f5`） | 本地与 CI 结论分开保留，不合并成"已验证"；**与 CLI 案例 B3 不是同一检查**（后者验证 1.0 工件不含 `eligibility` 键，已 PASS） |
| **A8b** — 超大 `CACHEDIR.TAG` | 安全性 **PASS**（未产生 EXCLUDE）；**内存行为未测量** | 边界测试 `oversizedMarker` PASS | 源码检查：`readFile` 在 `fstat` 后、分配缓冲区之前以 `sizeBytes > limit` 返回 `unreadable("oversized")`（marker 上限 1,024 字节）→ 有界读取成立；**不做内存剖析宣称** |

编号说明：Owner 报告中的 "B3" 指"畸形 1.1 资格块应被拒绝"，而 CLI 夹具里的 `B3` 指"1.0 工件不携带资格块"。两者名称相似、检查不同，本文以"B3（Owner 编号）"区分。

### 8.5 安全声明（Owner）

未访问真实业务目录；未做 DEVONthink 操作；未调用 Provider；未外发文件；未修改仓库；临时夹具已清理；资格默认仍关闭。

### 8.6 分类

| 证据 | 分类 |
| --- | --- |
| Mac 合成执行 | 已执行；**原始证据已独立完整性复核（VERIFIED）** |
| CLI 案例 | 30/30 PASS |
| B3 畸形 1.1 块 | 本地 `NOT_VERIFIED`；CI PASS |
| A8b 超大标记内存行为 | 未测量（安全性 PASS） |
| **M11 合成现场验收（总体）** | **`MACOS_SYNTHETIC_PARTIAL`** |
| 真实目录验收 | **`NOT_STARTED`** |
| 生产默认启用 | **`NOT_AUTHORIZED`** |
