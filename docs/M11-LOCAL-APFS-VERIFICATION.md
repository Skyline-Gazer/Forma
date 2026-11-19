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
| macOS + 可写 APFS 卷 | `build`/`stamp`/`compare`/`clean` 每次都用 `diskutil info` 校验：非 APFS、只读卷（快照挂载）、不可写一律拒绝 |
| 夹具不在云同步根下 | 同上：路径含 `Library/CloudStorage`、`OneDrive`、`Dropbox`、`Google Drive` 即拒绝 |
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

## 3. 工具布局与所有权模型

`build` 在指定父目录下创建三样东西，彼此不重叠：

| 路径 | 作用 |
| --- | --- |
| `<parent>/apfs-fixture` | **扫描源**，只放夹具内容 |
| `<parent>/apfs-outside` | 根外逃逸目标，故意做成兄弟目录 |
| `<parent>/.forma-m11-apfs/` | 工具状态：`token`、`manifest`、`stamps/<tag>.tsv` |

三条设计约束：

1. **指纹不进扫描树**。`stamp` 写 `<parent>/.forma-m11-apfs/stamps/<tag>.tsv`，所以一枚指纹永远不会被下一枚枚举到，工具自身的写入也不可能造成 before/after 差异。夹具内唯一的工具产物是所有权标记 `.forma-m11-owner`（一个真实文件，因此在扫描结果里如实显示为一条 `INCLUDE` 记录）。
2. **所有权是被证明的，不是被假设的**。`build` 生成随机 token，写入 `token` 与 `manifest`（`<token>\t<fixture|outside>\t<canonical path>`），并在两棵树的 `.forma-m11-owner` 里写入同一 token。`stamp`/`compare`/`clean` 都要求 canonical path 出现在 manifest 且 marker token 一致；`clean` 只删除 manifest 中逐项验证通过的路径，**从不按目录名猜兄弟目录**，并拒绝 `/`、`$HOME`、层级过浅的路径、符号链接路径与 token 不符的标记。
3. **失败要报出来**。不可读文件写 `UNREADABLE` 摘要（不写空字段，避免被后续比较读成"内容变更"）；不可读目录记为 `unreadable-dir`；`find` 的枚举错误只有在能归因到本脚本自己造的不可读目录时才容忍，否则中止。stamp 含 `size / mode / flags / mtime / ctime / sha256 / 链接目标`，因此新增、删除、内容修改、权限修改与 mtime 修改都可检出；符号链接始终不被跟随。

## 4. 执行步骤

```bash
cd <Forma 仓库> && git checkout dev && git pull --ff-only

# 0) 先确认工具本身在真实卷上可用（CI 每次都跑；本地首次使用也建议跑）
bash scripts/test_m11_apfs_fixture.sh

# 1) 建夹具
bash scripts/m11_apfs_fixture.sh build "/Volumes/FormaVerify"

# 2) 扫描前指纹（写到 <parent>/.forma-m11-apfs/stamps/before.tsv）
bash scripts/m11_apfs_fixture.sh stamp "/Volumes/FormaVerify/apfs-fixture" before

# 3) 只读验收扫描（新的空运行目录；先建目录再把同一个变量传两处）
RUN_DIR="$HOME/.forma/evidence/m11-real/apfs-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 -p "$RUN_DIR"
swift run FormaAcceptance m11-real \
  --source "/Volumes/FormaVerify/apfs-fixture" \
  --evidence-dir "$RUN_DIR" \
  --dry-run

# 4) 扫描后指纹 + 比对（证明源树零改动）
bash scripts/m11_apfs_fixture.sh stamp "/Volumes/FormaVerify/apfs-fixture" after
bash scripts/m11_apfs_fixture.sh compare "/Volumes/FormaVerify/apfs-fixture" before after

# 5) 复核后导入标签（同一个运行目录，不重扫）
swift run FormaAcceptance m11-real \
  --source "/Volumes/FormaVerify/apfs-fixture" \
  --evidence-dir "$RUN_DIR" \
  --dry-run \
  --labels "$RUN_DIR/human-labels.json"

# 6) 清理（只删本脚本建的两棵树与工具状态）
bash scripts/m11_apfs_fixture.sh clean "/Volumes/FormaVerify/apfs-fixture"
```

