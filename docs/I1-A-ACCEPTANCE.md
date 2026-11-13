# I1-A 离线阶段验收（I1-A-ACCEPTANCE）

> 状态：**Offline Verified**。不是 Import Integration Verified：本轮没有调用任何真实 DEVONthink 写工具、没有创建真实记录、没有访问生产库。I1-B 需 Owner 单独批准。

## 1. 交付范围

| 切片 | 内容 | PR | 合并 SHA |
| --- | --- | --- | --- |
| A1 | 契约 ADR、`ImportOperationKey`、源字节/业务记录身份分离、`ImportPreflight` 20 码 | #62 | `f00002a` |
| A2 | `ImportLedger` + `import-ledger-v1` + `ImportSingleWriter` 租约 + 重启清扫 | #63 | `0906345` |
| A3 | `ImportArbitration` 四态、写读分离传输契约、`ImportExecutor`、Fake Transport | (pending) | — |
| A4 | 故障矩阵、恢复回归、本报告 | (pending) | — |

## 2. 状态迁移表

（引自 `docs/ADR-I1-A-IMPORT-CONTRACT.md` §4.2，测试 `transitionShape` 钉住形状）

| 从 | 到 | 守卫 |
| --- | --- | --- |
| planned | preflighted | Preflight pass |
| planned | deferred | 仅瞬时失败 |
| preflighted | intent_persisted | 意图已提交 |
| intent_persisted | skipped_verified | 只读查询证明已存在且一致 |
| intent_persisted | record_observed | 创建返回 UUID 或只读唯一命中 |
| intent_persisted / record_observed / metadata_observed | conflict_hold | 确认是同一条业务记录但位置/字段/内容不一致 |
| record_observed | metadata_observed | Metadata 写入被应答 |
| metadata_observed | readback_verified | 独立回读一致 |
| in-flight | verify_required | 超时/断连/进程终止/候选不唯一 |
| verify_required | record_observed / metadata_observed / readback_verified / skipped_verified / conflict_hold | 先只读核查 |
| 任意未终结 | failed / cancelled | 明确失败或取消 |

不存在的迁移：`verify_required → import`、`conflict_hold → 覆盖`、任何删除。

## 3. 故障矩阵

| 故障 | 注入点 | 期望 | 证据 |
| --- | --- | --- | --- |
| 创建前拒绝 | `create` 抛错且无记录 | VERIFY_REQUIRED，0 记录 | `createRefusedBeforeApply` |
| 创建后断连 | `create` 写入后抛错 | 只读找回，1 记录，READBACK_VERIFIED | `createUnknownOutcome` |
| lookup 超时 | `lookup` 抛错 | VERIFY_REQUIRED，0 写入 | `lookupTimeout` |
| lookup 结论性不足 | `conclusive=false` | VERIFY_REQUIRED，0 写入 | `inconclusiveLookup` |
| Metadata 写失败 | `writeMetadata` 抛错 | VERIFY_REQUIRED，1 记录 | `metadataFailure` |
| 回读失败 | `read` 抛错 | VERIFY_REQUIRED | `readbackFailure` |
| 回读不一致 | 回读篡改 | CONFLICT_HOLD | `readbackMismatch` |
| 已存在且一致 | 预置记录 | SKIP_VERIFIED，0 写入 | `existingMatch` |
| 已存在、仅锚点匹配但字段不同 | 预置差异记录 | VERIFY_REQUIRED（锚点 + 字段不足以确认） | `existingDifference` |
| 已确认（锚点 + 字段）但字节不同 | 预置同元数据异哈希记录 | CONFLICT_HOLD，0 写入 | `confirmedButBytesDiffer` |
| 同 SHA 无锚点 | 预置他项目记录 | VERIFY_REQUIRED，0 写入 | `sameBytesNoAnchor` |
| 重复执行 | 同 key 第二次 | 不再次创建 | `idempotentReexecution` |
| 重启后在途 | 进程中断 | 先标 verify_required，再只读解析 | `resumeAfterRestart` |
| 已知 UUID 续写 | 记录已建、Metadata 未写完 | 只补缺失步骤，不重建 | `resumeFinishesKnownRecord` |
| 重启后证明不存在 | 结论性空搜索 | failed(`absent_after_unknown`)，不写 | `resumeDoesNotImport` |
| Preflight 阻断 | 失败码 | 不落意图、不写 | `blockedPreflight` |

## 3.1 测试清单

| 套件 | 用例数 | 覆盖 |
| --- | --- | --- |
| `ImportIdentityTests` | 9 | 操作键稳定性/逐分量区分/规范化无歧义/解码校验；哈希不确认业务身份 |
| `ImportPreflightTests` | 19 | 20 个失败码、瞬时 vs 阻断、授权独立、Profile/Schema、SHA 不一致 |
| `ImportLedgerTests` | 15 | 唯一意图、迁移守卫、终态不可变、UUID 单写、追加式审计、重启清扫、租约 |
| `ImportSingleWriterTests` | 5 | 排他、预留、成功/抛错释放、第二个 writer 被拒 |
| `ImportArbitrationTests` | 9 | 四态判定顺序与未知优先 |
| `ImportExecutorTests` | 16 | 正常、幂等、创建后断连恢复、创建前拒绝、metadata/回读失败、取消、resume 三条路径 |
| `ImportFaultMatrixTests` | 4 | 故障矩阵扫描、崩溃后恢复、并同键、写前取消 |
| **合计** | **77** | 全部为合成来源 + 临时 SQLite + Fake Transport |

## 4. 未验证接口清单（I1-B 必须现场确认）

1. 真实 MCP 写工具名称、参数与错误码；写工具白名单。
2. 真实创建返回的 UUID 语义（是否持久、是否跨库唯一）。
3. 目标标准 SHA-256 的可得性与等价性；不可得时的 `hash_unverified` 路径。
4. Group 查询/分页语义：能否证明"不存在"，以及范围参数。
5. Metadata 写入的原子性与部分成功语义。
6. 断连/超时后的真实可观测状态。
7. DEVONthink 版本、隔离库 UUID 与可丢弃记录授权。
8. `SF_DATALESS` 与 OneDrive hydration 对读取的影响（M4/M9）。

## 5. macOS 现场验证步骤（I1-B 草案）

1. 指定隔离数据库与可丢弃 Group；确认写工具白名单。
2. 用 1 个合成文件执行 IMPORT：创建 → 回读 UUID/父组/字段/标准 SHA。
3. 注入断连（kill 进程）后重启，运行 `ImportRecovery.open` + `resume`，确认不产生第二份记录。
4. 重复执行同一操作键，确认 SKIP_VERIFIED 且无第二份记录。
5. 制造字段冲突，确认 CONFLICT_HOLD 且原记录未被覆盖。
6. 记录每步的 MCP 请求/响应摘要与回读证据；不合格项按 PASS/FAIL/BLOCKED/NOT_VERIFIED 报告。

## 6. 结论

- 离线可验证的部分全部通过合成夹具与 Fake Transport 验证；报告只覆盖 **Offline Verified**。
- 没有真实写入、没有真实记录、没有生产库访问、没有真实 Provider 请求。
- 未验证项与现场步骤见 §4/§5；在 I1-B 批准前不得宣称 Import Integration Verified。
