# Configuration

## 推荐方式

优先使用环境变量，尤其是 `MINERU_TOKEN`。

## 环境变量写法

### PowerShell 当前会话

```powershell
$env:MINERU_TOKEN = "<在这里填写你的 MineU Token>"
$env:DEFAULT_OUTPUT_ROOT = "C:\docs\_mineru"
```

### PowerShell 持久写入当前用户

```powershell
[System.Environment]::SetEnvironmentVariable(
  "MINERU_TOKEN",
  "<在这里填写你的 MineU Token>",
  "User"
)
```

### CMD 当前会话

```cmd
set MINERU_TOKEN=<在这里填写你的 MineU Token>
```

## 外置配置文件

真实配置文件不要放进技能目录。

建议位置：
- `C:\Users\zengw\.config\opencode\local\mineru.env`
- `C:\Users\zengw\.config\opencode\local\mineru.json`

如果技能目录里为了本地验证暂时保留了 `mineru..env` 一类文件，也要把它视为隔离对象：
- 不把它写进 `SKILL.md` 示例
- 不把它当成推荐配置路径
- 不把它带进分发或打包产物

## `.env` 写法

```dotenv
MINERU_TOKEN=<在这里填写你的 MineU Token>
DEFAULT_OUTPUT_ROOT=
```

规则：
- UTF-8
- `键=值`
- 支持 `#` 注释
- 不写 `Bearer ` 前缀

## `.json` 写法

```json
{
  "MINERU_TOKEN": "<在这里填写你的 MineU Token>",
  "DEFAULT_OUTPUT_ROOT": ""
}
```

## 优先级

1. 命令行显式参数
2. 环境变量（`MINERU_TOKEN`、`DEFAULT_OUTPUT_ROOT`）
3. `--config` 指定的 `.env` 或 `.json`

说明：
- `--output-root` 未显式传入时，才会回退到 `DEFAULT_OUTPUT_ROOT`

## Token 变量差异

MinerU 生态中有两个不同的 token 变量，分别用于不同工具：

| 变量 | 适用工具 | 说明 |
| --- | --- | --- |
| `MINERU_TOKEN` | 本 skill、`mineru-open-api` CLI、Python/Go SDK | 命令行和 SDK 认证 |
| `MINERU_API_TOKEN` | 官方 MCP Server（`mineru-open-mcp`） | Agent 对话内工具调用认证 |

规则：
- 只用本 skill 或 CLI：配置 `MINERU_TOKEN` 即可。
- 只用官方 MCP：配置 `MINERU_API_TOKEN` 即可。
- 同时使用两者：需要分别配置两个变量，值通常相同但不能互换变量名。
- 不要把 `MINERU_TOKEN` 写进 MCP 的配置，反之亦然。

MCP Precision/VLM 路径以 `MINERU_API_TOKEN` 为认证前提。如果只有 `MINERU_TOKEN` 而没有 `MINERU_API_TOKEN`，MCP 无法使用 Precision/VLM 路径；此时应使用本 skill 或官方 CLI（它们使用 `MINERU_TOKEN`），或先补配 `MINERU_API_TOKEN`。

### MCP 可选环境变量

官方 MCP Server 还支持以下可选变量（与本 skill 无关，仅供了解）：
- `OUTPUT_DIR` — MCP 输出目录（默认 `~/mineru-downloads`）
- `MINERU_LOG_LEVEL` — MCP 日志级别

### 本 skill 专属配置

- `DEFAULT_OUTPUT_ROOT` — 本 skill 默认输出根目录
- `KEEP_RAW_TREE` — 是否保留原始目录树结构

这两个变量只在本 skill 中有效，不是 MCP 配置项。

## 模型选择规则

### MCP 模型参数

官方 MCP 的 `parse_documents` 工具接受可选的 `model` 参数：

| 场景 | `model` 参数值 | 说明 |
| --- | --- | --- |
| 非 HTML 文档（PDF、DOCX、PPTX 等） | 省略（不传） | SDK 自动推断为 VLM，推荐模式 |
| HTML 文件 / 网页 URL | `"html"` | 使用 MinerU-HTML 模型 |
| 强制传统流水线 | `"pipeline"` | 不使用 VLM，零幻觉但精度较低 |

**不要给 MCP 配置 `MINERU_MODEL` 或 `DEFAULT_MODEL` 环境变量**——这些变量在官方 MCP 中不存在。模型选择通过 `model` 参数在调用时控制。

### 本 skill 模型行为

本 skill 当前通过 SDK 的 `client.extract()` 调用 Precision API，未显式传递 `model` 参数。SDK 自动推断规则：
- 非 HTML 文件 → 使用 VLM 模型
- HTML/HTM 文件 → 使用 MinerU-HTML 模型

这意味着本 skill 的非 HTML 解析默认已使用 VLM，无需额外配置。

## 禁止项

- 不把真实 token 写进 `SKILL.md`
- 不把真实 token 写进 `examples/mineru.env` 或 `examples/mineru.json`
- 不把真实配置文件放进 `SelfMadeSkills\\convert-with-mineru\\`
- 不把 `MINERU_API_TOKEN` 当作本 skill 的认证变量
- 不把 `MINERU_TOKEN` 当作 MCP 的认证变量
- 不给 MCP 配置 `MINERU_MODEL` 或 `DEFAULT_MODEL`（这些变量不存在）
- 不把 `DEFAULT_OUTPUT_ROOT` / `KEEP_RAW_TREE` 描述成 MCP 配置项
