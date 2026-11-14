# R1 Batch 2A — Real macOS Acceptance（现场执行结果）

状态：**现场验证已在 macOS 执行**（2026-11-15）；**M01 / M02（除锁定态）/ M03 / M04 的主体已取得现场证据，其中发现 2 个阻断性打包缺陷与 2 个实现缺陷**；**M06 BLOCKED**（本机无 macOS 14.x 运行时）。

- 授权：Owner 2026-11-14 批准 R1 Batch 2A（仅无 DEVONthink 写入的现场验证）。
- 本轮未调用任何 DEVONthink 写工具；未修改生产库；未修改任何现有 Keychain 凭据；未做 Developer ID 签名与公证。
- 上一轮（2026-11-14）执行主机为 Linux，结论为 BLOCKED，原文见 §12；本文是同一授权的真实 macOS 执行结果。
- 证据原件仅保存在本机 `~/.forma/evidence/r1-batch2a/`；本文不含真实数据库 UUID、路径或业务数据。

## 0. 执行事实

| 项 | 值 |
| --- | --- |
| macOS | 27.0.1（26A434），arm64 |
| DEVONthink | 4.4.2（官方 MCP，stdio） |
| `dev` | `6642f16`（PR #90），CI run `43612484825` **success** |
| Batch 2A 工程 PR | #86（上一轮 BLOCKED 报告）· #87（T05）· #88（T06）· #89（T04）· #90（收尾文档）全部 merged |
| 被测 `.app` | CI 产物 `Forma-app-adhoc`（`gh run download`），非本地重新构建 |
| 启动前其他 Forma 实例 | 无 |
| 执行后进程残留 | 无（应用、其 MCP 子进程均已退出） |

`.app` 的既有静态结论（bundle id、结构、`LC_CODE_SIGNATURE`、链接依赖）本轮复核一致：`codesign --verify --strict` 通过、`Identifier=io.github.skyline-gazer.forma`、`flags=0x10002(adhoc,runtime)`、`LSMinimumSystemVersion=14.0`、entitlements 为空字典、Mach-O arm64。

## 1. Baseline：打包产物**无法启动**（FAIL）

| 检查 | 结果 |
| --- | --- |
| Bundle ID / 签名 / 结构 | **PASS**（同上，CI 产物本机复核） |
| 应用资源 | **FAIL**：产物内无 `Contents/Resources`（空目录被 artifact 上传丢弃），且**没有 `Forma_FormaCore.bundle`** |
| 产物落地 | 观察：`gh run download` 解出的根是 `Contents/`（artifact 压平了 bundle 目录），本机重建为 `Forma.app/` 后再验签 |
| 启动路径 | **FAIL** |
| 是否存在其他实例 | **PASS**（启动前后均无） |

实际执行：

```
FormaCore/resource_bundle_accessor.swift:12: Fatal error: could not load resource bundle:
  from …/Forma.app/Forma_FormaCore.bundle
  or  /Users/runner/work/Forma/Forma/FormaApp/.build/arm64-apple-macosx/release/Forma_FormaCore.bundle
```

崩溃报告（`~/Library/Logs/DiagnosticReports/Forma-2026-11-15-001131.ips`）faulting thread：

```
_assertionFailure(_:_:file:line:flags:)
closure #1 in variable initialization expression of static NSBundle.module
static MappingProfile.shipped()
WorkspaceModel.restore()
```

根因：`scripts/build_app.sh` 只拷贝 `Forma_FormaApp.bundle`（该 bundle 实际不存在），**从未拷贝 `Forma_FormaCore.bundle`**；而 SwiftPM 生成的 `Bundle.module` 访问器只查找 `Bundle.main.bundleURL/Forma_FormaCore.bundle`，即 `.app` 根目录。CI 的 `macOS app package` job 只做 `codesign --verify` 与结构断言，从不启动应用，因此该产物在 CI 上"打包成功"而本机必然崩溃。

