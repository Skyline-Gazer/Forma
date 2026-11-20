# Alpha 离线模式（Offline Planner — Not AI）

本文件只描述离线模式的现场操作；总体验收清单见 `docs/ALPHA-ACCEPTANCE.md`（随 Import 干跑 PR 提交）。

## 1. 它是什么

- **确定性草稿**：不调用任何 Provider、不使用 API Key、不向任何外部发送数据。
- 产物如实记录 `modelProvider = "offline"`、`modelID = "offline-planner.v1"`；运行报告里 token 用量为空。
- **不声明任何字段**：每条记录的字段都进入 `unknown_fields`，`documentCategory` 为空，`confidence = low`（字段保持未知，等待人工确认）。
  原因：`ManifestValidator` 拒绝任何"非空但没有引用证据"的值，而离线模式不读正文，无法引用证据。
  把记录硬塞进"待分类"会产生逐条违规，所以正确的做法是**不猜**。

## 1.1 离线模式仍然会读什么（重要）

| 行为 | 事实 | 依据 |
| --- | --- | --- |
| 正文读取 | **会**为每个文件注册本地证据行（提取文本片段），以便人工修正时引用真实内容 | `WorkspaceModel.runMapping` → `workspace.captureEvidence` |
| 规划器本身 | 不使用这些证据，**不声明任何字段** | `OfflinePlannerAnswerer`（全部 `unknown_fields`） |
| 网络 | 无任何外发；离线请求在 `ProviderTransport` 被拒绝 | `ProviderTransport.makeRequest` guard |
| FileProvider 占位符 | 证据读取在打开正文前检查 dataless 标志并直接返回 `hydrationPending`，因此**不会**因注册证据而物化占位符 | `SourceEvidenceReader.swift:48`、`SourceFilesystem.swift:31`（`ubiquitousPending` 或 `SF_DATALESS`） |
| 零物化 | **未证明**。上面是代码路径上的保证，不是现场观测；OneDrive 行为仍是 `NOT_VERIFIED`（Issue #129） | M11 轨道 |

## 2. Owner Mac 上的最短操作

1. 启动 App → **Workspace** → Add Source，选择一个**合成**项目目录（含几份 pdf/docx/xlsx）。
2. 扫描完成后确认记录数与 issue。
3. Settings 选择 Profile（Project Archive 或 Vendor Library）。
4. **Mapping** 页 → 顶部 `Mode` 选择 **Offline Planner — Not AI** → 点 `Map Files`。
   - 此时不需要打开 cloud egress，也不需要任何 Key。
   - 完成后左侧显示批次与 `Provider requests 0`；Manifest 区 `Provider` 应为 `offline`、`Model` 为 `offline-planner.v1`。
5. 逐条修正：选中记录 → 在字段面板选择类目/填写项目名与年份 → 修正会引用该文件已注册的证据行 → 重新验证。
6. 导出 bundle，重新打开验证内容仍在。
7. 切到 **Import** 页 → `Build plan` → 确认横幅为干跑、`blocked` 原因包含 `authorization_missing`、不存在写入按钮。

## 3. 判读要点

| 现象 | 含义 |
| --- | --- |
| Manifest `Provider = offline` | 本次是确定性草稿，不是模型输出 |
| `Input/Output tokens = Not reported` | 没有模型调用，数字不存在 |
| 每条记录 `documentCategory` 为空 | 预期行为：无正文证据 ⇒ 不声明字段 |
| Import 计划全部 `blocked` | 本构建无导入授权与写入路径；这是正确状态 |

## 4. 明确不属于本模式的能力

- 业务类别判断、项目归属推断、年份推断（这些需要正文证据与人工确认）。
- 任何网络请求、任何 DEVONthink 写入。
- 真实 AI 质量结论（P3-B 未授权）。
