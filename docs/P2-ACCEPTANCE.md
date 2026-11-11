# Forma P2 验收报告（AI Mapping Engine + Native Workspace）

**日期：** 2026-11-11　**范围：** E2（P2.1–P2.5）+ E3（P2.6–P2.7）　**集成分支：** `dev`
**判定口径：** `PASS` = 本轮实际执行并读回结果；`FAIL` = 执行后确认不符；`BLOCKED` = 缺凭据/环境/授权而无法执行；`NOT_VERIFIED` = 已实现但缺现场证据。Mock 与单元测试不计为现场验证。

## 1. 交付与集成

| PR | 内容 | 合并提交 | 合并前 GitHub Actions（macos-15 + Xcode 26.3） | CNB 评审轮次 |
|---|---|---|---|---|
| #38 | P2.1 双 Profile、版本化 Draft 2020-12 工件 Schema、12 字段契约、Schema 门禁与依赖选型 | `b24463e`（head `1a28bb2`） | tests、app build 均 `pass`（run 42988017585） | CNB pull #4：3 轮（`17929d7`/`ddc9045`/`bda8280`），发现全部修复；第 3 轮修复提交由 CI 验证，未触发第 4 轮评审 |
| #39 | P2.2 Context Builder、P2.3 Evidence Registry、P2.5 Validator、mapping SQLite 迁移、reconcile | `ee9954c`（head `5c4e932`） | tests、app build 均 `pass`（run 42999561166） | CNB pull #5：4 轮（`e86f2ea` 1 critical+5 warning → `b78e270` 4 → `e924919` 3 → `5ccf3a0` 3），发现全部修复；第 4 轮属预算外，见 §6「覆盖边界」 |
| #40 | （stacked PR，基线分支被 squash 合并后自动关闭；由 #41 取代） | - | - | - |
| #41 | P2.4 Provider 传输复用 + Mapping Engine + CasePack + Prompt/脱敏 | `98c956d`（head `f660f8b`） | tests、app build 均 `pass`（run 43020359230） | CNB pull #6：11 轮（1c+4w → 1c+2w → 1c+7w → 1c+9w+1i → 1c+9w+1i → 0c+4w+1i → 0c+0w → 1c+2w → 0c+3w → 0c+2w+2i → 0c+2w+2i），发现全部处理 |
| #42 | P2.5 导出/离线重校验 + P2.7 Correction Capture 与候选案例 | `09baffe`（head `99632a4`） | tests、app build 均 `pass`（run 43024661916） | CNB pull #7：2 轮（1c+6w → 0c+2w，末轮 `passed`），发现全部处理 |
| #43 | P2.6 原生工作界面 + P2.7 纠错落地路径 | 26a2c3b（head `921808b`） | tests、app build 均 `pass`（run 43078381212，最终测试数 213） | CNB pull #8：**38 次评审构建、37 次有效判定**（`3885a57` 因评审器输出缺字段判 `REVIEW_EVIDENCE_INVALID`，发现仍从 stage-2 日志读出并处理），累计 14 条 critical。最后四轮只命中注释冗余或复述前一轮已修项；发现全部处理或附证据说明不成立 |
| #44 | P2 验收报告 + ADS 台账（本文档） | 合并为 `63e15e1`；该号由合并之后的这次修订填入——正是本行先前担心并写下理由的自指情形，此处以实际历史为准 | tests、app build 在 `9ab80a1` 上 `pass`（run 43094565466）；最终 head 的 run 因 runner 无容量从未开始，见 §7 第 4 条 | CNB pull #9：第 1 次构建 `changes_requested`，评审器标注 2 critical + 2 warning，**全部针对已合并代码而非文档**（即 §9 中「发现方式」列写作 `CNB 文档 pull #9 critical/warning` 的那 4 行；全文只用该列文字定位，不用行号）；此后每次镜像都继续产出「文档失真」类发现，逐条处置见 §6 的「#9 后续构建的文档失真类发现及处置」子项。本行不记 #9 的构建次数（口径与理由只写在 §6 计数条一处），见 §6 |
| #45 | #43 合并后遗留项：3 项注释/界面反馈 + pull #9 的 4 项缺陷 + 整改自身的 3 项编译期缺陷 | `63618ea`（head `af147e8`） | tests、app build 均 `pass`（run 43090470052） | CNB pull #10：4 次构建（`4adcb95` 1 项 → `094edd3` 1 项 → `2a29986` 1 项 → `af147e8` **通过**）；评审输出未逐条标注严重度，三项内容为进度指示挂全局 `phase` 两次、导出提示读取不存在的成员一次，后者在推送该次构建前已由自查修掉 |

注：#43 行原先列出逐次计数，完整 38 次链见 `docs/ADS-ADOPTION.md` 的 P2 台账；此处只保留汇总，避免同一串数字在两处失同步。

注：P2.7 的「稳定占位脱敏与外发预览」随 #41 交付，「Correction Capture 与候选案例审核」随 #42 交付，因此不再单独开「纠错与隐私」PR。

## 2. 实现范围与真实数据链