**第二个问题（同一根因，必须一起修）**：把 `Forma_FormaCore.bundle`（含 GRDB/ZIPFoundation bundle）放进 `.app` **根目录**后应用可以启动，但 `codesign --verify --strict` 立刻报 `Forma.app: unsealed contents present in the bundle root` —— `.app` 根目录不是可封存（sealed）的位置。也就是说：满足运行期访问器的布局与满足 `codesign --strict` 的布局当前**互斥**，不是"漏拷一个文件"就能同时满足的。

本报告的 §3–§6 是在"拷贝资源 bundle 到 `.app` 根 + 重新 ad-hoc 签名"的补丁产物上完成的；所有 M04 结论都标注了这一点，打包基线仍是 **FAIL**。

已实测："把 bundle 放进 `Contents/Resources/`"**不能**解决问题——SwiftPM 生成的访问器只查 `.app` 根目录，实测仍以同一 `Fatal error` 退出。

建议修法（未在本轮实施，需单独工程 PR）：资源 bundle 放到 `Contents/Resources/` 以满足 `codesign --strict`，同时让应用侧按 `Bundle.main.resourceURL` 解析（或为 `Bundle.module` 增加 `.app` 变体回退）；`build_app.sh` 显式拷贝 `Forma_FormaCore.bundle`；CI 增加一次"启动后 3 秒仍存活"的冒烟，避免再次出现"打包成功但无法启动"。

## 2. M01 — Bookmark（现场通过，1 项分类缺陷）

合成来源目录（`m01/…`，3 个文件；`m01b/…`，1 个文件），新建 workspace；所有步骤均为真实 `Security` 书签 + 真实文件系统。

| 场景 | 观察 | 判定 |
| --- | --- | --- |
| 首次授权（API 路径）+ 正常扫描 | `register` 成功（`security_scoped=1`），扫描 `complete`，3 条 entry 全 `present` | PASS |
| 首次授权（应用内 `NSOpenPanel` 路径） | 未被验证：本轮授权通过 CLI 夹具走同一 `SourceWorkspace.register`，未在 GUI 面板中选目录 | NOT_VERIFIED |
| 权限失效（`chmod 000`） | 扫描 `incomplete`，issue = `unreadable`，`missing` 计数 **0**，历史 entry ID 全部保留 | PASS |
| 扫描 incomplete 时历史不被标记 missing | 同上（`listing.state=incomplete`，`missing=0`） | PASS |
| 恢复权限 + 重新授权 | 可用性 `accessible`；`reauthorize` 同一目录 → `updated(accessible)`；重扫 `complete`、ID 稳定 | PASS |
| 来源身份变化时拒绝静默复用 | 用**另一个目录**重新授权 → `identityMismatch`，未写入任何东西 | PASS |
| 目录被移走 | 可用性 `bookmark_stale`，`needsReauthorization=true`；历史 `missing=0` | PASS |
| 同路径换成另一个目录（新 inode） | 可用性 `identity_changed`；扫描返回 `incomplete` + `authorization` issue，历史 `missing=0`；`reauthorize` → `identityMismatch` | PASS |
| 目录被删除 | 可用性 `bookmark_stale`（而非 `missing`） | **FAIL（分类缺陷）** |
| 外部卷 / iCloud | 无隔离夹具，按授权不得用真实业务目录替代 | BLOCKED |

缺陷证据：对**已删除**目录解析书签时，普通书签抛 `NSCocoaErrorDomain 4`（`NSFileNoSuchFileError`），而实际存储的 **security-scoped** 书签抛 `NSCocoaErrorDomain 259`（`NSFileReadUnknownError`）。`SourceAvailability.classify(_:)` 只把 code 4 映射为 `.missing`，259 落入 `default` → `.bookmarkStale`。因此"文件夹已经不存在"会被 UI 说成"需要重新授权"，与 `SourceRootAvailability` 的注释契约（"a bookmark can go stale because the folder was deleted, and 'needs reauthorization' would be the wrong thing"）相反。

建议修法（未实施）：解析失败后对 `last_path` 做一次 `stat`；`ENOENT` → `.missing`，存在但身份不可证 → `.unavailable`，绝不因为"读不到属性"就把未知当 missing。

