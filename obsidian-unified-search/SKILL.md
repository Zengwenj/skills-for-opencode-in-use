---
name: obsidian-unified-search
description: Obsidian 统一搜索 Skill。根据用户自然语言需求自动路由到基础全文搜索（smart-search 四层故障转移）或高级语义查询（官方 Obsidian CLI），覆盖文件搜索、上下文搜索、任务、标签、属性、反链、出链、目录列表、大纲、笔记读取等场景。
---

# Obsidian 统一搜索

将基础全文搜索与高级语义查询合并为单一入口。Agent 根据用户意图自动选择合适的搜索路径，无需关心底层实现。

## 何时使用此 Skill

当用户想在 Obsidian 仓库中搜索笔记、查找上下文、筛选任务、标签、属性、反链、文件列表或进行结构化查询时触发。典型说法：

- "帮我找最近的会议记录"
- "搜一下包含某关键词的笔记"
- "看看这篇笔记有哪些反向链接"
- "列出 work 目录下的文档"
- "我有哪些未完成的任务"

## 能力模型：意图路由 + 基础搜索兜底 + 官方 CLI 语义查询

本 Skill 包含三组能力：

1. **意图路由**：解析用户自然语言，判断属于基础搜索还是高级语义查询。
2. **基础全文搜索**：通过 `scripts/smart-search.*` 四层故障转移（Omnisearch HTTP → 官方 CLI → obs CLI → ripgrep/Select-String）完成纯文本查找，无需官方 CLI 也可运行。
3. **高级语义查询**：需要官方 Obsidian CLI 支持，提供 tasks、tags、properties、backlinks、links、outline、read 等结构化查询能力。

## 自然语言意图路由表

Agent 收到用户请求后，先匹配下表选择执行路径：

| 用户意图 | 路由目标 | 命令示例 |
|----------|----------|----------|
| 找包含某词的笔记 | 基础搜索 | `scripts/smart-search.* "关键词"` |
| 看匹配词出现的上下文行 | 上下文搜索（CLI 优先） | `obsidian search:context query="关键词"` |
| 找待办/已完成事项 | 高级语义（CLI only） | `obsidian tasks todo` |
| 看标签分布或某标签详情 | 高级语义（CLI only） | `obsidian tags` / `obsidian tag` |
| 看属性分布或某文件属性 | 高级语义（CLI only） | `obsidian properties` |
| 看谁链接到这篇笔记 | 高级语义（CLI only） | `obsidian backlinks` |
| 看这篇笔记链接到了谁 | 高级语义（CLI only） | `obsidian links` |
| 列出某目录下文件 | 高级语义（CLI only） | `obsidian files folder=<path>` |
| 看文档结构/标题层级 | 高级语义（CLI only） | `obsidian outline` |
| 直接读某篇笔记内容 | 两步法：先定位再读 | `search`/`files` → `obsidian read` |
| 总结某主题在知识库中的分布 | 两步法：搜索缩小范围后补充 | `search`/`search:context` → `read`/`outline`/`backlinks` |

**两步法说明**：当用户的问题本质是"总结某个主题"，先搜索缩小范围，再对最相关的少量文件使用 `read`、`outline` 或 `backlinks` 补充信息后总结。

## 基础全文搜索：smart-search 四层故障转移

### 四层架构

系统按以下顺序尝试，使用第一个可用的方案：

| 优先级 | 方案 | 触发条件 | 特点 |
|--------|------|----------|------|
| 1 | Omnisearch HTTP | Obsidian 运行且 HTTP 开启 | 速度最快，BM25 权重 |
| 2 | 官方 CLI | Obsidian 运行但 HTTP 不可用 | 功能完整 |
| 3 | obs CLI | Obsidian 未运行 | 独立运行，随时可用 |
| 4 | ripgrep / Select-String | 以上都不可用 | 零依赖纯文本搜索 |

### 使用方式

```bash
# 基础搜索（bash / PowerShell）
scripts/smart-search.sh "工作报告"
scripts/smart-search.ps1 "工作报告"

# 指定结果数量
scripts/smart-search.sh "项目进度" 20
```

在 OpenCode 中直接说"帮我搜索和 Q3 项目相关的资料"，Agent 会自动调用 smart-search 并返回结果。

## 上下文搜索：官方 CLI 优先，非 CLI 仅近似

上下文搜索的目标是返回关键词所在行及其上下文，而非仅文件名。

### 有官方 CLI 时

1. 优先使用 `obsidian search:context query="关键词"`。
2. 若 `search:context` 成功但无输出，先降级到 `obsidian search` 验证是否存在候选文件。
3. 若候选文件存在，可对候选文件执行 `obsidian read` 获取内容。

### 无官方 CLI 时

使用 `smart-search.*` 的 Omnisearch 摘录或 ripgrep 行匹配作为近似上下文，**必须明确标注**：

