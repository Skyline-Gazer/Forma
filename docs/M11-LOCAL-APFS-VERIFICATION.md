# M11 本地 APFS 实体范围验证（Level 4 补口，Issue #130）

状态：**准备就绪，尚未执行**。本文与 `scripts/m11_apfs_fixture.sh` 只提供验证方法与夹具，不新增生产能力，不改策略，不启用默认过滤。

## 1. 为什么需要它

2026-11-19 的第 4 级真实样本运行发生在 OneDrive CloudStorage / FileProvider 上：3,357 条记录中 3,157 条 dataless。因此当时验证的是**元数据分类在 FileProvider 上的行为**，而以下三类只在合成夹具里验证过，真实 APFS 实体路径仍是 `PARTIAL`：

1. 本地实体文件（非占位符）的完整探测与快照绑定；
2. 权限失败（不可读目录 / 不可读文件）在真实卷上的错误报告与覆盖状态；
3. APFS 特有的名称语义（大小写不敏感、Unicode 归一化折叠）与符号链接、空目录、嵌套仓库并存时的守恒。

本文件定义一次可复现的补口运行，运行完成后 `MACOS-VALIDATION-BACKLOG` M11 的 `Local APFS` 行才允许从 `PARTIAL` 改写。

## 2. 前置条件

| 条件 | 检查方式 |
| --- | --- |
| macOS + 可写 APFS 卷 | `scripts/m11_apfs_fixture.sh build` 自行用 `diskutil info` 校验，非 APFS 或只读卷（快照挂载）直接拒绝 |
| 夹具不在云同步根下 | 同上：路径含 `Library/CloudStorage` 或 `OneDrive` 即拒绝 |
| 干净的仓库工作树 | `git status --porcelain` 为空，HEAD 为 Owner 认可的 SHA |
| 新的空证据运行目录 | 一次扫描一个目录；已有内容的目录会被 `evidenceDirectoryNotEmpty` 拒绝 |
| 权限 | 夹具内会 `chmod 000` 一个目录与一个文件；`clean` 会先恢复再删除，不要手工留下不可读的树 |

如需专用卷（推荐，避免与个人数据混在一起）：

```bash
diskutil apfs list
diskutil apfs addVolume disk3 "Apple_APFS" FormaVerify
# 用完后删除，属于破坏性操作，必须由 Owner 亲自确认卷名与目标盘
diskutil apfs deleteVolume disk3 FormaVerify
```

## 3. 执行步骤

```bash
cd <Forma 仓库> && git checkout dev && git pull --ff-only

# 1) 建夹具（只在指定父目录下新建 apfs-fixture / apfs-outside）
sh scripts/m11_apfs_fixture.sh build "/Volumes/FormaVerify"

# 2) 扫描前指纹
sh scripts/m11_apfs_fixture.sh stamp "/Volumes/FormaVerify/apfs-fixture" before

# 3) 只读验收扫描（新的空运行目录）
mkdir -m 700 -p "$HOME/.forma/evidence/m11-real/apfs-$(date +%Y-%m-%d-%H%M%S)"
swift run FormaAcceptance m11-real \
  --source "/Volumes/FormaVerify/apfs-fixture" \
  --evidence-dir "$HOME/.forma/evidence/m11-real/apfs-<时间戳>" \
  --dry-run

# 4) 扫描后指纹 + 比对（证明源树零改动）
sh scripts/m11_apfs_fixture.sh stamp "/Volumes/FormaVerify/apfs-fixture" after
sh scripts/m11_apfs_fixture.sh compare "/Volumes/FormaVerify/apfs-fixture" before after

# 5) 复核后导入标签（同一个运行目录）
swift run FormaAcceptance m11-real \
  --source "/Volumes/FormaVerify/apfs-fixture" \
  --evidence-dir "$HOME/.forma/evidence/m11-real/apfs-<时间戳>" \
  --dry-run \
  --labels "$HOME/.forma/evidence/m11-real/apfs-<时间戳>/human-labels.json"

# 6) 清理（只删本脚本建的树，缺 marker 即拒绝）
sh scripts/m11_apfs_fixture.sh clean "/Volumes/FormaVerify/apfs-fixture"
```

## 4. 预期结果

夹具条目与预期判定，全部来自 `eligibility.v2` 现有规则，不含任何新规则：