## 3. M02 — Keychain（生命周期通过；可访问性回读 FAIL；锁定态 NOT_VERIFIED）

独立测试 service `io.github.skyline-gazer.forma.r1-batch2a`（及其 `.legacy` / `.alt`），未触碰 `com.skyline-gazer.forma.provider-api-key`。

| 场景 | 观察 | 判定 |
| --- | --- | --- |
| 添加 + 读取 | `save` → `load` 返回同一密钥 | PASS |
| 更新（`save` 重复项）/ 轮换 | 值被替换；对不存在项 `rotate` → `credentialMissing` | PASS |
| 删除（幂等） | 连续 `delete` 两次均成功，`load` → `nil` | PASS |
| 迁移（copy + verify，legacy 保留） | `migrated([openAI])`；新 service 有值，legacy 仍在 | PASS |
| 回滚迁移（只删本 service） | `rolledBack([openAI])`；legacy 仍在 | PASS |
| 迁移计划语义 | `noRenameConfigured` / `ready` 两态正确 | PASS |
| 访问性属性回读 | 对**存在**的项，`accessibility(for:)` 返回 `nil`（`.whenUnlockedThisDeviceOnly` 与 `.afterFirstUnlockThisDeviceOnly` 都一样） | **FAIL** |
| 锁定状态错误处理 | 未能可靠制造；见下 | NOT_VERIFIED |
| GUI 提示 | 未出现任何 Keychain 提示（因为锁定态未触发） | NOT_VERIFIED |

可访问性缺陷证据：直接 `SecItemCopyMatching(kSecReturnAttributes)` 返回的键只有 `acct / cdat / class / labl / mdat / svce`（加 `kSecReturnData` 亦无变化），**不含 `pdmn`**；`security find-generic-password -g` 同样不输出该属性。因此在本机 macOS 27 上无法区分"项不存在"与"项存在但属性不可读"，方法契约（`nil` 仅表示没有项）不成立。修法需评估替代读取路径（例如显式 `kSecUseDataProtectionKeychain` 组合或对创建路径做显式自检），不应默默改成"回读不到就当作默认值"。

锁定态：另建临时文件 keychain（`security create-keychain`）、写入同名 service 项、把临时 keychain 置于用户搜索列表首位、`security lock-keychain` 后调用 `load`。A/B 结果：**解锁与锁定读取都返回 `nil`（item not found）**——`SecItem*` 在本机走 data-protection keychain，根本看不到文件 keychain 里的项，所以 `errSecInteractionNotAllowed` 分支没有被走到。测试后搜索列表已恢复为仅 login keychain，临时 keychain 已删除，测试项在 `m02` 收尾时已删除；`com.skyline-gazer.forma.provider-api-key` 前后均为 absent。

## 4. M03 — MCP Process（全部 PASS）

全部通过随仓库发布的 `DEVONthinkReadOnlyClient`（真实 `MCPStdio` + 连接监督器）执行，只用只读工具。

| 检查 | 结果 |
| --- | --- |
| `initialize` | protocol `2025-06-18`，server `devonthink-mcp 1.0.0` |
| `tools/list` | 62 个工具，1 页；只读白名单 8 个；`hasRecordParents=true` |
| Schema digest 复核 | **62/62 与 I1-B1 `client-digests.json` 完全一致**（`inputSchemaSHA256` 逐项相等）→ schema 未变 |
| 只读连接建立 | `get_databases` 命中沙盒库（库名 `Forma_I1B2_Sandbox`，root group 与库 UUID 一致） |
| 主动关闭连接 | `close()` 后子进程退出（exit code 0） |
| 重新建立读连接 | 新子进程，`tools/list` 62 |
| 双连接并存 | 两个客户端同时 `initialize` + `tools/list` 均成功 |
| 终止本次自己的 MCP 子进程 | 客户端观察到 `disconnected`；随后重连成功 |
| 写工具调用 | **0** |

## 5. M04 — App Lifecycle（GUI 主体通过；两处受限）

GUI 证据来自 Accessibility 树文本转储（`ax-empty.txt`、`ax-pending.txt`），不是截图。

