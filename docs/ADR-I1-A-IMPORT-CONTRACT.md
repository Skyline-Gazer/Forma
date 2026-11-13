# ADR：I1-A 离线 Import 契约（IMPORT-CONTRACT）

> 状态：**Proposed → 随 I1-A1 合并生效**。本 ADR 是 I1-A 的实现基线，不修改冻结 SPEC v0.1.1；与 SPEC 冲突时暂停受影响部分并提交 Contract Delta。
>
> 权威来源：SPEC v0.1.1、`docs/PLAN.md` §10.1–§10.3、Owner 2026-11-13 的 I1-A 授权。本轮只覆盖**不产生真实 DEVONthink 副作用**的工程：无真实写工具调用、无真实记录、无生产库写入、无真实文件 Import。

## 1. 决定

1. 幂等操作键为 `(source_id, snapshot_fingerprint, manifest_revision, target_association_id, operation_kind)`，其 SHA-256 作为 Ledger 的唯一键。
2. **操作键不是业务记录身份**。判定"这是同一条业务记录"必须有不来自哈希的锚点证据（见 §3）。
3. 写入前先持久化 Intent；Intent 与外部副作用之间没有跨系统事务，因此不声明 exactly-once。
4. 任何"结果未知"都必须先只读核查，再落到四态之一；未知不得被读成"不存在"。
5. Import 只消费 Manifest 的既有决定，不重新执行 AI Mapping，不把 Eligibility `INCLUDE` 当作 Import 授权。
6. 授权是一个**独立对象**，不是 Manifest 上的标志位：`ManifestEnvelope.grantsExecution` 恒为 `false`，且**解码器直接拒绝** `grants_execution: true` 的文件（`FormaError.invalidOutput`）。Preflight 因此不重复检查这个不可能出现的值——契约在唯一能产生它的地方执行。
7. Ledger schema 版本化、追加式审计；不覆盖既有 attempt/observation 行。

## 2. 操作键（`ImportOperationKey`）

| 分量 | 来源 | 说明 |
| --- | --- | --- |
| `source_id` | `ManifestEntry.sourceID` | 来源身份，不是路径 |
| `snapshot_fingerprint` | `ManifestEntry.snapshotFingerprint` | 决定所依据的快照 |
| `manifest_revision` | `ManifestEnvelope.revision` | 不可变 revision，不是"最新版本" |
| `target_association_id` | `ManifestAssociation(sourceID:)` 中 `kind == .projectCandidate` 的那条 | 目标关联，不是目标 Group 字符串 |
| `operation_kind` | `ImportOperationKind` | 目前只有 `create_record`；新增种类必须改本 ADR |

规范化：`v1|<uuid>|<fingerprint>|<revision>|<uuid>|<kind>`，分量内不允许出现 `|`；digest = `SHA-256(canonical UTF-8)`。

同一个来源在 Profile 或目标改变后是**新意图**（新键）；但写前仍必须检查实际记录，不能因为键新就假定记录不存在。

## 3. 三个问题必须分开回答

| 问题 | 证据 | 不充分的反例 |
| --- | --- | --- |
| 这是同一个**操作**吗？ | 操作键 digest 相同 | 同一文件第二次运行 = 新 revision，键不同 |
| 是同一份**源字节**吗？ | `source_id` + `snapshot_fingerprint` + 已验证 `sha256` | 同 SHA 的两个不同业务用途文件 |
| 是同一条**业务记录**吗？ | 锚点 + 佐证 + 实际观测到的 UUID（§3.1） | 仅 SHA 相同；仅同名；仅同 Group |

### 3.1 业务记录身份的证据要求

`BusinessRecordIdentity.isConfirmed` 只有在下列全部成立时为真：

1. 已观测到实际目标 UUID；
2. 至少一个**锚点**：来源账本匹配（`sourceLedgerMatch`）或目标关联匹配（`targetAssociationMatch`）；
3. 至少两项佐证（锚点 + 项目/用途匹配 + 实际属性匹配中的任意两项）。

