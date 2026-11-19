# M11 生成型诊断日志目录识别研究（Issue #131）

状态：**研究结论，未采纳任何策略变更**。本文只评估如何识别"运维诊断日志目录"这类生成物，默认过滤仍关闭，`docs/IMPORT-ELIGIBILITY-POLICY.md` 未改动，Level 5 仍 `NOT_AUTHORIZED`。

## 1. 现有能力（代码事实）

规则本体是数据文件 `Sources/FormaCore/Eligibility/Policies/forma-eligibility.v1.json`（`policy_version` = `eligibility.v2`，与 `EligibilityPolicy.currentVersion`（`EligibilityPolicy.swift:269`）一致；`shipped()` 在 `:350`）。判定顺序与降级全部在 `EligibilityClassifier.swift`。

| 能力 | 位置 | 真实行为 |
| --- | --- | --- |
| `path_components` 谓词 | `EligibilityPolicy.swift:131, 145-148` | `relativePath.split("/")` 后**小写比对**，**包含末段文件名**：目录组件命中，恰好同名的文件也命中。没有"仅目录组件"的谓词 |
| 其它路径谓词 | `EligibilityPolicy.swift:136-144`（`extensions` / `basenames` / `basename_prefixes`，编码键见 `:106-108`） | 全部可用，但 `extensions` 在出厂策略中**未被任何规则使用**；噪声规则用的是 `basenames` 精确名 |
| 生成型目录规则 | `forma-eligibility.v1.json`（`generated-directory-review`，priority 39，`evidence_strength: weak`） | `path_components` 含 `build`/`dist`/`bin`/`target`/`.build`/`coverage` → `REVIEW`，**不是** `EXCLUDE` |
| 保护事实优先级 | `EligibilityClassifier.swift:94-108, 154-176` | `businessEvidence == .confirmed`、`gitTracked == .yes`、`nestedRepository == .yes`、`sourceCodeOrDeployment == .yes` 任一成立即阻止排除（转 `REVIEW`）；缓存规则声明的 `protection_facts` 为 `[gitTracked, nestedRepository]` |
| 未知即不猜 | `EligibilityClassifier.swift:166-171` | 声明了保护事实但值为 UNKNOWN → `REVIEW` + `protection_fact_unknown` |
| 扫描状态门槛 | `EligibilityClassifier.swift:178-183` | 除"强证据噪声排除"外，`scanState != .complete` 一律 `DEFER`（`scan_incomplete`）；强噪声排除不等待完整扫描（`:154-176` 在门槛之前） |
| 无规则命中 | `EligibilityClassifier.swift:226-230` | → `REVIEW`（`no_rule_matched`）。符号链接条目 `state = .symlink`（`SourceFilesystem.swift:221`）不满足 `entry_states: ["present"]`，因此落在此处 |

因此：一个名为 `onekeylog/`（或任何诊断工具输出目录名）的目录，今天得到的是**逐文件的 `default-mapping-candidate` → `INCLUDE`**；只有其内部恰含 `bin/`、`target/` 等组件时才会 `REVIEW`。没有任何规则会仅凭 `.log`、`.ini`、`.csv`、`README.txt` 排除文件——`extensions` 谓词存在但未被使用。

## 2. 这类目录里有什么（通用形态）

典型运维/诊断工具的输出目录（合成描述，不含真实路径）同时包含：

- 生成物：滚动日志（`.log`、`.log.1`、按日期命名的子目录）、转储（`.dmp`、`.dump`）、指标导出（`.csv`）、工具配置快照（`.ini`、`.conf`）；
- **人手写的业务内容**：现场记录、验收/巡检单、配置说明；
- 随工具一起归档的交付物：客户提供的 `.csv` 数据、现场拍摄的 `.txt` 记录。

关键冲突：日志扩展名与"运维记录"这一业务文档类别重叠（`docs/IMPORT-ELIGIBILITY-POLICY.md` 的业务文档清单含"运维记录"）。任何按扩展名的排除都会命中真实业务文件。

## 3. 候选方案