| 场景 | 观察 | 判定 |
| --- | --- | --- |
| 正常启动 | 补丁产物可启动并稳定存活；窗口 "source" 出现 | PASS（**基于补丁产物**；原 CI 产物见 §1 FAIL） |
| Workspace 加载 | 空库时显示 "Choose a source" / "Add a local or OneDrive folder to scan its files." | PASS |
| 恢复状态展示 | 注入合成 ledger（`phase=verify_required`）后出现横幅："Interrupted import operations" · "1 outcome unknown" · 说明文字（"…stay VERIFY_REQUIRED and are never retried automatically."） | PASS |
| 未确认读范围时明确拒绝 | 横幅显示 `no_authorized_scope` 的解释；"Recheck read-only" 不可用 | PASS |
| 无效读范围被拒绝 | 空输入点确认 → 红色提示 "Enter a database UUID, a name and at least one group component."，sheet 不关闭；横幅 reason = `invalid_scope` | PASS |
| 授权 Sandbox 只读范围后正确回查 | **GUI 文本输入无法驱动**：AX `set value` / 粘贴后字段显示正确，但 SwiftUI 绑定未接受，点确认仍报 `invalid_scope` | **NOT_VERIFIED（GUI 路径）** |
| 同一路径的库级现场验证 | 用应用自身的 `DEVONthinkReadOnlyClient → DEVONthinkImportReadAdapter → ImportRecoveryCoordinator`：正确摘要 → `verified / readback_matches`；故意写错摘要 → `differs / target_sha_mismatch`；范围外库（不确认该库）→ `outsideScope`，`readAttempted=false`；ledger 保持 `verify_required`、attempts 0 | PASS（库级） |
| 正常退出 | `⌘Q` 退出，进程结束，**无遗留 MCP 子进程** | PASS |
| 重新启动 + 恢复未决状态 | 同一横幅、同一 `1 outcome unknown`；读范围不持久（session-only，符合设计） | PASS |
| 不自动重试 Import | 两次启动后 `import_operations.phase` 仍为 `verify_required`，`import_attempts` 仍为 0，应用启动期间**未启动**任何 DEVONthink MCP 子进程 | PASS |
| GUI 截图 | `screencapture` 被系统拒绝（无屏幕录制授权） | BLOCKED（以 AX 文本代替） |

关于"未决 Intent 的制造"：只写入了**合成** ledger 行（`run` + `operation`，`phase=verify_required`、目标为沙盒库与 `Forma_I1B2/r1`、目标记录为 B2 现存合成记录之一），使用仓库自身 `ImportLedger` API 生成，未创建任何 DEVONthink 记录。应用数据库在测试前备份（`m04/app-workspace-before.sqlite`），测试后已还原（`scopes=0`、`import_operations=0`）。侧栏把夹具来源标为 "Access needs renewing"，属于"书签由另一个进程创建"的预期结果，不是产品缺陷。

## 6. M06 — macOS 14.x

**BLOCKED**。本机 macOS 27.0.1；Parallels 仅有 Windows 11 虚拟机，无 macOS 14.x 运行时或设备。未用"在 macOS 27 上编译通过"代替 14.x 运行时验收。

## 7. DEVONthink 写调用计数

**0**。本轮所有 DEVONthink 交互均为只读工具：`get_databases`、`get_record_properties`、`get_record_children`、`get_record_parents`、`get_imported_record_path`（以及 `tools/list`）。未出现 `import_file` / `create_group_path` / `set_record_custom_metadata` / `move_record` / `trash_record` 等写工具调用；未读取生产库；沙盒对象未增删改。

## 8. 状态汇总