只有 SHA 匹配、只有文件名匹配、只有 Group 匹配，都**不能**确认业务身份；它们最多把结果推到 `CONFLICT_HOLD` 或 `VERIFY_REQUIRED`。

## 4. 阶段与状态机

### 4.1 阶段（`ImportPhase`）

`planned → preflighted → intent_persisted → record_observed → metadata_observed → readback_verified`

- 阶段单调递增，只能通过 §4.2 的迁移前进。
- `record_observed` 表示"已拿到该操作的记录 UUID"，不表示内容正确。
- `readback_verified` 只由**独立只读客户端**的回读结果推进；写请求的回显永远不算证据。
- 终态：`skipped_verified`、`conflict_hold`、`failed`、`cancelled`。终态不可再写。

### 4.2 迁移表

| 从 | 到 | 守卫 |
| --- | --- | --- |
| `planned` | `preflighted` | Preflight `pass` |
| `planned` | `deferred` | Preflight 只有瞬时失败（`hydration_pending` / 权限 / capability） |
| `preflighted` | `intent_persisted` | Intent 行已提交（同一事务内） |
| `intent_persisted` | `skipped_verified` | 只读查询证明记录已存在且位置/字段/标准 SHA 与 Manifest 一致 |
| `intent_persisted` | `record_observed` | 创建返回 UUID，或只读查询唯一命中 |
| `intent_persisted` / `record_observed` / `metadata_observed` | `conflict_hold` | 确认是同一条业务记录但位置/字段/内容不一致 |
| `record_observed` | `metadata_observed` | Metadata 写入被应答 |
| `metadata_observed` | `readback_verified` | 独立回读：UUID、父组、字段、标准 SHA 与意图一致 |
| 任意未终结 | `verify_required` | 超时、断连、进程终止、候选不唯一、写入结果未知 |
| `verify_required` | `record_observed` / `metadata_observed` / `readback_verified` | 先只读核查，再按事实推进 |
| `verify_required` | `conflict_hold` | 确认是同一条业务记录，但位置/字段/内容与 Manifest 不一致 |
| 任意未终结 | `failed` / `cancelled` | 明确失败或用户取消；不得留下"可能已写"的静默状态 |

**不存在的迁移**：`verify_required → import`（盲重试）；`conflict_hold → 覆盖`；任何删除既存记录的迁移。

## 5. Ledger schema（v1，A2 实现）

SQLite，随 workspace 数据库迁移，追加式审计：

```sql
CREATE TABLE import_runs (
    id TEXT PRIMARY KEY NOT NULL,
    scope_id TEXT NOT NULL,
    manifest_id TEXT NOT NULL,
    manifest_revision INTEGER NOT NULL,
    profile_id TEXT NOT NULL,
    profile_version TEXT NOT NULL,
    schema_version TEXT NOT NULL,
    authorization_digest TEXT NOT NULL,     -- 授权对象的摘要，不是凭据
    started_at REAL NOT NULL,
    state TEXT NOT NULL                     -- running / completed / aborted
);

CREATE TABLE import_operations (
    id TEXT PRIMARY KEY NOT NULL,
    run_id TEXT NOT NULL REFERENCES import_runs(id),
    key_digest TEXT NOT NULL UNIQUE,        -- 操作键 SHA-256
    source_id TEXT NOT NULL,
    snapshot_fingerprint TEXT NOT NULL,
    manifest_revision INTEGER NOT NULL,
    target_association_id TEXT NOT NULL,
    operation_kind TEXT NOT NULL,
    phase TEXT NOT NULL,
    outcome TEXT,                           -- 四态之一，未仲裁时为 NULL
    target_database TEXT NOT NULL,
    target_group_path TEXT NOT NULL,        -- JSON 数组
    intended_metadata_digest TEXT NOT NULL,
    intended_metadata TEXT NOT NULL,        -- JSON，脱敏后字段
    actual_uuid TEXT,
    source_sha256 TEXT,
    target_sha256 TEXT,
    error_code TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE import_attempts (
    id TEXT PRIMARY KEY NOT NULL,
    operation_id TEXT NOT NULL REFERENCES import_operations(id),
    attempt INTEGER NOT NULL,
    phase_before TEXT NOT NULL,
    phase_after TEXT,
    request_digest TEXT NOT NULL,
    response_digest TEXT,
    error_code TEXT,
    started_at REAL NOT NULL,
    finished_at REAL,
    UNIQUE (operation_id, attempt)
);

CREATE TABLE import_observations (
    id TEXT PRIMARY KEY NOT NULL,
    operation_id TEXT NOT NULL REFERENCES import_operations(id),
    observed_at REAL NOT NULL,
    kind TEXT NOT NULL,                     -- readback / lookup
    actual_uuid TEXT,
    parent_path TEXT,                       -- JSON 数组
    metadata_digest TEXT,
    target_sha256 TEXT,
    matches INTEGER NOT NULL,
    detail_digest TEXT
);

CREATE TABLE import_leases (
    id TEXT PRIMARY KEY NOT NULL,           -- 单写者租约
    owner TEXT NOT NULL,
    acquired_at REAL NOT NULL,
    expires_at REAL NOT NULL
);
```

