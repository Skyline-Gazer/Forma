# Forma — WorkBuddy 业务文档整理专家 (Alpha)

Forma 是运行在 WorkBuddy 内的业务文档理解与归档专家（单 Agent + 领域 Skills + 确定性安全内核），帮助你整理杂乱的业务文件夹：先读懂文档内容与项目关系，再输出清晰的整理方案预览，经你明确批准后才安全移动/重命名，并支持日志恢复与可选的 DEVONthink 索引。

---

## 1. 私有安装步骤（基于 M1-A 已验证路径）

> 说明：当前版本为内部 Alpha 测试包，仅用于合成或受控测试目录体验，不用于生产库或公开分发。

1. 解压测试包 `forma-organizer-0.1.0-alpha.1.zip`，得到 `forma-expert/` 目录（内含 `.codebuddy-plugin/plugin.json`、`agents/forma.md`、`skills/`、`avatars/expert.png`）。
2. 打开 macOS WorkBuddy 客户端，进入 **「专家 · 技能 · 连接器 → 我的专家 → 创建/导入专家」**（或将本地 `forma-expert/` 目录通过客户端已验证的本地专家/技能加载入口导入，并在提示信任工作区时选择正常打开）。
3. 确认专家列表中出现 **「Forma 文档整理专家」**，且关联技能 `forma-organize`（及可选 `forma-devonthink-optional`）已就绪。

### 卸载方式
在 WorkBuddy 客户端 **「我的专家」** 中移除 `Forma 文档整理专家` 及对应本地技能目录即可；若需清理运行日志，可手动删除 `~/.forma-workbuddy/state/`。

---

## 2. 推荐安全中心配置（使用前请确认）

为配合 Forma 的「先预览、批准后再执行」机制，建议在 WorkBuddy 客户端保持以下设置（参见官方《默认权限与安全沙箱》）：
- **权限模式**：保持底部权限开关为 **「默认权限」**（切勿在日常整理时长期开启「允许完全访问」）。
- **安全中心建议开启**：`沙箱安全`、`自动备份`（默认最高 3000 MB，修改已有文件前自动快照）、`删除保护`、`工具内容注入防护`、`敏感保护`。
- **工作空间**：为每次整理单独选定测试/源文件夹，避免把桌面、下载目录或个人根目录整体设为工作区。

---

## 3. 快速开始与 3 个常用指令（Quick Prompts）

召唤 **Forma** 后，可直接点击或输入以下任意指令：
1. **整理选定文件夹**：「请整理我选定的文件夹：先只读检查并展示整理方案预览，经我确认后再执行。」
2. **仅预览不写入**：「仅检查选定文件夹并生成整理方案预览，不要修改或移动任何文件。」
3. **审阅或恢复**： 「请帮我审阅或恢复上一次的文档整理方案与执行日志。」

---

## 4. 依赖说明（Native-First）

- **必需**：WorkBuddy 客户端 + macOS 系统自带 `python3`（`forma_fs.py` 仅使用 Python 标准库，零第三方依赖）。
- **可选回退（仅当原生读取遇到扫描件或复杂多表时按需安装）**：
  - `docvortex`（`0.6.26`, Apple Silicon macOS 14+）：`pip install docvortex==0.6.26`
  - `mac-ocr`（macOS Vision 离线 OCR）：`npm install -g mac-ocr`
- **可选 DEVONthink**：仅当明确启用时使用，需本机已安装 DEVONthink（Custom Metadata 需 Pro/Server）并手动指定隔离测试库。