- **Profile 数据化**：`project-archive.v1`、`vendor-library.v1` 为带版本 JSON；六分类严格取自 SPEC §5.1 顺序，12 字段带层级/类型/可空/允许与不足证据来源/规则文本；`grants_execution` 在 Schema 层为常量 `false`；目标为符号目标（V6 未确认）。
- **Context Builder**：阶段一按目录、命名实体、相邻性生成候选簇（不假定目录深度）；阶段二与 Profile 及**获授权的**历史记录对齐。历史匹配收紧为：完全相等才算 `exactName`，非精确匹配要求 ≥3 字符的完整词元，且只有完全相等的历史名可替换展示名——避免单字符目录名把猜测包装成已确认项目名。结构指纹只覆盖路径/身份/状态；局部失效由 `affectedSourceIDs(between:and:)` 的成员差集决定。
- **Evidence Registry**：证据 id 由来源 + 快照修订 + 定位器派生；登记为**追加式历史**（旧行不删除），因为已入册 manifest 的引用带外键指向注册表，删除会让重读已归档文件直接失败；当前修订视图用于映射请求，历史视图用于审计与离线复核。读取失败也登记一条**不可用**证据；继承值必须携带所属候选关系。
- **Validator 六组**：schema/覆盖、证据七项真实性、Profile 政策、快照、关联、资格。引文与取值的一致性按证据种类分别定义（content/filename/path 包含、fs_metadata 逐项、sibling 取 `inherited from <path>: <value>` 标记后等值、mcp 等值），使"继承可用"成为可校验规则而非注释承诺。`confidence` 仅展示；资格由程序计算；解码时直接拒绝声称执行权限的工件。
- **Mapping Engine**：按候选分批（默认 100 条/批），大项目拆子批共享同一上下文版本；`entry_ref` 不透明且不含路径；未知引用只计数并拒绝；Schema 违规只允许一次修复调用；正文证据缺失且文件本地可读时只允许一次有界复判，复判证据回写注册表；取消以 `CancellationError` 传播，不返回半成品证据集；429 有界退避。
- **Manifest 绑定与导出**：绑定 8 项版本字段；导出 bundle 含 manifest/报告/异常/所引证据/版本摘要/摘要清单；离线 `revalidate` 不访问网络或 Keychain，能发现被篡改文件与缺失引用。
- **Reconcile**：已失效条目不重复报告；无变化时返回 `already_invalidated` 空集，避免把无操作重扫当成新事实变动。
- **Correction Capture**：纠正生成新修订；纠正值仍须通过类型/枚举/证据校验；候选案例 `candidate → reviewed → accepted/rejected`，未经审核或脱敏未通过者不可入包。
- **GUI**：Workspace / Mapping / Exceptions / Settings 四区域，SwiftUI 原生，共享一个编排模型；业务判定全部留在 FormaCore，界面只做状态编排与呈现。外发同意默认关闭、从不持久化，且每个入口各自一次（Reprocess 面板的勾选不继承全局设置）；被拒绝的运行不消耗同意。隐私预览显示的是**引擎为该列表规划的第一个真实批次**——分组与切片取自 `MappingEngine.plannedBatches`，证据行取自已登记存储；界面同时给出「本批文件数」与「整个列表所需批次数」，并明确说明 run 在发送前会重读文件正文，因此正文摘录可能与实际请求不同（预览不是收据）。预览状态由「payload + 批次形状」合成单值，避免计数与请求分离漂移。字段级纠正由 FormaCore 判定：被拒绝的尝试与已发布的决定同表列出，各自标明「针对哪一版 / 产生了哪一版」；导入他人 bundle 时明确说明其尝试记录不在本机。长任务的取消只发生在窗口根部与工具栏 Cancel，切换 tab 不再中止后台工作。

## 3. 构建与测试结果

- 单元测试规模：P1 结束时 118 项 → #38 合并后 132 项 → #39 合并后 144 项 → #41 合并后 183 项 → #42（导出与纠错）分支 201 项 → #43（工作界面与纠错落地）合并后 **213 项 / 19 个 suite**（CI run 43078381212 日志：`Test run with 213 tests in 19 suites passed`）。CI 在每个 PR head 上执行 `swift test --parallel`；#38 run 42988017585、#39 run 42999561166、#41 run 43020359230、#42 run 43024661916 均 `success`。本轮新增的主要用例：注册迁移的真实路径（rewind 生产库后重开）、重复 target 的归属规则、`pending` 行不被赋号、被取代修订的纠正被拒且不留孤儿修订、两个纠正不得主张同一号、六条 Profile 反例逐条送达、`RedactionPlan` 相等语义。
- **本地测试执行限制**：本机 Command Line Tools 6.4 的 swift-testing 宏插件解析在本轮中途起持续失败（`plugin for module 'TestingMacros' not found`），同一命令重跑有时可过、连续 10 次重试全败，与 P1 报告的缺陷同源但已恶化为常态。因此 P2 的测试权威为 GitHub Actions（Xcode 26.3）；本地保留 `swift build`/`swift build --build-tests` 作为编译门禁。此限制如实登记，不把本地未跑成说成通过。
- **FormaApp 的本地类型检查不可用**：`swiftc -parse` 只做语法解析；把整个 app target 一起 `-typecheck` 停在 `missing required module 'GRDBSQLite'`（SwiftPM 生成的 modulemap 不在命令行可见路径），而完整编译需要本机缺失的 SwiftUIMacros 插件。GUI 改动因此只有两类本地信号：逐文件语法与 FormaCore 的类型面。本轮五次真实编译错误（`Phase.label` 分支缺失、init 中提前使用 `defaults`、`envelope.profile`/`entry.sourceID` 成员不存在、`try?` 叠加 optional 返回造成双层 optional、整改中新加的归属校验引用了本函数从未绑定的 `scope`）全部只能由 CI 的 macOS app build 发现；另有一次测试层错误（迁移测试删错表名，GRDB 用 `grdb_migrations`）同样先由 CI 暴露。据此，验收把「CI 的 app build 通过」记为 GUI 代码唯一的类型层面门禁，不再声称本地验证过界面代码。

## 4. PLAN P2 验收条款逐项判定

`docs/PLAN.md` §P2「验收」列出的每一条，逐条判定；判定口径同 §1。