退出码（脚本合同，本轮未改）：`0` 成功（`compare` 表示两枚指纹逐行一致）；`1` 拒绝或两枚指纹不一致；`2` 用法错误；`3` 非 macOS。

## 5. 预期结果

夹具条目与预期判定，全部来自 `eligibility.v2` 现有规则，不含任何新规则：

| 夹具条目 | 预期 | 依据 |
| --- | --- | --- |
| `01..05` 业务文档（pdf/xlsx/docx/txt） | `INCLUDE` | `default-mapping-candidate` |
| `运维记录.log`、`验收记录.csv`、`设备配置.ini` | `INCLUDE`，**不得** `EXCLUDE` | 策略无扩展名排除规则（Issue #131） |
| `01-项目/.DS_Store`、`02-售前/sub/.DS_Store` | `EXCLUDE`（`technical-noise-ds-store`） | 噪声规则只命中该文件自身 |
| `01-项目/._投标-说明.pdf` | `EXCLUDE`（`technical-noise-appledouble`） | 同上 |
| `.forma-m11-owner`、`.hidden/config.txt` | `INCLUDE` | 无隐藏文件规则；所有权标记是真实文件 |
| `06-cache/artifact.bin` | `REVIEW` + `protection_fact_unknown` | 标记可验证但保护事实未知，不得静默排除 |
| `06-cache-2/keep.pdf`、`06-cached-docs/manual.pdf` | `INCLUDE` | 相邻目录不继承缓存标记 |
| `07-repo/README.md` | `REVIEW`（扫描根非仓库时 `nested-repository-review` 优先，仓库内文件也可由 `git-tracked-review` 命中） | 仓库内容只复核 |
| `07-repo/.git/**` | 非 `EXCLUDE`（`REVIEW`/`DEFER`） | 无按目录排除规则，且 `protection_facts` 拦住缓存规则 |
| `01-项目/别名.pdf`（根内符号链接） | `REVIEW`（`no_rule_matched`，entryState `symlink` 不满足 `entry_states: ["present"]`） | 未知类型不排除、不跟随 |
| `escape`（指向根外目录） | `REVIEW`；**不得**出现 `escape/secret.pdf` 记录 | 扫描不跟随链接目录 |
| `loop-a` / `loop-b`（循环链接） | 扫描正常结束，两条记录均非 `EXCLUDE` | `lstat` 分类为 `.symlink`，不解析目标 |
| `08-empty/**` | 不产生记录 | 目录不是记录 |
| `09-locked/secret.txt`（mode 000） | 非 `EXCLUDE`（`INCLUDE` 或 `DEFER`） | 读不出即不猜 |
| `10-locked-dir`（mode 000 目录） | `scan_complete = false`、`coverage_state = PARTIAL`、退出码 `3`；其内文件不得为 `EXCLUDE` | 不可读子树必须显式暴露 |
| `Report.pdf` / `report.pdf`、`café.txt`（NFC/NFD） | 记录数与卷上实际存储数一致；APFS 折叠时不重复计数 | 名称语义按实际存储报告 |

若希望同时取得一次 `COMPLETE`（退出码 `0`）的对照运行：先 `chmod 700 10-locked-dir && chmod 600 09-locked/secret.txt`，再换一个**新的运行目录**扫描一次；两次结果分别记录，不得混成一次结论。

## 6. 证据格式

| 产物 | 处理 |
| --- | --- |
| `sanitized-summary.json`、`scan-completeness.json`、`false-exclusion.json`、`onedrive-coverage.json`、`SHA256SUMS` | 可外发（脱敏）；`onedrive-coverage.json` 在本地 APFS 上仍固定 `NOT_VERIFIED`，这是正确结果，不是缺陷 |
| `private-review-sheet.json`、`human-labels.json`、`acceptance-workspace.sqlite` | 留本机，mode `0600`，目录 `0700` |
| `<parent>/.forma-m11-apfs/stamps/before.tsv`、`after.tsv` | 留在工具状态目录（不在扫描树内），随 `clean` 删除；外发时只报"两枚指纹逐行一致"这一结论，不上传业务文件名清单 |

