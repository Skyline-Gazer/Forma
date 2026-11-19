# M11 OneDrive / FileProvider 只读验收协议（Issue #129）

状态：**准备就绪，Mac 矩阵未执行**。本文固化"代码里到底做了什么系统调用"、"哪些已在 DevBox 证明"、"Mac 上要按什么顺序验收"，并给出允许与禁止的主张措辞。本文不改变任何默认行为：默认过滤仍关闭，`--dry-run` 仍是唯一模式。

## 1. 当前记录

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| OneDrive FileProvider 真实目录元数据分类 | `VERIFIED — SCOPE LIMITED` | `run-2026-11-19-134600`：3,357 条记录，3,157 dataless，EXCLUDE 37（全部 `.DS_Store`），REVIEW/DEFER/skipped/unaccounted 均为 0 |
| OneDrive 子状态 `onedrive_fileprovider` | `NOT_VERIFIED` | backlog `OneDrive/FileProvider` 行；上表只覆盖元数据与排除，不覆盖 hydration |
| hydration 是否发生 | `NOT_VERIFIED` | 无传输层或 `dataless` 标志翻转观测 |
| 默认过滤启用 | `OFF`，未授权 | I1 Slice 5 = `NOT_AUTHORIZED` |

## 2. 现有实现的系统调用清单（代码事实）

| 用途 | 调用 | 位置 | 范围 | 可能 hydration？ |
| --- | --- | --- | --- | --- |
| 类型 / 大小 / 修改时间 | `lstat` | `SourceFilesystem.swift`（按 `st_mode` 分类，`SF_DATALESS` 由 `st_flags` 读出） | 每个目录项一次，不跟随链接 | 否，仅元数据 |
| 读 `CACHEDIR.TAG` | `open(..., O_RDONLY \| O_NOFOLLOW)` + `fstat` + 有界 `read`（超限即视为不匹配） | `EligibilityFactProbe.swift:374-404`（`cacheMarker`）、`:438`（limit 1024）、`readFile` | 从文件所在目录**逐级上溯到作用域根**，最近优先；每个目录的标记只读一次并复用（`:277`） | **可能**：命中 dataless 占位符时 `open` 触发 FileProvider 拉取 |
| 读 `.git` | 同上，有界 4096 B | `EligibilityFactProbe.swift:465` 附近 | 仅在上溯过程中遇到 `.git` 项时 | **可能**：`.git` 本身若为 dataless 占位符（OneDrive 上常见） |
| 符号链接条目 | `lstat`（不 `open`、不解析目标） | `SourceFilesystem.swift:205-232`（`state` 为 `.symlink`） | 链接条目不进入 `entry_states: ["present"]` 规则，落为 `REVIEW`（`no_rule_matched`） | 否 |
| 目录名 / 扩展名 / 隐藏 / `contentHash` | 无额外调用 | 谓词见 `EligibilityPolicy.swift:126-172` | `contentHash` 在 Level 4 视图里固定 `nil` | 否 |
| 网络 | Level 4 验收路径**无任何网络调用**：Forma 的出网只存在于显式 Provider 请求路径（`ProviderTransport.swift:26` `URLSessionConfiguration.ephemeral`，用于报价/映射），验收 CLI 不调用；DEVONthink 走 stdio | `ProviderTransport.swift:26`、`MCPStdio.swift` | — | 不适用 |

结论：扫描与判定本身不读业务文件内容、不请求哈希、不下载；唯一的内容读取是上面两行标记文件，且**只沿祖先目录**发生——这正是 §3 风险的来源，也是它不能被笼统写成"Forma 不下载文件"的原因。

## 3. 标记读取的 hydration 风险

`CACHEDIR.TAG` 与 `.git` 在 OneDrive 上通常也是 dataless。一次 `open(O_RDONLY)` 足以让 FileProvider 拉取该小文件：字节量小（≤1 KiB / ≤4 KiB），但对"Forma 不下载文件"的笼统主张构成反例，也会污染 `lsof` / 活动监视器观察。

**本轮未改代码**（策略语义变更需独立评审，见 Issue #129）。讨论过的候选，仅记录：

| 候选 | 机制 | 问题 |
| --- | --- | --- |
| 祖先链只 `lstat`，不 `open` | 彻底无读取 | 无法区分 `Signature:` 与同名垃圾 → 误判缓存目录 |
| 跳过 dataless 标记的读取（`st_flags` 已知） | 只在实体文件上验证签名 | 行为随云端置灰状态漂移，需要新的 UNKNOWN 语义 |
| 维持现状 + 明确主张边界 | 零代码变更 | 主张必须写"不读业务文件内容"，而不是"不下载任何文件" |