| 条款（PLAN §P2 验收） | 判定 | 依据或缺口 |
|---|---|---|
| 真实目录/模型输出能完整关联清单，展示两个 Profile | **BLOCKED**（真实目录/模型）；**PASS**（合成目录下的关联链）；**NOT_VERIFIED**（界面展示两 Profile） | 关联链由 MappingEngine/CorrectionPersistence 断言：文件 → 证据行 → 候选 → 字段 → 修订；本机无可授权真实目录 |
| Vendor 无项目时 `projectname=null` | **PASS** | `vendor-library.v1` 契约与 Validator 覆盖组测试断言无项目候选时该字段为 null，不复制历史标签 |
| 六组 SPEC 关键反例均有证据到判定链 | **PASS**（规则送达与判定链）；**BLOCKED**（真实模型对这些反例的回答） | 两个 Profile 各内嵌 6 条 SPEC 反例规则并随系统文本原文送达；本轮新增断言逐条核对六条规则都出现在各自 Profile 的 system 文本中（此前只核对第一条），并断言两个 Profile 的规则互不泄漏。CasePack v1 实为 24 例（positive 12 / negative 8 / conflict 2 / refusal 2），Profile 声明的每条反例所点名的分类，都必须能在 CasePack 的非 positive 样本 `whyNot` 中找到解释，否则 `CasePack.check` 报出未讲授分类（要求从 Profile 读出而非在此发明）；conflict/refusal 进入 hold 判定链由引擎测试闭合 |
| 项目成员/字段冲突、伪造 evidence/UUID/hash、越权工具名、模型拒答/截断/未知枚举进入可解释 hold；一次复判后停止 | **PASS**（确定性替身）；**BLOCKED**（真实会话） | invented-reference、forged hash/UUID、membership/field conflict、refusal、truncation、unknown enum、bounded re-ask 各自成组；复判上限为 1 且由 `MappingRunOutcome` 计数可查 |
| 界面显示目标/字段来源/冲突、取消后可恢复 | **NOT_VERIFIED** | CI 的 macOS app build 只证明可编译；无界面自动化或人工确认记录 |
| 离线查看导出可重新校验 | **PASS** | ManifestExport 离线 `revalidate`：检出被替换文件与缺失引用，路径不触网络与 Keychain |
| Mapper 在真实会话中零写调用且发送前越权测试通过 | 发送前越权 **PASS**；真实会话零写 **BLOCKED** | 越权由 Prompt/白名单与 leaks 断言覆盖；`grants_execution` 在 Schema 层恒为 false。零写需真实凭据与授权会话 |
| 更改文件、项目上下文或政策版本后不能执行旧修订 | **PASS** | 快照/上下文/Profile/CasePack 任一版本变化使旧修订失效（reconcile 与失效判定测试）；引擎缓存亦按 profile+casePack 版本键控，换 Profile 不会沿用旧引擎 |

## 5. 现场验证状态

| 能力 | 状态 | 证据或缺口 |
|---|---|---|
| 真实 Provider 结构化 Mapping | **BLOCKED** | 无 `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`，Keychain 无 Forma 条目；未发起真实 Mapping 请求。引擎/传输契约由确定性替身验证，**不记为真实验证** |
| DEVONthink 隔离库只读对齐 | **BLOCKED** | 无可确认授权的隔离库 UUID；Context Builder 的 `history` 入参在生产路径上仍为空集 |
| 真实 OneDrive 目录扫描与 hydration | **NOT_VERIFIED** | 存在 `~/Library/CloudStorage/OneDrive-个人`，但未获授权读取真实业务目录，继续使用合成场景 |
| SwiftUI GUI 人工交互 | **NOT_VERIFIED** | 本机无完整 Xcode，无法构建 `.app` 驱动界面；CI 编译成功不等于人工确认 |
| 脱敏判别力前后对照 | **BLOCKED** | 需真实凭据与授权；`RedactionPlan` 的角色区分仅有单元测试 |

## 6. CNB 评审批次与发现处置

- **P2 的评审计数。口径只有一条：以下两组求和都只含评审已闭合的 pull #4、#5、#6、#7、#8、#10，一律不含 pull #9**——#9 审的对象包含本报告，次数与条数都随每次推送变化，并入任何一组都会让该组立刻失真；#9 的逐次判定只写在 §1 的 #44 行与 `docs/ADS-ADOPTION.md` 的 #9 行里，需要全量数时把那里的实际数字加进来并注明取数时点。
  - 评审构建次数：#4 3、#5 4、#6 11、#7 2、#8 38、#10 4 → 相加 **62 次**，其中 **61 次有效判定**（#8 的 38 次之内含 `3885a57` 一次 `REVIEW_EVIDENCE_INVALID`：评审器输出缺 `severity`，发现仍从 stage 日志读出并处理）。
  - 评审器标注为 critical 的实现层缺陷：#4 0、#5 1、#6 6、#7 1、#8 14、#10 0 → 相加 **22 条**。这些分量取自各次评审构建的输出（逐 pull 记录见 §1 各行与 `docs/ADS-ADOPTION.md` 的对应行），**不是** §9 表「发现方式」列的统计 - 该列只在部分行写明 critical 级，按它相加得到的是另一个数。（#10 记 0 不是因为没发现，而是其评审输出未逐条标注严重度，见下条；#9 的 2 条 critical 按上述口径不在此列。本条是全报告唯一说明该口径之处。）
  - #10 的 3 项发现（进度指示挂在全局 `phase` 上两次、导出提示读取不存在的成员一次）在评审输出里没有逐条严重度标注，因此不并入上一条，其末次构建判定通过。
  - 每个 pull 的逐次判定链在 `docs/ADS-ADOPTION.md` 的对应行；下面按 pull 展开要点。