| 夹具条目 | 预期 | 依据 |
| --- | --- | --- |
| `01..05` 业务文档（pdf/xlsx/docx/txt） | `INCLUDE` | `default-mapping-candidate` |
| `运维记录.log`、`验收记录.csv`、`设备配置.ini` | `INCLUDE`，**不得** `EXCLUDE` | 策略无扩展名排除规则（Issue #131） |
| `01-项目/.DS_Store`、`02-售前/sub/.DS_Store` | `EXCLUDE`（`technical-noise-ds-store`） | 噪声规则只命中该文件自身 |
| `01-项目/._投标-说明.pdf` | `EXCLUDE`（`technical-noise-appledouble`） | 同上 |
| `06-cache/artifact.bin` | `REVIEW` + `protection_fact_unknown` | 标记可验证但保护事实未知，不得静默排除 |
| `06-cache-2/keep.pdf`、`06-cached-docs/manual.pdf` | `INCLUDE` | 相邻目录不继承缓存标记 |
| `07-repo/README.md` | `REVIEW`（扫描根非仓库时 `nested-repository-review` 优先，仓库内文件也可由 `git-tracked-review` 命中） | 仓库内容只复核 |
| `07-repo/.git/**` | 非 `EXCLUDE`（`REVIEW`/`DEFER`） | 无按目录排除规则，且 `protection_facts` 拦住缓存规则 |
| `01-项目/别名.pdf`（根内符号链接） | `REVIEW`（`no_rule_matched`，entryState `symlink` 不满足 `entry_states: ["present"]`） | 未知类型不排除、不跟随 |
| `escape`（指向根外目录） | `REVIEW`；**不得**出现 `escape/secret.pdf` 记录 | 扫描不跟随链接目录 |
| `loop-a` / `loop-b`（循环链接） | 扫描正常结束，两条记录均非 `EXCLUDE` | `lstat` 分类为 `.symlink`，不解析目标 |
| `08-empty/**` | 不产生记录 | 目录不是记录 |
| `.hidden/config.txt` | `INCLUDE` | 无隐藏文件规则 |
| `09-locked/secret.txt`（mode 000） | 非 `EXCLUDE`（`INCLUDE` 或 `DEFER`） | 读不出即不猜 |
| `10-locked-dir`（mode 000 目录） | `scan_complete = false`、`coverage_state = PARTIAL`、退出码 `3`；其内文件不得为 `EXCLUDE` | 不可读子树必须显式暴露 |
| `Report.pdf` / `report.pdf`、`café.txt`（NFC/NFD） | 记录数与卷上实际存储数一致；APFS 折叠时不重复计数 | 名称语义按实际存储报告 |

若希望同时取得一次 `COMPLETE`（退出码 `0`）的对照运行：先 `chmod 700 10-locked-dir && chmod 600 09-locked/secret.txt`，再换一个**新的运行目录**扫描一次；两次结果分别记录，不得混成一次结论。

## 5. 证据格式

| 产物 | 处理 |
| --- | --- |
| `sanitized-summary.json`、`scan-completeness.json`、`false-exclusion.json`、`onedrive-coverage.json`、`SHA256SUMS` | 可外发（脱敏）；`onedrive-coverage.json` 在本地 APFS 上仍固定 `NOT_VERIFIED`，这是正确结果，不是缺陷 |
| `private-review-sheet.json`、`human-labels.json`、`acceptance-workspace.sqlite` | 留本机，mode `0600`，目录 `0700` |
| `.forma-stamp-before` / `.forma-stamp-after` | 留在夹具目录，随 `clean` 一起删除；外发时只报"两枚指纹逐行一致"这一结论，不上传业务文件名清单 |

判定与统计口径按 `docs/M11-LEVEL4-RUNBOOK.md` §4.4 / §5：排除侧读 `exclude_adjudication` 普查，保留侧读 `include_sample` 抽样，两者不得互相冒充。

## 6. 通过 / 失败 / 未验证

| 结论 | 条件 |
| --- | --- |
| `PASS` | 上表全部命中预期；守恒成立（`include + exclude + review + defer = probed`，`probed + skipped = discovered`，`unaccounted = 0`）；`compare before after` 输出 `identical`；无根外记录 |
| `FAIL` | 出现任何一条"预期非 `EXCLUDE` 却被排除"；或 `compare` 报告差异（源树被改动）；或 `escape/secret.pdf` 出现在记录里 |
| `PARTIAL` | 覆盖不完整（`skipped > 0` 或存在扫描 issue）但无 `FAIL` 项；或只做了 `PARTIAL` 场景未做对照运行 |
| `NOT_VERIFIED` | 未执行；或执行环境不满足 §2（例如夹具落在云同步根内被拒绝） |

任何一项不得写 `PASS`：本地 APFS 夹具**不能**证明 OneDrive dataless / hydration 行为（那是 Issue #129 的范围），也**不能**证明默认过滤可以启用。

## 7. 已知限制

1. 本地 APFS 卷上没有 FileProvider 占位符，`SF_DATALESS` 无法在此验证；夹具中 `hydration_pending` 预期全为 `false`。
2. 夹具文件内容均为占位文本，不构成任何真实业务样本；判定只依赖元数据与标记文件，与内容无关。
3. `chmod 000` 在部分挂载选项（`noexec`、外部卷、加密卷的某些状态）下语义不同；若夹具创建成功但权限场景未按预期，记录为 `NOT_VERIFIED` 而不是猜测。
4. 脚本用 `stat`/`shasum`/`find` 等系统工具，只读夹具自身；`build` 与 `clean` 只操作 `apfs-fixture` 与 `apfs-outside` 两个它自己创建的目录。
