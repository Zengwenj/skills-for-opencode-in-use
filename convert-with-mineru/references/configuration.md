# Configuration

## 推荐方式

优先使用环境变量，尤其是 `MINERU_TOKEN`。

本 skill 的 MinerU 路径只使用精准解析 API（Precision API）。`MINERU_TOKEN` 会作为 Bearer Token 传给官方 `/api/v4/*` 接口；Agent 轻量解析 API、MCP `mineru_parse_documents`、flash/轻量路径都不是本 skill 的配置或 fallback 路径。

## 官方 API 事实

依据 `C:\Users\zengw\mineru-downloads\MinerU 文档解析接口文档_1.md`：

- 精准解析 API 需要 Bearer Token，本 skill 使用 `MINERU_TOKEN` 提供该 token。
- 精准解析 API endpoint 包括：`/api/v4/extract/task`（单文件 URL 任务）、`/api/v4/file-urls/batch`（本地批量上传申请链接）、`/api/v4/extract/task/batch`（URL 批量任务）、`/api/v4/extract-results/batch/{batch_id}`（批量结果查询）。
- 精准解析 API 支持批量；官方批量上限为 200 个，本地批量上传单次申请链接不超过 50 个。
- 精准解析 API 文件限制为 200MB / 200 页。
- `model_version` 官方默认是 `pipeline`，但本 skill 不依赖默认值：非 HTML 强制 `model_version: "vlm"`，HTML/HTM 强制 `model_version: "MinerU-HTML"`。
- Agent 轻量 API 位于 `/api/v1/agent/parse/url` 和 `/api/v1/agent/parse/file`，10MB / 20 页，固定 pipeline，无批量，仅 Markdown 输出；本 skill 不使用，也不得作为失败 fallback。

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

建议位置（opencode 标准 local 目录，跨用户通用）：
- Linux/macOS: `~/.config/opencode/local/mineru.env`
- Windows: `%USERPROFILE%\.config\opencode\local\mineru.env`
- 同目录的 `mineru.json` 是 JSON 等价写法

如果技能目录里为了本地验证暂时保留了 `mineru..env` 一类文件，也要把它视为隔离对象：
- 不把它写进 `SKILL.md` 示例
- 不把它当成推荐配置路径
- 不把它带进分发或打包产物

## `.env` 写法

```dotenv
MINERU_TOKEN=<在这里填写你的 MineU Token>
DEFAULT_OUTPUT_ROOT=
MINERU_AUDIT_DIR=
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
  "DEFAULT_OUTPUT_ROOT": "",
  "MINERU_AUDIT_DIR": ""
}
```

## 优先级

1. 命令行显式参数
2. 环境变量（`MINERU_TOKEN`、`DEFAULT_OUTPUT_ROOT`）
3. `--config` 指定的 `.env` 或 `.json`

说明：
- `--output-root` 未显式传入时，才会回退到 `DEFAULT_OUTPUT_ROOT`

## Token 变量差异

MinerU 生态中有两个不同的 token 变量，分别用于不同工具。本 skill 仅需要 `MINERU_TOKEN`：

| 变量 | 适用工具 | 说明 |
| --- | --- | --- |
| `MINERU_TOKEN` | **本 skill**、`mineru-open-api` CLI、Python/Go SDK | 命令行和 SDK 认证 |

以下为排障参考（非日常使用）：

| 变量 | 适用工具 | 说明 |
| --- | --- | --- |
| `MINERU_API_TOKEN` | 官方 MCP Server（`mineru-open-mcp`） | Agent 对话内工具调用认证 |

规则：
- 使用本 skill：只需配置 `MINERU_TOKEN`。
- 官方 MCP 如被单独使用，才涉及 `MINERU_API_TOKEN`；它不是本 skill 的认证变量。
- 不要把 `MINERU_TOKEN` 写进 MCP 的配置，反之亦然。
- MCP `mineru_parse_documents` 不是本 skill 的执行路径，也不是 Precision API 失败后的 fallback。