- **pull #4 与 #5（#38、#39）合计 1 条 critical**（重读已归档文件触发外键约束失败，导致证据永远无法刷新），另有以下真实 warning：工件长度/数量上界只在 Schema 而不在构造、lint 对部分关键字形态放行、Profile 契约用 `else` 代表 Vendor、历史匹配用裸子串包含、失效判定与注释不一致、 reconcile 重复报告旧失效、死代码与无调用方的分支入口、注释描述与实现不符。全部 FIXED，并有对应回归测试或收紧后的断言。
- **覆盖边界**：#38 的第 3 轮修复提交未触发第 4 轮评审（自动循环上限 3 轮），验证依据是 GitHub Actions 与本地编译。#39 跑了 4 轮，第 4 轮在预算外，其修复提交同样只由 CI 验证。两处缺口在此登记，不追认为已评审通过。
- **#41 评审轮数超出预期**：同一 PR 在 CNB 上跑了 11 轮，逐轮为 `1c+4w → 1c+2w → 1c+7w → 1c+9w+1i → 1c+9w+1i → 0c+4w+1i → 0c+0w → 1c+2w → 0c+3w → 0c+2w+2i → 0c+2w+2i`（`c`/`w`/`i` = critical/warning/info），按段相加为 6 条 critical、44 条 warning、7 条 info。每轮都产出真实缺陷，其中三条属于生产语义错误而非风格问题：`candidate_ref` 与 projectKey 的错配（会让所有真实模型答案失去资格）、批次按 projectKey 分组却反查 candidateID（同一 key 多候选时挂错成员集合）、429 与 schema 修复共用一轮循环（一次限流吃掉修复额度）。这说明「一次集中复核」的预算假设对 AI 生成代码不成立；后续切片 PR 仍按同一流程执行，但验收报告按实际轮数记录，不把多轮评审当作异常。
- **#43（CNB pull #8）跑了 38 次评审构建、37 次有效判定**（第 11 次 `3885a57` 因评审器输出缺 `severity` 被判 `REVIEW_EVIDENCE_INVALID`，发现仍从 stage-2 日志读出并处理，不计为有效判定），累计 14 条 critical。逐次计数与被评审 head 链见 `docs/ADS-ADOPTION.md` 的 P2 台账。趋势不是「风格收敛」而是**同一状态机被逐层追问到自洽**：第 1–10 次修数据与写入路径（scope 持久化双写、引擎缓存键与本体分离、纠正记录一列两义、发布与记录分两次写、stale-base 可覆盖新修订）；第 11–21 次修并发与生命周期（await 之后的归属校验、回读吞掉已成功的写入、tab 卸载取消共享任务句柄、restore 双趟 reload、UI 先写后校验）；第 22–35 次修**整改自身引入的问题**与迁移对真实旧库的适配；第 36–38 次只命中注释密度与文档准确性。
  - 以下逐条是**有代表性的若干条，不是 14 条的全集**；完整链（38 次构建、被评审 head 与逐次计数）见 `docs/ADS-ADOPTION.md` 的 #8 行。
  - 第 22 次构建（`bffed12`）critical：`corrections_produced` 唯一索引在含「两行声称读过同一修订」的 v1 历史上会让 `CREATE UNIQUE INDEX` 失败、迁移中止，用户启动即 `Workspace unavailable` → 早者保留主张、晚者留空；新增测试先 rewind 一个由生产 store 建出的库、删除迁移记录再重开，让注册迁移真实执行。
  - 第 30 次构建（`e839a1c`）warning：`applyCorrection` 里 `nextManifestRevision` 被读两次（守卫一次、`persist` 一次），`produced_revision` 取第二次的值，二者理论上可以不一致 → `persist(..., expecting:)` 单次读并在同一处判定（`4a2bfbd`）。
  - 第 31 次构建（`98cfdfc`）warning：迁移把 `supersedes_revision IS NOT NULL` 当成「已接受」，而 `review_state` 允许 `pending`；`pending` 行什么都没发布却被赋上修订主张 → 两条 UPDATE 写明状态，测试加入第四行钉住（`659c490`）。同轮另一条：`ExceptionsView` 用两条独立可选链比较 `Int? == Int?` → 单次 `guard let` 绑定。
  - 第 32 次构建（`4a2bfbd`）warning：外发预览的守卫比较**输入字段**，而请求由这些输入**派生**的 `RedactionPlan` 构成；比较输入相等不能保证派生值是同一份 → 给 `RedactionPlan` 增加按可观察替换定义的相等并直接比较 plan（`520163e`）。
  - 第 33 次构建（`659c490`）warning：预览面板两行读**当前**设置，而 payload 来自点击时快照 → `Preview` 自带构建时的 limit 与脱敏描述，两行改读快照（`c9060f3`）；`record.producedRevision` 与引擎候选号的分工补一句说明。
  - 第 34 次构建（`520163e`）warning：`merge` 注释缺少可核对来源 → 写明 `MappingStore.insertEvidence` 使用 `INSERT OR IGNORE`；`plannedBatches` 文档未说明该路径的 `limit` 未经构造器钳制 → 写明下限在 `batches` 内部、两入口在此汇合。
  - 第 35–38 次构建：只命中注释密度与复述（这四次与 head 的一一对应见 `docs/ADS-ADOPTION.md` #8 行的 38 个 head 序列，本节不再自行摘录——曾在此处出现「四次构建列了三个 SHA」的失配）（`revisionSplitSQL` 8→4 行、`merge` 7→4 行、预览守卫 8→3 行、`didSet` 5→3 行），以及「注释描述被替换掉的旧写法」这一类（`emptyReason`、`producedRevision`、`outcomeLine` 文案）。
