# R1 — macOS App Packaging (Batch 1)

状态：**开发用打包工程，非发行物**。

- 本轮产出：`FormaApp/Info.plist`、`FormaApp/Forma.entitlements`、`scripts/build_app.sh`、CI `macOS app package` job。
- 签名：**ad-hoc**（`codesign --sign -`），Hardened Runtime 已开启。
- **未做**：Developer ID 证书、`notarytool` 公证、staple、Gatekeeper 干净机验证、DMG、更新机制、App Store 打包。
- 基线：`dev` @ `a3a3cf7`（R1 Batch 1 授权，见 `docs/R1-READINESS.md`）。

## 1. Bundle 结构

```
Forma.app/
  Contents/
    Info.plist
    MacOS/Forma                 # SwiftPM 产物，原样拷入
    Resources/                  # 资源 bundle（若有）、AppIcon.icns（若存在）
    _CodeSignature/
```

| Info.plist 键 | 值 | 理由 |
| --- | --- | --- |
| `CFBundleIdentifier` | `io.github.skyline-gazer.forma` | Owner 候选值；与现有 OSLog subsystem 一致（§2） |
| `CFBundleExecutable` | `Forma` | 与 `swift build --product Forma` 的产物同名 |
| `CFBundleName` / `CFBundleDisplayName` | `Forma` | 菜单与 Finder 名称 |
| `CFBundlePackageType` | `APPL` | — |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` | 开发版本；发行前需与 Release Tag 绑定 |
| `LSMinimumSystemVersion` | `14.0` | 与 `Package.swift` 的 `.macOS(.v14)` 一致 |
| `LSApplicationCategoryType` | `public.app-category.productivity` | App Store 元数据兼容，当前不提交 |
| `NSPrincipalClass` | `NSApplication` | SwiftUI `App` 生命周期进入 AppKit 事件循环 |
| `CFBundleIconFile` | `AppIcon` | 资源入口已接线；图形资产未提供，缺省时使用系统通用图标 |
| `NSSupportsSuddenTermination` | `false` | 突然终止会跳过 `applicationWillTerminate`（以及任何 AppKit 终止回调），而退出时必须在其中取消任务并关闭 MCP 子进程（T04） |
| `NSSupportsAutomaticTermination` | `false` | 同上 |

## 2. Bundle identifier 兼容性报告

| 现有标识 | 位置 | 与候选值的关系 | 处置 |
| --- | --- | --- | --- |
| `io.github.skyline-gazer.forma` | `Sources/FormaCore/Diagnostics.swift` 的 `Logger(subsystem:)` | **完全相同** | 保留；打包后日志子系统与 bundle id 一致 |
| `com.skyline-gazer.forma.provider-api-key` | `Sources/FormaCore/Providers/ProviderKeyStore.swift` 的 `kSecAttrService` | 不同字符串 | **本轮不改**。Keychain service 是独立命名空间，不必等于 bundle id；但与 bundle id 的团队前缀不一致，若将来统一命名，已存条目会变成孤儿 |
| `com.devon-technologies.think.mcp-server` | B1 文档 | 第三方标识 | 不属于 Forma，不打包、不复制 |

结论：

1. **没有发现冲突**：仓库内不存在第二处 `CFBundleIdentifier`，也没有 `.xcodeproj` 的 `PRODUCT_BUNDLE_IDENTIFIER` 可以漂移。
2. **Keychain service 名与 bundle id 前缀不一致是已知差异**，不构成功能故障（service 名由 Forma 自定），但**改名必须先做迁移**：读旧 service → 写新 service → 删除旧条目，失败保留旧条目。R1 Batch 1 **不执行任何迁移**（授权明确禁止）。
3. 因此本轮不修改 `ProviderKeyStore` 中的字符串；该项作为 Batch 2 的独立任务，未获授权前保持原样。

## 3. Entitlements 与签名

- `FormaApp/Forma.entitlements` 为空字典，且是**有意**为空：Hardened Runtime 是签名选项，不是 entitlement；不开 App Sandbox（当前渠道为 Developer ID 方向）；不申请 Apple Events（禁止 AppleScript 通道）；不申请全盘访问（只读用户通过面板授权并保存为 security-scoped bookmark）。
- 签名命令：`codesign --force --options runtime --timestamp=none --entitlements … --sign - Forma.app`。
- 校验命令：`codesign --verify --strict --verbose=2`、`codesign -dv --verbose=4`、`plutil -lint`、`bundle id` 断言。

## 4. CI

新增 job `macOS app package`（macos-15 + Xcode 26.3）：

1. `sh scripts/build_app.sh` → 组装 + ad-hoc 签名 + 自检；
2. 上传 `build/Forma.app` 为构建产物 `Forma-app-adhoc`。

产物是**开发验证用**：ad-hoc 签名不能分发给其他机器，无法通过 Gatekeeper 的开发者身份校验。

## 5. 未验证项（不得视为发行就绪）

| 项 | 状态 |
| --- | --- |
| Developer ID 签名 | **NOT_VERIFIED**（无证书） |
| 公证与 staple | **NOT_VERIFIED**（`notarytool` 未运行） |
| 干净机安装与 Gatekeeper | **NOT_VERIFIED** |
| 公证后的 `.app` 内 `Process()` 拉起 DEVONthink MCP | **NOT_VERIFIED**（Hardened Runtime 下未实测） |
| 正式图标、DMG、更新机制 | 未开始 |
| App Sandbox / Mac App Store | 未授权、未验证（`docs/MACOS-VALIDATION-BACKLOG.md` M8） |
| 版本号与 Release Tag 绑定 | 未开始（发行阶段） |

只有在 Developer ID + 公证 + 干净机三项真实通过后，才可以讨论发行；本轮不宣称 `.app` 可发布。