| 方案 | 机制 | 正面例 | 反面例（会被误判） | 需要的回归 | 风险 | 本轮 |
| --- | --- | --- | --- | --- | --- | --- |
| **A. `REVIEW` 路径组件清单** | 扩充 `generated-directory-review` 的 `path_components` 值集（`onekeylog` 等诊断目录名），判定仍为 `REVIEW` | 生成物不再自动进 `INCLUDE`，但仍出现在复核清单、守恒不变 | 目录恰好叫该名的业务归档 → 变 `REVIEW`（多一步人工确认，**不会丢**）；**副作用已知**：谓词包含末段文件名，因此名为 `onekeylog` 的无扩展名文件也会进 `REVIEW` | 现有生成目录用例 + 新名单逐项 `REVIEW` 断言 + 一条"名称相近的业务目录不被排除" + 一条"同名文件也只到 REVIEW" | **低**：只改判定档位，不改可见性；纯 JSON 变更 | 记录为推荐第一步，未实施 |
| **B. 生成器签名** `generatorSignature` | 新事实：目录内特定文件（manifest / 安装日志）的有界内容匹配已知工具签名 | 精度高，能区分工具产出与人写内容 | 签名不匹配的工具无效果（漏检），签名误配则批量误判；**需要读内容**，与 OneDrive 标记读取风险叠加（Issue #129） | 事实 probe + 有界读取 + 缓存 + 脱敏（路径不得外发）+ dataless 行为用例 | **中高**：新事实、新读取面 | 未实施，需先有普查证据 |
| **C. 仅信息标注** | `INCLUDE` 不变，视图追加 advisory 字段（如 `generated_directory_candidate`） | 零分类风险；给复核人线索，可量化命中数 | 不解决问题，只是让问题可见 | 只加视图字段与 CLI 输出，需证明旧产物仍可解码 | **最低** | 建议与 A 并行；未实施 |
| **D. 直接 `EXCLUDE`** | 新规则按目录名或扩展名排除 | 噪声骤减 | **会丢证据**：现场 `.log` 运维记录、`.csv` 验收数据、`.ini` 配置说明；错误率完全取决于名单质量 | 需要保留侧普查（当前仅 14 条抽样） | **高，不可接受**：第 4 级证据不足以支撑自动丢弃 | **拒绝** |

补充约束（对所有方案生效）：

1. 名单一律用 `path_components` 的**精确目录名**值，不用 `basename_prefixes`、不用 `extensions`：前者会牵连 `onekeylog-现场记录.pdf` 这类人写文件名，后者是按扩展名的批量判定。必须同时记录 `path_components` 也匹配末段文件名这一已知副作用（§1），要么接受"同名文件也只进 REVIEW"，要么先新增"仅目录组件"谓词——那是生产代码变更，需独立评审，不属于本研究；
2. 保护事实优先级必须保留：`businessEvidence == .confirmed` / `gitTracked == .yes` / `nestedRepository == .yes` / `sourceCodeOrDeployment == .yes` 时任何排除类启发式都不得覆盖（`EligibilityClassifier.swift:94-108` 现有行为），且规则声明的 `protection_facts` 必须写全，未知事实才会走 `REVIEW` 而不是被当作"可以排除"；
3. 名称匹配走小写比对，但**不得**依赖它处理 Unicode 归一化：APFS 的 NFC/NFD 与大小写折叠由文件系统决定，已有保护回归用例（`caseOnlyNamesAreNeverMerged`、`unicodeNamesStayConsistent`）要求任何名单变更都不把两种写法静默合并；
4. 排除类规则还有一道顺序陷阱：强证据噪声排除**不受**扫描完整性门槛保护（`EligibilityClassifier.swift:154-183`，见 `a strong noise exclusion does not wait for a complete scan`）。任何新的 `EXCLUDE` 规则在 PARTIAL 扫描中同样会生效，因此 D 的误伤面在覆盖不完整时更大；
5. 无论采纳哪一项，改动对象是策略 JSON 或 `EligibilityPolicy.swift` 的谓词层，属策略语义变更：`docs/IMPORT-ELIGIBILITY-POLICY.md` 需同步修订，`docs/SPEC.md` 为冻结合同需先提案。

## 4. 建议顺序与决策条件

1. **先取得数据，再改名单**：完成 Issue #130 的本地 APFS 运行与第 4 级保留侧普查（Runbook §5 第 6 步，222 条 `INCLUDE` 全量 KEEP/ERROR 复核）。普查前，任何排除类方案的误排除率都是未知的。
2. **A + C 同批**（若 Owner 采纳）：A 只改变档位，C 提供命中率测量；两者都可通过 `sanitized-summary.json` 的 `by_decision` 与私有复核清单验证，不新增内容读取。
3. **B 只有在**普查显示某类生成物确实集中在特定目录、且签名的假阳性率有实测数字后才提案。
4. **D 不做**。若未来要自动丢弃，前提是：保留侧普查完成、误排除计数为 0 且有人工复核记录、以及独立的策略修订 PR（`docs/SPEC.md` 为冻结合同，需先提案）。

无论采纳哪一步，都需要独立评审 + 单独 PR：本文不构成变更，也不改变默认过滤 `OFF` 的现状。

## 5. 待补证据

| 需要 | 用途 |
| --- | --- |
| 第 4 级保留侧普查（`include_total` / `include_reviewed` / `include_error_count`） | 判定 A/C 的实际收益与误伤面 |
| 真实目录中该类别的样本统计（仅计数与合成示例，不外发路径/文件名） | 名单是否需要包含变体（大小写、缩写、日期子目录） |
| APFS 与 OneDrive 各一次 `REVIEW` 计数对照 | 确认档位变更在两种文件系统上行为一致 |