| 项 | 状态 |
| --- | --- |
| Baseline 静态验收（bundle id / 签名 / 结构 / 依赖） | PASS |
| Baseline 应用资源（SwiftPM resource bundle） | **FAIL**（缺 `Forma_FormaCore.bundle`） |
| Baseline 启动路径 | **FAIL**（资源 bundle 缺失；修法见 §1） |
| M01 书签授权 / 扫描 / 撤销 / 重授权 / 身份校验 | PASS（授权经 API 夹具；GUI 面板选目录 NOT_VERIFIED） |
| M01 删除根目录的分类（`missing` vs `bookmark_stale`） | **FAIL** |
| M01 外部卷 / iCloud | BLOCKED |
| M02 添加 / 读取 / 更新 / 轮换 / 删除 / 迁移 / 回滚 | PASS |
| M02 访问性属性回读 | **FAIL** |
| M02 锁定态与 GUI 提示 | NOT_VERIFIED |
| M03 initialize / tools / digest / 关闭 / 重连 / 并发 / 子进程终止 | PASS |
| M04 启动 / 加载 / 恢复展示 / 拒绝 / 退出 / 重启 / 不自动重试 | PASS（补丁产物） |
| M04 授权范围后的 GUI 回查 | NOT_VERIFIED（AX 文本输入不可驱动）；库级等价路径 PASS |
| M04 截图 | BLOCKED |
| M06 macOS 14.x | BLOCKED |
| DEVONthink 写调用 | 0 |

## 9. 只由 CI 证明、未在本机证明的部分

- `codesign --verify --strict` 与结构断言：CI job 通过，本机复核亦通过（但见 §1 的启动缺陷）。
- Developer ID 签名、公证、staple、干净机 Gatekeeper、DMG、更新机制：**NOT_VERIFIED**，未授权。
- FormaCore 全量单元测试（550 用例）：CI 通过，本轮未重跑。

## 10. 结论

- **Read-only Integration（R1 Batch 2A 范围）：Verified with defects** —— M01/M02/M03/M04 的主路径已在真实 macOS 上取得证据，同时确认 4 个缺陷（2 个打包阻断、1 个可用性分类、1 个 Keychain 属性回读）。
- **打包/启动**：当前 CI 产物在本机**无法启动**，因此 R1 的"打包基线"不能算通过；这必须先修，否则 Batch 2B 的 GUI 现场验证没有可信起点。
- **未执行**：M05（真实写入）、R01–R03（签名/公证/干净机）。本轮**不宣布** Release Ready。

## 11. 申请 R1 Batch 2B 前置条件

1. 修复 §1 的资源 bundle 布局与拷贝，使产物同时满足"能启动"与"`codesign --strict` 通过"，并在 CI 增加启动冒烟。
2. 修复 §2 的删除根目录分类（`.missing` 与 `.bookmark_stale` 可区分）。
3. 决定 §3 的访问性回读方案（修实现或明确改为不可回读并调整契约/测试）。
4. 补齐 M04 的 GUI 输入验证手段（可用 UI 测试或显式调试入口），因为 Accessibility 文本注入不能驱动当前 SwiftUI 绑定。
5. 提供 macOS 14.x 设备或虚拟机以完成 M06。

## 12. 上一轮（2026-11-14）执行记录

同一授权在 Linux DevBox 上执行，M01/M02/M03/M04/M06 全部 BLOCKED（无 Darwin、无 Security/AppKit、无 DEVONthink、无 `codesign`），仅完成 `.app` 静态验收。该轮的阻塞证据保留在对应 PR #86 的正文中，结论已被本文取代。

## 13. 证据索引（本机）

| 文件 | 内容 |
| --- | --- |
| `m01-bookmark.json` / `m01b-identity.json` | 书签授权、incomplete、重授权、身份变化、删除/移动 |
| `m02-keychain.txt` / `m02-keychain.json` | Keychain 生命周期与可访问性回读 |
| `m03-client.json` | 客户端 initialize / tools / digest / 重连 / 并发 / 子进程终止 |
| `m03-mcp.json` / `m03-schema.json` | 原生 JSON-RPC 探索与 schema 对照 |
| `m04-review.txt` | 库级只读回查（verified / mismatch / outsideScope） |
| `ax-empty.txt` / `ax-pending.txt` | GUI 可访问性树（空库、未决恢复） |
| `m04/workspace.sqlite`、`m04/app-workspace-before.sqlite` | 合成 ledger 夹具与测试前的应用库备份 |
| `app/` | CI 产物重建的 `.app`（含补丁 bundle） |