判定与统计口径按 `docs/M11-LEVEL4-RUNBOOK.md` §4.4 / §5：排除侧读 `exclude_adjudication` 普查，保留侧读 `include_sample` 抽样，两者不得互相冒充。

## 7. 通过 / 失败 / 未验证

| 结论 | 条件 |
| --- | --- |
| `PASS` | 第 5 节全部命中预期；守恒成立（`include + exclude + review + defer = discovered`，`probed + skipped = discovered`，`unaccounted = 0`）；`compare before after` 输出 `identical`；无根外记录；`include_sample.state = SAMPLED` 或 `N/A`（无 `INCLUDE` 记录时） |
| `FAIL` | 出现任何一条"预期非 `EXCLUDE` 却被排除"；或 `compare` 报告差异（源树被改动）；或 `escape/secret.pdf` 出现在记录里 |
| `PARTIAL` | 覆盖不完整（`skipped > 0` 或存在扫描 issue）、排除侧裁决未闭合、存在未解决的 `UNCERTAIN`，或必要抽样未完成——且无 `FAIL` 项 |
| `NOT_VERIFIED` | 未执行；或执行环境不满足第 2 节（例如夹具落在云同步根内被拒绝） |

四个结论互斥，优先级 `FAIL > PARTIAL > PASS`，`NOT_VERIFIED` 只用于"没有执行证据"的情形。任何一项不得写 `PASS`：本地 APFS 夹具**不能**证明 OneDrive dataless / hydration 行为（那是 Issue #129 的范围），也**不能**证明默认过滤可以启用。

## 8. 工具自检（`scripts/test_m11_apfs_fixture.sh`）

CI 的 `M11 APFS fixture tool smoke` 作业在 `macos-15` 上真实执行夹具工具，覆盖：首次 `build` 成功且全部父目录存在、重复 `build` 拒绝、`before/after` 一致时 `compare` 成功、内容/删除/新增/权限/mtime 五种变更均被检出、标签重复与非法标签被拒、符号链接与循环链接不被跟随、不可读文件与目录被显式记录、无所有权状态/伪造 marker/缺失 marker/符号链接路径的 `clean` 全部拒绝、`clean` 只删归属目录并保留无关兄弟目录、重复 `clean` 拒绝。

环境声明：只有 `uname` 为 Darwin 时才跑用例，否则打印 `SKIPPED` 并以 0 退出（GitHub macOS 作业会真实执行，不会走到这条）。若临时卷不是 APFS，脚本打印 `ENVIRONMENT:` 并以 1 退出——**不会**把"没跑"写成"通过"。真实"非 APFS 卷"场景无法在 runner 上构造，因此该分支只由路径护栏测试与文档覆盖。

## 9. 已知限制

1. 本地 APFS 卷上没有 FileProvider 占位符，`SF_DATALESS` 无法在此验证；夹具中 `hydration_pending` 预期全为 `false`。
2. 夹具文件内容均为占位文本，不构成任何真实业务样本；判定只依赖元数据与标记文件，与内容无关。
3. `chmod 000` 在部分挂载选项（`noexec`、外部卷、加密卷的某些状态）下语义不同；若夹具创建成功但权限场景未按预期，记录为 `NOT_VERIFIED` 而不是猜测。
4. 指纹以秒级 `mtime`/`ctime` 与 `sha256` 为准；同一秒内的纯 mtime 变更可能不被区分，内容变更始终由摘要覆盖。
5. `build` 与 `clean` 只操作 `<parent>/apfs-fixture`、`<parent>/apfs-outside` 与 `<parent>/.forma-m11-apfs`，且每一项都要通过所有权验证；无关目录只被观察，不被触碰。
