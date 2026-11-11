# Forma — Implementation Roadmap (Approved Planning Baseline)

**状态：Roadmap prepared / Not authorized for application implementation.**  
**基线：** [SPEC v0.1.1 FROZEN](SPEC.md) · [PLAN v0.1](PLAN.md) · [PLAN PR #1 merged](https://github.com/Skyline-Gazer/Forma/pull/1)  
**Owner 决策确认日期：** 2026-11-11

## 已批准的三项 Owner 决策

1. **AI Mapping 质量目标：候选值，非正式验收 Gate。** 初始参考 PLAN 提议的 precision_auto ≥95%、coverage ≥70%、field_precision ≥98%、high_confidence_error_rate ≤2%；应先做真实独立测量，结合 Profile、分层样本量、风险和置信区间，再由 Owner 批准最终 Gate。禁止将建议值写成已经获批通过。
2. **目标与年份：** Vendor Library 使用**独立的 DEVONthink 数据库**（具体库 UUID 和目录结构留待 V6 现场绑定）；Project Archive **保持现有 Group 布局**；completionyear 必须来自**已核实的归档完成事实**，不能从投标截止年、封面日期或产品年份猜测；不明则 hold。
3. **发行与生命周期：** **macOS 14+ 为当前开发基线**，P0/V7 核实兼容性；默认 GUI 退出时保存任务及未决操作状态，**下次启动先回查后恢复**。首版不做独立后台 Worker；签名/沙盒/分发策略以实测为准。

## 主链与可选分支

```mermaid
flowchart LR
    E0["E0 / P0\nContracts"] --> E1["E1 / P1\nSource facts"]
    E1 --> E2["E2 / P2\nAI mapping"]
    E2 --> E3["E3 / P2\nNative UI"]
    E3 --> E4["E4 / P3\nEvaluation"]
    E4 --> E5["E5 / I1\nImport"]
    E5 --> E7["E7 / R1\nRelease"]
    E5 --> E6["E6 / I2\nOptional sharing"]
```

P2 的 E2/E3 可部分并行，但用户可操作的 Prototype 应形成完整 Mapping + UI 流程。I2 **不阻塞** I1 和 R1；V1–V4 优先为 Prototype 提供实际能力证据，V5 仅阻塞 Replicant 选项。

## Epic / Feature 索引

| Epic | 阶段 | Feature Issues | 验收出口 |
|---|---|---|---|
| [#2 E0 契约与只读能力](https://github.com/Skyline-Gazer/Forma/issues/2) | P0 | [#10 MCP/字段](https://github.com/Skyline-Gazer/Forma/issues/10), [#11 Providers/Extractors](https://github.com/Skyline-Gazer/Forma/issues/11) | V1–V4、真实只读探针；生产零写 |
| [#3 E1 来源事实](https://github.com/Skyline-Gazer/Forma/issues/3) | P1 | [#12 source_id](https://github.com/Skyline-Gazer/Forma/issues/12), [#13 snapshot/evidence](https://github.com/Skyline-Gazer/Forma/issues/13) | 重扫、移动、替换、快照和只读证据 |
| [#4 E2 AI Mapping](https://github.com/Skyline-Gazer/Forma/issues/4) | P2 | [#14 Context/Profile](https://github.com/Skyline-Gazer/Forma/issues/14), [#15 Providers/CasePack](https://github.com/Skyline-Gazer/Forma/issues/15), [#16 Validator](https://github.com/Skyline-Gazer/Forma/issues/16) | 双 Profile 真实 Manifest、可验证 Evidence |
| [#5 E3 Native UI](https://github.com/Skyline-Gazer/Forma/issues/5) | P2 | [#17 Mapping UI](https://github.com/Skyline-Gazer/Forma/issues/17), [#18 Privacy/Correction](https://github.com/Skyline-Gazer/Forma/issues/18) | Workspace/Mapping/Exceptions/Settings、脱敏/纠错闭环 |
| [#6 E4 质量评测](https://github.com/Skyline-Gazer/Forma/issues/6) | P3 | [#19 gold/metrics](https://github.com/Skyline-Gazer/Forma/issues/19), [#20 performance/cost](https://github.com/Skyline-Gazer/Forma/issues/20) | 真实模型与样本报告，正式 Gate 待 Owner 实测后批准 |
| [#7 E5 Import](https://github.com/Skyline-Gazer/Forma/issues/7) | I1 | [#21 Write/SHA](https://github.com/Skyline-Gazer/Forma/issues/21), [#22 Ledger/Recovery](https://github.com/Skyline-Gazer/Forma/issues/22) | 隔离记录读写回读、幂等、VERIFY_REQUIRED |
| [#8 E6 Optional Sharing](https://github.com/Skyline-Gazer/Forma/issues/8) | I2 | [#23 Associations/Replicant](https://github.com/Skyline-Gazer/Forma/issues/23) | 元数据兼容才考虑 Replicant；不支持可关闭 |
| [#9 E7 Release](https://github.com/Skyline-Gazer/Forma/issues/9) | R1 | [#24 Release/Lifecycle](https://github.com/Skyline-Gazer/Forma/issues/24) | 真实安装、授权恢复、签名公证与重启核查 |

## 实施与治理边界

- **本次授权范围：** 合并 PLAN、建立 Roadmap、创建并关联 Issues。**没有批准开始代码开发**，因此全部 Issues 为 Planned / Open，未指派开发人，也不启动工作流。
- 首阶段 Prototype 只读隔离 DEVONthink 库，禁止任何写入；生产 Project_Archive 现有 991 条记录不可修改。
- SPEC 产品契约有变化须先获 Owner 批准修订；一般实现细节以 PLAN 和对应 Issue 为准。
- 公开仓库只允许脱敏/合成案例；真实资料留本地。
- 不引入 Rust/Tauri、独立 RAG/Vector DB 或不必要服务。
- 正常执行异常驱动复核；不为每批资料引入不必要审批。
- **真正开始开发之前仍需 Owner 明确授权。**

## GitHub Project 看板状态

仓库 Issues 和本文件已经建立可执行的 Roadmap；**GitHub Projects v2 看板尚未创建**。当前连接只暴露 GitHub Issues 与 PR 的创建/管理能力，没有 GitHub Projects 的创建/添加条目写入接口，因此不能假装看板已经存在。将来有 GitHub Projects 写权限工具时，可按上表建立单个 Forma Project 并批量导入这些 Issues；不应重复创建任务。