当前采用第三项：本文 §6 的主张措辞就是它的执行形式。

## 4. DevBox 自动化覆盖

`Tests/FormaCoreTests/OneDriveFileProviderSimulationTests.swift`（`@Suite("OneDrive FileProvider simulation")`，9 项；输入为合成事实与合成清单，**不声称真实 FileProvider**）：

| 场景（测试名） | 证明的事实 |
| --- | --- |
| `a verified cache marker still excludes a dataless record` | 标记已验证 + 保护事实已探测为否 + 记录 dataless → 仍 `EXCLUDE`（锁定现有行为，防"顺手改成 REVIEW"） |
| `an unprobed protecting fact stops the cache exclusion` | 同一标记但 `gitTracked` 未知 → 降级 `REVIEW`（`protection_fact_unknown`），`exclude == 0`：未知事实从不被当作"可以排除" |
| `a marker that could not be verified never excludes anything` | 标记 `unreadable` / `presentUnverified` / `notChecked` 三种失败都不得 `EXCLUDE`，落回默认候选 `INCLUDE`；`notChecked` 不等于"无标记" |
| `a dataless record and a hydrated one reach the same decision` | 占位符与实体文件判定一致（`INCLUDE`），但命中规则不同（`dataless-metadata-only` vs `default-mapping-candidate`）——判定不依赖 hydration，规则归因如实记录 |
| `a FileProvider access failure defers instead of excluding` | 路径带访问失败 issue → `DEFER`，`exclude == 0`，守恒成立 |
| `an offline tree is reported, not guessed` | 清单不完整 + 全树 hydration 待处理 → 全部 `DEFER`（`scan_incomplete`），无记录丢失 |
| `an interrupted scan cannot exclude protected content` | 扫描取消时，被 Git 跟踪的内容即使撞上已验证缓存标记也只到 `REVIEW`，`exclude == 0`，`scanState` 如实为 `cancelled` |
| `a strong noise exclusion does not wait for a complete scan` | 记录分类器刻意的不对称：精确名噪声规则在扫描未完成时也排除，而其它判定必须 `DEFER`。这是 Issue #131 拒绝"按扩展名排除"的直接依据 |
| `the verdict binding moves with metadata and never with hydration state` | 绑定输入是 id/revision/size/mtime/kind/identity/providerVersion/sha256，逐项变动都会移动摘要；`hydration_pending` 根本不是输入参数（`SourceReconciliation.swift:103, 173-176` 的 hydration-only 更新不写新 revision），所以占位符转实体不会使既有绑定失效 |

这些用例只说明"事实与判定层不会因 dataless 或读取失败而误排除"。真实 `materialDownload`、真实 `SF_DATALESS` 翻转、真实网络行为仍需 §5 的 Mac 矩阵。

## 5. Mac 小规模样本矩阵

准备：OneDrive 根下建 `FormaVerify/<随机后缀>/`，只放合成文件；每项之间用 Finder 或 `brctl download`/置灰操作切换云端状态；**每项都用新的空运行目录**（同一次 `--labels` 复核除外）。

| # | 场景 | 构造 | 预期 |
| --- | --- | --- | --- |
| 1 | dataless 文档 | 新建小文件 → 等同步完成 → 在 Finder 取消本地保留 | `INCLUDE`，`hydration_pending = true` |
| 2 | hydrated 文档 | 同文件 `brctl download` | 同一记录的判定与 #1 一致，`hydration_pending = false` |
| 3 | 离线 | 暂停 OneDrive 同步后扫描 | 可读到的记录仍在；若扫描未能完整结束，除精确名噪声规则外的判定必须转为 `DEFER`（`scan_incomplete`），不得留下 `EXCLUDE` |
| 4 | 挂起 | OneDrive 提示"需要更多空间/账户过期"期间扫描 | 不得出现 `EXCLUDE`；异常按 `DEFER`/`skipped` 计入守恒 |
| 5 | 权限失败 | 云根内不可读项（或以 APFS 夹具对照） | `scan_complete = false`；除精确名噪声规则外无 `EXCLUDE`（分类器里强噪声排除不等完整扫描，见 §4） |
| 6 | 符号链接 | 云根内指向本地 APFS 文件的链接 | 记录为 `entryState = symlink`、判定 `REVIEW`（无规则命中，非 `EXCLUDE`）；链接目标不得被下载 |
| 7 | 缓存标记 | 含可验证 `CACHEDIR.TAG` 的目录 | 标记读取按 §2；子项 `EXCLUDE` 需保护事实，否则 `REVIEW` |
| 8 | 应用包 / 空目录 | `.app` 与空目录 | 包内项按元数据判定；空目录不产记录 |

