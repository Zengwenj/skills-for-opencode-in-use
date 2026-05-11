# Obsidian 统一搜索

AI 意图路由 + 四层基础搜索兜底 + 官方 CLI 高级查询。自动选择最佳搜索路径，覆盖全文搜索、上下文搜索、任务、标签、属性、反链等场景。

## 核心特性

- **AI 意图路由**：解析用户自然语言，自动判断走基础搜索还是高级语义查询
- **四层基础搜索兜底**：Omnisearch HTTP → 官方 CLI → obs CLI → ripgrep/Select-String
- **官方 CLI 高级查询**：tasks、tags、properties、backlinks、links、outline、read 等结构化查询
- **零配置故障转移**：自动检测环境，使用第一个可用方案
- **统一接口**：无论底层使用什么方案，调用方式完全一致
- **OpenCode 集成**：完美支持 OpenCode/Claude Code AI 助手

## 自然语言意图路由

Agent 收到用户请求后，根据意图自动选择执行路径：

| 用户意图 | 路由目标 | 说明 |
|----------|----------|------|
| 找包含某词的笔记 | 基础搜索 (`smart-search.*`) | 四层故障转移，无需官方 CLI |
| 看关键词出现的上下文行 | 上下文搜索（CLI 优先） | `obsidian search:context` |
| 找待办/已完成事项 | 高级语义（CLI only） | `obsidian tasks` |
| 看标签分布或详情 | 高级语义（CLI only） | `obsidian tags` / `obsidian tag` |
| 看属性分布或文件属性 | 高级语义（CLI only） | `obsidian properties` |
| 看反向链接 | 高级语义（CLI only） | `obsidian backlinks` |
| 看出站链接 | 高级语义（CLI only） | `obsidian links` |
| 列出目录下文件 | 高级语义（CLI only） | `obsidian files folder=<path>` |
| 看文档标题层级 | 高级语义（CLI only） | `obsidian outline` |
| 读某篇笔记内容 | 两步法：先定位再读 | `search` → `obsidian read` |

详细路由表和命令映射参见 [SKILL.md](SKILL.md)。

## 四层基础搜索架构

```
┌─────────────────────────────────────────────────┐
│  第一层: Omnisearch HTTP (推荐)                 │
│  • Obsidian 运行时使用                          │
│  • 速度最快，有 BM25 权重                       │
│  • 支持容错搜索                                 │
├─────────────────────────────────────────────────┤
│  第二层: 官方 Obsidian CLI                      │
│  • Obsidian 运行时使用                          │
│  • 功能完整，支持复杂查询                       │
├─────────────────────────────────────────────────┤
│  第三层: obs 社区 CLI                           │
│  • Obsidian 关闭时使用                          │
│  • 完全独立，随时可用                           │
├─────────────────────────────────────────────────┤
│  第四层: ripgrep / Select-String                │
│  • 零依赖，纯文本搜索                           │
│  • 最后保障                                     │
└─────────────────────────────────────────────────┘
```

## 快速开始

### 1. 安装依赖

至少安装一种搜索方案：

```bash
# 方案 1-2: Obsidian 官方工具（推荐）
# - 安装 Obsidian 1.12+
# - 启用 CLI: Settings → General → Command line interface
# - 安装 Omnisearch 插件并启用 HTTP server

# 方案 3: 社区 CLI（推荐作为备用）
npm install -g obsidian-vault-cli
obs init

# 方案 4: ripgrep（大多数系统已预装）
# Windows: choco install ripgrep
# macOS: brew install ripgrep
```

### 2. 检测环境

```bash
# Bash
scripts/check-env.sh

# Windows PowerShell
.\scripts\check-env.ps1
```

### 3. 开始使用

```bash
# 基础搜索（Bash）
scripts/smart-search.sh "工作报告"

# 基础搜索（PowerShell）
.\scripts\smart-search.ps1 -Query "工作报告"

# 高级查询（需要官方 CLI）
obsidian tasks todo
obsidian backlinks file="项目计划"
obsidian tags
```

在 OpenCode 中直接说"帮我搜索和 Q3 项目相关的资料"，Agent 会自动调用最佳可用方案。

## 使用场景

### 场景 1: 全文搜索

```
用户: 帮我找找和"客户反馈"相关的资料

AI: 使用 Omnisearch HTTP 搜索...

📄 meetings/client-feedback.md
   相关度: 0.95
   摘要: 客户反馈总结：主要关注点包括...

📄 notes/user-research.md
   相关度: 0.87
   摘要: 用户调研发现的关键反馈...

建议：第1条适合放入"问题总结"部分，第2条有具体数据...
```

### 场景 2: 高级语义查询

```
用户: 我有哪些未完成的任务？

AI: 调用 obsidian tasks todo...

☐ 完成季度报告（projects/q3.md）
☐ 提交设计方案（design/proposal.md）
☑ 已完成：团队周会纪要（meetings/week12.md）

共 2 项待办，1 项已完成。
```

### 场景 3: Obsidian 未运行

```
用户: 搜索"合同条款"

AI: Obsidian 未运行，使用 obs CLI 搜索

📄 legal/contracts.md:45
   内容: 合同条款第3条规定...

📄 notes/agreements.md:12
   内容: 补充协议中提到...
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OBSIDIAN_VAULT` | `~/Documents/ObsidianVault` | Vault 路径 |
| `OMNISEARCH_PORT` | `51361` | Omnisearch HTTP 端口 |
| `SEARCH_TIMEOUT` | `3` | 搜索超时（秒） |

> 注：当前脚本中的 fallback 默认值为 `D:\ObsBocdVault`（本机示例路径）。生产使用请通过 `OBSIDIAN_VAULT` 环境变量设置你的实际 Vault 路径。

## 迁移说明

如果你之前使用 `obsidian-search` skill，已合并到本 skill。主要变化：

- 原有的 10 种意图路由全部保留，在 [SKILL.md](SKILL.md) 的路由表中
- "三层混合"描述已统一为"四层基础搜索故障转移"
- 高级语义查询（tasks/tags/backlinks 等）仍需要官方 Obsidian CLI
- 参考文档已迁移到 `references/` 目录

## 相关文档

- [SKILL.md](SKILL.md)：完整的 Skill 定义和指令
- [WINDOWS_SETUP.md](WINDOWS_SETUP.md)：Windows 配置指南
- [OMNISEARCH_SETUP.md](OMNISEARCH_SETUP.md)：Omnisearch 配置指南
- [references/cli-query-patterns.md](references/cli-query-patterns.md)：命令模式和自然语言映射