- **两条被证据推翻的评审意见（记录以免被当成已修）**：第 30 次构建的 critical 称 `recordsByID` 会被旧副本覆盖——citation id 由 `sourceID`+`snapshotRevision`+source+locator 哈希而来（`EvidenceRegistry.identifier`），且 FormaCore 从不 `UPDATE evidence_items`，同一 id 的任何一次读取内容相同，故不存在新旧副本之分；第 25 次构建建议为索引冲突增加识别分支与日志入口，实现后按第 30 次构建自身给出的「该路径经守卫不可达」论证删除，只保留 schema 层约束与说明。两处最终都只留下可核对的事实说明。
- **#43 的六条真实缺陷来自 CI 而非评审**：`Phase.label` 穷尽分支缺失、init 中在成员初始化前读取 `defaults`、`SourceEntry.sourceID`/`envelope.profile`/未绑定的 `scope` 等不存在的标识符（其中一条正是上一轮整改自己引入的）、`#expect` 宏内漏写 `try`、以及新迁移测试里删错表名（GRDB 的迁移记录表是 `grdb_migrations`，不是 `grdb_database_migrations`）。这不是巧合：FormaApp 在本机无法做跨文件类型检查（见 §3），而 GUI 改动几乎全是跨文件契约。P2 的 GUI 验收因此把 CI app build 当作类型层门禁。#45 的整改又添了三条同类，全部是「凭印象引用 FormaCore 类型成员」的形状：导出改为读取登记行时写成 `manifest.entries.map(\.id)`（`ManifestEntry` 的键是 `sourceID`）；导出提示读取 `Summary.missingEvidence`（该字段属于 `ManifestExport.Revalidation`，离线重校验才有）；导出提示拆成两分支插值字符串后，`Task { }` 体的类型检查超时（`unable to type-check this expression in reasonable time`）。三次都是 app target 编译失败而 FormaCore 测试全绿，因为本机对 FormaApp 只能做 `-parse`。前两条已改为正确成员、并把「bundle 是否含全部被引用行」的说明交回重校验路径（缺行在那里以 `evidence_not_found` 报出），第三条把提示拆成独立函数。
- **两处判断被评审纠正**：其一，我先把 `pending` 纠正行当作不可能状态并从 UI 删除，评审指出该状态在 schema 与 `CorrectionRecord.init` 默认值上都合法；随后又发现「合法」不等于「会发布修订」，最终口径是 UI 用红色上报这一组合、迁移拒绝为它赋号。其二，我声称 `SettingsView` 的字段在预览期间被 `phase.isBusy` 禁用，实际只有 provider 选择器带 `.disabled`，因此那几项比较是必需而非冗余——同时暴露出 `redactionSalt` 漏比。同类的「把当前代码的性质当成整个数据集的性质」错误一共出现三次（另一次是把 `try?` 叠加在本来 optional 的返回上）。
- **文档 pull（CNB #9）的评审在已合并代码里找到 2 条 critical，而 #43 自身的 38 次构建没有**：评审范围是 `review/p2-docs` 对 `dev` 的 diff，因而重新读了 GUI 代码。两条均真实且可复现（已由 #45 的 `094edd3` 修复）：其一，`applyCorrection` 在写成功后用 `currentManifest(scope:profile:)` 回读以检测「修订已被推进」，而该查询返回的是这一 scope+profile 组合的**最新** manifest——当存在另一份 manifest（例如先跑过映射得到 B，再打开导入 bundle 里的 A 并修正它）时，屏幕被换成 B 的表头与条目，而提示说的是刚写下的 A 的修订；修复是不再二次读取，直接用写操作返回的 manifest。其二，`export()` 打包的是**本次会话点开过**的证据行，不是 manifest 引用的行；不点文件直接导出的 bundle 里 `evidence.json` 缺行、`missingEvidence` 非空，只有在另一台机器离线重校验时才暴露。修复是导出前按 manifest 自身来源读取登记行，并把缺行写进提示而不是宣布导出成功。同轮 2 条 warning（纠错校验对每个引用做线性扫描、历史读失败被降级成 `.notRead` 配一行列表）一并处理。
  - **结论对 §7 第 6 条的排期判断是加强而非削弱**：评审次数不等于覆盖面，#43 的 38 次构建密集看了状态机与注释，却漏掉「一次多余的读取」和「会话缓存被当成数据来源」这两类；要把这类缺陷压在前置期内，需要**按数据流边界重读**（每个存储查询的归属、每个写路径的返回值去向），而不是同一视角的第 N 轮。P3 的评审检查项按此添加，见 §8。
  - **#9 后续构建的「文档失真」类发现**：七类，逐条在这份 PR 的评审线程与提交历史里（`docs: ` 开头的每一节对应一类）：计数口径、章节指针、表格行数、授权记录的转述、列表结构、分类不互斥、以及同一规则的复述。本条只列类别名，不复述内容 - 复述一次就多一处会失同步的地方；处置后的现状写在各发现所属的段落里。

  - **#45 的第一版整改自身又被 CNB pull #10 连续两轮判为缺陷**（`4adcb95` 的「Recording…」进度指示挂在全局 `model.phase == .correcting` 上）：`phase` 由扫描、映射、导出、预览共用，且 `Task.cancel()` 只置标志位，`finishWork()` 要等任务走到 `defer` 才执行——取消后 reviewer 打开另一字段的 sheet，会看到「Recording…」而没有按钮，按回车不写入任何东西。改为挂 `recordingDraftID`（写入开始时置为该 draft 的 id、`defer` 清除），同轮自查又发现成功路径无条件 `self.draft = nil` 会清掉 reviewer 在写入期间新开的另一字段草稿，改为只在仍是本次点击那一份时关闭。这与上面 pull #8 第 22–35 次构建的「整改自身引入的问题」是同一类，只是这次发生在合并之后。

- **本地测试可用性**：`swift test` 对 `TestingMacros` 插件仍会随机失败（重跑 1–5 次通常可过，本会话最后一次全量为 213 项通过），因此**测试与 app 编译的权威仍是 GitHub Actions**；本地结果只用于快速反馈，不作为验收依据。

## 7. 风险与遗留

