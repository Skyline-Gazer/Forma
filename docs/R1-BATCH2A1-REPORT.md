# R1 Batch 2A.1 — Engineering Remediation Report

状态：**Engineering Remediation Complete / Pending Remaining Real macOS Acceptance**。

本轮只做工程修复、合成测试与 macOS CI；未调用任何 DEVONthink 工具（读写都没有），未触碰生产库或既有 Keychain 凭据，未做 Developer ID 签名、公证或发行，`main` / ADS pin / 冻结 SPEC 未改。

- 基线：`dev` @ `d0f6fae`（PR #91 合并，CI run `43616258294` success）。
- 现场依据：`docs/R1-BATCH2A-REPORT.md`（2026-11-15 macOS 实测，4 个缺陷）。本文件**不修改**该报告的现场事实，只记录修复与新的证据。

## 1. 修复清单

| PR | 缺陷 | 修复 | Merge SHA |
| --- | --- | --- | --- |
| #92 | 资源 bundle 未打包；启动 `fatalError`；根目录布局破坏 `codesign --strict` | `FormaResourceBundle` 自有解析器；`Contents/Resources` 布局；脚本断言；CI 启动冒烟 + 资源可读检查；artifact 改 tar | `5f7655b` |
| #93 | 删除 security-scoped 根目录被报为 `bookmark_stale`（Cocoa 259） | 解析失败先探测 `last_path`：ENOENT→missing，EACCES→denied，存在且同身份→stale，异身份→identityChanged，无法分类→unavailable | `fcac126` |
| #94 | `accessibility(for:)` 用 `nil` 同时表示"没有项"与"不可观察" | 三态契约 `missing / presentUnobservable / verified(…)`；`DataProtectionKeychainProbe` 实测替代推断 | `745e821` |
| #95 | AX 文本注入不能驱动 SwiftUI 绑定，表单逻辑无测试 | 校验抽到 `RecoveryScopeDraft`（6 例测试）+ Sheet 绑定；评估文档与人工验收步骤 | `96c51bc` |

对应 CI（PR HEAD）：#92 `43622919150` · #93 `43620948962` · #94 `43621279017` · #95 `43621738960`，均 success。

## 2. 打包与启动证据（P0）

同一份 **未经人工补丁** 的 CI artifact（`Forma-app-adhoc.tar.gz`）在 `launch-smoke` job 中：

| 检查 | 结果 |
| --- | --- |
| 解压根 | `Forma.app/`（tar 保留可执行位；zip 会丢权限，已改为 tar） |
| 结构 + 严格验签 | `codesign --verify --strict` 通过；`Identifier=io.github.skyline-gazer.forma`；`flags=0x10002(adhoc,runtime)` |
| 资源可读 | `FormaResourceCheck`：`bundle: …/Contents/Resources/Forma_FormaCore.bundle`，`missing: none`，`unreadable: none`，`result: COMPLETE` |
| 启动 | `pid 3597`，`alive after 5s: yes`，`result: PASS` |
| 清理 | 应用与其子进程在观察后终止；job 内无残留 |

CI 提供 Aqua 会话（`launchctl managername` = Aqua）；若某环境没有，`smoke_app.sh` 返回退出码 3 并明确"不作通过声明"，不制造绿色。

脚本：`scripts/build_app.sh`（构建→组装→资源断言→签名→严格验签）、`scripts/verify_app_bundle.sh`、`scripts/smoke_app.sh`、`Sources/FormaResourceCheck`。

## 3. Bookmark 分类回归

`SourceRootAvailability` 现在：解析失败时**先问文件系统**，再回落到错误码；`unknown` 一律 `.unavailable`，既不冒充 missing，也不默认 stale。

回归测试 12 例（`SourceAvailabilityClassificationTests`）覆盖：259+ENOENT→`missing`（缺陷本体）、同目录→`stale`、异目录→`identityChanged`、EACCES→`denied`、探针不可分类→`unavailable`、`noSuchFile`/`noPermission` 在探针失效时仍分别给出 missing/denied、resolved 四态、Cocoa/POSIX/未知域映射。

现场补充（仍待真实 macOS 复测）：删除 security-scoped 根目录后 UI 应显示 "Folder not found"，且历史条目保持 `present`。

## 4. Keychain 契约与真实回读

| 状态 | 含义 |
| --- | --- |
| `.missing` | 没有该 service/account 的项 |
| `.presentUnobservable` | 项存在，但该 keychain 不返回 `kSecAttrAccessible`（现场 macOS 27 的实测行为） |
| `.verified(KeychainAccessibility)` | 属性被返回且可识别 |

