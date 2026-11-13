# I1 离线准备评估（I1-OFFLINE-PREPARATION）

> 状态：**设计评估，不含实现**。I1 未授权；本文件不新增 Import Executor、不定义已批准的持久化 schema、不连接 DEVONthink 写入。它记录"哪些组件可以在 DevBox 离线准备、各自需要什么才能开始、以及为什么本轮没有写代码"。
>
> 关联：Issue [#7](https://github.com/Skyline-Gazer/Forma/issues/7)、[#21](https://github.com/Skyline-Gazer/Forma/issues/21)、[#22](https://github.com/Skyline-Gazer/Forma/issues/22)、`docs/PLAN.md` §9、`docs/ROADMAP.md`（I1 未授权）、`docs/MACOS-VALIDATION-BACKLOG.md` M10。

## 1. 为什么单独写这份评估

DevBox-First 指令要求区分**设计/模拟准备**与 **I1 实际开发授权**。这两件事在代码上只差一步——一个纯状态机加上 Fake transport 看起来"无副作用"，但它会顺带把等键、Ledger schema 和状态迁移**固定下来**，而这些正是 Owner 尚未批准的契约。因此本轮只做分类与完成条件，不写实现。

判断标准只有一条：**这段代码一旦合并，是否会让某个尚未批准的契约变成事实上的默认值。** 是，则属于实施；否，则属于准备。

## 2. 组件分类

| 组件 | 能否离线准备 | 一旦实现即固定的契约 | 本轮状态 |
| --- | --- | --- | --- |
| Preflight 规则（目标库、权限、容量、路径、Schema 版本） | 可以：纯函数 + 合成夹具 | 规则集与失败码；哪些失败是"阻止整批" | **仅设计** |
| SHA-256 数据流与版本校验 | 可以：已有 `SourceEvidence.sha256` 与流式哈希 | 哈希对象（原始字节 vs 抽取文本）、版本前缀格式 | **仅设计** |
| 等键模型（equality key） | 可以：纯函数 | 键的构成（source_id / sha256 / 目标 / Profile）、冲突判定语义 | **仅设计** |
| Import Intent / Ledger schema | 可以：类型定义 | 持久化字段、版本、迁移策略 | **仅设计** |
| 四态 `SKIP_VERIFIED` / `IMPORT` / `CONFLICT_HOLD` / `VERIFY_REQUIRED` | 可以：状态迁移表 | 迁移的触发条件与终态 | **仅设计** |
| 单写者状态机 | 可以：纯逻辑 | 并发假设（单进程 actor / 跨进程锁） | **仅设计** |
| 超时后恢复 | 可以：纯逻辑 | "超时"后允许的下一步（重查 vs 重建） | **仅设计** |
| Fake MCP Transport | 可以：内存实现 | 传输语义（错误码、重试边界） | **仅设计** |
| 创建后崩溃 / 重复请求 / 冲突模拟 | 可以：确定性脚本 | 幂等证明方式 | **仅设计** |

没有一项被标记为"不能离线准备"。这说明限制不在工程能力，而在**授权**：上述每一行的"契约"列都需要 Owner 决定后才应写进代码。

## 3. 与现有代码的接口（已经存在，不需要 I1 授权）

| 现有能力 | 位置 | I1 会如何消费 |
| --- | --- | --- |
| 来源身份与快照指纹 | `SourceEntry.snapshotFingerprint`、`SourceScope` | 等键的输入之一 |
| 流式 SHA-256 | `SourceWorkspace.hash(for:)`、`SourceEvidence.sha256` | 幂等键的字节证据 |
| Mapping 候选投影 | `EligibilityView.mappingCandidates()` | I1 的输入集合（当前未接线） |
| Manifest 与验证报告 | `ManifestEntry`、`ManifestValidator` | 写入前的目标与字段断言 |
| 只读 DEVONthink MCP | `FormaCore/DEVONthink/` | I1 的唯一写入通道（**尚未存在**） |

I1 不需要重做这些；它需要的是**在这些事实之上**决定何时写、写什么、写失败怎么办。

## 4. 完成条件（逐项）

| 组件 | 开始实施所需 |
| --- | --- |
| Preflight 规则 | Owner 批准规则清单与失败码；确认"阻止整批"的边界 |
| SHA-256 与版本校验 | 确认哈希对象与版本前缀；确认与 `SourceEvidence` 的一致性要求 |
| 等键模型 | Owner 批准键构成与冲突判定；明确"同一文件改元数据"是否算同一键 |
| Intent / Ledger schema | Owner 批准字段与版本；确认迁移与回滚策略 |
| 四态状态机 | 批准迁移表；确认哪些迁移需要人工确认 |
| 单写者 | 确认部署形态（单进程/多进程）与锁的语义 |
| 超时恢复 | 确认超时后的允许动作与证据要求 |
| Fake transport 与故障脚本 | 无额外授权；但只能在上述契约批准后编写，否则等于替 Owner 决定契约 |

**统一前置**：一份批准的 I1 设计（等键、Ledger、四态、单写者）与一个隔离测试库（真实 DEVONthink 写入属于现场验证，不在 DevBox 完成）。

## 5. 明确未验证 / 未授权

- 真实 DEVONthink 写入、真实记录创建、Metadata 回读：**未授权**。
- 隔离测试库的 UUID 与权限：**未提供**。
- 等键、Ledger schema、四态迁移：**未批准**。
- 崩溃恢复的真实证据：需要真实写入环境；模拟通过不能写成 Import 验收成功。
- 生产 `Project_Archive` 的 991 条记录：任何情况下都不修改。

## 6. 风险

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 契约被代码抢先固定 | 先写状态机 = 替 Owner 决定等键与迁移 | 本轮只写评估；代码在批准后写 |
| 幂等键设计错误 | 重复记录比不写入更难清理 | 等键与冲突语义先批准，再实现 |
| 崩溃窗口 | "创建成功但未记账"是唯一不可逆点 | 以 lookup-by-key 作为恢复唯一依据，禁止盲目重试 |
| 模拟通过被当成验收 | Fake transport 全绿不等于真实写入正确 | 状态只报 PASS/FAIL/BLOCKED/NOT_VERIFIED，模拟标 `simulated` |

## 7. 下一步

本评估完成即"记录完成条件"这一步。继续 DevBox 开发的选择有两条，均需 Owner 决策：

1. **批准 I1 设计**（等键 + Ledger + 四态 + 单写者），随后可在 DevBox 编写纯逻辑与 Fake transport，并在隔离库上做一次真实现场验证。
2. **维持 I1 未授权**，DevBox 侧转入其他已授权工作（P3-A 的剩余项已在本轮完成：2b 运行器、2c 规模基准、2d 外发契约、2e/2f 资格策略与探测、2g 覆盖与血缘、2h 探测规模测量）。
