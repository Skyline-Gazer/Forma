# ADS 消费者接入与 CNB 评审验收报告

**日期：** 2026-11-11　**执行者：** Principal Engineer Agent　**模式：** 远程优先、证据驱动
**对象：** GitHub `Skyline-Gazer/Forma`（Primary）、GitHub Actions macOS（CI 唯一权威）、CNB `KoolingMachine/Forma`（仅 AI 评审）、ADS 固定提交 `16b99f4b49769555acc66a0c57b8cfcb8c8bac60`（`cnb/dev` 适配线）

`PASS` 为已执行并读回；`FAIL` 为执行后确认不符；`BLOCKED` 为缺授权或能力不可用；`NOT_VERIFIED` 为证据不足；`NOT_APPLICABLE` 为与当前架构无关。未执行的配置一律不记 `PASS`。

## 1. 分项结果

| 领域 | 期望证据 | 结果 |
|---|---|---|
| Forma GitHub 基线 | `main` = `38d4553`，`dev` 现为 `f8499a1`（后续台账更正待合并）；`dev` 无分支保护（API 404，单维护者默认，非合规失败）；合并方式允许 merge/squash/rebase | **PASS** |
| ADS 基线 | `Skyline-Gazer/ADS` 存在，含 `cnb/dev`；pin `16b99f4` 在远端可取回 | **PASS** |
| ADS 接入 | `.ads` 为 `160000 commit 16b99f4…`；`.gitmodules` 指向 `ADS.git`；`ads-pin.txt` 四键与 gitlink 一致；`AGENTS.md` 仅追加项目约束、不复制 ADS 规范 | **PASS** |
| 接入一致性可执行 | `scripts/check_ads_pin.py` 对 gitlink/index/url/branch/commit/consumption 逐项比对；正向 `ADS_PIN_OK`；伪造 `ADS_COMMIT` 与非零起始磁盘均退出码 1；`--verify-upstream` 实测区分「对象不存在」与「远端不可达」 | **PASS** |
| PR #25 复核 | head 演进 `3f15780 → d20b513 → 5a4d5ee → 0826759 → 887b1e7 → 4afbff3`，合并提交 `967b2e2`；GitHub Actions 在最终 head：tests 1m30s、app build 1m15s `pass`（run 42958695278） | **PASS** |
| CNB 仓库 | `KoolingMachine/Forma` 存在、Public、2026-11-11 创建、评审账号权限 `Owner`；初始无分支；匿名 `git push` 被拒（凭据作用域），改用已认证 token 的 Authorization 头后按精确 SHA 播种成功 | **PASS** |
| CNB 评审集成 | `.cnb.yml` 仅 `pull_request` 触发的官方 `cnbcool/code-review:v1.22.2`，无任何 build/test/release 阶段；真实运行 6 次（PR #25 四轮 + FormaCore 两轮），全部 `event=pull_request` | **PASS** |
| SHA 完整性 | 台账逐轮记录 reviewed source/target；`scripts/report_cnb_review.py --expect-sha` 对不匹配返回 `REVIEW_STALE` 且退出码 1；实测过期基线（target 未跟进 `dev`）会把已合并代码混入 diff，据此改为按代码自身 SHA 对评审 | **PASS** |
| ADS 感知评审 | 评审规则内嵌项目约束（GitHub 为 Primary、Actions 为唯一 CI、SPEC 冻结、P0–P3 只读、Mock 不记现场验证、禁止敏感资料入库）；运行日志显示评审者实际读取 diff、`160000` gitlink 与仓库上下文 | **PASS** |
| 发现回读 | 通道一：保留的 runner 日志打印结构化 JSON；通道二：`list-pull-reviews` + `list-pull-review-comments`（作者标记 `is_npc: true`）。第 1 轮评论投递失败（插件无法解析自身结果）已作为缺陷处理；第 3 轮起正文完整可读 | **PASS** |
| 平台 AI 评审者能力 | 可读 PR 上下文与 diff、可创建评审对象与行内评论、可经 API 回读；**写权限未授予、未测试、未需要**；本工作区无该评审者提交的提交或 PR | **PASS（读取与评论）／NOT_APPLICABLE（写入）** |
| Agent 修复回路 | 第 1 轮 2 条 → 修 `d20b513`；第 2 轮 `Max turns` 失败 → 预算与证据留存整改；第 3 轮 4 条（含 1 条真实脚本缺陷）→ 修 `887b1e7` 并本地执行十个结果状态 + 过期对照；第 4 轮 2 条（脚本会崩成 traceback、文档宣称强于代码）→ 修并合并。FormaCore 侧：8 条（1 critical）→ PR #31 逐条处置 → 复审 `passed` 0 发现 | **PASS**，PR #25 用满三轮自动 fix/re-review 上限 |
| GitHub Actions | macOS runner 固定 `macos-15` + `DEVELOPER_DIR=/Applications/Xcode_26.3.app/…`；两个任务（`swift test` 与 App 构建）；PR #25/#27/#28/#30/#31/#32 全绿；权限 `contents: read`；无 artifacts 上传；CNB 侧零 build/test 阶段 | **PASS**，无重复 CI |
| 安全评估 | 无密钥入库；token 只经 Authorization 头传递且日志中已脱敏；Actions 不暴露凭据给 PR；评审内容按不可信输入处理；写操作（合并、播种、评论）均由已认证 Agent 显式执行，未自动同步、未改远端或默认分支、未放宽权限 | **PASS**；建议项见 §3 |
| 端到端 | 真实 PR（#25、#31）走通：GitHub PR → 精确 SHA 播种 CNB → AI 评审 → 结构化发现回读 → 关联 GitHub PR → 复现/修复/驳回 → Actions 校验 → 绑定新 head 的复审 → 合并；过期评审不被当作覆盖 | **PASS** |
| 文档 | `docs/ADS-ADOPTION.md`（职责矩阵、镜像来源、逐轮台账、门禁语义、轮次上限）与本报告 | **PASS** |
| 未完成项 | 见 §3 | **BLOCKED / NOT_VERIFIED** |