- 未降低安全策略：新条目仍请求 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。
- `DataProtectionKeychainProbe` 在 CI 上实测 `kSecUseDataProtectionKeychain`：add→read→attributes→delete 全部用一次性合成 service；`usable` 只在往返成功后为真，`accessibilityVisible` 单独报告（CI 日志可见）。这替代了"按文档推断"。
- 真实 login keychain 测试断言：不得为 `.missing`；若 `.verified` 必须是 device-only。
- 未触碰 `com.skyline-gazer.forma.provider-api-key`；未迁移。

## 5. GUI 验证覆盖与限制

- 已覆盖（自动）：`RecoveryScopeDraft` 的 6 种决策——空表单/缺字段、非法 UUID、合法规范化（大写 UUID、去空白、组路径切分）、单段组路径、重复确认条款一致、reset。
- 未覆盖（自动）：真实键入事件。现场已证伪 AX `setValue` 不驱动 SwiftUI 绑定；XCUITest 需 Xcode 工程；CGEvent/System Events 需 TCC 辅助功能授权与可交互会话，hosted CI 无法授权。
- 人工验收：`docs/R1-GUI-VERIFICATION.md` §4 的 8 步（有效/无效/取消/重复确认/回查结果/写调用计数），状态 **NOT_VERIFIED**，直至有人在真实 Mac 上执行并记录。

## 6. macOS 14.x

- `Package.swift` 与 `FormaApp/Package.swift` 均声明 `.macOS(.v14)`；本轮用到的 API（`ContentUnavailableView`、`NavigationSplitView`、`Table`、`Settings`、`defaultSize`、`URL.applicationSupportDirectory`、`NSOpenPanel`、`SecItem*`、`kSecUseDataProtectionKeychain`）均在 macOS 14 及以下可用，未发现高于 14 的 API。
- **无 macOS 14 运行时**：M06 仍 **BLOCKED**。编译目标与 API 审计不等于实机运行。

## 7. DEVONthink 写工具调用计数

**0**。本轮未连接 DEVONthink，未调用 `import_file` / `create_group_path` / `set_record_custom_metadata`，未读取生产库，未改沙盒对象。此前 Batch 2A 现场轮同样为 0（见 `docs/R1-BATCH2A-REPORT.md` §7）。

## 8. 未解决阻断项

| 项 | 状态 | 需要 |
| --- | --- | --- |
| 修复后产物的真实 macOS 启动/资源加载复测 | **待现场** | 用本轮 CI tar 在 macOS 上重跑 `verify_app_bundle.sh` + `smoke_app.sh` |
| 删除 security-scoped 根的 UI 现场复测 | **待现场** | 真实 `NSOpenPanel` 授权目录 |
| Keychain 锁定态（`errSecInteractionNotAllowed`） | **NOT_VERIFIED** | 能在文件型 keychain 中制造并读取项的环境 |
| GUI 真实键入（有效/无效/取消/重复） | **NOT_VERIFIED** | 有人值守的 Mac + 辅助功能授权 |
| macOS 14.x 运行时 | **BLOCKED** | 14.x 设备或虚拟机 |
| 外部卷 / iCloud 书签 | **BLOCKED** | 隔离夹具 |
| Developer ID / 公证 / 干净机 | 未授权 | Owner 授权 + 证书 |

## 9. 是否可申请 Batch 2B

建议：**先完成 §8 的"待现场"三项**（同一台 Mac 上即可，无需新代码），再由 Owner 判断。本轮工程缺陷已修复且 CI 有启动证据，但真实 macOS 对**修复后产物**的复测尚未发生；在它发生前，不应把 Batch 2B 的 GUI 现场验收建立在未复测的基线上。

## 10. 变更文件索引

- `Sources/FormaCore/Support/FormaResourceBundle.swift`、`ShippedResourceProbe.swift`
- `Sources/FormaCore/Sources/SourceAvailability.swift`（分类重构）
- `Sources/FormaCore/Providers/ProviderKeyStore.swift`（三态契约 + DP 探测）
- `Sources/FormaCore/Import/RecoveryScopeDraft.swift`
- `Sources/FormaResourceCheck/main.swift`、`Package.swift`
- `scripts/build_app.sh`、`scripts/verify_app_bundle.sh`、`scripts/smoke_app.sh`
- `.github/workflows/ci.yml`、`docs/R1-APP-PACKAGING.md`、`docs/R1-GUI-VERIFICATION.md`
- 测试：`ResourceBundleTests`（5）、`SourceAvailabilityClassificationTests`（12）、`KeychainCredentialStoreTests`（15）、`RecoveryScopeDraftTests`（6）
