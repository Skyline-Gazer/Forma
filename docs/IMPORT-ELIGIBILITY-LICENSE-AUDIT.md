# Import Eligibility — License & Provenance Static Audit (Issue #51)

状态：**PASS**（本轮实现可继续合入；正式 Credits 义务随 Mac App Store 构建由 [#52](https://github.com/Skyline-Gazer/Forma/issues/52) 绑定）。
基线：`dev` @ `6bd17bb`（PR #114 merged）。审计日期：2026-11-16。审计方式：静态审查 + 仓库内可复算的守护测试；未执行任何 Mole 代码，未引入任何新依赖。

本文件是 [Issue #51](https://github.com/Skyline-Gazer/Forma/issues/51) 要求的"完成前静态审计与合成 fixture 核验"的记录件；`IMPORT-ELIGIBILITY-POLICY.md` §9 是结论摘要，本文件是完整程序与证据。

## 1. 审计对象与程序

1. Forma 全部第三方依赖（`Package.swift` / `Package.resolved`）——是否存在 GPL/AGPL 或其他会向闭源商业发行传染的义务。
2. `Sources/FormaCore/Eligibility/`（`EligibilityClassifier`、`EligibilityPolicy`、`EligibilityFacts`、`EligibilityFactProbe`、`EligibilityView`）与 `Policies/forma-eligibility.v1.json`——是否存在对 `tw93/Mole`（GPL-3.0）源码、shell 函数、规则表文本或测试 fixture 的复制、翻译、改写或移植。
3. 资格相关测试夹具（`ImportEligibilityTests.swift`、`EligibilityProbeTests.swift`）——是否为独立编写。
4. 已评审工件的字节身份（policy digest）与规则清单——评审后的任何变更是否可被机械发现。

复算程序（任何审阅者在无网络环境下可执行）：`swift test` 运行 `EligibilityLicenseAuditTests`；该套件解析依赖清单、比对 `Package.resolved` 固定版本、重算并核对 policy digest、并校验本文件第 4 节规则清单与策略 JSON 逐项一致。

## 2. 依赖清单（固定版本）

| 依赖 | 固定版本 | 许可证 | 闭源商业发行兼容性 |
| --- | --- | --- | --- |
| `groue/GRDB.swift` | `7.8.0`（exact pin） | MIT | 兼容 |
| `weichsel/ZIPFoundation` | `0.9.20`（exact pin） | MIT | 兼容 |
| `objecthub/swift-dynamicjson` | `2.0.1`（exact pin） | Apache-2.0 | 兼容 |

- 无 GPL、AGPL 或其他 copyleft 组件进入解析图；本切片对 `Package.swift` **零改动**（守护测试以精确集合比对，任何新增/浮动版本都会使测试失败并要求重新评审）。
- Apache-2.0 的授权与 NOTICE 义务（如有）归 #52 的正式 Credits 清单管理；本项目前依赖树中无 NOTICE 文件要求被触发。

## 3. Mole 设计来源与独立实现核验

研究基线：`tw93/Mole` @ `64daaf86499c7`，仅阅读以下文件以提取**思想与通用事实**：`lib/clean/purge_shared.sh`（候选产物字典概念、`CACHEDIR.TAG` 标准签名、Git tracked 检查的存在性）、`lib/clean/project.sh`（名称不代表可重建；嵌套仓库保守处理）、`lib/core/base.sh`（不可覆盖的强制保护分层）、`SECURITY_AUDIT.md`（不确定即拒绝危险行为）。

独立性证据（结构性，而非措辞性）：

1. **表达形式不同**：Mole 是 shell 字典与过程式清理脚本；Forma 是声明式 JSON 谓词（`all/any` 事实谓词、`priority`、`protection_facts`、`evidence_strength`）加纯函数 Swift 分类器。没有一行 Mole shell 逻辑被移植。
2. **语义目标相反**：Mole 决定"哪些可以删除"；Forma 决定"哪些可以进入业务映射候选"。Mole 的"最近 7 天默认不勾选"等删除风险控制未被迁移；Forma 无任何删除/移动/清理语义（Issue #51 硬边界）。
3. **规则数据原创**：全部 13 条规则 ID、`explanation_code`、优先级布局均为本仓库编写（第 4 节清单即评审通过的原文）；谓词语言（`basenames`/`basename_prefixes`/`path_components`/`facts` 枚举）不存在于 Mole。
4. **通用事实不构成移植**：`CACHEDIR.TAG` 的签名内容（`Signature: 8a477f597d28d172789f06886806bc55`，即规范声明的 `.IsCacheDirectory` 之 MD5，已对 bford.info 原始规范复核）是 Public Content 标准（https://bford.info/cachedir/spec.html）；`.DS_Store`、AppleDouble `._*`、Office `~$*` 是跨产品命名约定事实，非 Mole 表达。
5. **无上游文本/fixture 复用**：测试夹具全部为本仓库构造的合成路径与事实（`Project/公告.pdf` 等命名与 Mole 测试无任何对应关系）；守护测试防止 policy 文本漂移。

未采用清单：Mole 的默认家目录扫描、清理动作、白名单文件格式、输出文案——均未采用。

## 4. 已评审工件身份

- 策略文件：`Sources/FormaCore/Eligibility/Policies/forma-eligibility.v1.json`
- `policy_id = forma-import-eligibility`，`policy_version = eligibility.v2`
- 评审时 canonical digest（`EligibilityPolicy.digest`，规则按优先级/ID 规范序 + 键排序的紧凑 JSON 之 SHA-256）：

  `aa7796dfe21d3eca6b0030f39cb1cb5f95c26c8cfab6069910bc4baad54d2a57`

- 规则清单（classifier 唯一使用的顺序，逐条评审）：

| # | rule_id | decision | evidence_strength |
| --- | --- | --- | --- |
| 1 | `business-evidence-protect` | INCLUDE | strong |
| 2 | `verified-cache-directory` | EXCLUDE | strong（需 `protection_facts` 已知） |
| 3 | `technical-noise-ds-store` | EXCLUDE | strong |
| 4 | `technical-noise-appledouble` | EXCLUDE | strong |
| 5 | `technical-noise-office-lock` | EXCLUDE | strong |
| 6 | `nested-repository-review` | REVIEW | contextual |
| 7 | `git-tracked-review` | REVIEW | contextual |
| 8 | `source-code-review` | REVIEW | contextual |
| 9 | `rebuildable-artifact-review` | REVIEW | contextual |
| 10 | `vendor-directory-review` | REVIEW | weak |
| 11 | `generated-directory-review` | REVIEW | weak |
| 12 | `dataless-metadata-only` | INCLUDE | contextual（未 hydration 不阻断元数据候选，见规则正文） |
| 13 | `default-mapping-candidate` | INCLUDE | contextual |

变更规程：任何规则增删改必须同时（a）提升 `policy_version`，（b）在本文件更新 digest 与清单行，并（c）在 PR 中说明评审理由。三者缺一，`EligibilityLicenseAuditTests` 失败。

## 5. Mac App Store Credits 义务（移交 #52）

正式发行构建的 Credits 必须包含：`tw93/Mole` 项目名、上游 URL、被研究的 commit `64daaf86499c7`、GPL-3.0 许可证说明，并明确"设计参考，不含 Mole 代码"。该措辞仅在本文第 3 节核验持续成立时使用；禁止暗示 Mole 作者对 Forma 的认可或背书。署名不能代替许可证授权：若未来希望复用 Mole 任何代码/规则表文本，须先取得权利人另行商业许可，未经许可不合入。

## 6. 结论

- 本轮资格实现满足"闭源商业 Mac App Store 发售不承担不可接受许可义务"的 Gate；判定 **PASS**。
- 任何会让上游 GPL 文本、fixture 或代码进入构建产物的后续改动，都应使本审计失效并重判为 `BLOCKED`，不得以改名或贴 Credit 放行。
- 真实业务样本的误排除率仍未测量（M10/P3-B 前置条件未满足）；本审计不涉及、也不得被引用为该测量的完成。
