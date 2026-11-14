# R1 — macOS App Packaging

状态：**开发用打包工程，非发行物**；**Batch 2A.1 已修复资源 bundle 布局与启动缺陷**。

- 产出：`FormaApp/Info.plist`、`FormaApp/Forma.entitlements`、`scripts/build_app.sh`、`scripts/verify_app_bundle.sh`、`scripts/smoke_app.sh`，CI jobs `macOS app package` + `macOS app launch smoke`。
- 签名：**ad-hoc**（`codesign --sign -`），Hardened Runtime 已开启。
- **未做**：Developer ID 证书、`notarytool` 公证、staple、Gatekeeper 干净机验证、DMG、更新机制、App Store 打包。

## 0. 现场缺陷与修复（2026-11-15）

Batch 2A 在真实 macOS 上发现 CI 产物**无法启动**：

```
Fatal error: could not load resource bundle:
  from …/Forma.app/Forma_FormaCore.bundle
  or  …/FormaApp/.build/…/release/Forma_FormaCore.bundle
```

根因有两个，必须一起修：

1. `build_app.sh` 拷贝的是从未存在的 `Forma_FormaApp.bundle`，**从未拷贝** `Forma_FormaCore.bundle`；
2. SwiftPM 生成的 `Bundle.module` 访问器只查 **`.app` 根目录**与编译机路径。根目录不是可封存位置，`codesign --verify --strict` 会报 `unsealed contents present in the bundle root`；放进 `Contents/Resources` 又找不到。所以"能启动"与"可签名"当时互斥。

修复方式（不修改 SwiftPM 生成的 accessor）：

| 改动 | 作用 |
| --- | --- |
| `Sources/FormaCore/Support/FormaResourceBundle.swift` | 应用自己解析资源 bundle：`Bundle.main.resourceURL` → 可执行文件目录 → `.app` 根（兼容旧布局）→ `Bundle(for:)` 路径；找不到返回 `nil` |
| 5 处 `Bundle.module.url(...)` 改为 `FormaResourceBundle.url(...)` | 缺资源时抛 `FormaError.unavailable`（可诊断），而不是 `fatalError` 崩溃 |
| `build_app.sh` 拷贝 `$BIN/*.bundle` 到 `Contents/Resources/`，`Forma_FormaCore.bundle` 缺失即失败 | 资源随包，且位于可封存位置 |
| 脚本断言必需资源存在、根目录无 `.bundle` | 不允许"打包成功但缺资源" |
| CI `launch-smoke` job | 下载**发布的 artifact**，复验结构+严格签名，真正启动并观察存活 |

## 1. Bundle 结构

```
Forma.app/
  Contents/
    Info.plist
    MacOS/Forma
    Resources/
      Forma_FormaCore.bundle/
        Contents/Info.plist
        Contents/Resources/            # Profiles、Schemas、CasePack、Eligibility 政策
      AppIcon.icns                     # 可选，目前未提供
    _CodeSignature/
```

`.app` 根目录**不得**出现任何 `.bundle`：那是未封存内容，`codesign --strict` 会拒绝。

### 1.1 资源解析顺序

`FormaResourceBundle` 依次检查：

1. `Bundle.main.resourceURL` → `Contents/Resources`（标准位置，签名安全）
2. `Bundle.main.executableURL` 所在目录（开发运行）
3. `Bundle.main.bundleURL`（旧布局/根目录，仅兼容，不用于产物）
4. `Bundle(for: BundleToken.self).resourceURL`、`.bundleURL`（测试与框架宿主）

不包含 `.build` 编译机路径：发行产物不能依赖构建机。解析结果缓存一次；任一 loader 在 `nil` 时抛 `FormaError.unavailable`。

## 2. Info.plist