观察手段（均为只读）：
- 拉取：`log stream --predicate 'eventMessage CONTAINS "FileProvider" OR eventMessage CONTAINS "OneDrive"' --info`（运行前起，运行后停，日志留本机）；
- 打开的文件：扫描进程存活期间 `lsof -p <pid>`；`brctl` 与 Finder"取消本地保留"用于构造与复核状态；
- 网络：`nettop -p <pid>` 观察 Forma 进程；`nettop -p <onedrive pid>` 观察 OneDrive 进程。**归因规则**：`m11-real` 运行期间 Forma 自身无出网（§2），OneDrive agent 的流量属于云同步自身行为，不得记为"Forma 产生了网络请求"。禁止 MITM 代理、抓包载荷、上传任何真实内容。

### 5.1 hydration 观测判据（可证伪）

"没有触发物化"必须是一个能失败的主张，因此观测定义为：

| 观测 | 命令（只读） | 判据 |
| --- | --- | --- |
| dataless 标志 | `stat -f '%f %Sf' <path>`，扫描前后各一次 | 任何**业务文件**在扫描后从 `dataless` 变为实体，即 `FAIL`（内容被拉取） |
| 标记文件 | 同上，对象为祖先链上的 `CACHEDIR.TAG` 与 `.git` | 只允许这两个文件出现翻转；翻转必须记录，并归入 Issue #129 的"接受风险"决定 |
| 进程打开 | 扫描存活期间 `lsof -p <pid>` | 只应看到目录句柄与上述标记文件；出现业务文件即 `FAIL` |
| FileProvider 事件 | `log stream --predicate '…FileProvider…'` | 窗口内若出现由扫描 PID 触发的 `materialize` 类事件，记录为"发生了拉取" |
| 网络归因 | `nettop -p <pid>` | Forma 进程零出网；OneDrive agent 的流量不得记作 Forma 请求 |

**负对照**：对同一目录做一次不含标记文件的空跑时，任何 dataless 标志都不应变化；负对照失败说明观测手段本身不可信，先修手段再谈结论。

**中止条件**：任一业务文件出现 dataless → 实体翻转，立即停止该场景、保留日志、报告 `FAIL`，不得继续叠加样本，也不得为了"跑完矩阵"而忽略该结果。

以上观测都只用 `stat`/`lsof`/`log`/`nettop`，不需要打开业务正文，也不能在 DevBox 上执行。

## 6. 允许与禁止的主张

允许：

- "Forma 的第 4 级验收在 OneDrive FileProvider 上对目录树做了只读元数据分类；单次运行 3,357 条记录，全部探测无跳过。"
- "验收 CLI 不计算内容哈希、不调用 Provider、不读业务文件内容；为判定缓存/仓库事实，它最多读取祖先目录上的 `CACHEDIR.TAG`（≤1 KiB）与 `.git` 文件（≤4 KiB）。"
- "Level 4 的结论是范围受限的：排除侧已完成普查，保留侧仍是抽样。"

禁止（无新证据前一律不得写）：

- "Forma 不下载任何文件" / "不会产生数据流量"（§3 未测量，`NOT_VERIFIED`）；
- "OneDrive 已验证" / "hydration 不会发生"（子状态仍 `NOT_VERIFIED`）；
- "误排除率为 0%" / "保留集准确率 X%"（分母与抽样边界不符，见 Runbook §4.4）；
- "默认过滤可以开启"（关闭中，Issue #130/#131 未收口，I1 Slice 5 `NOT_AUTHORIZED`）。

## 7. 子状态改写的退出条件

`onedrive_fileprovider` 从 `NOT_VERIFIED` 改为 `VERIFIED — SCOPE LIMITED` 需要，且只需要：

1. 矩阵 1–8 中除"拉取测量"外每项都有 `--dry-run` 证据，运行目录已记录；
2. 一次针对 §3 的定向观察：构造 dataless 的 `CACHEDIR.TAG` / `.git`，记录 `log stream` 与 `lsof` 是否显示 FileProvider 读取（若显示，把"标记文件可能被拉取"写入 backlog 并新建/更新 Issue，不得静默）；
3. 结论以脱敏形式写入 `docs/M11-LEVEL4-REAL-RUN-RECORD.md`（或新的运行记录），列出通过/未通过/未验证；
4. 任何主张措辞变更走 `MACOS-VALIDATION-BACKLOG.md` 与 `ROADMAP.md`，不在代码注释里私自扩张。

第 2 项若 Owner 决定"允许极小标记文件被拉取"，记录为**接受的风险**；若决定不允许，则属策略语义变更，需要独立 PR 与独立评审（Issue #129），本轮不做。
