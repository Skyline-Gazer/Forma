# DEVONthink 可选集成契约 (`devonthink-contract`)

## 1. 已知平台能力与限制（基于 2026-11-26 Mac 物理实测 `dae571dc`）
- **已验证可用（`PASS`）**：Index 原件、获取/校验记录 `uuid`、原件重命名/移动后保持引用、自定义元数据字段写入与回读（需 DEVONthink Pro/Server 版）。
- **已验证限制（不可承诺自动化）**：
  - DEVONthink 4.4.2 AppleScript 字典**不支持**脚本创建 Smart Groups（需用户在原生 UI 中创建，严禁直连外部 SQLite）；
  - AppleScript **不支持**按自定义元数据 key 搜索；
  - AppleScript 无法直接回读 tag 名称字符串列表（可写入并按 tag 数量或 tag 列表检索）。

## 2. 推荐最小元数据子集（来自 `#10` 契约，按需选用、禁止编造）
仅当文档中存在明确证据且用户批准时写入：
- `projectname`（所属项目）
- `documentcategory` / `documenttype`（业务分类/角色）
- `bidderentity` / `endcustomer`（相关主体）
- `completionyear`（年份）
- 未提取到的字段留空，严禁为凑齐字段而编造值。