| 键 | 值 | 理由 |
| --- | --- | --- |
| `CFBundleIdentifier` | `io.github.skyline-gazer.forma` | 与 OSLog subsystem 一致 |
| `CFBundleExecutable` | `Forma` | SwiftPM 产物名 |
| `CFBundleName` / `CFBundleDisplayName` | `Forma` | 菜单与 Finder |
| `CFBundlePackageType` | `APPL` | — |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` | 开发版本 |
| `LSMinimumSystemVersion` | `14.0` | 与 `Package.swift` 一致 |
| `LSApplicationCategoryType` | `public.app-category.productivity` | 发行元数据预留 |
| `NSPrincipalClass` | `NSApplication` | SwiftUI `App` 进入 AppKit 事件循环 |
| `CFBundleIconFile` | `AppIcon` | 入口已接线；资产未提供 |
| `NSSupportsSuddenTermination` / `NSSupportsAutomaticTermination` | `false` | 两者都会跳过 `applicationWillTerminate`，而退出时必须在其中取消任务并关闭 MCP 子进程 |

## 3. Bundle identifier 兼容性

| 现有标识 | 位置 | 关系 | 处置 |
| --- | --- | --- | --- |
| `io.github.skyline-gazer.forma` | `Diagnostics.swift` OSLog subsystem | 完全相同 | 保留 |
| `com.skyline-gazer.forma.provider-api-key` | `ProviderKeyStore.swift` Keychain service | 不同前缀 | **不改名**；改名会让已存密钥成孤儿，必须先迁移 |
| `com.devon-technologies.think.mcp-server` | 第三方 | 非 Forma | 不打包 |

## 4. Entitlements 与签名

`FormaApp/Forma.entitlements` 为空字典，且有意为空：Hardened Runtime 是签名选项；不开沙盒（Developer ID 方向）；不申请 Apple Events（禁止 AppleScript 通道）；不申请全盘访问（只用用户授权目录的 security-scoped bookmark）。

```
codesign --force --options runtime --timestamp=none \
    --entitlements FormaApp/Forma.entitlements --sign - Forma.app
codesign --verify --strict --verbose=2 Forma.app
```

## 5. CI

| job | 内容 |
| --- | --- |
| `macOS app package` | `build_app.sh`（构建→组装→资源断言→ad-hoc 签名→严格验签）→ `verify_app_bundle.sh` → 打包 `Forma-app-adhoc.tar.gz`（内含 `Forma.app/`）→ 上传 |
| `macOS app launch smoke` | 下载同一 tar → 解压 → 断言 `Forma.app` 与可执行位 → 复验结构与严格签名 → `FormaResourceCheck`（按应用同一路径打开并解码 6 个必需资源）→ `smoke_app.sh`：启动、存活 5 s、收集崩溃日志、清理进程与子进程 |

`smoke_app.sh` 的退出码：`0` 通过；`1` 失败（未启动或观察期内退出）；`3` 当前会话没有 Aqua（GUI 不可用），此时**不宣称启动通过**，由运行者记录环境限制。

为什么是 tar 而不是目录/zip：`upload-artifact` 的 zip 不保留 POSIX 权限，下载后的 `Contents/MacOS/Forma` 失去可执行位，无法启动；tar 保留权限，且解压根就是 `Forma.app/`。冒烟 job 因此运行的是**与上传内容一致**的产物，而不是事后修补过的副本。

## 6. 未验证项（不得视为发行就绪）

| 项 | 状态 |
| --- | --- |
| 从 CI artifact 启动（本机 macOS） | 由 `launch-smoke` job 证明；**macOS 27 现场仍未对修复后产物复测** |
| Developer ID 签名 | NOT_VERIFIED（无证书） |
| 公证与 staple | NOT_VERIFIED |
| 干净机安装与 Gatekeeper | NOT_VERIFIED |
| 公证后 `.app` 内 `Process()` 拉起 DEVONthink MCP | NOT_VERIFIED |
| 正式图标、DMG、更新机制 | 未开始 |
| App Sandbox / Mac App Store | 未授权、未验证（`MACOS-VALIDATION-BACKLOG.md` M8） |
| macOS 14.x 运行时 | BLOCKED（无设备） |

只有 Developer ID + 公证 + 干净机三项真实通过后，才可以讨论发行；当前 `.app` 是开发验证产物。
