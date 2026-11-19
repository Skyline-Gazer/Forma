# M11 Level 4 Runbook（真实目录只读验收）

状态：**第 4 级 = `VERIFIED — SCOPE LIMITED`（2026-11-19 真实样本运行，见 `MACOS-VALIDATION-BACKLOG` M11）**，范围限定于该次 Owner 授权目录、元数据分类、`eligibility.v2` 与当时的 Policy digest；其中 Human Review = `COMPLETE`、Local APFS = `PARTIAL`、OneDrive = `NOT_VERIFIED`。本文件描述 `swift run FormaAcceptance m11-real` 的用法与产物格式。运行本工具**不等于** Level 4 通过：只有当一次真实目录运行完成、排除侧普查闭合、统计口径按 §4.4 分开陈述时，第 4 级才可以被这样记录。

## 1. 边界（执行前必须确认）

- 工具**只读**：它扫描一个被明确授权的目录，把产物写进另一个独立目录。它不写源目录、不触发 Import、不写 DEVONthink、不调用 Provider、不读取业务正文、不启用默认过滤。
- **不主动下载，但也不能承诺零下载**：探测为了确认 `CACHEDIR.TAG` 与 `.git` 标记会做有界读取（`O_NOFOLLOW`，上限 1024 / 4096 字节）。在 dataless 的 FileProvider 文件上，这类读取可能让**该标记文件自身**被物化。业务正文不在读取范围内，但这条边界必须照实说，见 §6 第 8 条。
- **必须显式给出目录**。工具没有默认目录，也不会去 `Documents`、`Home` 或 OneDrive 里找目标。相对路径一律拒绝。
- **证据目录必须在源目录之外**，也不能反过来包住源目录；软链接解析后同样成立。
- **一次扫描 = 一个新的证据运行目录**。证据目录必须不存在或为空；已有内容一律拒绝（`.evidenceDirectoryNotEmpty`）。这样新的扫描永远不会覆盖旧的人工标签与审核结论。
- **证据目录必须只属于当前用户**（mode `0700`）；私人产物写为 `0600`。目录对其他用户可读时拒绝执行（`.unsafeEvidencePermissions`）。
- **固定产物名与 SQLite 文件不得是符号链接**。写之前逐个检查，发现链接即拒绝（`.unsafeEvidenceSymlink`），报告不会经链接写到别处。
- `--dry-run` 是**唯一模式**。没有"真的导入"这个开关。
- 私人审核表**默认留在本机**。只有脱敏产物可以离开这台机器。

## 2. 前置条件

1. macOS 14+（记录 `sw_vers -productVersion`、`uname -m`、APFS 卷）。
2. Swift 6 工具链（`swift --version`），仓库位于 `dev` 且包含 `Sources/FormaAcceptance`。
3. `git` 可用时，Git 事实（tracked / 嵌套仓库）才会被建立；缺失时相关事实在报告里是 `unknown`，**不会**产生排除。
4. Owner 授权的绝对目录路径，以及一个独立的证据输出目录。
5. 证据运行目录必须是**新的**且**只属于当前用户**。建议整条路径预先建成 0700：
   ```bash
   mkdir -m 700 -p "$HOME/.forma/evidence/m11-real/run-2026-11-18"
   ```
   工具会把产物写为 0600；目录权限不安全时它会拒绝执行，而不是先写再说。
6. 确认该目录不包含生产 DEVONthink 数据（`Project_Archive` 的 991 条记录不可触碰）。

## 3. 执行

### 3.1 扫描与分类

```bash
cd <repo>
swift run FormaAcceptance m11-real \
  --source "/absolute/path/to/authorized/dir" \
  --evidence-dir "$HOME/.forma/evidence/m11-real/run-2026-11-18" \
  --dry-run
```

`--evidence-dir` 必须指向**新的**目录：不存在或为空都可以，已有内容会被拒绝。想做第二次扫描，就换一个运行目录。