## 2. 三项独立结论

**A. ADS 消费者接入 — PASS。** gitlink、`.gitmodules`、`ads-pin.txt` 与远端对象四者一致且有可执行校验；`AGENTS.md` 只追加 Forma 专属约束，未复制或改写 ADS 规范语义；pin 未擅自浮动（更新的 `v1.23.0/v1.23.1` 插件 tag 已记录但明确不采用）。

**B. CNB 代码评审接入 — PASS。** GitHub PR → CNB 精确 SHA 评审 → 发现回读 → 逐条处置 → Actions 校验 → 绑定新 head 复审的闭环在两个真实 PR 上跑通，并实际发现了实现缺陷（ZIP 数据区间可跨越下一本地头、ZIP64 触发库层不可捕获崩溃、折叠拼写导致文件从清单消失、`--verify-upstream` 空操作、证据脚本崩成 traceback）。评审仍不提供合并授权，CI 仍是唯一构建/测试权威。

**C. Forma 开发就绪度 — PARTIAL。** 可日常使用 GitHub 为 Primary + CNB 为 AI 评审平台继续开发；限制是：PR #25 的最终整改 head 只有本地验证（三轮自动评审上限已用满，记录在案）；`dev` 尚无分支保护与必需状态检查，评审覆盖靠流程纪律而非平台强制；一次性构建产物 scratch 差异揭示本地 Command Line Tools 工具链在增量重建时会丢失 Swift Testing 宏插件，本地全量重建或 CI 才是可信执行环境。

## 3. 需要 Owner 决定的事项

1. **是否为 PR #25 的最终整改提交授权一次额外 CNB 评审**（当前依据：四轮评审 + GitHub Actions + 本地执行验证，覆盖缺口已写入 `docs/ADS-ADOPTION.md`）。
2. **是否把 `dev` 设为受保护分支并要求两个 Actions 检查**（不引入新评审门禁，仅把现有纪律平台化）。
3. **是否授权一次 CNB 评审轮次以覆盖台账更正 PR #33**（纯文档，默认不申请额外轮次）。
4. 三项 P0 现场验证仍缺环境：隔离 DEVONthink 测试库 UUID、Provider 凭据与首次外发授权、已授权 OneDrive 目录。
5. 仓库当前 `allowed_actions: all` 且未强制 SHA pinning；若希望收紧，需要 Owner 明确授权后仅改 Actions 权限设置。