不变量：

1. `key_digest` 唯一：一个操作键只有一行意图。
2. `import_attempts` / `import_observations` 只追加，不更新、不删除。
3. `actual_uuid` 只写一次；再次写入是错误，不是"纠正"。
4. 终态行的 `phase`/`outcome` 不可变。
5. 任何 `intent_persisted` 之后的行，重启时必须先只读核查才能继续。
6. 不存路径、不存正文、不存凭据：只存 digest、字段值与脱敏后的目标路径。

### 5.1 实现（A2）

`Sources/FormaCore/Import/ImportLedger.swift` 提供 `ImportLedger`（意图唯一、迁移守卫、追加式 attempt/observation、UUID 单次写入、重启清扫）与 `ImportLedgerMigrations`（`import-ledger-v1` 建表、`import-ledger-v2` 增加 `authorization_digest`，均随 workspace 数据库迁移注册；v2 的列可空，旧行照常可读）。`ImportSingleWriter` 把 PLAN §10.2 的"单个 Executor actor"落成 actor + `import_leases` 租约行：租约说"本进程可以写"，回读才决定写没写。

## 6. Preflight（A1 实现）

逐文件判定，只阻断受影响记录。失败码：

| 码 | 类别 | 含义 |
| --- | --- | --- |
| `source_unauthorized` | 瞬时 | 来源访问被拒；稍后重试，不忙等 |
| `source_missing` | 阻断 | 来源已不存在 |
| `source_changed` | 阻断 | 快照指纹与当前文件不一致 |
| `source_unreadable` | 瞬时 | 读取失败（I/O） |
| `hydration_pending` | 瞬时 | 占位文件未下载 |
| `source_sha_mismatch` | 阻断 | 内容 SHA 与 Manifest 证据不一致 |
| `entry_not_eligible` | 阻断 | `eligible_for_auto_execution == false` |
| `entry_invalidated` | 阻断 | 条目已失效 |
| `manifest_not_validated` | 阻断 | Manifest 不是 `validated` |
| `target_unresolved` | 阻断 | 目标 Group 模板未解析 |
| `target_missing` | 阻断 | 目标 Group/库不存在 |
| `target_outside_authorization` | 阻断 | 目标不在授权范围 |
| `target_not_writable` | 阻断 | 目标只读 |
| `insufficient_space` | 瞬时 | 空间不足 |
| `capability_missing` | 瞬时 | 写/回读工具不可用 |
| `authorization_missing` | 阻断 | 没有 Import 授权对象 |
| `authorization_expired` | 阻断 | 授权已过期 |
| `profile_mismatch` / `schema_mismatch` | 阻断 | 运行 Profile / Schema 与目标不一致 |

判定：任一阻断码 → `blocked`；只有瞬时码 → `deferred`；无失败 → `pass`。`deferred` 不是"跳过"，它保留在账本里等待恢复。

### 6.1 Preflight 结论是绑定事实的许可（实现层，2026-11-13 硬化）