> ⚠️ 当前为近似上下文（ripgrep/Omnisearch 行匹配），非官方 CLI 上下文结果。

## 高级语义查询：官方 Obsidian CLI Only

以下查询类型依赖官方 Obsidian CLI，**不能**由 Omnisearch/ripgrep 等价处理：

- `obsidian tasks`：任务查询（待办、已完成、每日任务）
- `obsidian tags` / `obsidian tag`：标签统计与详情
- `obsidian properties`：属性统计
- `obsidian backlinks`：反向链接
- `obsidian links`：出站链接
- `obsidian files folder=<path>`：目录文件列表
- `obsidian outline`：文档大纲/标题层级
- `obsidian read`：读取笔记全文

Agent 判断用户意图属于上述类型时，直接调用对应 CLI 命令。

## 命令构造规则

- `vault=<name>` 放在命令最前，仅在需要切换仓库时使用。
- 包含空格的值用双引号包裹：`query="会议纪要"`。
- `file=` 按笔记名解析；需要精确定位时改用 `path=`。
- 用户说"最近""最新"时，CLI 本身不直接支持按时间排序，先查出候选文件再结合仓库工具补充判断。
- 需要统计数量时，加 `total` 或 `format=json` 后自行汇总。
- 需要机器可读结果时优先 `format=json`；用户只要快速答复时可用默认文本格式。
- 单次不要返回过多文件，除非用户明确要求全量，一般加 `limit=10` 或更小。
- `search:context` 可能出现"命令成功但无输出"的情况，此时优先降级到 `obsidian search` 验证候选文件。

详细命令模式和自然语言映射参见 [references/cli-query-patterns.md](references/cli-query-patterns.md)。

## 输出总结规则

- 先给结论，再给依据。
- 结果少时，直接列出关键文件或关键行。
- 结果多时，聚类总结主题、标签、目录分布或高频模式。
- 没有结果时，明确说"未找到"，并建议更宽松的查询词。
- `search:context` 无输出但 `search` 有命中时，告诉用户"已找到相关文件，但当前 CLI 未返回上下文行"，改为总结候选文件。
- 查询语义不够清晰时，先做最稳妥的一轮搜索，再根据结果决定是否追问。

### 输出格式

默认按以下顺序组织回答：

1. 一句话回答用户问题
2. 关键发现（2 至 5 条）
3. 必要时给出执行过的命令
4. 必要时建议下一步更精确的查询方向

## 失败降级与软失败模板

### 基础搜索失败

所有四层方案都不可用时，运行 `scripts/check-env.sh` 诊断环境。

### 高级语义查询失败（CLI 不可用）

输出固定文案：

> 该查询需要官方 Obsidian CLI（例如 tasks/tags/backlinks/properties/outline/read）。当前环境未确认 CLI 可用。请先启动 Obsidian 并启用 CLI；如果只需要近似纯文本查找，可以改用基础搜索关键词。

## 安装、环境变量与路径说明

### 安装依赖（至少安装一种）

```bash
# 方案 1-2: Obsidian 官方工具
# - 安装 Obsidian 1.12+
# - 启用 CLI: Settings → General → Command line interface
# - 安装 Omnisearch 插件并启用 HTTP server

# 方案 3: 社区 CLI（推荐作为备用）
npm install -g obsidian-vault-cli
obs init  # 配置 vault

# 方案 4: ripgrep（大多数系统已预装）
# macOS: brew install ripgrep
# Ubuntu: sudo apt install ripgrep
# Windows: choco install ripgrep
```

### 环境变量

```bash
# Vault 路径（通用建议默认值 ~/Documents/ObsidianVault；
# 当前脚本 fallback 使用 D:\ObsBocdVault 作为本机示例路径）
export OBSIDIAN_VAULT="/path/to/your/vault"

# Omnisearch HTTP 端口（默认 51361）
export OMNISEARCH_PORT="51361"

# 搜索超时时间（默认 3 秒）
export SEARCH_TIMEOUT="3"
```

### 常见问题

| 问题 | 解决方案 |
|------|----------|
| 所有方案不可用 | 运行 `scripts/check-env.sh` 诊断 |
| Omnisearch HTTP 连接失败 | 检查插件是否启用、HTTP server 是否开启、防火墙是否阻止端口 |
| 官方 CLI 未找到 | macOS: 添加 PATH `/Applications/Obsidian.app/Contents/MacOS`；Windows: 检查环境变量 |
| obs CLI 找不到 vault | 重新运行 `obs init` 或手动指定 vault 路径 |

## 参考资料

- [references/cli-query-patterns.md](references/cli-query-patterns.md)：常用查询命令、参数选择和自然语言到命令的映射
- [Obsidian CLI 文档](https://help.obsidian.md/cli)
- [obs CLI 仓库](https://github.com/markfive-proto/obsidian-vault-cli)
- [Omnisearch 插件](https://github.com/scambier/obsidian-omnisearch)
