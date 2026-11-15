# R1 Batch 2A.2 — 真实 macOS 验收（执行结果）

状态：**打包类项目（1–2）由 macOS CI 证明；交互类项目（3–7）BLOCKED —— 执行会话主机不是 macOS**。

- 基线：`dev` @ `dc510e1`，CI run `43625876979` success；`main` `38d4553` 未动。
- 本轮未调用任何 DEVONthink 工具（读写都没有），未触碰生产库与既有 Keychain 凭据，未签名/公证/发行，未进入 M05/R01–R03。
- **未对产物做任何修补**：使用的是该 CI run 上传的 `Forma-app-adhoc.tar.gz` 原件。

## 0. 主机事实

| 检查 | 结果 |
| --- | --- |
| 内核 | `Linux 7.0.0-42-generic x86_64` |
| `sw_vers` / `security` / `codesign` / `plutil` / `osascript` / `swift` | 全部不存在 |
| `/Applications/DEVONthink.app` | 不存在 |
| 可交互 macOS 会话 | 无（已配置的 SSH 主机在早前轮次认证失败，本轮未重试） |

因此 NSOpenPanel、删除根目录后的 UI、真实键盘输入、Recovery 回查、退出/重启与子进程观察**无法在本机执行**。

## 1. 原始 CI 产物核验

| 项 | 值 |
| --- | --- |
| 来源 | run `43625876979`，job `macOS app package`，artifact `Forma-app-adhoc` |
| 文件 | `Forma-app-adhoc.tar.gz`，SHA-256 `e3aae74f02e399c430c2e0b23768d9a6704aaccc455fd4fee53b45d934503a78` |
| 归档结构 | 24 个条目，根为 `Forma.app/`（无 `__MACOSX`、无裸 `Contents/`） |
| 可执行文件 | Mach-O 64-bit arm64，16,591,328 bytes，权限保留 |
| 链接库 | 23 个，全部为 `/usr/lib` 或 `/System/Library`；未链接或打包 DEVONthink 二进制 |
| `LC_CODE_SIGNATURE` | 存在（dataoff 16443392 / size 147936） |
| `Info.plist` | `CFBundleIdentifier=io.github.skyline-gazer.forma`、`CFBundleExecutable=Forma`、`LSMinimumSystemVersion=14.0`、版本 `0.1.0 (1)` |
| 资源 bundle | `Contents/Resources/Forma_FormaCore.bundle`（shallow：文件直接位于 bundle 根），10 个 JSON，包含全部 6 个必需文件 |

## 2. 逐项结果

| # | 项目 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 原始 `.app` 严格验签与资源完整性 | **PASS（macOS CI）** | job `macOS app launch smoke`：`codesign --verify --strict` 通过、`Identifier`、`flags=0x10002(adhoc,runtime)`；`FormaResourceCheck`：`missing: none`、`unreadable: none`、`COMPLETE`；本地静态复核见 §1 |
| 2 | 原始 `.app` 真实启动与稳定性 | **PASS（macOS CI）** | 同一 job：`open -n` 后 `pid` 存在、`alive after 5s: yes`、`PASS`；启动前后无其他 Forma 实例，结束后无残留子进程 |
| 3 | NSOpenPanel 授权的合成来源目录 | **BLOCKED** | 需可交互 macOS 会话；步骤见 `docs/R1-GUI-VERIFICATION.md` §4 与 `docs/R1-BATCH2A-REPORT.md` §12.2 |
| 4 | 删除根目录后的 `.missing` 分类与历史保留 | **BLOCKED** | 同上；分类逻辑本身已有 12 例回归（`SourceAvailabilityClassificationTests`），但 UI 现场未复测 |
| 5 | 真实键盘输入下的 Read Scope 表单 | **BLOCKED** | 需辅助功能授权与有人值守会话；AX 文本注入已证伪（#95），校验逻辑有 6 例测试 |
| 6 | 仅已批准隔离库范围的 Recovery 只读回查 | **BLOCKED** | 需 DEVONthink 与授权范围；本机无 DEVONthink |
| 7 | 退出、重启、MCP 子进程清理、未决状态 | **BLOCKED** | 需真实 GUI 生命周期 |

## 3. 调用计数

| 类别 | 次数 |
| --- | --- |
| DEVONthink 写工具（`import_file` / `create_group_path` / `set_record_custom_metadata`） | **0** |
| DEVONthink 只读工具 | **0**（本机无 DEVONthink，未建立连接） |
| 生产库记录级查询 | **0** |
| Keychain 修改 | **0** |
| 签名 / 公证 / 发布 | **0** |

## 4. 未解决阻断项

| 项 | 状态 | 需要 |
| --- | --- | --- |
| 第 3–7 项现场验证 | **BLOCKED** | 一台可交互 macOS 14+ 机器（装有 DEVONthink，可授权辅助功能） |
| 修复后产物在**现场**（非 CI）启动 | NOT_VERIFIED | 同上；CI 已证明 macOS 上可启动，但现场机器仍需复核 |
| Keychain 锁定态 | NOT_VERIFIED | 能制造锁定并读取文件型 keychain 项的环境 |
| macOS 14.x 运行时 | BLOCKED | 14.x 设备或虚拟机 |
| 外部卷 / iCloud | BLOCKED | 隔离夹具 |
| Developer ID / 公证 / 干净机 | 未授权 | Owner 授权与证书 |

## 5. Batch 2B 前置判断

**不满足。** Batch 2B 需要第 3–7 项的真实现场事实；本轮只取得打包与启动的 CI 证据。建议在 macOS 上按以下顺序补齐（无需新代码）：

1. 用 §1 的 artifact 在本机跑 `scripts/verify_app_bundle.sh` 与 `scripts/smoke_app.sh`（现场复核 CI 结论）；
2. 按 `docs/R1-GUI-VERIFICATION.md` §4 做 8 步表单验收；
3. 按 `docs/R1-BATCH2A-REPORT.md` §12.2 做删除根目录与重授权；
4. 按 §12.5 做 Recovery 只读回查（仅隔离库范围）；
5. 按 §12.6 做退出/重启与子进程清理。

记录到 `~/.forma/evidence/r1-batch2a2/`，仓库只提交脱敏结论；在此之前不上调任何 `NOT_VERIFIED`。
