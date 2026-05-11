# obsidian-unified-search — Obsidian 统一搜索

AI 意图路由 + 四层基础搜索兜底 + 官方 CLI 高级查询。

## 能力模型

| 能力层 | 说明 | 依赖 |
|--------|------|------|
| 意图路由 | 解析用户自然语言，判断走基础搜索还是高级语义查询 | 无 |
| 基础全文搜索 | `smart-search.*` 四层故障转移 | 至少一种搜索方案 |
| 高级语义查询 | tasks/tags/properties/backlinks/links/outline/read | 官方 Obsidian CLI |

## 执行者决策表

Agent 收到搜索请求时，按以下规则选择执行路径：

| 用户意图 | 执行方式 | 命令示例 |
|----------|----------|----------|
| 找包含某词的笔记 | `smart-search.*`（基础搜索） | `scripts/smart-search.ps1 "关键词"` |
| 看关键词出现的上下文行 | 官方 CLI `search:context`（优先） | `obsidian search:context query="关键词"` |
| 找待办/已完成事项 | 官方 CLI `tasks` | `obsidian tasks todo` |
| 看标签分布或详情 | 官方 CLI `tags`/`tag` | `obsidian tags` |
| 看属性分布或文件属性 | 官方 CLI `properties` | `obsidian properties` |
| 看反向链接 | 官方 CLI `backlinks` | `obsidian backlinks` |
| 看出站链接 | 官方 CLI `links` | `obsidian links` |
| 列出目录下文件 | 官方 CLI `files` | `obsidian files folder=<path>` |
| 看文档标题层级 | 官方 CLI `outline` | `obsidian outline` |
| 读某篇笔记内容 | 两步法：先定位再读 | `search` → `obsidian read` |
| 总结某主题分布 | 两步法：搜索 + 补充 | `search` → `read`/`outline`/`backlinks` |

**何时用 `smart-search.*`**：用户要做全文搜索、关键词匹配，或官方 CLI 不可用时的兜底。

**何时直接调用官方 CLI**：用户明确要求查询 tasks、tags、properties、backlinks、links、outline、read 等结构化信息。

详细的自然语言到命令映射参见 [SKILL.md](SKILL.md) 和 [references/cli-query-patterns.md](references/cli-query-patterns.md)。

## 四层基础搜索故障转移

| 优先级 | 方案 | 触发条件 | 特点 |
|--------|------|----------|------|
| 1 | Omnisearch HTTP | Obsidian 运行且 HTTP 开启 | 最快，BM25 权重 |
| 2 | 官方 Obsidian CLI | Obsidian 运行但 HTTP 不可用 | 功能最全 |
| 3 | obs CLI (`obsidian-vault-cli`) | Obsidian 未运行 | 独立运行 |
| 4 | ripgrep / Select-String | 以上都不可用 | 零依赖兜底 |

## 脚本清单

```
scripts/
├── smart-search.sh          ← 主搜索脚本 (Bash)
├── smart-search.ps1         ← 主搜索脚本 (PowerShell)
├── smart-search.bat         ← Windows 批处理入口
├── smart-search-simple.ps1  ← 简化版 PowerShell 搜索
├── check-env.sh             ← 环境依赖检查
└── verify-all.sh            ← 全部方案可用性验证
```

## 使用方式

```bash
# 基础搜索（Bash）
scripts/smart-search.sh "工作报告"

# 基础搜索（PowerShell，Windows 推荐）
.\scripts\smart-search.ps1 -Query "工作报告"

# 指定结果数量
smart-search.sh "项目进度" 20

# 高级查询（需要官方 CLI）
obsidian tasks todo
obsidian backlinks file="项目计划"
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OBSIDIAN_VAULT` | `~/Documents/ObsidianVault` | Vault 路径 |
| `OMNISEARCH_PORT` | `51361` | Omnisearch HTTP 端口 |
| `SEARCH_TIMEOUT` | `3` | 搜索超时（秒） |

> 注：当前脚本中的 fallback 默认值为 `D:\ObsBocdVault`（本机示例路径）。生产使用请通过 `OBSIDIAN_VAULT` 环境变量设置你的实际 Vault 路径。

## 依赖（至少需要一个）

1. Obsidian 1.12+ + Omnisearch 插件（方案 1-2）
2. `npm install -g obsidian-vault-cli`（方案 3）
3. ripgrep（方案 4，大多数系统已预装）

高级语义查询（tasks/tags/backlinks 等）额外需要官方 Obsidian CLI。

## 故障排除

```bash
# 检查环境
scripts/check-env.sh

# 验证全部方案
scripts/verify-all.sh
```

## 平台差异

- Bash 脚本 (`smart-search.sh`) 为主要维护版本
- PowerShell (`smart-search.ps1`) 和 BAT (`smart-search.bat`) 为 Windows 兼容版本
- `smart-search-simple.ps1` 是无外部依赖的简化版