可选参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--profile` | `project-archive` | 映射档案；另一个可选值是 `vendor-library` |
| `--max-entries` | `5000` | 单次探测的记录上限；超出部分计入 `skipped`，**不会被当作已验证** |
| `--deadline-seconds` | `120` | 探测批次的时间预算 |

退出码：

| 码 | 含义 |
| --- | --- |
| `0` | 运行完成且覆盖完整（`coverage_state = COMPLETE`） |
| `3` | 运行完成但覆盖不完整（`coverage_state = PARTIAL`：不可读子树、探测上限、超时或取消） |
| `2` | 参数或路径校验失败，工具拒绝执行 |

退出码 `2` 的具体原因（消息会打印在 stderr）：

| 原因 | 含义 | 该怎么做 |
| --- | --- | --- |
| `evidenceDirectoryNotEmpty` | 证据目录已有内容，扫描会覆盖旧证据 | 换一个新的运行目录 |
| `unsafeEvidencePermissions` | 证据目录对其他用户可达，或产物无法证明只属主可读 | `chmod 700` 该目录后重试 |
| `unsafeEvidenceSymlink '<name>'` | 固定产物名或 SQLite 文件是符号链接 | 删掉该链接；不要经链接收集证据 |
| `sourceIsEvidence` / `evidenceInsideSource` / `sourceInsideEvidence` | 两个目录互相包含 | 证据目录必须完全独立 |
| `sourceMismatch` | `--source` 与审核表记录的授权目录不同 | 用产生该审核表的那个目录导入 |
| `policyChanged` | 发布的 Policy digest 与审核表记录的不同 | 旧结论不可复用，按新 Policy 重新扫描 |
| `labelSnapshotMismatch` | 标签绑定的是另一份内容快照 | 只导入针对本次快照内容的标签 |
| `sheetMissing` / `sheetUnreadable` | 该运行目录里没有审核表，或审核表读不出来 | 确认 `--evidence-dir` 指向产生审核表的那一次运行 |
| `sheetInvalid` | 审核表存在但本构建无法解析（例如来自旧版本工具） | 旧结论不可复用：重新扫描到一个新的运行目录 |
| `unknownLabelSourceID` | 标签引用的 `source_id` 不在这份审核表里 | 标签必须来自本次运行，不能跨运行搬运 |

### 3.2 人工标注导入（不重新扫描）

复核人填完标签文件后：

```bash
swift run FormaAcceptance m11-real \
  --source "/absolute/path/to/authorized/dir" \
  --evidence-dir "$HOME/.forma/evidence/m11-real" \
  --labels "$HOME/.forma/evidence/m11-real/human-labels.json" \
  --dry-run