1. 三项现场依赖仍缺输入（Provider 凭据 + 外发授权、隔离库 UUID、授权 OneDrive 目录）。缺的是执行环境，不是代码路径。
2. 本地 swift-testing 宏插件在本轮后期完全不可用（见 §3），测试权威为 GitHub Actions；若 Owner 需要本地闭环，需安装完整 Xcode。
3. 映射质量指标属 P3，需要独立脱敏金标准；本轮不宣称任何质量阈值达成。
4. `dev` 无必需状态检查保护。本轮六个代码 PR（#38、#39、#41、#42、#43、#45）都在两项检查为合并 head 上的绿之后合入。文档 PR #44 是例外，且是已作出的决定而非一次通过的检查：最后一个被 runner 实际执行的 head 是 `9ab80a1`（tests + app build pass，run 43094565466），其后两次推送只改 `docs/` 两个文件（11 增 10 删，`git diff --name-only` 核验），而这两个 head 的 run 排队 90 分钟以上、始终未创建任何 job（仓库无 self-hosted runner，20:18 UTC 之后没有任何 macOS job 起步）。合并理由写在合并说明里。
5. 「当前 manifest」这一查询本身有歧义：`MappingStore.latestManifest` 以 `created_at DESC, revision DESC` 判定，而 `nextManifestRevision` 以 `MAX(revision)` 分配下一号，二者在时间戳重排下可对「哪一版最新」给出不同答案；同一 scope+profile 存在多份 manifestID 时，「当前」甚至不指向调用者刚写过的那份。CNB 文档 pull #9 的 critical 正是这一歧义落地成缺陷（写后又读、读到别份），#45 已让写路径不再依赖该查询。读取路径仍按 `created_at` 排序，统一为 `revision DESC` 会改变既有库的显示语义，留待 Owner 决定。
6. 「Prototype 与 Import/Release 阶段区分；一次集中复核即可，不添加无批准的强门禁」（AGENTS.md 第 6 条）中的**一次集中复核**假设在 AI 生成代码上不成立：#41 跑了 11 轮，#43 跑了 38 次评审构建（37 次有效判定、14 条 critical）。发现类型依次为数据正确性 → 并发与生命周期 → **整改自身引入的问题** → 注释与文档的可信度；第 22 次构建才暴露「唯一索引会让含重复 target 的旧库迁移失败、用户启动即不可用」这一真实数据形状问题，说明前 20 轮都停在代码内部而没有面对历史库。而 #43 合并之后，文档 pull 的评审在重读同一批代码时又找到 2 条 critical（见 §6 末条），所以**轮数多不等于覆盖到**：排期应按「多轮评审为常态」估计、把每轮计数写入台账，并在 P3 增加按数据流边界的专门复查，而不是指望同一视角的第 N 轮会自然收敛。
7. `docs/ROADMAP.md` 的「当前授权范围（Owner，2026-11-11）」第 43 行的授权记录原文为「P2、P3、I1、I2、R1 未授权」，而 P2 各 PR 已按本轮指令合入 `dev`。本轮不擅自改写 Owner 的授权记录：该行需要 Owner 用一句话确认「P2 = 已授权、P3/I1/I2/R1 = 未授权」后由文档 PR 更新。

## 8. 是否具备进入 P3（判定见下）

本地闭环（扫描 → 上下文 → 证据 → 校验 → Manifest → 导出 → 离线复核 → 纠正 → 界面）已实现并由 CI 验证；进入 P3 还需两项外部输入：真实 Provider 调用（凭据 + 授权）与 ≥150 条独立脱敏金标准。二者缺一时 P3 只能报告缺口，不能宣称质量验收。

P3 的评审增加两类检查项，来源是 P2 漏网的缺陷形状（§6 末条、§9 末尾按其「发现方式」列划分的后 11 行——该说明是唯一划分处，本文其他地方不再重述其取值集合）：

1. **每个存储查询的归属**：这次读的是不是调用者刚写的那一条，还是「该容器里最新的一条」；写路径的返回值是否被二次读取覆盖。
2. **每个数据来源的身份**：界面/导出用的是持久化登记的数据，还是本次会话顺带缓存的数据；若不是同一集合，缺失时要显式说出而不是报告成功。

## 9. 评审期间发现并修复的实质缺陷（P2 切片 B/C/D/E）

