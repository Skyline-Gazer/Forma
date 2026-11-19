# M11 第 4 级真实目录运行记录（脱敏）

状态：**`VERIFIED — SCOPE LIMITED`**（范围限定见 §6）。本文件只登记聚合数字与判定口径，不含目录路径、文件名、客户名或正文。私人审核表与人工标签留在 Owner 本机。

## 1. 运行环境

| 项 | 值 |
| --- | --- |
| 主机 | MacBookPro18,3 / macOS 27.0.1 / arm64 |
| 工具链 | Swift 6.4 |
| 仓库基线 | `dev` @ `408baa7e25f56d96fe6a063e1d096ee08beb16af`（PR #128 合并后），工作树干净 |
| 命令 | `swift run FormaAcceptance m11-real --source <Owner 授权目录> --evidence-dir <本机运行目录> --dry-run` |
| 运行目录 | `run-2026-11-19-134600`（本机，一次扫描一个目录） |
| 文件系统 | OneDrive CloudStorage / FileProvider |
| 样本构成 | Owner 授权的真实业务资料目录，覆盖个人文件、售前、项目文件、笔记、应用五类 |
| Policy | `forma-import-eligibility` / `eligibility.v2` / digest `aa7796dfe21d3eca6b0030f39cb1cb5f95c26c8cfab6069910bc4baad54d2a57` |

## 2. 扫描结果

| 指标 | 结果 |
| --- | --- |
| Discovered | 3,357 |
| Probed | 3,357 |
| Skipped | 0 |
| INCLUDE | 3,320 |
| EXCLUDE | 37 |
| REVIEW | 0 |
| DEFER | 0 |
| Scan issues | 0 |
| Unaccounted | 0 |
| Coverage | `COMPLETE` |
| 扫描耗时 | 25.7 s |
| 标签导入耗时 | 35.6 s |
| dataless（metadata-only） | 3,157 |
| `default-mapping-candidate` | 163 |
| 技术噪声 | 37 |

守恒：`3,320 + 37 = 3,357`，与 `REVIEW = 0`、`DEFER = 0` 一致；`unaccounted = 0` 表示没有"扫描报错但没有对应记录"的路径。

## 3. 人工复核

- `EXCLUDE` 37/37 全部逐条判定，均为 `.DS_Store`（macOS 目录元数据，通用文件名，非业务标识）。
- `INCLUDE` 侧分层抽样 14 条，覆盖 docx / pdf / xlsx / pptx / doc / xls / txt / zip / rar。
- `UNCERTAIN` 标签 7 条：保持未确定，未被换算成 `KEEP`，也未记为已确认错误。
- 全过程未打开业务正文（探测只做 `stat` 与标记文件的有界读取，见 §5）。

## 4. 统计口径（对初版报告的修正）

三个人群必须分开读，产物字段见 `docs/M11-LEVEL4-RUNBOOK.md` §4.4：

| 人群 | 本次数字 | 能主张 | 不能主张 |
| --- | --- | --- | --- |
| 排除侧普查 `exclude_adjudication` | `CENSUS_COMPLETE`，excluded 37、adjudicated 37、`keep_labelled = 0` | 排除侧**观察到零误排除**；证据已闭合 | 不涉及被保留的记录 |
| 保留侧抽样 `include_sample` | labelled 21（其中 `KEEP` 14、`UNCERTAIN` 7）of 3,320 | 抽样内的保留一致性 | **不能**换算成总体误排除率 |
| 标注算术 `false_exclusion` | `MEASURED`，0 / 14 = 0.0，population = `human-labelled KEEP records` | 冻结口径（分母＝已独立标注为应保留的样本）下的比率 | 不是普查、不是总体率 |

**修正内容**：初版现场报告把 `0/14` 写成"误排除率为零"。`14` 来自保留侧抽样，它既不是排除侧全集也不是总体样本。本次运行的排除侧证据是普查 `37/37` 且 `keep_labelled = 0`，其正确表述是"观察到零误排除"，而不是"误排除率为零"。工具与文档已改为分开输出三口径并随产物写出一句边界说明，避免同一误读再次发生。历史运行目录的产物不被改写或回填。

## 5. 证据完整性

| 产物 | 受众 | Owner 侧校验 | DevBox 独立复核 |
| --- | --- | --- | --- |
| `sanitized-summary.json`、`scan-completeness.json`、`false-exclusion.json`、`onedrive-coverage.json`、`human-labels`(仅本机)、`SHA256SUMS` | 脱敏件可外发 | 6/6 SHA-256 一致（Owner 报告） | **PENDING**：脱敏原件尚未送达 DevBox，未逐字节复算 |
| `private-review-sheet.json`、`human-labels.json`、`acceptance-workspace.sqlite` | 仅本机 | mode `0600` / 目录 `0700` | 不适用（不外发） |

`SHA256SUMS` 每行 `哈希  文件名`，任何拿到脱敏件的人都能离线重算比对；工作库不列入清单（本地工作文件，非证据）。**本记录中的数字来自 Owner 汇总，不等价于原始证据的独立复核结论。**

## 6. 范围限定

`VERIFIED` 只覆盖：该次 Owner 授权目录、元数据分类路径、`eligibility.v2` 与上表 digest、本次样本与人工复核。

分开保留、未随本次通过的状态：

| 子项 | 状态 | 缺口 |
| --- | --- | --- |
| Human Review | `COMPLETE` | 排除侧普查闭合；保留侧仍是抽样 |
| Local APFS 实体 | `PARTIAL` | 本次样本位于 FileProvider；纯本地 APFS 实体文件、权限失败与错误报告路径未单独验收（Issue #130） |
| OneDrive FileProvider | `NOT_VERIFIED` | hydration / 离线 / 访问失败 / 扫描期间状态变化未验证；`onedrive-coverage.json` 固定记 `NOT_VERIFIED`（验收矩阵见 Issue #129） |
| 默认过滤 | `OFF` | `FormaApp` 未改，生产调用不传 `eligibility` |
| 第 5 级（生产默认启用） | `NOT_AUTHORIZED` | 三道前置之一通过，另两道未闭合，且需 Owner 再确认 |

## 7. 本次运行暴露的后续工程项

1. **标记文件的有界读取可能物化 dataless 标记自身**：`CACHEDIR.TAG`（≤1,024 B）与 `.git`（≤4,096 B）读取走 `openat(O_RDONLY|O_NOFOLLOW)` + `read`，在 FileProvider 上这是可触发下载的调用序列。业务正文不在读取范围内，但"绝不触发下载"这句不能承诺。已提出的最小修复（dataless 标记跳过内容读取）会改变排除侧事实可用性，属策略语义变更 → 独立审查，不在本轮采纳。
2. **诊断型目录（如项目内 `onekeylog`）中的 log / ini / csv 仍走 `default-mapping-candidate` 保留**：本轮未新增任何按扩展名的排除规则。候选方案与风险见 `docs/M11-DIAGNOSTIC-LOG-CLASSIFICATION.md`。
3. **原件独立复核 PENDING**：与第 3 级同样流程（Owner 送达脱敏件 → DevBox 只读复算哈希 → 逐条比对），完成前第 4 级的完整性结论限于 Owner 侧声明。