```

这条命令**不扫描源目录**：它读取已有的私人审核表，合并标签，重算指标并重写产物。导入被绑定在产生该审核表的那一次运行上，三项都必须对上，否则拒绝：

| 绑定 | 不匹配时 |
| --- | --- |
| `--source` 必须与审核表记录的授权目录一致 | `.sourceMismatch` |
| 当前发布的 Policy digest 必须与审核表记录的一致 | `.policyChanged`（旧结论不可复用） |
| 标签引用的 `source_id` 必须在审核表里；标签若带 `snapshot_fingerprint`，必须与该记录一致 | `.unknownLabelSourceID` / `.labelSnapshotMismatch` |

导入只操作**该运行目录**，不会把上一次运行的标签文件留成"看起来属于本次执行"的样子：`human-labels.json` 每次导入都被重写。

## 4. 产物

| 文件 | 受众 | 内容 |
| --- | --- | --- |
| `private-review-sheet.json` | 仅本机 | 每条发现的记录：相对路径、决策、规则、解释码、事实 provenance、人工标签、复核备注 |
| `sanitized-summary.json` | 可外发 | 计数、覆盖率、复核进度、误排除算术、policy digest、审核表 SHA-256。**不含路径、文件名、客户名或正文** |
| `scan-completeness.json` | 可外发 | 扫描状态、issue 数、未配对路径数、探测覆盖 |
| `false-exclusion.json` | 可外发 | 三个人群分开：标注过的记录算术、`EXCLUDE` 全集裁决（普查）、`INCLUDE` 抽样计数，以及一句"本次能主张什么"的边界说明 |
| `onedrive-coverage.json` | 可外发 | OneDrive 覆盖状态（本工具固定为 `NOT_VERIFIED`） |
| `human-labels.json` | 仅本机 | 导入的标签副本 |
| `SHA256SUMS` | 可外发 | 上述产物的 SHA-256（不含 `SHA256SUMS` 自身） |
| `acceptance-workspace.sqlite` | 仅本机 | 扫描用工作库，不是证据产物 |

所有产物都写为 `0600` 并读回校验；证据运行目录是 `0700`。工作库及其 `-wal`/`-shm` 同样收紧为 `0600`，但不列入 `SHA256SUMS`（它们是本地工作文件，不是证据）。`SHA256SUMS` 每行是 `哈希  文件名`，可以逐条重算复核。

### 4.1 私人审核表字段

```json
{
  "schema_version": "1.0",
  "policy_id": "forma-import-eligibility",
  "policy_version": "eligibility.v2",
  "policy_digest": "…",
  "source_scope_id": "…",
  "source_root_id": "…",
  "source_path": "/absolute/path",
  "scan_state": "complete",
  "scan_complete": true,
  "scan_issue_count": 0,
  "probe_coverage": { "discovered": 12, "probed": 12, "skipped": 0, "timed_out": false, "cancelled": false },
  "rows": [
    {
      "source_id": "…",
      "relative_path": "cache/artifact.pdf",
      "snapshot_fingerprint": "…",
      "decision": "REVIEW",
      "rule_id": "verified-cache-directory",
      "explanation_code": "protection_fact_unknown",
      "follow_up": "probe_facts",
      "override_state": "none",
      "hydration_pending": false,
      "facts": [ { "fact": "cacheMarker", "status": "confirmed", "reason": "marker_signature", "evidence": "…" } ],
      "human_label": null,
      "reviewer_note": null
    }
  ],
  "unaccounted_paths": []
}
```

四种决策：`INCLUDE`、`EXCLUDE`、`REVIEW`、`DEFER`。**每一条 `EXCLUDE` 和 `REVIEW` 都需要人工判定**。

`snapshot_fingerprint` 是这条决策所依据的内容快照：标签导入时可以带上它，带上就必须一致，这样旧结论不会被套用到已经变化的文件上。

### 4.2 标签文件格式

```json
{
  "schema_version": "1.0",
  "labels": [
    { "source_id": "…", "label": "KEEP", "note": "招标文件，必须保留", "snapshot_fingerprint": "…" },
    { "source_id": "…", "label": "TECHNICAL_NOISE", "note": "编译产物" },
    { "source_id": "…", "label": "UNCERTAIN", "note": "用途不明" }
  ]
}
```

- `KEEP`：业务资料。它是**唯一**能形成误排除的标签：`KEEP` 记录被 `EXCLUDE` 就是误排除。
- `TECHNICAL_NOISE`、`UNCERTAIN` 不进入误排除分母。
- 标签必须引用审核表里存在的 `source_id`，否则拒绝导入。
- `snapshot_fingerprint` 可选：写了就必须与审核表里该记录的快照一致，避免把旧内容的结论套到新内容上。

### 4.3 脱敏摘要字段

```json
{
  "schema_version": "1.0",
  "coverage_state": "COMPLETE",
  "discovered": 12, "include": 7, "exclude": 1, "review": 4, "defer": 0,
  "unaccounted": 0, "scan_issue_count": 0,
  "scan_state": "complete", "scan_complete": true,
  "probe_coverage": { "discovered": 12, "probed": 12, "skipped": 0, "timed_out": false, "cancelled": false },
  "per_rule": { "verified-cache-directory": 1 },
  "review_progress": { "state": "in_progress", "required": 5, "reviewed": 2, "unreviewed": 3, "keep_samples": 1, "technical_noise_samples": 1, "uncertain_samples": 0, "include_sampled": 1 },
  "false_exclusion": {
    "state": "MEASURED", "numerator": 0, "denominator": 1, "rate": 0.0, "unit": "records",
    "population": "human-labelled KEEP records",
    "exclude_adjudication": { "state": "CENSUS_INCOMPLETE", "excluded_records": 1, "adjudicated": 0, "unadjudicated": 1, "keep_labelled": 0, "uncertain_labelled": 0, "verdict": "INCOMPLETE", "unit": "records" },
    "include_sample": { "state": "SAMPLED", "included_records": 7, "labelled": 1, "keep_labelled": 1, "technical_noise_labelled": 0, "uncertain_labelled": 0, "unit": "records", "claim_boundary": "an INCLUDE-side sample says whether records the policy kept look like business material; it does not measure the false-exclusion rate of the whole run" },
    "claim_boundary": "only 0 of 1 excluded records were adjudicated, so the excluded set is not fully evidenced; an INCLUDE-side sample says whether records the policy kept look like business material; it does not measure the false-exclusion rate of the whole run (1 of 7 included records carry a verdict)"
  },
  "policy_digest": "…",
  "evidence_sha256": "…",
  "artifacts": { "private-review-sheet.json": "…" }
}
```

状态含义必须分开读：

| 字段 | 含义 |
| --- | --- |
| `coverage_state` | `COMPLETE` = 扫描与探测覆盖了全部发现记录；`PARTIAL` = 有不可读子树、探测上限、超时或取消 |
| `review_progress.state` | `not_required`（没有待判定记录）/ `unreviewed`（一条都没标）/ `in_progress`（标了一部分）/ `complete`（全部 `EXCLUDE`/`REVIEW` 已判定） |
| `false_exclusion.state` | `N/A` = 没有任何 `KEEP` 标注，此时**不能**报告"零误排除"；`MEASURED` = 分子/分母/比率有值，但分母只是**被标注为 `KEEP` 的记录**，不是全集 |
| `exclude_adjudication.state` | **只描述审查覆盖**：`N/A` = 本次没有 `EXCLUDE` 记录；`CENSUS_COMPLETE` = 每条 `EXCLUDE` 都有人工判定；`CENSUS_INCOMPLETE` = 还有 `EXCLUDE` 未判定。它**不**说明排除是否安全 |
| `exclude_adjudication.verdict` | **只描述结论**，优先级 `FALSE_EXCLUSION_FOUND` > `INCOMPLETE` > `NEEDS_REVIEW` > `SAFE_TO_CLEAR`（`N/A` 表示没有排除）。`NEEDS_REVIEW` = 普查已完成但仍有 `UNCERTAIN`；`keep_labelled = 0` 单独出现**不构成**安全结论 |
| `include_sample.state` | `SAMPLED` / `NOT_SAMPLED`（有保留记录但一条未标）/ `N/A`（本次没有任何保留记录，抽样不适用）。抽样只说明"被保留的记录看起来确实是业务资料"，**不能**换算成总体误排除率 |

### 4.4 三个人群，三种主张

同一次运行里有三个互不等价的统计人群，产物把它们分开写，就是为了防止互相冒充：

| 人群 | 分母 | 能主张什么 | 不能主张什么 |
| --- | --- | --- | --- |
| `EXCLUDE` 全集裁决（普查） | 本次被排除的全部记录 | 排除侧**实际观察到**的误排除条数（`keep_labelled`）；普查未完成就是证据未闭合 | 不能说明被保留的记录里有没有噪声 |
| `INCLUDE` 抽样 | 被抽样并标注的保留记录 | 保留集合的一致性（抽样里有没有噪声、有多少 `UNCERTAIN`） | **不能**当作总体误排除率，也不能写成"零误排除" |
| 标注过的记录算术（`false_exclusion`） | 全部 `KEEP` 标注记录 | `docs/IMPORT-ELIGIBILITY-POLICY.md` 规定的比率口径（分母必须是"已独立标注为应保留的业务样本"） | 分母由标注方式决定，样本多大就只能说多大 |

因此：`0/14` 这类数字的含义是"14 条被标注为 `KEEP` 的记录里没有一条被排除"，它属于第 2、3 行；排除侧的证据要读 `exclude_adjudication`。`UNCERTAIN` 既不算 `KEEP`，也不算已确认的错误：它计入普查的"已判定"（`adjudicated`），但会单独计入 `uncertain_labelled`，并使 `verdict` 停在 `NEEDS_REVIEW`——**审查完成 ≠ 排除安全**，`keep_labelled = 0` 必须配合 `verdict = SAFE_TO_CLEAR` 才能读成"排除侧已清除"。

还有一个必须并列的切分（Issue #136，本轮采用方案 C）：`INCLUDE` 人群内部还分"已探测候选"与"未探测候选"。当 `probe_coverage.skipped > 0` 时，未探测记录没有任何事实，按 `default-mapping-candidate` 落到 `INCLUDE`，因此产物里的 `include` 是两者之和。引用 `include` 的任何结论都必须同时给出 `discovered` / `probed` / `skipped`，不得把全部 `INCLUDE` 写成"已完成事实探测的候选"。机器可读区分属于 Issue #136 的方案 A（新增计数），把未探测记录改判 `DEFER` 属于方案 B（会改变 `by_decision` 的含义，需合同层评审）——两者本轮都未实施。

历史产物兼容：`exclude_adjudication`、`include_sample`、`claim_boundary`、`include_sampled` 是新增可选字段，`schema_version` 仍为 `1.0`；旧运行目录里的产物不会被改写，读旧产物时这些字段缺失即为"该运行未记录普查/抽样"。**已冻结的历史证据不做回填。**

## 5. 判定

| 判定 | 条件（按优先级互斥） |
| --- | --- |
| `FAIL` | `exclude_adjudication.keep_labelled > 0`（`verdict = FALSE_EXCLUSION_FOUND`）：排除侧普查里出现了 `KEEP` 记录。记录 `source_id`、规则、复现条件，**不擅自修改 Policy**。此判定优先于其它一切条件 |
| `PARTIAL` | 无 `FAIL`，且满足任一项：`coverage_state = PARTIAL`；`review_progress.state` 为 `unreviewed` 或 `in_progress`（仍有 `EXCLUDE`/`REVIEW` 未判定——普查只覆盖 `EXCLUDE`，未判定的 `REVIEW` 记录不会体现在 `exclude_adjudication` 里）；`CENSUS_INCOMPLETE`／`verdict = INCOMPLETE`；`verdict = NEEDS_REVIEW`（普查已闭合但有 `UNCERTAIN` 未解决）；`include_sample.state = NOT_SAMPLED`（有保留记录却没有任何抽样证据） |
| `PASS` | 无 `FAIL`、无 `PARTIAL` 条件：`coverage_state = COMPLETE`、`review_progress.state` 为 `complete` 或 `not_required`（没有待判定记录，例如空目录运行）、`exclude_adjudication.state` 为 `CENSUS_COMPLETE` 或 `N/A`、`verdict` 为 `SAFE_TO_CLEAR` 或 `N/A`、且 `include_sample.state` 为 `SAMPLED` 或 `N/A` |
| `NOT_VERIFIED` | 没有执行证据：工具未运行、环境缺失、参数被拒。它不能与上面三者同时成立 |

判定互斥且按上表顺序判定：先看 `FAIL`，再看 `PARTIAL`，其余才可能是 `PASS`；没有任何执行证据时只能是 `NOT_VERIFIED`。本次没有 `INCLUDE` 记录时，`include_sample.state = N/A` 不阻止 `PASS`（没有东西可抽，不是"跳过抽样"）。

`PASS` 只描述本次授权目录、本次 Policy digest 下的证据闭合程度，不自动扩成"该策略在任意目录都安全"。抽样抽了多少条、按什么分层抽，记录在验收报告里，产物本身不规定抽样量：产物只如实报告"抽了 `labelled` 条 / 共 `included_records` 条"。

发现误排除时的最小记录：`source_id`、`relative_path`、`rule_id`、`explanation_code`、对应的标签与复核备注、复现条件。

## 6. 本工具的已知边界

1. **未实现分页探测**。超过 `--max-entries` 的记录计入 `skipped`，覆盖状态变成 `PARTIAL`；它们不会被当作已验证。**但要注意统计口径**（Issue #136，本轮采用方案 C）：这些未探测记录没有任何事实，按 `default-mapping-candidate` 落到 `INCLUDE`，因此 `by_decision.include` **混合了已探测候选与未探测候选**。任何引用 `include` 的结论必须并列写出 `discovered` / `probed` / `skipped`，不得把全部 `INCLUDE` 描述为"已完成事实探测的候选"，也不得把 `PARTIAL` 写成 `COMPLETE`。机器可读区分（新增计数或把未探测记录改判 `DEFER`）保留为 Issue #136 的方案 A/B，需独立评审，本轮未实施。
2. **Git 事实需要授权根本身是仓库顶层**。否则 `gitTracked` 为 `unknown`。
3. **保护事实未建立时，缓存目录排除会降级为 `REVIEW`**（`protection_fact_unknown`），而不是被当成已验证的排除。这是保守方向，但也意味着非 Git 的业务目录里 `EXCLUDE` 会很少。
4. **OneDrive 覆盖恒为 `NOT_VERIFIED`**。本工具能读出 dataless 标志（`st_flags`，来自 `stat`，不下载内容），因此能报告"多少条是 metadata-only"；但它不验证 hydration 行为、离线状态、FileProvider 失败与权限失败，也不证明下载未被触发。这些需要单独授权的 OneDrive 目录和另一次运行。
5. **默认过滤始终关闭**。本工具只读，不改 `FormaApp`，不改变生产行为。
6. **一次扫描只对应一个运行目录**，没有历史运行管理系统。想保留多次结果，就用不同的 `--evidence-dir`。
7. **安全检查是"证明不了就不写"**：证据目录的权限、固定产物名的链接、目录与源目录的重叠，都在写入前复核；任何一项无法确认即拒绝执行。
8. **标记文件的有界读取可能触发自身物化**。`verified-cache-directory` 与嵌套仓库判定需要读 `CACHEDIR.TAG`（≤1024 B）与 `.git`（≤4096 B）；`readFile` 走 `openat(O_RDONLY|O_NOFOLLOW)` + `read`，在 FileProvider 上这正是可能引起下载的调用序列。业务文档的正文从不在这个范围内。已提出的最小修复（dataless 标记跳过内容读取）会改变排除侧事实的可用性，属于策略语义变更，需独立审查，见 Issue #129。

## 7. 与默认启用门的关系

第 4 级通过只是第 5 级（生产默认启用）三道前置之一。合成验收（`MACOS_SYNTHETIC_PARTIAL`）、真实目录验收和 Owner 再确认，三者都不可互相替代。