### MCP 可选环境变量（非本 skill 配置）

官方 MCP Server 还支持以下可选变量（与本 skill 无关，仅供了解）：
- `OUTPUT_DIR` — MCP 输出目录（默认 `~/mineru-downloads`）
- `MINERU_LOG_LEVEL` — MCP 日志级别

### 本 skill 专属配置

- `DEFAULT_OUTPUT_ROOT` — 本 skill 默认输出根目录
- `KEEP_RAW_TREE` — 是否保留原始目录树结构
- `MINERU_AUDIT_DIR` — 外部审计归档根目录（环境变量）；对应的配置文件键为 `AUDIT_DIR`
  - 默认行为：`<output_root>/../_review/mineru/<batch_id>/`
  - 审计目录保存完整 MinerU raw 输出和批量 `mineru_manifest.json`
- `DEFAULT_MODE` — 无效字段；`Settings` dataclass 只有 `token`、`default_output_root`、`keep_raw_tree`、`audit_dir` 四个字段，代码不读取 `DEFAULT_MODE`

这些变量只在本 skill 中有效，不是 MCP 配置项。

**注意**：本 skill 硬限制为仅精准模式（Precision API），不支持模式切换。`mineru.env` 里的 `DEFAULT_MODE=precision` 或 `DEFAULT_MODE=vlm/pipeline` 都会被 `Settings` 忽略，不能作为配置建议。所有 MinerU 路径都走 Precision API：非 HTML 使用 `model_version: "vlm"`，HTML/HTM 使用 `model_version: "MinerU-HTML"`，无需也无法通过配置改变。

## 模型选择规则

### 本 skill 模型行为

本 skill 通过 SDK 的 `client.extract_batch()` 调用 Precision API，显式传递 `model_version` 参数：
- 非 HTML 文件（PDF、DOCX、PPTX、图片等）→ `model_version="vlm"`
- HTML/HTM 文件 → `model_version="MinerU-HTML"`
- 混合输入按模型自动分批

### 非本 skill 路径

以下路径仅用于识别边界，不作为本 skill 的配置建议或 fallback：

| 路径 | 官方特征 | 本 skill 规则 |
| --- | --- | --- |
| MCP `mineru_parse_documents` | 使用官方 MCP Server，认证变量为 `MINERU_API_TOKEN` | 不使用；不得作为本 skill 的 MinerU 路径 |
| Agent 轻量 API `/api/v1/agent/parse/*` | 无需 token，10MB / 20 页，固定 pipeline，无批量，仅 Markdown | 禁止作为本 skill fallback |
| flash/轻量路径 | 轻量解析或对话内工具路径 | 禁止作为本 skill fallback |
| 官方默认 `pipeline` | `model_version` 省略时的默认模型 | 本 skill 必须显式覆盖为 `vlm` 或 `MinerU-HTML` |

**不要给本 skill 配置 `MINERU_API_TOKEN`、`MINERU_MODEL`、`DEFAULT_MODEL` 或 `DEFAULT_MODE` 来尝试切换模型或路径**；这些都不是本 skill 读取的有效配置。

## 禁止项

- 不把真实 token 写进 `SKILL.md`
- 不把真实 token 写进 `examples/mineru.env` 或 `examples/mineru.json`
- 不把真实配置文件放进 `SelfMadeSkills\\convert-with-mineru\\`
- 不把 `MINERU_API_TOKEN` 当作本 skill 的认证变量
- 不把 `MINERU_TOKEN` 当作 MCP 的认证变量
- 不给 MCP 配置 `MINERU_MODEL` 或 `DEFAULT_MODEL`（这些变量不存在）
- 不把 `DEFAULT_OUTPUT_ROOT` / `KEEP_RAW_TREE` 描述成 MCP 配置项
- 不把 MCP、Agent 轻量 API、flash 或默认 `pipeline` 描述成本 skill fallback