`ImportPreflight.evaluate` 返回 `ImportPreflightClearance`，其构造器**私有**：许可只能由 Preflight 规则产生，不能由调用方手写一个空失败列表。许可绑定：

| 分量 | 含义 |
| --- | --- |
| `source_id` / `snapshot_fingerprint` | 这条结论说的是哪个来源的哪一份字节 |
| `manifest_revision` | 哪一版不可变 Manifest |
| `target_database` / `target_group_path` | 哪个目标 |
| `authorization_digest` | 在哪份授权下做出 |
| `verdict` / `failures` | 结论本身 |

执行器在写任何东西之前逐项核对许可与本次 Intent 的事实；任一项不同即拒绝（`clearance_mismatch`），零写入。`ImportIntent` 携带 `authorization_digest`，Ledger v2 把它落到 `import_operations.authorization_digest`，因此"这条操作是在哪份授权下开始的"在审计里可查。

### 6.2 执行前置授权不变量

一次外部写入只有在下列全部成立时才可能发生：

1. 存在与本次 Intent 事实绑定的 `ImportPreflightClearance`，且结论为 `pass`；
2. 执行器持有单写者租约，并对该来源与目标做了互斥预留；
3. Intent 行已持久化（`intent_persisted`），且本次操作键此前不存在；
4. 目标身份、字段与内容状态经**独立只读客户端**核对过，冲突项为零；
5. 目标能够给出可验证的内容摘要，**且该摘要的值等于本次 Intent 的源字节 SHA**；否则分别停在 `VERIFY_REQUIRED(hash_unverified)` 或 `CONFLICT_HOLD(target_sha_mismatch)`；
6. 目标的 UUID、数据库与父组与 Intent 一致；否则 `VERIFY_REQUIRED(target_identity_mismatch / target_location_changed)`；
7. 持久化 Intent 行仍与本次 Intent 的键分量、目标与授权摘要一致（恢复路径的等效事实绑定校验，不重新构造 pass）。

任何一条不成立，结果都是零写入与一个明确的原因码。

### 6.3 写路径前置条件（I1-B0 审计）

| 写路径 | 可能发出的写请求 | 前置条件 |
| --- | --- | --- |
| Initial create | `create` | 与 Intent 绑定的 `ImportPreflightClearance` 为 pass 且六项事实一致；单写者租约与预留；Intent 已落盘且键此前不存在；写前 lookup 结论完整且证明无记录 |
| Metadata write | `writeMetadata` | UUID 已知；独立只读读取成功；§6.2 的第 4–7 项全部成立；没有不可覆盖的字段冲突；只写仍缺失的槽位 |
| Resume with known UUID | `writeMetadata` | Ledger 行在途；`storedBindingFailure` 与 `sourceFailure` 均为 nil（见 §7）；租约与预留；随后进入 Metadata write 的全部前置条件 |
| Resume without known UUID | **无写** | 同上；`resolveUnknown` 只做只读 lookup 与仲裁，结果只能是 skip / conflict / failed / verify-required |
| Recovery after unknown create | `create`（仅原始一次），随后可 `writeMetadata` | 原始 create 已尝试且结果未知；恢复 lookup 结论完整、候选唯一、业务身份已确认、摘要可验证；认领 UUID 后进入 Metadata write 的全部前置条件；**禁止第二次 create** |
| Recovery after partial metadata write | `writeMetadata` | Resume with known UUID 的全部条件；独立读取显示部分字段已写入且无冲突；只补写缺失槽位 |

**没有**任何写路径绕过 `finish()` 的写前核验：唯一的 `create` 在 `run()` 中，唯一的 `writeMetadata` 在 `finish()` 中；`resolveUnknown` 与 `adoptAfterUnknownCreate` 本身不写。

## 7. 恢复规则