| 缺陷 | 影响 | 发现方式 |
|---|---|---|
| `ManifestValidator` 用 projectKey 比较 `candidate_ref`，而 Prompt 发出的是候选不透明 id | 任何真实模型答案都会被判 `candidate_unknown` 并失去自动执行资格 | 让复判测试真正可达时暴露（此前替身答案解码失败，从未走到该比较） |
| 测试替身 metadata 用 nil 赋值 → 键被删除，严格解码要求 12 字段齐全 | invented-reference、bounded-re-ask 等多组断言长期空跑 | CI 与本地全量运行差异 + 评审「不可验证」红线 |
| CasePack JSON 未声明为 target resource | 所有加载已发布案例包的测试抛 unavailable；本地旧缓存掩盖 | CI 干净构建 |
| 429 重试与 schema 修复共用一轮循环 | 一次限流吞掉修复额度，不合规答案直接变 hold | CNB 评审第 2 轮 critical |
| 金额脱敏无边界，且标识替换顺序使编号被误判为金额 | 招标编号、版本号、日期中的数字被改写；标识占位符的邻居使编号被判为价格 | CNB 评审第 1、2 轮 |
| payload 证据行无上限 | 单请求体可无界增长（重判轮并集后更明显） | CNB 评审第 3 轮 |
| `reconcile` 把「无变化」报为 `already_invalidated` | 静默重扫被解释成损伤已上报 | 本地新增测试 |
| 批次按 projectKey 分组却反查 candidateID（candidate id 含成员集合） | 同一 key 多候选时挂到不含该文件的候选，正确答案被报 membership_mismatch | CNB 评审第 10 轮 critical |
| 429 重试失败后不计请求数（`send` 抛出，调用方未累加） | 报告里「已联系 provider」显示为 0 次请求 | 本轮新增限流测试首次运行即失败 |
| corrections 迁移从未注册 | 全新数据库没有 corrections / case_candidates 表，任何纠错在写入时崩溃 | 切片落到已合并 dev 后的本地集成测试 |
| 纠错重新校验按 projectKey 指称候选 | 每条被纠正的条目都会被新校验语义判为 candidate_unknown | 同上 |
| 可分享副本只脱敏 relative_path | target.groupPath、association basis、database name 里的项目名原样外发 | 本地集成测试 + 评审 |
| 纠正 sheet 的引用候选来自仅本会话填充的内存字典 | 重启后 reviewer 看不到任何可引用行，每次纠正都被拒为「无依据」 | CNB 评审第 2 轮 warning |
| selectedScopeID 有两个写入者（模型 didSet 缺落盘 + 视图 @AppStorage 回写） | defaults 永久留下失效 scope id；重启可能落到别的来源 | CNB 评审第 3 轮 critical |
| `isRestoring` 同时短路「落盘」与「失效引擎缓存」 | 回退 profile 既不持久化也不清引擎，每次启动重复修复 | CNB 评审第 3 轮 |
| 文件读取句柄所有权错误（取消不等待，旧任务 defer 清空新任务句柄） | 并发两次读取互相覆盖结果，且取消按钮指不到在跑的任务 | CNB 评审第 4 轮 critical |
| 预览自建批次（present 前 N、ref `p1..`、无证据行），真实 run 按候选分组并附证据 | 「外发预览」承诺的确切字节与实际请求不同 | CNB 评审第 4 轮 |
| `entryLimit` 为自由文本框，0 会让引擎切片循环永不推进 | 点 Start 后界面卡在批规划，无请求无失败 | 本轮整改时定位 |
| 纠错重新校验用「当前」context 而非 manifest 引用的 revision | 无关文件出现即可让正确纠正被判 candidate_unknown，并顺带落库新 context 版本 | CNB 评审第 4 轮 |
| `corrections.manifest_revision` 一列两义（接受=产生的修订，拒绝=针对的修订） | 「先拒绝再接受」后同一 (manifest, revision) 出现两行，按修订关联审计得到二义结果 | CNB 评审第 5 轮 critical |
| 界面把三种 `reviewState` 当两种渲染 | `pending` 记录显示为「已记入修订 N」，拒绝记录引用它针对的修订号 | CNB 评审第 5 轮 |
| App 内维护两份证据视图且按 id 那份整表替换 | 旧修订引用的行可能从界面消失；两份视图需长期同步 | CNB 评审第 5 轮 |
| 空「纠错记录」列表不区分「没有记录」与「尚未读回」 | reload 提前返回时显示成「没人纠正过」 | CNB 评审第 5 轮 |
| 纠正写回不校验当前来源 | 点击在路上时切换来源，决定被写到刚离开的界面 | CNB 评审第 5 轮 |
| 纠正「记录」与「发布修订」分两次写；发布失败后遗留悬挂的 produced 声明 | 该声明占住唯一索引，用户重试被自己失败留下的行拒绝，界面只报一次普通存储错误 | CNB 评审第 6 轮 warning（同段 critical 的真实根因） |
| 唯一性测试跨 `@Sendable` 写闭包捕获局部函数与可变变量；一处裸 SQL 仍写被重命名的列 | 测试目标在 CI 编译失败；本机宏插件失效时该失败完全不可见 | GitHub Actions run 43042593565 |
| 删除脱敏词行时 ForEach 用数组下标作身份 | 剩余行的绑定指向已消失的下标，文字被改到错误的词条上 | CNB 评审第 6 轮 |
| `Phase.readingFile` 同时表示单文件读取与 provider run；工具栏 Cancel 依 `phase.isBusy` 出现却只取消 run | 读取期间按钮什么也不取消；一次文件打开还会阻塞所有要求 `phase == .idle` 的入口 | CNB 评审第 6/7 轮 |
| `reload()` 在 manifest/attempts 两次挂起后不校验来源 | 一个项目的审计历史可挂到另一个项目的界面上 | CNB 评审第 7 轮 |
| `restore()` 与 `didSet` 各起一趟 reload | 启动时两趟并发写同一组状态，留下哪组取决于响应顺序 | CNB 评审第 7 轮 |
| 纠正 sheet 捕获旧 manifest，提交时只校验当前选中项自身 | 换来源后提交 = 在 B 项目上记录关于 A 的决定 | CNB 评审第 7 轮 |
| 某 manifest 的纠正审计历史放在异常筛选栏 | 信息架构错位：该区块不是异常筛选条件 | CNB 评审第 7 轮 |
| 纠正落库后的回读错误吞掉成功事实 | 用户看不到「已记录」，再次点击被自己刚写入的修订触发 sourceChanged | CNB 评审第 10 轮 |
| 通知的修订号与标题显示的修订号来自不同时刻 | 界面显示 R+2 而审计说 R+1，无人能判断本次纠正对应哪一版 | CNB 评审第 10 轮 |
| UI 为存储不可能产生的组合写解释文字 | 无人可验证的分支占据可读性，掩盖真实坏数据 | CNB 评审第 10 轮 |
| 预览计数写成「12 of 3 batches」（文件数除以批次数） | 单位在两个方向上都错，读者无法判断自己看到的是什么 | CNB 评审第 13 轮 |
| `previewEgress` 在证据读取挂起后不校验归属 | 切换来源后仍把另一个列表的请求显示为本面板预览 | CNB 评审第 13 轮 |
| 界面文案与实际行为不符三处 | 预览批次数量显示上限而非实际；`Remove Selected` 实为删除所有空行；Reprocess 说明读全局同意而按钮用本面板同意 | CNB 评审第 2、3 轮 |
| `previewEgress` 的归属校验引用了本函数从未绑定的 `scope` | app target 编译失败，本机无法发现 | GitHub Actions macOS app build（`c130895`） |
| `SettingsView` 残留自己的 `.onDisappear`：切标签页调用 `model.cancelAux()` 并清空正在输入的 Key | 预览/能力探测/MCP 共享的一个槽位被别的面板取消 | CNB 评审第 21 次构建 |
| `loadBundle` / `revalidate` 全程无归属校验 | 大 bundle 解码期间切换来源，外来 manifest 与当前 listing 拼成一张表；结论挂到另一个 bundle | CNB 评审第 23 次构建 |
| 唯一索引在含「两行读过同一修订」的 v1 历史上让迁移整体失败 | 用过的库启动即 `Workspace unavailable`，而 SQL 文本测试全绿 | CNB 评审第 22 次构建 critical |
| 新迁移测试删除 `grdb_database_migrations`（GRDB 实际用 `grdb_migrations`） | 回退未发生，测试在第一条语句即失败 | GitHub Actions FormaCore tests run 43062035804 |
| 迁移把 `supersedes_revision IS NOT NULL` 当成「已接受」，给 `pending` 行赋修订主张 | 为一个无人写入的修订编造作者 | CNB 评审第 31 次构建 |
| `applyCorrection` 与 `persist` 在同一事务里各读一次 `nextManifestRevision` | 守卫比较的号与实际写入的号理论上可以不同 | CNB 评审第 30 次构建 |
| 预览守卫比较输入字段（limit/terms），请求却由派生的 `RedactionPlan` 构成；`redactionSalt` 漏比 | 改 salt 后屏幕上仍是旧占位文本的 payload | CNB 评审第 29、32 次构建 |
| 预览面板两行读当前设置，payload 是点击时快照 | 外发同意面把一次请求的字节与另一次请求的设置并排显示 | CNB 评审第 33 次构建 |
| `ExceptionsView` 用两条独立可选链比较 `Int? == Int?` | 正确性依赖上方四行的早退；两侧同为 nil 时相等 | CNB 评审第 31 次构建 |
| `entryLimit` 从 defaults 原样读出并显示 | 界面写「0」而引擎每批仍放 1 个文件，计数与设置不符 | CNB 评审第 38 次构建 |
| 写成功后用 `currentManifest(scope:profile:)` 回读来检测修订推进 | 同 scope+profile 存在另一份更新的 manifest 时，屏幕被换成那份的表头与条目，提示说的却是刚写下的这份 | CNB 文档 pull #9 critical |
| `export()` 取会话缓存 `evidenceBySource` 而非登记行 | 未点开文件即导出的 bundle 引用缺失证据，只有换机离线重校验才暴露 | CNB 文档 pull #9 critical |
| 纠错校验对每个引用在来源的全部历史行上线性查找 | 单次修正成本为引用数 × 历史长度，与同批引入的批量读优化方向相反 | CNB 文档 pull #9 warning |
| 历史读取失败时置 `.notRead` 却渲染一行列表 | 看起来完整、实际只有一条的审核历史，旁注还说「尚未读取」 | CNB 文档 pull #9 warning |
| `(.evidenceVerified, nil)` 的说明写成「旧库让两次尝试记了同一个被读取的修订」 | 读者去找不存在的旧库行为；实际是迁移去重时主动不给晚者归属 | PR #45（合并后自查） |
| `merge` 注释声称同一 id「每一次读取都相同」 | 只讲得住存储层：会话内新副本会覆盖内存视图而不写回存储 | PR #45（合并后自查） |
| 提交纠正期间按钮仅置灰、无任何进行指示 | 慢盘或锁库时 reviewer 无法区分「未响应」与「已受理」，倾向重复点击 | PR #45（合并后自查） |
| 进度指示挂在全局 `phase` 上；成功路径无条件清空当前 draft | 别处忙或取消未落时 sheet 显示「Recording…」却无按钮可点；写入完成清掉另一字段正在输入的草稿 | CNB pull #10 两轮评审 |
| 导出取登记行时误用 `ManifestEntry.id`（键为 `sourceID`） | app target 编译失败，而 FormaCore 测试全绿、本机无法跨文件检查 | GitHub Actions macOS app build run 43087794362 |
| 导出提示读取 `Summary.missingEvidence`（属 `Revalidation` 字段） | 同上：编译失败；且概念上把离线复核的结论当作导出即时可知的事实 | GitHub Actions macOS app build run 43089752867 |
| 导出提示写成两分支插值字符串放在 `Task` 体内 | 类型检查超时导致 app target 失败 | GitHub Actions macOS app build run 43089234676 |

