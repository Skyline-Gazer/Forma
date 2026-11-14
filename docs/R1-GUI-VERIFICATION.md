# R1 — GUI 验证基础设施（Batch 2A.1）

状态：**逻辑层已验证；真实 GUI 输入仍为 NOT_VERIFIED**。

本文件记录 Batch 2A 现场暴露的问题（Accessibility 文本注入不能驱动 SwiftUI 绑定）、可选自动化方案的实际可行性，以及本轮交付的验证方式与人工验收步骤。

## 1. 现场事实（不是推断）

- 在真实 macOS 上用 `AXUIElementSetAttributeValue(kAXValue)` 写入 "Read Scope…" 的三个字段：**界面文本显示正确**，但点击确认仍得到 `invalid_scope`。
- 说明 AX 文本赋值不等价于用户键入：它没有走 SwiftUI 的编辑绑定，`TextField` 的 `Binding` 没有收到值。
- 因此"AX 里看得见"不能作为"用户输入已生效"的证据。

## 2. 方案评估

| 方案 | 可行性 | 结论 |
| --- | --- | --- |
| XCTest UI Testing（XCUITest） | 需要 `.xcodeproj`、被测 app target、签名后的 test runner；本仓库是 SwiftPM 包（`FormaApp/` 只有 `Package.swift`） | **不采用**：会引入第二套构建体系，且 CI 仍需 GUI 会话与辅助功能授权 |
| macOS Accessibility（读取） | AX 树可读取窗口、按钮、静态文本 | **采用为证据来源**：用于断言横幅文本、按钮可用性、提示语 |
| AX 文本注入（`kAXValue`） | 现场证伪：不驱动 SwiftUI 绑定 | **禁止当作输入证据** |
| AX `AXPress`（按钮） | 是真实的框架动作，不是文本替换 | 可用，但只有在输入可信时才有意义 |
| `CGEvent` 键盘 / System Events `keystroke` | 需要辅助功能（TCC）授权与真实 Aqua 会话；hosted CI 没有可授权的交互用户 | **仅在有人值守的 Mac 上可用**；CI 记为 NOT_VERIFIED |
| 逻辑层测试 + 人工验收 | 验证规则可完全自动测；交互路径由人执行并记录 | **本轮采用** |

## 3. 本轮交付

1. `Sources/FormaCore/Import/RecoveryScopeDraft.swift`：表单校验的唯一实现。
   - `incomplete`：仍在填写，不报错；
   - `invalidUUID`：填满但 UUID 非法，提示红色错误；
   - `ready(ImportRecoveryScopeConfirmation)`：可确认，UUID 规范化为大写，组路径按 `/` 切分并丢空段。
2. 表单（`RecoveryScopeSheet`）绑定该 draft；「Confirm」只在 `.ready` 时设置读范围，否则设置 `invalid_scope`；「Cancel」清空 draft。
3. 测试 `RecoveryScopeDraftTests`（6 例）：空表单、缺字段、非法 UUID、合法规范化、单段组路径、重复确认条款一致、reset。

这覆盖了"输入内容 → 校验 → 确认动作 → 错误提示 → 后续结果"里的**决策部分**；真实键入事件仍不可自动验证。

## 4. 人工验收步骤（真实 Mac，需辅助功能/输入权限）

前置：`scripts/build_app.sh` 产物、空 workspace、无其他 Forma 实例。

| 步骤 | 操作 | 期望 |
| --- | --- | --- |
| 1 | 启动应用，打开 **Read Scope…** | 三个字段为空；无红色错误；「Confirm」可点但不应生效 |
| 2 | 直接点 **Confirm** | sheet 不关闭；出现 "Enter a database UUID, a name and at least one group component." |
| 3 | 在 UUID 字段键入 `not-a-uuid`，其余填好 | 立即出现红色错误（`invalidUUID`） |
| 4 | 把 UUID 改为隔离库 UUID，名称与组路径填 `Forma_I1B2/r1` | 错误消失；「Confirm」后 sheet 关闭，横幅显示 "Read scope: …" |
| 5 | 点 **Recheck read-only** | 结果摘要出现；无 `actual_uuid` 的操作保持 `unverifiable`，Ledger 仍为 `verify_required` |
| 6 | 重新打开 **Read Scope…** 后按 **Cancel** | sheet 关闭；读范围保持上一次确认值（Cancel 只清空草稿，不改已确认范围） |
| 7 | 重复步骤 4（同一范围再确认一次） | 允许；范围条款相同，`confirmedAt` 更新 |
| 8 | 全程检查 | 无 DEVONthink 写工具调用（`import_file`/`create_group_path`/`set_record_custom_metadata` 计数为 0），无新记录 |

记录：每步的 AX 文本或截图、`import_operations` 行数、写调用计数。

## 5. 限制与状态

| 项 | 状态 |
| --- | --- |
| 表单校验逻辑 | DevBox Implemented · macOS CI Verified |
| 真实键入（CGEvent/System Events）自动化 | **NOT_VERIFIED**（需要 TCC 辅助功能授权与可交互会话） |
| AX 读取证据 | 现场可用（Batch 2A 已用 AX 文本代替截图） |
| 无 Aqua 会话的 CI | `scripts/smoke_app.sh` 返回退出码 3 并明确不作通过声明 |

不引入隐藏的调试入口来"让测试通过"：GUI 输入的可信验证只在有人值守的 Mac 上用真实键盘完成。