0. **补写前先读**：任何 Metadata 补写之前，先用独立只读客户端读取目标记录。记录中已被外部改动的槽位**保留原值**，操作进入 `CONFLICT_HOLD(external_modification)`；只有仍然缺失的槽位会被写入。外部新增的槽位不覆盖，也不阻断。
1. 重启时：`intent_persisted` 之后的每个操作，先只读核查，再决定下一步。
1a. Ledger 中没有对应操作时，恢复请求只返回"缺少意图"（`intent_missing`），**不得**据此启动一次新的导入。
1b. 恢复时若来源快照或字节摘要已变（`source_changed`），零写入。
2. "已创建、UUID 未落库"的崩溃窗口：在已验证的目标 Group 内按来源关联与时间窗口检索；**只有**查询结论完整、候选唯一、且候选的业务身份已确认（锚点 + 第二项佐证）时，才把该 UUID 认作本操作的记录；多候选、身份未确认或查询不完整 → `VERIFY_REQUIRED`，零补写；**禁止**盲重试，也**禁止**取"第一条候选"。
3. 记录已建、Metadata 未写完：证明为本操作的部分成功后，只继续未完成且与意图兼容的步骤。
4. 恢复不得：重新分类、删除既存记录、覆盖用户后续修改、清理未知重复。
5. 回读由独立只读客户端发起；写请求回显、DT 自有哈希都不能作为 `readback_verified` 的唯一证据。
5a. 目标无法给出可验证的内容摘要时，操作停在 `VERIFY_REQUIRED(hash_unverified)`：**不**标记完整 `SKIP_VERIFIED` 或 `readback_verified`。
6. SQLite 丢失：以本地导出账本与真实目标对账；无法还原的来源关系标 `unknown`，不因源路径仍在就批量重导。

## 8. 明确不声明

- 不声明 exactly-once。能做到的是"同操作键至多一次意图 + 可核查的恢复"，外部系统是否重复由回读事实判定。
- 不声明 DT 自有哈希等价于标准 SHA-256；目标字节不可验证时标 `hash_unverified`。
- 不声明 Eligibility `INCLUDE` 等于 Import 授权；两者是不同对象。
- 不声明 Replicant；默认不创建。
- 不声明 Fake Transport 通过等于 I1 现场验收；I1-A 只能报 **Offline Verified**。

## 9. Contract Delta

本 ADR 未修改 SPEC 产品契约。四处**实现层**决定：

1. 授权以独立 `ImportAuthorization` 对象表达，而不是复用 `ManifestEnvelope.grantsExecution`（后者恒为 `false`，且解码器拒绝 `true`）。
2. `ImportOperationKind` 目前只有 `create_record`；Metadata 写入是同一操作内的阶段，不是第二个键。若 I1-B 需要"补写 Metadata"作为独立可重试操作，需扩展本 ADR。
3. （2026-11-13 硬化授权）Preflight 许可改为绑定事实的 `ImportPreflightClearance`，执行器逐项核对后才允许写入；`ImportCreateRequest` 携带 `ImportSourceBinding`（获授权的源文件、字节 SHA、快照、读取会话），**不**假定 DEVONthink 文件导入工具的参数形状——该形状在 I1-B 核实前仍是未决对应关系。
4. （2026-11-14，I1-B0 已授权缺陷修复）`finish()` 在任何补写前完整核验目标 UUID / database / 父组 / 已验证且值相等的 SHA；`resume()` 改为完整来源核验与等效事实绑定校验。`ImportSourceFacts` 增加 `readSessionID` / `byteCount`，均为可选：旧调用**编译**兼容，但恢复路径要求二者非 nil 且与 `ImportSourceBinding` 一致——这是 I1-B1 接线时必须由生产侧提供的当前事实，不能用默认值假造。以上为**实现层**，不改 SPEC 产品语义。

## 10. 验收（I1-A）

| 项 | 证据 |
| --- | --- |
| 操作键与业务身份分离 | `ImportEqualityTests` |
| Preflight 全部失败码 | `ImportPreflightTests` |
| Ledger schema 与迁移 | `ImportLedgerTests`（A2） |
| 单写者与重启恢复 | `ImportSingleWriterTests`（A2） |
| 四态仲裁与 Fake Transport | `ImportArbitrationTests`（A3） |
| 故障矩阵 | `ImportFaultMatrixTests`（A4） |
| 阶段报告 | `docs/I1-A-ACCEPTANCE.md`：只报 **Offline Verified** |
