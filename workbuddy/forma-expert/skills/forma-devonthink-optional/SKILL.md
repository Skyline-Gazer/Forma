---
name: forma-devonthink-optional
display_name: Forma DEVONthink 可选归档
display_name_en: Forma DEVONthink Optional Archival
description: Optional DEVONthink integration: index organized originals into an isolated test database, write approved metadata/tags, and read back UUID/path safely.
description_zh: 可选 DEVONthink 集成：仅在用户明确启用时，将整理后的原件索引至隔离测试库、写入已批准元数据并回读 UUID 与路径。
description_en: Optional DEVONthink integration for isolated DB indexing, approved metadata writes, and UUID/path readback.
version: 0.1.0
author: "Mark D."
---

# DEVONthink 可选集成技能 (`forma-devonthink-optional`)

> **可选能力边界**：普通本地文件夹整理无需启用 DEVONthink。仅当用户明确要求将整理后的文件索引至 DEVONthink 并写入业务元数据时使用本技能。

详细契约与平台限制见 `@references/devonthink-contract.md`。

## 核心操作原则
1. **隔离库硬性门禁**：必须由用户显式指定隔离/测试数据库名称或 UUID；**严禁写入生产数据库**，严禁将活动 DEVONthink 数据库置于 OneDrive 目录内。
2. **Index 而非 Import**：使用 Index（引用原件路径，不复制重复字节），原件状态由本地文件系统独立管理。
3. **连接优先级**：
   - 优先使用 DEVONthink 4.4+ 官方内置 MCP（macOS Sequoia+）；
   - 若不可用，通过极简 `osascript`（AppleScript/JXA）执行 Index、写入用户已批准的标签与必要自定义字段子集，并独立回读实际 `uuid`、`path` 与字段值。
4. **状态分离与部分失败**：本地文件整理成功与 DEVONthink 索引/元数据写入状态分离记录；若 DEVONthink 部分写入失败，精确报告已成功与失败项以便安全重试，不承诺跨系统分布式原子事务。