本表 60 行，按「发现方式」列分成两段，划分以枚举后置段为准（其余行自动归前段，因此不存在漏项）：后段 **11 行** = 该列写作 `CNB 文档 pull #9 critical`／`…warning`（4 行）、`PR #45（合并后自查）`（3 行）、`CNB pull #10 两轮评审`（1 行）、`GitHub Actions macOS app build run 4308…`（3 行）者，均为 #43 合并后发现、由 #45 修复；前段 = 其余 **49 行**（该列写作 `CNB 评审第 N 轮`、`CNB 评审第 N 次构建`、`GitHub Actions FormaCore tests …`、`本轮整改时定位` 等），在所属 PR 合并前修复——每行只归一类：4 行改变运行时行为（写后又读、导出取会话缓存、每引用一次线性扫描、历史读失败的状态语义）；3 行是注释与界面措辞（`outcomeLine` 的说法、`merge` 的断言、纠正期间没有进行指示）；1 行是整改自身引入的缺陷（进度指示挂在全局 `phase` 上，且写入完成时清掉另一字段的草稿）；3 行是凭印象引用 FormaCore 类型成员造成的 app target 编译失败或类型检查超时。4 + 3 + 1 + 3 = 11。全部未进入 I1/I2，也未对 DEVONthink 做任何写操作。

